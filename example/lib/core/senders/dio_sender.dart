/// The `dio` sender.
///
/// The richest Dart-side API of the four non-native clients: real per-request
/// options, upload and download progress out of the box, and its own cancel
/// token. What it does not have is a whole-request deadline — `sendTimeout` and
/// `receiveTimeout` are both idle timers — and no cookie jar without a second
/// package.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpClient, HttpHeaders;
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
// The IO adapter is a separate entry point, and it is how `dio` expects the
// underlying client to be configured on native platforms.
import 'package:dio/io.dart' show IOHttpClientAdapter;

import '../http_library.dart';
import '../http_sender.dart';
import '../request_spec.dart';
import '../sent_response.dart';
import 'sender_support.dart';

/// Sends through [dio.Dio].
final class DioSender implements HttpSender {
  /// Creates a sender. The `Dio` instance is built on first use.
  DioSender();

  /// One `Dio` per compression setting.
  ///
  /// `dio` has no `Accept-Encoding` switch of its own, but it does treat the
  /// adapter as configuration — so declining compression means an
  /// `IOHttpClientAdapter` over an `HttpClient` with `autoUncompress` off.
  /// That is a client-level object, hence two of them rather than one that
  /// gets mutated between sends.
  final Map<bool, dio.Dio> _clients = <bool, dio.Dio>{};

  /// The jar `dio` does not have without `dio_cookie_manager`. See [CookieJar].
  final CookieJar _jar = CookieJar();

  @override
  HttpLibrary get library => HttpLibrary.dio;

  @override
  SenderCapabilities get capabilities => dioCapabilities;

  @override
  Future<SendOutcome> send(
    RequestSpec spec, {
    required String baseUrl,
    void Function(SendProgress)? onProgress,
    Future<void>? cancel,
  }) async {
    final clock = Stopwatch()..start();
    final url = spec.resolve(baseUrl: baseUrl);
    if (url == null) {
      return _refused(spec, 'Not a valid URL: "${spec.url}".', clock);
    }
    final refusal = refuseReason(spec);
    if (refusal != null) return _refused(spec, refusal, clock);

    final token = dio.CancelToken();
    final abort = AbortSignal(
      // `dio` has no whole-request deadline of its own, so the deadline is a
      // timer that trips its cancel token. That is a real teardown, not a
      // `Future.timeout` that abandons a socket still draining in the
      // background.
      after: spec.totalTimeout,
      cancel: cancel,
      onAbort: () => token.cancel('aborted by the console'),
    );

    var sent = 0;
    var received = 0;
    int? sendTotal;
    int? receiveTotal;
    void emit() => onProgress?.call(
      SendProgress(
        sent: sent,
        received: received,
        sendTotal: sendTotal,
        receiveTotal: receiveTotal,
      ),
    );

    try {
      final headers = _headersOf(spec, url);
      final body = _bodyOf(spec, headers);
      final buffered = spec.responseMode == ResponseMode.buffered;

      final response = await _clientFor(spec).requestUri<Object?>(
        url,
        data: body,
        cancelToken: token,
        options: dio.Options(
          method: methodTokenOf(spec),
          headers: headers,
          responseType: buffered
              ? dio.ResponseType.bytes
              : dio.ResponseType.stream,
          followRedirects: spec.followRedirects,
          maxRedirects: spec.maxRedirects < 1 ? 1 : spec.maxRedirects,
          connectTimeout: spec.connectTimeout,
          // A 404 is a result the console has to show, and a benchmark row must
          // not abort because a fixture answered 500.
          validateStatus: (int? _) => true,
        ),
        onSendProgress: onProgress == null
            ? null
            : (int count, int total) {
                sent = count;
                sendTotal = total < 0 ? null : total;
                emit();
              },
        onReceiveProgress: onProgress == null
            ? null
            : (int count, int total) {
                received = count;
                receiveTotal = total < 0 ? null : total;
                emit();
              },
      );

      final stored = spec.sendCookies
          ? _jar.store(
              url,
              response.headers.map[HttpHeaders.setCookieHeader] ??
                  const <String>[],
            )
          : 0;

      final data = response.data;
      final Uint8List bytes;
      switch (data) {
        case dio.ResponseBody(:final stream, :final contentLength):
          bytes = await collectBody(
            stream,
            sentBytes: sent,
            sendTotal: sendTotal,
            receiveTotal: contentLength < 0 ? null : contentLength,
            onProgress: onProgress,
            abort: abort,
          );
        case final List<int> raw:
          bytes = Uint8List.fromList(raw);
        case null:
          bytes = Uint8List(0);
        default:
          // Unreachable while the response type stays bytes-or-stream, but a
          // silent empty body would be a nasty way to find out otherwise.
          bytes = Uint8List(0);
      }
      clock.stop();

      return SentResponse(
        library: library,
        spec: spec,
        statusCode: response.statusCode ?? 0,
        reasonPhrase: response.statusMessage ?? '',
        headers: <KeyValueRow>[
          for (final MapEntry(:key, :value) in response.headers.map.entries)
            for (final single in value) KeyValueRow(name: key, value: single),
        ],
        bodyBytes: bytes,
        timings: ResponseTimings(total: clock.elapsed),
        finalUrl: response.realUri.toString(),
        redirectCount: response.redirects.length,
        extras: _extrasOf(spec, response, stored),
      );
    } on dio.DioException catch (error) {
      clock.stop();
      return FailedSend(
        library: library,
        spec: spec,
        failure: SendFailure(
          kind: abort.kind ?? _kindOf(error),
          message: error.message ?? '${error.error ?? error}',
          elapsed: clock.elapsed,
        ),
      );
    } on Object catch (error) {
      clock.stop();
      return FailedSend(
        library: library,
        spec: spec,
        failure: SendFailure(
          kind: abort.kind ?? classifyIoFailure(error),
          message: '$error',
          elapsed: clock.elapsed,
        ),
      );
    } finally {
      abort.finish();
    }
  }

  @override
  Future<void> close() async {
    for (final client in _clients.values) {
      client.close(force: true);
    }
    _clients.clear();
    _jar.clear();
  }

  dio.Dio _clientFor(RequestSpec spec) =>
      _clients.putIfAbsent(spec.acceptEncoding, () {
        final client = dio.Dio();
        if (!spec.acceptEncoding) {
          client.httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () => HttpClient()..autoUncompress = false,
          );
        }
        return client;
      });

  Map<String, String> _headersOf(RequestSpec spec, Uri url) {
    final headers = headerMapOf(spec);
    if (spec.bodyKind != RequestBodyKind.multipart) {
      final type = contentTypeOf(spec);
      if (type != null) headers['Content-Type'] = type;
    }
    // The adapter above already stops the response from being decoded; this
    // asks the server not to compress in the first place. Both halves are
    // needed — a server that gzips anyway would otherwise arrive as bytes the
    // console cannot read.
    final encoding = acceptEncodingOverride(spec);
    if (encoding != null) headers[HttpHeaders.acceptEncodingHeader] = encoding;
    if (spec.sendCookies) {
      final cookies = _jar.headerFor(url);
      if (cookies != null && !headers.containsKey('cookie')) {
        headers['Cookie'] = cookies;
      }
    }
    return headers;
  }

  /// Builds the payload, writing `Content-Length` into [headers] for the
  /// streamed kinds.
  ///
  /// `dio` reads a stream body's length from that header and nowhere else; omit
  /// it and the upload silently becomes chunked, which is a different thing to
  /// be benchmarking.
  Object? _bodyOf(RequestSpec spec, Map<String, String> headers) {
    switch (spec.bodyKind) {
      case RequestBodyKind.none:
        return null;
      case RequestBodyKind.text:
      case RequestBodyKind.json:
        // A `Uint8List` is the one payload `dio` hands to the adapter
        // untouched. Anything else goes through the transformer, which would
        // re-encode the JSON the user typed into JSON of its own choosing.
        return utf8.encode(spec.bodyText);
      case RequestBodyKind.form:
        // `dio`'s own encoder, but applied here rather than by handing over a
        // Map: given a Map, `dio` picks an encoding from the content type, so
        // an overridden `Content-Type` would quietly turn a form body into a
        // JSON one. The Form body kind means url-encoded under every library.
        return utf8.encode(dio.Transformer.urlEncodeMap(formMapOf(spec)));
      case RequestBodyKind.generatedBytes:
        final length = generatedLengthOf(spec);
        headers[HttpHeaders.contentLengthHeader] = '$length';
        return generatedStreamOf(spec);
      case RequestBodyKind.file:
        final file = File(spec.filePath!);
        headers[HttpHeaders.contentLengthHeader] = '${file.lengthSync()}';
        return file.openRead();
      case RequestBodyKind.multipart:
        final form = dio.FormData();
        for (final part in enabledParts(spec)) {
          if (part.isFile) {
            form.files.add(
              MapEntry<String, dio.MultipartFile>(
                part.field,
                dio.MultipartFile.fromFileSync(
                  part.filePath!,
                  contentType: part.contentType == null
                      ? null
                      : dio.DioMediaType.parse(part.contentType!),
                ),
              ),
            );
          } else {
            form.fields.add(MapEntry<String, String>(part.field, part.value));
          }
        }
        return form;
    }
  }

  Map<String, String> _extrasOf(
    RequestSpec spec,
    dio.Response<Object?> response,
    int storedCookies,
  ) => <String, String>{
    'response mode': spec.responseMode.label.toLowerCase(),
    'adapter': response.requestOptions.extra['adapter']?.toString() ??
        'IOHttpClientAdapter (dart:io)',
    'protocol': 'not reported: dio surfaces nothing from the adapter',
    if (response.redirects.isNotEmpty)
      'redirect chain': response.redirects
          .map((dio.RedirectRecord hop) => '${hop.statusCode} ${hop.location}')
          .join(' → '),
    'cookie jar': spec.sendCookies
        ? '$storedCookies stored, ${_jar.length} held '
              '(app-side: a real dio jar is the separate dio_cookie_manager '
              'package)'
        : 'off for this request',
    if (spec.totalTimeout != null)
      'total timeout':
          'enforced by tripping dio\'s CancelToken on the deadline; dio has '
          'only sendTimeout and receiveTimeout, which are idle timers',
  };

  /// Maps `dio`'s one exception type onto the shared buckets through its
  /// [dio.DioExceptionType] tag.
  ///
  /// The tag is precise where it exists — three separate timeout kinds, a
  /// dedicated certificate kind — and useless for `connectionError` and
  /// `unknown`, both of which just carry whatever the adapter threw. Those two
  /// are handed to the shared `dart:io` classifier so a refused connection is
  /// bucketed the same way here as under every other sender.
  static SendFailureKind _kindOf(dio.DioException error) =>
      switch (error.type) {
        dio.DioExceptionType.connectionTimeout ||
        dio.DioExceptionType.sendTimeout ||
        dio.DioExceptionType.receiveTimeout ||
        dio.DioExceptionType.transformTimeout => SendFailureKind.timeout,
        dio.DioExceptionType.badCertificate => SendFailureKind.certificate,
        dio.DioExceptionType.cancel => SendFailureKind.cancelled,
        dio.DioExceptionType.connectionError => _fromCause(
          error.error,
          SendFailureKind.connection,
        ),
        // Only reachable if something rewrote `validateStatus`; a rejected
        // status is an answer from a live connection, not a transport failure.
        dio.DioExceptionType.badResponse => SendFailureKind.unknown,
        dio.DioExceptionType.unknown => _fromCause(
          error.error,
          SendFailureKind.unknown,
        ),
      };

  static SendFailureKind _fromCause(Object? cause, SendFailureKind fallback) {
    if (cause == null) return fallback;
    final classified = classifyIoFailure(cause);
    return classified == SendFailureKind.unknown ? fallback : classified;
  }

  FailedSend _refused(RequestSpec spec, String message, Stopwatch clock) =>
      FailedSend(
        library: library,
        spec: spec,
        failure: SendFailure(
          kind: SendFailureKind.unsupported,
          message: message,
          elapsed: clock.elapsed,
        ),
      );
}

/// What `dio` can do.
const SenderCapabilities dioCapabilities = SenderCapabilities(
  notes: <String, String>{
    'fileBodyWithoutHeap':
        'A file body is a Stream<List<int>> from File.openRead(), so nothing '
        'buffers the whole file, but every chunk is copied into the Dart heap '
        'on its way to the adapter.',
    'phaseTimings':
        'dio measures nothing. Its interceptor chain can time a whole request '
        'from Dart, but DNS, connect, TLS and time-to-first-byte all happen '
        'inside the adapter, which reports none of them.',
    'diskCache':
        'No cache in dio itself; dio_cache_interceptor is a separate package.',
    'contentTypeOverride':
        'Applied to every body kind except multipart, whose content type '
        'carries the generated boundary and so can only come from FormData.',
  },
);
