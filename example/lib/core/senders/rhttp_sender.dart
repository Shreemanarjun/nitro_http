/// The `rhttp` sender: Rust's `reqwest`, reached through
/// `flutter_rust_bridge`.
///
/// The other native client, and the one with the most awkward shape for a
/// console: almost everything a request wants to vary — timeouts, redirects,
/// cookies — is fixed on the *client*, and building a client is an async trip
/// across the bridge. Both are handled by caching one client per distinct
/// configuration instead of rebuilding on every send.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpHeaders;
import 'dart:typed_data';

import 'package:rhttp/rhttp.dart' as rhttp;

import '../http_library.dart';
import '../http_sender.dart';
import '../request_spec.dart';
import '../sent_response.dart';
import 'sender_support.dart';

/// Sends through [rhttp.RhttpClient].
final class RhttpSender implements HttpSender {
  /// Creates a sender. Nothing crosses the bridge until the first [send], so
  /// constructing one without the Rust library present is safe.
  RhttpSender();

  /// Clients keyed by everything `rhttp` fixes per client rather than per
  /// request: both timeouts, the redirect policy and the cookie jar.
  ///
  /// Futures rather than clients because `RhttpClient.create` is async — the
  /// map is the deduplication point, so two concurrent sends with the same
  /// configuration await one creation instead of racing to build two.
  final Map<String, Future<rhttp.RhttpClient>> _clients =
      <String, Future<rhttp.RhttpClient>>{};

  /// The bridge is process-wide and `RustLib.init` throws on a second call, so
  /// the guard has to outlive any one sender: the benchmark builds and closes a
  /// fresh sender per run.
  static Future<void>? _bridge;

  @override
  HttpLibrary get library => HttpLibrary.rhttp;

  @override
  SenderCapabilities get capabilities => rhttpCapabilities;

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

    final rhttp.RhttpClient client;
    try {
      client = await _clientFor(spec);
    } on Object catch (error) {
      // Either the Rust library is not in the process or the bridge refused to
      // start. Both mean no request will ever leave, and the loader's own words
      // are the only useful thing to show.
      clock.stop();
      return _refused(spec, '$error', clock);
    }

    final token = rhttp.CancelToken();
    final abort = AbortSignal(
      cancel: cancel,
      // `rhttp` owns the deadline through TimeoutSettings on the client, so the
      // signal only carries the caller's cancel. `CancelToken.cancel` is async
      // and never completes if no request ever picks the token up, so it is
      // deliberately not awaited here.
      onAbort: () => unawaited(token.cancel()),
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
      final buffered = spec.responseMode == ResponseMode.buffered;
      final headers = _headersOf(spec);
      final response = await client.request(
        method: rhttp.HttpMethod(methodTokenOf(spec)),
        url: url.toString(),
        headers: rhttp.HttpHeaders.rawMap(headers),
        body: _bodyOf(spec, headers),
        expectBody: buffered
            ? rhttp.HttpExpectBody.bytes
            : rhttp.HttpExpectBody.stream,
        cancelToken: token,
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

      final Uint8List bytes;
      switch (response) {
        case rhttp.HttpBytesResponse(:final body):
          bytes = body;
        case rhttp.HttpTextResponse(:final body):
          bytes = utf8.encode(body);
        case rhttp.HttpStreamResponse(:final body):
          bytes = await collectBody(
            body,
            sentBytes: sent,
            sendTotal: sendTotal,
            receiveTotal: receiveTotal,
            onProgress: onProgress,
            abort: abort,
          );
      }
      clock.stop();

      return SentResponse(
        library: library,
        spec: spec,
        statusCode: response.statusCode,
        // `rhttp` does not surface the reason phrase at all — not even over
        // HTTP/1.1, where the wire still carries one.
        reasonPhrase: '',
        headers: headerRowsOf(response.headers),
        bodyBytes: bytes,
        timings: ResponseTimings(total: clock.elapsed),
        httpVersion: _versionLabel(response.version),
        // Redirects are followed but never reported, so the request URL is the
        // only URL there is; claiming it is the final one would be a guess.
        finalUrl: url.toString(),
        extras: _extrasOf(spec, response),
      );
    } on rhttp.RhttpException catch (error) {
      clock.stop();
      return FailedSend(
        library: library,
        spec: spec,
        failure: SendFailure(
          kind: abort.kind ?? _kindOf(error),
          message: '$error',
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
    final pending = _clients.values.toList(growable: false);
    _clients.clear();
    for (final creation in pending) {
      try {
        (await creation).dispose(cancelRunningRequests: true);
      } on Object {
        // A client that never finished being created has nothing to dispose,
        // and a close() must not throw on the way out.
        continue;
      }
    }
  }

  Future<rhttp.RhttpClient> _clientFor(RequestSpec spec) {
    final key =
        'connect=${spec.connectTimeout?.inMicroseconds ?? -1},'
        'total=${spec.totalTimeout?.inMicroseconds ?? -1},'
        'redirects=${spec.followRedirects ? spec.maxRedirects : -1},'
        'cookies=${spec.sendCookies}';
    return _clients.putIfAbsent(key, () async {
      await (_bridge ??= _startBridge());
      return rhttp.RhttpClient.create(
        settings: rhttp.ClientSettings(
          // A 4xx is a result the console has to render, not an exception.
          throwOnStatusCode: false,
          cookieSettings: rhttp.CookieSettings(
            storeCookies: spec.sendCookies,
          ),
          redirectSettings: spec.followRedirects
              ? rhttp.RedirectSettings.limited(spec.maxRedirects)
              : const rhttp.RedirectSettings.none(),
          timeoutSettings: rhttp.TimeoutSettings(
            timeout: spec.totalTimeout,
            connectTimeout: spec.connectTimeout,
          ),
        ),
      );
    });
  }

  static Future<void> _startBridge() => rhttp.Rhttp.init().catchError((
    Object error,
  ) {
    // `flutter_rust_bridge` refuses a second initialisation rather than
    // no-opping, and this app is not the only thing in the process that may
    // have started it. A genuine load failure still propagates.
    if ('$error'.toLowerCase().contains('twice')) return;
    throw error;
  });

  Map<String, String> _headersOf(RequestSpec spec) {
    final headers = headerMapOf(spec);
    if (spec.bodyKind != RequestBodyKind.multipart) {
      final type = contentTypeOf(spec);
      if (type != null) headers['Content-Type'] = type;
    }
    // `reqwest` advertises whichever codings it was compiled with and `rhttp`
    // exposes no switch, so declining compression means saying so on the wire.
    final encoding = acceptEncodingOverride(spec);
    if (encoding != null) headers[HttpHeaders.acceptEncodingHeader] = encoding;
    return headers;
  }

  rhttp.HttpBody? _bodyOf(RequestSpec spec, Map<String, String> headers) {
    switch (spec.bodyKind) {
      case RequestBodyKind.none:
        return null;
      case RequestBodyKind.text:
      case RequestBodyKind.json:
        // Bytes, not `HttpBody.text`: the user's JSON goes out exactly as
        // typed, and the content type is already on the header map.
        return rhttp.HttpBody.bytes(utf8.encode(spec.bodyText));
      case RequestBodyKind.form:
        return rhttp.HttpBody.form(formMapOf(spec));
      case RequestBodyKind.generatedBytes:
        return rhttp.HttpBody.stream(
          generatedStreamOf(spec),
          length: generatedLengthOf(spec),
        );
      case RequestBodyKind.file:
        final file = File(spec.filePath!);
        return rhttp.HttpBody.stream(
          file.openRead(),
          length: file.lengthSync(),
        );
      case RequestBodyKind.multipart:
        // The list form, not the map form: a multipart body may legitimately
        // repeat a field name, and a `Map` would silently keep only the last.
        return rhttp.HttpBodyMultipart.list(<(String, rhttp.MultipartItem)>[
          for (final part in enabledParts(spec))
            (
              part.field,
              part.isFile
                  ? rhttp.MultipartItem.file(
                      file: part.filePath!,
                      contentType: part.contentType,
                    )
                  : rhttp.MultipartItem.text(
                      text: part.value,
                      contentType: part.contentType,
                    ),
            ),
        ]);
    }
  }

  Map<String, String> _extrasOf(RequestSpec spec, rhttp.HttpResponse response) {
    final ip = response.remoteIp;
    return <String, String>{
      'response mode': spec.responseMode.label.toLowerCase(),
      if (ip != null && ip.isNotEmpty) 'peer': ip,
      'reason phrase': 'not surfaced by rhttp, even over HTTP/1.1',
      'redirects': spec.followRedirects
          ? 'followed up to ${spec.maxRedirects}; rhttp reports neither the '
                'count nor the final URL'
          : 'not followed',
      'cookie jar': spec.sendCookies
          ? "reqwest's own jar, scoped to this client and not readable "
                'from Dart'
          : 'off for this request',
    };
  }

  static String _versionLabel(rhttp.HttpVersion version) => switch (version) {
    rhttp.HttpVersion.http09 => 'HTTP/0.9',
    rhttp.HttpVersion.http1_0 => 'HTTP/1.0',
    rhttp.HttpVersion.http1_1 => 'HTTP/1.1',
    rhttp.HttpVersion.http2 => 'HTTP/2',
    rhttp.HttpVersion.http3 => 'HTTP/3',
    rhttp.HttpVersion.other => 'HTTP/?',
  };

  /// Maps `rhttp`'s exception hierarchy onto the shared buckets.
  ///
  /// Chained `is` tests rather than a `switch`: [rhttp.RhttpException] is
  /// deliberately *not* sealed — the package documents it as open so callers
  /// can add their own — so the compiler cannot prove a switch exhaustive and
  /// there has to be a real fallback.
  static SendFailureKind _kindOf(rhttp.RhttpException error) {
    if (error is rhttp.RhttpCancelException) return SendFailureKind.cancelled;
    if (error is rhttp.RhttpClientDisposedException) {
      return SendFailureKind.cancelled;
    }
    if (error is rhttp.RhttpTimeoutException) return SendFailureKind.timeout;
    if (error is rhttp.RhttpInvalidCertificateException) {
      return SendFailureKind.certificate;
    }
    if (error is rhttp.RhttpConnectionException) {
      return SendFailureKind.connection;
    }
    // A redirect loop, a rejected status code and an interceptor blowing up are
    // all answers from a live connection rather than transport failures.
    return SendFailureKind.unknown;
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

/// What `rhttp` can do.
const SenderCapabilities rhttpCapabilities = SenderCapabilities(
  notes: <String, String>{
    'fileBodyWithoutHeap':
        'rhttp has no file body type outside multipart. A plain file body is '
        'HttpBody.stream over File.openRead(), so nothing buffers the whole '
        'file, but every chunk crosses the bridge from the Dart heap.',
    'phaseTimings':
        'rhttp surfaces no timings. reqwest measures phases internally; none '
        'of it is exposed across the bridge, and neither is the redirect count '
        'or the final URL after a redirect.',
    'diskCache': 'reqwest has no HTTP cache, and rhttp adds none.',
    'contentTypeOverride':
        'Applied to every body kind except multipart, whose content type is '
        'overwritten by rhttp with the boundary it generated.',
    'acceptEncoding':
        'Half honoured, like package:http. rhttp exposes no compression '
        'setting, so turning it off is a hand-written Accept-Encoding: '
        'identity header. reqwest decodes any Content-Encoding it was built to '
        'understand regardless, and that build flag is not reachable from '
        'Dart, so a server that compresses unbidden still arrives decoded.',
  },
);
