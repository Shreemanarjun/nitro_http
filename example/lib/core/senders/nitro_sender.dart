/// The `nitro_http` sender: this package, driving its own libcurl engine.
///
/// The only one of the five that can answer every field of a [RequestSpec]
/// without the sender inventing anything — including the phase breakdown, which
/// is the whole reason `ResponseTimings` has nullable fields at all.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:nitro_http/nitro_http.dart' as nitro;

import '../http_library.dart';
import '../http_sender.dart';
import '../request_spec.dart';
import '../sent_response.dart';
import 'sender_support.dart';

/// Sends through [nitro.NitroHttpClient].
final class NitroSender implements HttpSender {
  /// Creates a sender. No native call happens until the first [send], so
  /// constructing one on a machine with no engine built is safe.
  NitroSender();

  /// Clients keyed by the two settings `nitro_http` fixes per client rather
  /// than per request.
  ///
  /// Cookie participation and compression live on `ClientSettings`, but the
  /// console lets a user flip both between two sends. Keeping one client per
  /// combination — four at most — honours the spec without paying to build a
  /// client on every send, and without a mutable client that a concurrent
  /// benchmark row could reconfigure mid-flight.
  final Map<String, nitro.NitroHttpClient> _clients =
      <String, nitro.NitroHttpClient>{};

  @override
  HttpLibrary get library => HttpLibrary.nitroHttp;

  @override
  SenderCapabilities get capabilities => nitroCapabilities;

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

    final nitro.NitroHttpClient client;
    try {
      client = _clientFor(spec);
    } on Object catch (error) {
      // Constructing a client is itself an FFI call, so a missing or unbuilt
      // engine surfaces here rather than at request time. Reporting the
      // loader's own words is the only useful thing to do with it.
      return _refused(spec, '$error', clock);
    }

    final token = nitro.CancelToken();
    final abort = AbortSignal(
      cancel: cancel,
      onAbort: () => token.cancel('cancelled by the console'),
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
      final (method, customMethod) = _methodOf(methodTokenOf(spec));
      final request = nitro.HttpRequest(
        url: url,
        method: method,
        customMethod: customMethod,
        headers: _headersOf(spec),
        body: _bodyOf(spec),
        expectedBody: spec.responseMode == ResponseMode.streamed
            ? nitro.HttpExpectedBody.stream
            : nitro.HttpExpectedBody.bytes,
        options: nitro.RequestOptions(
          connectTimeout: spec.connectTimeout,
          timeout: spec.totalTimeout,
          followRedirects: spec.followRedirects,
          maxRedirects: spec.maxRedirects,
          wantTimings: true,
        ),
        cancelToken: token,
        onSendProgress: onProgress == null
            ? null
            : (int transferred, int? total) {
                sent = transferred;
                sendTotal = total;
                emit();
              },
        onReceiveProgress: onProgress == null
            ? null
            : (int transferred, int? total) {
                received = transferred;
                receiveTotal = total;
                emit();
              },
      );

      final response = await client.request(request);
      final Uint8List bytes;
      switch (response) {
        case nitro.HttpBytesResponse(:final bodyBytes):
          bytes = bodyBytes;
        case nitro.HttpTextResponse(:final bodyBytes):
          bytes = bodyBytes;
        case nitro.HttpStreamResponse(:final body, :final contentLength):
          bytes = await collectBody(
            body,
            sentBytes: sent,
            sendTotal: sendTotal,
            receiveTotal: contentLength,
            onProgress: onProgress,
            abort: abort,
          );
      }
      clock.stop();

      final timings = response.timings;
      return SentResponse(
        library: library,
        spec: spec,
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase,
        headers: headerRowsOf(response.headers.entries),
        bodyBytes: bytes,
        // A phase the engine reports as zero did not happen — no DNS on a warm
        // connection, no TLS over plain HTTP — so it is nulled here and drawn
        // as `—`. Reporting 0.0 ms would claim it happened instantly.
        timings: ResponseTimings(
          total: clock.elapsed,
          dns: _phase(timings.dns),
          connect: _phase(timings.connect),
          tls: _phase(timings.tls),
          firstByte: _phase(timings.firstByte),
        ),
        httpVersion: response.version.label,
        finalUrl: response.finalUrl.toString(),
        redirectCount: response.redirectCount,
        fromCache: response.fromCache,
        extras: _extrasOf(spec, response),
      );
    } on nitro.NitroHttpException catch (error) {
      clock.stop();
      return FailedSend(
        library: library,
        spec: spec,
        failure: SendFailure(
          kind: abort.kind ?? _kindOf(error),
          message: error.message,
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
      client.dispose();
    }
    _clients.clear();
  }

  nitro.NitroHttpClient _clientFor(RequestSpec spec) => _clients.putIfAbsent(
    'cookies=${spec.sendCookies},gzip=${spec.acceptEncoding}',
    () => nitro.NitroHttpClient(
      settings: nitro.ClientSettings(
        // A 404 is a result, not an error: the console has to show it, and a
        // benchmark row must not abort because a fixture answered 500.
        throwOnStatusCode: false,
        enableCompression: spec.acceptEncoding,
        cookieSettings: nitro.CookieSettings(storeCookies: spec.sendCookies),
        // The disk cache stays off: a cache hit would turn a latency
        // measurement into a measurement of the filesystem. The capability is
        // still declared, because the library really does have one.
        cacheSettings: const nitro.CacheSettings(),
      ),
    ),
  );

  nitro.HttpHeaders _headersOf(RequestSpec spec) {
    final headers = nitro.HttpHeaders.fromMap(headerMapOf(spec));
    // The engine only falls back to the body's own content type when no header
    // is set, so writing it here is what makes `contentTypeOverride` stick.
    // Multipart is exempt: its type carries the boundary the encoder generated.
    if (spec.bodyKind != RequestBodyKind.multipart) {
      final type = contentTypeOf(spec);
      if (type != null) headers.set('Content-Type', type);
    }
    // `enableCompression: false` on the client already omits `Accept-Encoding`.
    // Saying `identity` outright is stronger and keeps the wire identical to
    // what the other four senders put on it, so the comparison is of clients
    // rather than of five different requests.
    final encoding = acceptEncodingOverride(spec);
    if (encoding != null) headers.set('Accept-Encoding', encoding);
    return headers;
  }

  nitro.HttpBody? _bodyOf(RequestSpec spec) => switch (spec.bodyKind) {
    RequestBodyKind.none => null,
    // Text and JSON both go out as the exact bytes the user typed. Round-
    // tripping JSON through `HttpBody.json` would reformat it, and a console
    // that silently rewrites your payload is a console you cannot debug with.
    RequestBodyKind.text || RequestBodyKind.json => nitro.HttpBody.text(
      spec.bodyText,
    ),
    RequestBodyKind.form => nitro.HttpBody.form(formMapOf(spec)),
    RequestBodyKind.generatedBytes => nitro.HttpBody.stream(
      generatedStreamOf(spec),
      contentLength: generatedLengthOf(spec),
    ),
    // The one body the engine reads without it ever entering the Dart heap.
    RequestBodyKind.file => nitro.HttpBody.file(spec.filePath!),
    RequestBodyKind.multipart => nitro.HttpBody.multipart(<nitro.MultipartItem>[
      for (final part in enabledParts(spec))
        if (part.isFile)
          nitro.MultipartItem.file(
            part.field,
            part.filePath!,
            contentType: part.contentType,
          )
        else
          nitro.MultipartItem.text(part.field, part.value),
    ]),
  };

  Map<String, String> _extrasOf(RequestSpec spec, nitro.HttpResponse response) {
    final timings = response.timings;
    return <String, String>{
      'response mode': spec.responseMode.label.toLowerCase(),
      if (response.primaryIp.isNotEmpty)
        'peer': '${response.primaryIp}:${response.primaryPort}',
      'engine time': _ms(timings.total),
      if (timings.queue != Duration.zero) 'queued': _ms(timings.queue),
      if (timings.redirect != Duration.zero)
        'redirect hops took': _ms(timings.redirect),
      if (response.fromCache)
        'revalidated': response.revalidated ? 'yes (304)' : 'no',
      'disk cache': 'supported, off on this client so timings are the network',
      'cookie jar': spec.sendCookies ? 'engine jar' : 'off for this request',
    };
  }

  static Duration? _phase(Duration value) =>
      value == Duration.zero ? null : value;

  static String _ms(Duration value) =>
      '${(value.inMicroseconds / 1000).toStringAsFixed(2)} ms';

  static (nitro.HttpMethod, String?) _methodOf(String token) => switch (token) {
    'GET' => (nitro.HttpMethod.get, null),
    'HEAD' => (nitro.HttpMethod.head, null),
    'POST' => (nitro.HttpMethod.post, null),
    'PUT' => (nitro.HttpMethod.put, null),
    'DELETE' => (nitro.HttpMethod.delete, null),
    'PATCH' => (nitro.HttpMethod.patch, null),
    'OPTIONS' => (nitro.HttpMethod.options, null),
    'TRACE' => (nitro.HttpMethod.trace, null),
    _ => (nitro.HttpMethod.custom, token),
  };

  /// Maps the engine's sealed exception hierarchy onto the shared buckets.
  ///
  /// Exhaustive by construction — `NitroHttpException` is sealed, so a new
  /// variant in the plugin breaks this switch instead of quietly becoming
  /// "Error".
  static SendFailureKind _kindOf(nitro.NitroHttpException error) =>
      switch (error) {
        nitro.NitroHttpTimeoutException() => SendFailureKind.timeout,
        // Disposal cancels everything in flight, which is what the caller sees.
        nitro.NitroHttpCancelException() ||
        nitro.NitroHttpDisposedException() => SendFailureKind.cancelled,
        nitro.NitroHttpCertificateException() => SendFailureKind.certificate,
        nitro.NitroHttpConnectionException(:final failure) =>
          failure == nitro.ConnectionFailure.unsupportedScheme
              ? SendFailureKind.unsupported
              : SendFailureKind.connection,
        // A cache miss under `onlyIfCached` is a refusal to touch the network.
        nitro.NitroHttpCacheMissException() => SendFailureKind.unsupported,
        // Redirect limits, malformed HTTP, a body that would not decode and a
        // rejected status code are all real answers from a live connection, so
        // none of them is a transport failure.
        nitro.NitroHttpRedirectException() ||
        nitro.NitroHttpProtocolException() ||
        nitro.NitroHttpDecodingException() ||
        nitro.NitroHttpStatusCodeException() ||
        nitro.NitroHttpUnknownException() => SendFailureKind.unknown,
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

/// What `nitro_http` can do — which, uniquely here, is everything the console
/// can ask for.
const SenderCapabilities nitroCapabilities = SenderCapabilities(
  fileBodyWithoutHeap: true,
  phaseTimings: true,
  diskCache: true,
  notes: <String, String>{
    'contentTypeOverride':
        'Applied to every body kind except multipart, whose content type '
        'carries the generated boundary and so can only come from the encoder.',
    'acceptEncoding':
        'The advertising half is exact: enableCompression off omits '
        'Accept-Encoding, and this sender additionally sends identity. The '
        'decoding half is not switchable — a server that compresses anyway is '
        'still decoded by the engine, so a Content-Encoding you did not ask '
        'for arrives readable rather than as raw gzip. dart:io and dio can be '
        'made to hand the compressed bytes over; this cannot.',
  },
);
