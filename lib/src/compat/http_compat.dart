/// A `package:http` [http.BaseClient] backed by the native engine.
///
/// `package:http` ships inside `nitro_http` rather than as a separate package:
/// it is tiny, pure Dart, and already in nearly every app's dependency graph, so
/// bundling it costs approximately nothing and maximises the number of packages
/// that can be pointed at this transport with a one-line change.
///
/// ```dart
/// final client = NitroHttpCompatClient();
/// final res = await client.get(Uri.parse('https://example.com'));
/// ```
///
/// Correctness is verified against `package:http_client_conformance_tests` —
/// the same suite `cronet_http` and `cupertino_http` use.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api/body.dart';
import '../api/cancel_token.dart';
import '../api/client.dart';
import '../api/exceptions.dart';
import '../api/headers.dart';
import '../api/request.dart';
import '../api/settings.dart';

/// Requests whose length is unknown, or larger than this, take the streamed
/// path. Below it, buffering avoids the per-request credit-loop overhead for the
/// small-JSON case that dominates real traffic.
const int _kStreamThresholdBytes = 256 * 1024;

/// An `http.BaseClient` whose transport is the native engine.
class NitroHttpCompatClient extends http.BaseClient {
  /// Wraps a new client with [settings].
  ///
  /// `throwOnStatusCode` is forced off: `package:http` contract is that a 404 is
  /// a perfectly ordinary response, and callers check `statusCode` themselves.
  NitroHttpCompatClient({ClientSettings settings = const ClientSettings()})
    : _client = NitroHttpClient(
        settings: settings.copyWith(throwOnStatusCode: false),
      ),
      _ownsClient = true;

  /// Wraps an existing client. The caller keeps ownership: [close] will not
  /// dispose it.
  NitroHttpCompatClient.wrap(NitroHttpClient client)
    : _client = client,
      _ownsClient = false;

  final NitroHttpClient _client;
  final bool _ownsClient;
  var _closed = false;

  /// The underlying client, for cookie access and reconfiguration.
  NitroHttpClient get inner => _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }

    // Finalize before reading the headers, never the other way round:
    // `MultipartRequest` writes its `content-type` — boundary and all — inside
    // `finalize()`, and `Request`'s body setters rewrite it right up until the
    // request is locked. A snapshot taken earlier silently loses both.
    final byteStream = request.finalize();
    final contentLength = request.contentLength;

    final headers = HttpHeaders();
    request.headers.forEach(headers.set);

    final HttpBody? body;
    if (contentLength == 0) {
      body = null;
    } else if (contentLength != null && contentLength <= _kStreamThresholdBytes) {
      // Small and known: read it up front so the engine can send a real
      // Content-Length and reuse the connection without chunking.
      final bytes = await _collect(byteStream, contentLength);
      body = HttpBody.bytes(bytes);
    } else {
      body = HttpBody.stream(byteStream, contentLength: contentLength);
    }

    final method = _methodFor(request.method);
    final options = RequestOptions(
      followRedirects: request.followRedirects,
      maxRedirects: request.maxRedirects,
    );

    // `CancelToken` is exactly `http.Abortable`'s trigger with a different
    // name, so the two are wired together directly. Every request gets a token
    // even without one, because a closed client must abort its transfers.
    final token = CancelToken();
    _tokens.add(token);

    var abortedByTrigger = false;
    if (request case http.Abortable(abortTrigger: final trigger?)) {
      // Documented never to complete with an error.
      unawaited(
        trigger.then((_) {
          abortedByTrigger = true;
          token.cancel('aborted by abortTrigger');
        }),
      );
    }

    // Which cancellation this was is only known at throw time, so the mapper is
    // a closure over the flag rather than a static.
    http.ClientException toClientException(NitroHttpException error) =>
        switch (error) {
          // The suite matches this sentence exactly, and it is what `dart:io`,
          // `cronet_http` and `cupertino_http` all report, so it is the de
          // facto wording for a redirect overflow rather than a test-shaped
          // special case.
          NitroHttpRedirectException() => http.ClientException(
            'Redirect limit exceeded',
            request.url,
          ),
          NitroHttpCancelException() when abortedByTrigger =>
            http.RequestAbortedException(request.url),
          // Every other variant carries its own composed sentence, which is
          // all `package:http` can express.
          NitroHttpCancelException() ||
          NitroHttpTimeoutException() ||
          NitroHttpTlsException() ||
          NitroHttpConfigurationException() ||
          NitroHttpStatusCodeException() ||
          NitroHttpCertificateException() ||
          NitroHttpConnectionException() ||
          NitroHttpProtocolException() ||
          NitroHttpDecodingException() ||
          NitroHttpCacheMissException() ||
          NitroHttpDisposedException() ||
          NitroHttpUnknownException() => http.ClientException(
            error.message,
            request.url,
          ),
        };

    try {
      final response = await _client.requestStream(
        method,
        request.url.toString(),
        customMethod: method == HttpMethod.custom ? request.method : null,
        headers: headers,
        body: body,
        cancelToken: token,
        options: options,
      );

      return http.StreamedResponse(
        _mapBodyErrors(response.body, toClientException),
        response.statusCode,
        contentLength: response.contentLength,
        request: request,
        headers: _lowerCasedHeaderMap(response.headers),
        isRedirect: _isRedirectStatus(response.statusCode),
        persistentConnection: request.persistentConnection,
        // `''` means the protocol has no reason phrase (HTTP/2, HTTP/3) or the
        // server sent none; `package:http` spells that `null`.
        reasonPhrase: response.reasonPhrase.isEmpty
            ? null
            : response.reasonPhrase,
      );
    } on NitroHttpException catch (e) {
      // The conformance suite expects transport failures as ClientException.
      throw toClientException(e);
    } finally {
      _tokens.remove(token);
    }
  }

  /// A 3xx that reached the caller is a redirect the client did not follow —
  /// which is what `package:http` means by `isRedirect`. The engine's
  /// `redirectCount` answers the opposite question ("did we follow one?").
  ///
  /// 300, 304 and 305 are excluded: they are not `Location`-driven redirects.
  static bool _isRedirectStatus(int statusCode) => switch (statusCode) {
    301 || 302 || 303 || 307 || 308 => true,
    // Required: the subject is an int status code, not a closed type.
    _ => false,
  };

  /// `BaseResponse.headers` is contracted to be lower-case keyed, with repeated
  /// fields joined by `', '` — `HttpHeaders.toMap()` keeps the wire casing, so
  /// the map is built here rather than reused.
  static Map<String, String> _lowerCasedHeaderMap(HttpHeaders headers) {
    final map = <String, String>{};
    for (final (name, value) in headers.entries) {
      final lower = name.toLowerCase();
      final existing = map[lower];
      map[lower] = existing == null ? value : '$existing, $value';
    }
    return map;
  }

  /// A body can fail after the headers arrived — a truncated `Content-Length`
  /// is the common case — and `package:http` callers only ever catch
  /// [http.ClientException], so the stream is translated too.
  static Stream<List<int>> _mapBodyErrors(
    Stream<List<int>> body,
    http.ClientException Function(NitroHttpException) map,
  ) => body.handleError(
    (Object error, StackTrace stackTrace) =>
        Error.throwWithStackTrace(map(error as NitroHttpException), stackTrace),
    test: (error) => error is NitroHttpException,
  );

  final _tokens = <CancelToken>{};

  static Future<Uint8List> _collect(
    Stream<List<int>> stream,
    int expectedLength,
  ) async {
    final out = Uint8List(expectedLength);
    var offset = 0;
    await for (final chunk in stream) {
      if (offset + chunk.length > out.length) {
        // The declared length was wrong. Fall back to a growable copy rather
        // than truncating the body.
        final rest = <int>[...out.sublist(0, offset), ...chunk];
        await for (final more in stream) {
          rest.addAll(more);
        }
        return Uint8List.fromList(rest);
      }
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return offset == out.length ? out : Uint8List.sublistView(out, 0, offset);
  }

  static HttpMethod _methodFor(String method) => switch (method.toUpperCase()) {
    'GET' => HttpMethod.get,
    'HEAD' => HttpMethod.head,
    'POST' => HttpMethod.post,
    'PUT' => HttpMethod.put,
    'DELETE' => HttpMethod.delete,
    'PATCH' => HttpMethod.patch,
    'OPTIONS' => HttpMethod.options,
    'TRACE' => HttpMethod.trace,
    // Required: the subject is an arbitrary method string; anything the enum
    // does not name is sent verbatim as a custom method.
    _ => HttpMethod.custom,
  };

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final token in _tokens.toList()) {
      token.cancel('client closed');
    }
    _tokens.clear();
    if (_ownsClient) _client.dispose();
  }
}
