/// The `dart:io` sender: the SDK's own `HttpClient`, with no package between
/// it and the socket.
///
/// The baseline every other row in the benchmark is read against, and the one
/// that shows how much of a "library" is really just ergonomics: everything the
/// console asks for is reachable here, but multipart, cookies and a
/// whole-request deadline all have to be built by hand.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../http_library.dart';
import '../http_sender.dart';
import '../request_spec.dart';
import '../sent_response.dart';
import 'sender_support.dart';

/// Sends through `dart:io`'s [HttpClient].
final class DartIoSender implements HttpSender {
  /// Creates a sender. The first [send] opens the first client.
  DartIoSender();

  /// Clients keyed by the two knobs `HttpClient` exposes as mutable fields
  /// rather than per request.
  ///
  /// `connectionTimeout` and `autoUncompress` belong to the client, so honouring
  /// them per request either means mutating a shared client — which would let
  /// one benchmark row silently change another's timeout mid-flight — or
  /// keeping one client per combination. This is the second option.
  final Map<String, HttpClient> _clients = <String, HttpClient>{};

  /// The jar `HttpClient` does not have. See [CookieJar].
  final CookieJar _jar = CookieJar();

  @override
  HttpLibrary get library => HttpLibrary.dartIo;

  @override
  SenderCapabilities get capabilities => dartIoCapabilities;

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

    // Captured by the abort closure before it exists, so a cancel that arrives
    // during `openUrl` still tears down the request the moment there is one.
    HttpClientRequest? live;
    final abort = AbortSignal(
      after: spec.totalTimeout,
      cancel: cancel,
      onAbort: () => live?.abort(),
    );

    var sent = 0;
    int? sendTotal;

    try {
      final request = await _clientFor(spec).openUrl(methodTokenOf(spec), url);
      live = request;
      request
        ..followRedirects = spec.followRedirects
        // `maxRedirects` must stay positive even when nothing will be followed:
        // `HttpClient` asserts on a non-positive limit.
        ..maxRedirects = spec.maxRedirects < 1 ? 1 : spec.maxRedirects;
      _applyHeaders(request, spec, url);

      sendTotal = await _writeBody(
        request,
        spec,
        onProgress == null
            ? null
            : (int written) {
                sent = written;
                onProgress(
                  SendProgress(sent: sent, received: 0, sendTotal: sendTotal),
                );
              },
      );

      final response = await request.close();
      final stored = spec.sendCookies
          ? _jar.store(
              url,
              response.headers[HttpHeaders.setCookieHeader] ??
                  const <String>[],
            )
          : 0;
      final receiveTotal = response.contentLength < 0
          ? null
          : response.contentLength;
      final bytes = await collectBody(
        response,
        sentBytes: sent,
        sendTotal: sendTotal,
        receiveTotal: receiveTotal,
        onProgress: onProgress,
        abort: abort,
      );
      clock.stop();

      return SentResponse(
        library: library,
        spec: spec,
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase,
        headers: _responseHeaders(response),
        bodyBytes: bytes,
        timings: ResponseTimings(total: clock.elapsed),
        // Not read off the wire: `HttpClient` speaks HTTP/1.1 and nothing else,
        // so there is no negotiation to report and no field that reports one.
        httpVersion: 'HTTP/1.1',
        finalUrl: response.redirects.isEmpty
            ? url.toString()
            : response.redirects.last.location.toString(),
        redirectCount: response.redirects.length,
        extras: _extrasOf(spec, response, stored),
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

  HttpClient _clientFor(RequestSpec spec) {
    final key =
        'connect=${spec.connectTimeout?.inMicroseconds ?? -1},'
        'gzip=${spec.acceptEncoding}';
    return _clients.putIfAbsent(key, () {
      // `autoUncompress` controls only the *decoding* half. `HttpClient`
      // appends `Accept-Encoding: gzip` to every request unconditionally —
      // see `_HttpClientRequest` in the SDK — so turning the flag off without
      // also rewriting the header just means the reply arrives compressed and
      // undecodable. `_applyHeaders` handles the advertising half.
      final client = HttpClient()..autoUncompress = spec.acceptEncoding;
      final connect = spec.connectTimeout;
      if (connect != null) client.connectionTimeout = connect;
      return client;
    });
  }

  void _applyHeaders(HttpClientRequest request, RequestSpec spec, Uri url) {
    final headers = headerMapOf(spec);
    if (spec.bodyKind != RequestBodyKind.multipart) {
      final type = contentTypeOf(spec);
      if (type != null) headers['Content-Type'] = type;
    }
    // The other half of `acceptEncoding`. `set` rather than `add`, because the
    // SDK has already put `gzip` on the request and this has to replace it.
    final encoding = acceptEncodingOverride(spec);
    if (encoding != null) {
      headers[HttpHeaders.acceptEncodingHeader] = encoding;
    }
    if (spec.sendCookies && !headers.containsKey('cookie')) {
      final cookies = _jar.headerFor(url);
      if (cookies != null) headers['Cookie'] = cookies;
    }
    headers.forEach(request.headers.set);
  }

  /// Writes the body and returns its length, or null when it was chunked.
  Future<int?> _writeBody(
    HttpClientRequest request,
    RequestSpec spec,
    void Function(int written)? report,
  ) async {
    Future<int?> pump(Stream<List<int>> source, int? length) async {
      if (length != null) request.contentLength = length;
      var written = 0;
      await request.addStream(
        source.map((List<int> chunk) {
          written += chunk.length;
          report?.call(written);
          return chunk;
        }),
      );
      return length;
    }

    Future<int?> buffered(Uint8List bytes) async {
      request
        ..contentLength = bytes.length
        ..add(bytes);
      report?.call(bytes.length);
      return bytes.length;
    }

    switch (spec.bodyKind) {
      case RequestBodyKind.none:
        // Stated explicitly, because an unset length makes `dart:io` reach for
        // chunked transfer encoding on a request that has nothing to chunk.
        request.contentLength = 0;
        return 0;
      case RequestBodyKind.text:
      case RequestBodyKind.json:
        return buffered(utf8.encode(spec.bodyText));
      case RequestBodyKind.form:
        return buffered(utf8.encode(encodedFormOf(spec)));
      case RequestBodyKind.generatedBytes:
        return pump(generatedStreamOf(spec), generatedLengthOf(spec));
      case RequestBodyKind.file:
        final file = File(spec.filePath!);
        return pump(file.openRead(), await file.length());
      case RequestBodyKind.multipart:
        final payload = MultipartPayload.of(spec);
        request.headers.set(HttpHeaders.contentTypeHeader, payload.contentType);
        return pump(payload.open(), await payload.contentLength());
    }
  }

  static List<KeyValueRow> _responseHeaders(HttpClientResponse response) {
    final rows = <KeyValueRow>[];
    response.headers.forEach((String name, List<String> values) {
      for (final value in values) {
        rows.add(KeyValueRow(name: name, value: value));
      }
    });
    return rows;
  }

  Map<String, String> _extrasOf(
    RequestSpec spec,
    HttpClientResponse response,
    int storedCookies,
  ) => <String, String>{
    'response mode': spec.responseMode.label.toLowerCase(),
    'connection': response.persistentConnection ? 'keep-alive' : 'close',
    'body encoding': switch (response.compressionState) {
      HttpClientResponseCompressionState.notCompressed => 'identity',
      HttpClientResponseCompressionState.decompressed =>
        'gzip, decoded by HttpClient',
      HttpClientResponseCompressionState.compressed =>
        'compressed, handed over encoded',
    },
    if (response.redirects.isNotEmpty)
      'redirect chain': response.redirects
          .map((RedirectInfo hop) => '${hop.statusCode} ${hop.location}')
          .join(' → '),
    'cookie jar': spec.sendCookies
        ? '$storedCookies stored, ${_jar.length} held '
              '(app-side: HttpClient keeps none)'
        : 'off for this request',
    if (spec.totalTimeout != null)
      'total timeout': 'enforced by the sender via HttpClientRequest.abort(); '
          'HttpClient has only a connect timeout of its own',
  };

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

/// What `dart:io`'s `HttpClient` can do once the missing pieces are built by
/// hand.
const SenderCapabilities dartIoCapabilities = SenderCapabilities(
  notes: <String, String>{
    'fileBodyWithoutHeap':
        'HttpClient has no file body: the file is streamed with '
        'File.openRead(), so nothing buffers the whole thing, but every chunk '
        'is copied into the Dart heap on its way to the socket. Only '
        'nitro_http hands the path to its engine and skips the VM entirely.',
    'phaseTimings':
        'HttpClient exposes no timing hooks — not DNS, not connect, not even '
        'time to first byte — so the wall-clock total is the only honest '
        'number here.',
    'diskCache':
        'dart:io has no HTTP cache. Cache-Control on a response is data you '
        'can read, not behaviour you get.',
    'contentTypeOverride':
        'Applied to every body kind except multipart, whose content type '
        'carries the generated boundary and so can only come from the encoder.',
  },
);
