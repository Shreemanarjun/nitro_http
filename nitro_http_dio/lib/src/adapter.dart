/// The `dio` [HttpClientAdapter] backed by `nitro_http`'s native engine.
library;

import 'dart:async';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:nitro_http/nitro_http.dart' as nh;

/// The `RequestOptions.extra` key that selects a [nh.CacheMode] for one
/// request.
///
/// The value may be a [nh.CacheMode] or the `name` of one as a [String], so a
/// caller that does not want to import `nitro_http` can still reach the cache:
///
/// ```dart
/// await dio.get<String>(
///   '/feed',
///   options: Options(extra: {nitroHttpCacheModeKey: 'onlyIfCached'}),
/// );
/// ```
const String nitroHttpCacheModeKey = 'nitroHttp.cacheMode';

/// Routes every `dio` request through a [nh.NitroHttpClient].
///
/// ```dart
/// final dio = Dio()..httpClientAdapter = NitroHttpDioAdapter();
/// ```
///
/// The adapter is deliberately thin: it translates [RequestOptions] into an
/// [nh.HttpRequest], always takes the engine's **streamed** path, and hands the
/// body stream straight back to dio. Collecting that stream into bytes, JSON or
/// a file, validating the status code, and reporting progress all happen in
/// dio's own layers above this class, so nothing here duplicates them.
///
/// Two layers of interceptors exist once this adapter is installed: dio's run
/// above it, `nitro_http`'s run below. Neither can see the other's rewrites.
class NitroHttpDioAdapter implements HttpClientAdapter {
  /// Creates an adapter.
  ///
  /// With no [client] the adapter builds and owns one from [settings], and
  /// [close] disposes it. Pass [client] to share an existing client — the
  /// adapter then borrows it and [close] leaves it running.
  ///
  /// A borrowed client should be configured with `throwOnStatusCode: false`;
  /// dio's own `validateStatus` decides what counts as a failure, and a client
  /// that also throws turns a 404 into a [DioExceptionType.badResponse] with no
  /// [Response] attached. An owned client gets that setting forced.
  NitroHttpDioAdapter({
    nh.ClientSettings settings = const nh.ClientSettings(),
    nh.NitroHttpClient? client,
  }) : _ownsClient = client == null,
       _client = client ?? _buildOwnedClient(settings);

  /// Test seam: overrides how an adapter builds the client it owns.
  ///
  /// The default builds a real [nh.NitroHttpClient], whose executor binds to
  /// the native library the moment it is constructed. Setting this lets a test
  /// inject `nitro_http`'s `RequestExecutor` / `StreamDemux` fakes and exercise
  /// the owned-client path — including disposal on [close] — with no engine
  /// present. The settings handed to the factory are the ones the adapter would
  /// have used, forced flags included. Reset it to `null` afterwards.
  static nh.NitroHttpClient Function(nh.ClientSettings settings)?
  clientFactoryForTesting;

  static nh.NitroHttpClient _buildOwnedClient(nh.ClientSettings settings) {
    // dio owns status validation. Letting the engine throw as well would raise
    // a NitroHttpStatusCodeException before dio's `validateStatus` ever runs,
    // and would buffer every error body out of the streamed path to fill that
    // exception.
    final forDio = settings.copyWith(throwOnStatusCode: false);
    final factory = clientFactoryForTesting;
    return factory == null
        ? nh.NitroHttpClient(settings: forDio)
        : factory(forDio);
  }

  final nh.NitroHttpClient _client;
  final bool _ownsClient;

  /// One token per in-flight request, so [close] can abort exactly the
  /// transfers this adapter started — never a borrowed client's other work.
  final Set<nh.CancelToken> _pending = <nh.CancelToken>{};

  bool _closed = false;
  bool _disposeWhenIdle = false;

  /// The client this adapter sends through.
  ///
  /// Exposed so cookies, `cancelAll` and reconfiguration remain reachable on an
  /// adapter-owned client.
  nh.NitroHttpClient get client => _client;

  /// Whether this adapter created [client] and will dispose it on [close].
  bool get ownsClient => _ownsClient;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) {
      throw StateError(
        "Can't establish connection after the adapter was closed.",
      );
    }

    // Resolve before anything is allocated: a typo in `extra` is a programming
    // error and should surface without a socket being opened.
    final cacheMode = _cacheModeOf(options);

    final token = nh.CancelToken();
    // This is why the engine takes a token rather than a bare Future: dio only
    // reports cancellation as a Future, and the engine needs a signal it can
    // register a listener on to abort a transfer already on the wire.
    unawaited(
      cancelFuture?.whenComplete(() => token.cancel('cancelled by dio')),
    );
    _pending.add(token);

    final method = _methodOf(options.method);
    final request = nh.HttpRequest(
      method: method,
      // Carries the verb verbatim, so `PROPFIND` reaches the wire with the
      // casing dio was given.
      customMethod: method == nh.HttpMethod.custom ? options.method : null,
      // dio has already merged its own `baseUrl` and query parameters into
      // `uri`. Handing the engine the absolute URL keeps `ClientSettings
      // .baseUrl` from resolving it a second time.
      url: options.uri,
      headers: _requestHeaders(options),
      body: requestStream == null
          ? null
          : nh.HttpBody.stream(
              requestStream,
              contentLength: _declaredContentLength(options),
            ),
      // Always streamed: dio decides whether the caller wanted bytes, a string
      // or JSON, and buffering here would defeat `ResponseType.stream`.
      expectedBody: nh.HttpExpectedBody.stream,
      options: nh.RequestOptions(
        connectTimeout: _positive(options.connectTimeout),
        // dio's `sendTimeout` has no separate engine deadline; libcurl times
        // the whole transfer, so upload stalls are covered by this one.
        timeout: _positive(options.receiveTimeout),
        followRedirects: options.followRedirects,
        maxRedirects: options.maxRedirects,
        cacheMode: cacheMode,
      ),
      cancelToken: token,
      // No progress callbacks by design. dio wraps the request stream with its
      // own send-progress transformer and the returned response stream with its
      // own receive-progress handler, so wiring the engine's events here would
      // fire every user callback twice. It also leaves `reportProgress` false
      // on the wire, which suppresses native XFERINFO emission entirely.
    );

    nh.HttpStreamResponse response;
    try {
      response = await _client.request(request) as nh.HttpStreamResponse;
    } on nh.NitroHttpException catch (error, stackTrace) {
      _release(token);
      throw _toDioException(error, options, stackTrace);
    } on Object {
      _release(token);
      rethrow;
    }

    return ResponseBody(
      _trackBody(response.body, token, options),
      response.statusCode,
      headers: _responseHeaders(response.headers),
      isRedirect: _isRedirect(response),
      // HTTP/2 and HTTP/3 dropped the reason phrase from the protocol, so the
      // engine reports `''` for them. dio derives a phrase from the status code
      // when this is null, which is better than handing it an empty string.
      statusMessage: response.reasonPhrase.isEmpty
          ? null
          : response.reasonPhrase,
    );
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;

    if (force) {
      // Copy first: cancelling completes the request, which mutates `_pending`.
      for (final token in List<nh.CancelToken>.of(_pending)) {
        token.cancel('the dio adapter was closed');
      }
    }

    if (!_ownsClient) return;
    if (_pending.isEmpty) {
      _client.dispose();
    } else {
      // A non-forced close lets in-flight transfers finish, so the client has
      // to outlive this call.
      _disposeWhenIdle = true;
    }
  }

  // ── Request mapping ────────────────────────────────────────────────────────

  static const Map<String, nh.HttpMethod> _knownMethods =
      <String, nh.HttpMethod>{
        'GET': nh.HttpMethod.get,
        'HEAD': nh.HttpMethod.head,
        'POST': nh.HttpMethod.post,
        'PUT': nh.HttpMethod.put,
        'DELETE': nh.HttpMethod.delete,
        'PATCH': nh.HttpMethod.patch,
        'OPTIONS': nh.HttpMethod.options,
        'TRACE': nh.HttpMethod.trace,
      };

  static nh.HttpMethod _methodOf(String method) =>
      _knownMethods[method.toUpperCase()] ?? nh.HttpMethod.custom;

  /// Copies `options.headers` into engine headers.
  ///
  /// Values are stringified the way `dart:io`'s `HttpHeaders.set` does it —
  /// which is what dio's own adapter delegates to — so switching adapters
  /// cannot change what goes on the wire: `null` drops the field, an
  /// [Iterable] becomes one field per element, a [DateTime] becomes an
  /// HTTP-date, and anything else gets `toString()`.
  static nh.HttpHeaders _requestHeaders(RequestOptions options) {
    final headers = nh.HttpHeaders();
    options.headers.forEach((String name, dynamic value) {
      if (value == null) return;
      if (value is Iterable) {
        for (final Object? item in value) {
          if (item == null) continue;
          headers.add(name, _headerValue(item));
        }
      } else {
        headers.add(name, _headerValue(value as Object));
      }
    });
    return headers;
  }

  static String _headerValue(Object value) => switch (value) {
    String() => value,
    DateTime() => HttpDate.format(value),
    // Required: dio types header values as `Object`, an open universe.
    _ => value.toString(),
  };

  /// The `Content-Length` dio declared, or `null` when it did not.
  ///
  /// Without it the engine sends `Transfer-Encoding: chunked`, which is right
  /// for a body whose size nobody knows.
  static int? _declaredContentLength(RequestOptions options) {
    final declared = options.headers[Headers.contentLengthHeader];
    if (declared == null) return null;
    return declared is int ? declared : int.tryParse(declared.toString());
  }

  /// dio spells "no deadline" as both `null` and [Duration.zero]; the engine
  /// spells it `null`.
  static Duration? _positive(Duration? timeout) =>
      timeout == null || timeout <= Duration.zero ? null : timeout;

  static nh.CacheMode? _cacheModeOf(RequestOptions options) {
    final Object? raw = options.extra[nitroHttpCacheModeKey];
    if (raw == null) return null;
    if (raw is nh.CacheMode) return raw;
    if (raw is String) {
      for (final mode in nh.CacheMode.values) {
        if (mode.name == raw) return mode;
      }
      throw ArgumentError.value(
        raw,
        "extra['$nitroHttpCacheModeKey']",
        'not one of ${nh.CacheMode.values.map((m) => m.name).join(', ')}',
      );
    }
    throw ArgumentError.value(
      raw,
      "extra['$nitroHttpCacheModeKey']",
      'must be a CacheMode or its name as a String',
    );
  }

  // ── Response mapping ───────────────────────────────────────────────────────

  /// Flattens engine headers into dio's shape **without folding duplicates**.
  ///
  /// `HttpHeaders.toMap()` joins repeated fields with `', '`, which corrupts
  /// `Set-Cookie`: an `Expires` attribute contains a comma, so the joined value
  /// cannot be split apart again.
  static Map<String, List<String>> _responseHeaders(nh.HttpHeaders headers) {
    final map = <String, List<String>>{};
    for (final name in headers.names) {
      map[name] = List<String>.of(headers.getAll(name));
    }
    return map;
  }

  /// Whether dio should mark this response as a redirect.
  ///
  /// True when the engine followed at least one hop, and also when it did not
  /// follow but the server pointed elsewhere — otherwise `followRedirects:
  /// false` would report a plain 302 as a non-redirect.
  static bool _isRedirect(nh.HttpStreamResponse response) =>
      response.redirectCount > 0 ||
      (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          response.headers.location != null);

  /// Forwards body chunks to dio, mapping a mid-transfer failure and releasing
  /// the request when the stream ends for any reason — done, error, or the
  /// consumer walking away.
  Stream<Uint8List> _trackBody(
    Stream<List<int>> source,
    nh.CancelToken token,
    RequestOptions options,
  ) async* {
    try {
      await for (final chunk in source) {
        yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      }
    } on nh.NitroHttpException catch (error, stackTrace) {
      throw _toDioException(error, options, stackTrace);
    } finally {
      _release(token);
    }
  }

  void _release(nh.CancelToken token) {
    if (!_pending.remove(token)) return;
    if (_disposeWhenIdle && _pending.isEmpty) {
      _disposeWhenIdle = false;
      _client.dispose();
    }
  }

  // ── Error mapping ──────────────────────────────────────────────────────────

  static DioException _toDioException(
    nh.NitroHttpException error,
    RequestOptions options,
    StackTrace stackTrace,
  ) => DioException(
    requestOptions: options,
    type: dioExceptionTypeOf(error),
    error: error,
    message: error.message,
    stackTrace: error.stackTrace ?? stackTrace,
  );
}

/// The [DioExceptionType] that best describes [error].
///
/// Exhaustive over the sealed [nh.NitroHttpException] hierarchy, so a new
/// failure kind in `nitro_http` breaks this switch instead of silently
/// arriving as [DioExceptionType.unknown].
DioExceptionType dioExceptionTypeOf(nh.NitroHttpException error) =>
    switch (error) {
      nh.NitroHttpTimeoutException(:final stage) => switch (stage) {
        // The engine has one deadline for the whole transfer, so a request or
        // idle timeout is reported as dio's receive timeout. dio's
        // `sendTimeout` is never produced here — see the README.
        nh.TimeoutStage.connect => DioExceptionType.connectionTimeout,
        nh.TimeoutStage.request ||
        nh.TimeoutStage.idle => DioExceptionType.receiveTimeout,
      },
      nh.NitroHttpCancelException() => DioExceptionType.cancel,
      // dio has one TLS bucket, so a rejected chain and a handshake that never
      // produced one share it; a refused configuration is not a transport
      // fault at all and stays `unknown`.
      nh.NitroHttpCertificateException() ||
      nh.NitroHttpTlsException() => DioExceptionType.badCertificate,
      nh.NitroHttpConfigurationException() => DioExceptionType.unknown,
      nh.NitroHttpConnectionException() => DioExceptionType.connectionError,
      // Only reachable through a borrowed client left on
      // `throwOnStatusCode: true`; an adapter-owned client never throws these.
      nh.NitroHttpStatusCodeException() => DioExceptionType.badResponse,
      nh.NitroHttpRedirectException() ||
      nh.NitroHttpProtocolException() ||
      nh.NitroHttpDecodingException() ||
      nh.NitroHttpCacheMissException() ||
      nh.NitroHttpDisposedException() ||
      nh.NitroHttpUnknownException() => DioExceptionType.unknown,
    };
