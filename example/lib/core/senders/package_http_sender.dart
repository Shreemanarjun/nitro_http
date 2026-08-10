/// The `package:http` sender.
///
/// The smallest API of the five, and the one whose limits are the most
/// interesting: it is a portable *interface* over whatever client the platform
/// supplies, so anything not expressible everywhere — a connect timeout, a
/// redirect count, a negotiated protocol — is simply absent from the API, even
/// though the `dart:io` client underneath knows all three.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpHeaders;

import 'package:http/http.dart' as http;

import '../http_library.dart';
import '../http_sender.dart';
import '../request_spec.dart';
import '../sent_response.dart';
import 'sender_support.dart';

/// Sends through [http.Client].
final class PackageHttpSender implements HttpSender {
  /// Creates a sender. The client is built on first use.
  PackageHttpSender();

  /// One client, reused. `package:http`'s entire configuration surface is the
  /// client object you pass in, so unlike the other senders there is nothing
  /// per-request left to key a cache on.
  http.Client? _client;

  /// The jar `package:http` does not have. See [CookieJar].
  final CookieJar _jar = CookieJar();

  @override
  HttpLibrary get library => HttpLibrary.packageHttp;

  @override
  SenderCapabilities get capabilities => packageHttpCapabilities;

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

    // `Abortable.abortTrigger` is a future rather than a callback, so the
    // signal's only job here is to complete it. `IOClient` does the rest: it
    // aborts the socket before the response arrives, and injects a
    // `RequestAbortedException` into the body stream after it.
    final trigger = Completer<void>();
    final abort = AbortSignal(
      after: spec.totalTimeout,
      cancel: cancel,
      onAbort: () {
        if (!trigger.isCompleted) trigger.complete();
      },
    );

    var sent = 0;
    int? sendTotal;

    try {
      final request = _buildRequest(
        spec,
        url,
        trigger.future,
        onProgress == null
            ? null
            : (int written) {
                sent = written;
                onProgress(
                  SendProgress(sent: sent, received: 0, sendTotal: sendTotal),
                );
              },
      );
      _applyHeaders(request, spec, url);
      request
        ..followRedirects = spec.followRedirects
        // A non-positive limit is rejected downstream even when nothing will be
        // followed, so the floor stays at one.
        ..maxRedirects = spec.maxRedirects < 1 ? 1 : spec.maxRedirects;
      sendTotal = request.contentLength;

      final response = await (_client ??= http.Client()).send(request);
      // `headers` folds repeats with commas, which corrupts `Set-Cookie` dates;
      // `headersSplitValues` is the accessor that knows the difference.
      final split = response.headersSplitValues;
      final stored = spec.sendCookies
          ? _jar.store(url, split['set-cookie'] ?? const <String>[])
          : 0;

      final bytes = switch (spec.responseMode) {
        // Buffered runs through `package:http`'s own collector, which is what
        // nearly every app using this package actually calls.
        ResponseMode.buffered =>
          (await http.Response.fromStream(response)).bodyBytes,
        ResponseMode.streamed => await collectBody(
          response.stream,
          sentBytes: sent,
          sendTotal: sendTotal,
          receiveTotal: response.contentLength,
          onProgress: onProgress,
          abort: abort,
        ),
      };
      clock.stop();

      return SentResponse(
        library: library,
        spec: spec,
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase ?? '',
        headers: <KeyValueRow>[
          for (final MapEntry(:key, :value) in split.entries)
            for (final single in value) KeyValueRow(name: key, value: single),
        ],
        bodyBytes: bytes,
        timings: ResponseTimings(total: clock.elapsed),
        // `httpVersion` is left null on purpose: `package:http` has no field
        // for the negotiated protocol, and inferring HTTP/1.1 from the
        // `dart:io` client that happens to back it today would be inventing
        // data the library never gave us.
        finalUrl: switch (response) {
          http.BaseResponseWithUrl(url: final resolved) => resolved.toString(),
          _ => url.toString(),
        },
        extras: _extrasOf(spec, response, stored),
      );
    } on Object catch (error) {
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
    } finally {
      abort.finish();
    }
  }

  @override
  Future<void> close() async {
    _client?.close();
    _client = null;
    _jar.clear();
  }

  http.BaseRequest _buildRequest(
    RequestSpec spec,
    Uri url,
    Future<void> trigger,
    void Function(int written)? report,
  ) {
    final method = methodTokenOf(spec);
    switch (spec.bodyKind) {
      case RequestBodyKind.none:
        return _CountedRequest(method, url, trigger, report);
      case RequestBodyKind.text:
      case RequestBodyKind.json:
        // `bodyBytes`, not `body`: the string setter rewrites `Content-Type` to
        // append a charset, and a console has to send the bytes and the header
        // the user asked for, not an improved version of them.
        return _CountedRequest(method, url, trigger, report)
          ..bodyBytes = utf8.encode(spec.bodyText);
      case RequestBodyKind.form:
        // Set before the headers are applied: `bodyFields` refuses to encode
        // into a request whose content type is already something else, and
        // `contentTypeOverride` is allowed to be something else.
        return _CountedRequest(method, url, trigger, report)
          ..bodyFields = formMapOf(spec);
      case RequestBodyKind.generatedBytes:
        return _CountedStreamRequest(
          method,
          url,
          trigger,
          report,
          generatedStreamOf(spec),
          generatedLengthOf(spec),
        );
      case RequestBodyKind.file:
        final path = spec.filePath!;
        return _CountedStreamRequest(
          method,
          url,
          trigger,
          report,
          File(path).openRead(),
          File(path).lengthSync(),
        );
      case RequestBodyKind.multipart:
        final request = _CountedMultipart(method, url, trigger, report);
        for (final part in enabledParts(spec)) {
          if (part.isFile) {
            request.files.add(_multipartFile(part.field, part.filePath!, part));
          } else {
            request.fields[part.field] = part.value;
          }
        }
        return request;
    }
  }

  void _applyHeaders(http.BaseRequest request, RequestSpec spec, Uri url) {
    final headers = headerMapOf(spec);
    if (spec.bodyKind != RequestBodyKind.multipart) {
      final type = contentTypeOf(spec);
      if (type != null) headers['Content-Type'] = type;
    }
    // Half of what `acceptEncoding: false` means. The request side works —
    // this header goes out as sent — but the response side does not: see
    // `notes['acceptEncoding']`.
    final encoding = acceptEncodingOverride(spec);
    if (encoding != null) headers[HttpHeaders.acceptEncodingHeader] = encoding;
    if (spec.sendCookies) {
      final cookies = _jar.headerFor(url);
      if (cookies != null && !headers.containsKey('cookie')) {
        headers['Cookie'] = cookies;
      }
    }
    request.headers.addAll(headers);
  }

  Map<String, String> _extrasOf(
    RequestSpec spec,
    http.StreamedResponse response,
    int storedCookies,
  ) => <String, String>{
    'response mode': spec.responseMode.label.toLowerCase(),
    'connection': response.persistentConnection ? 'keep-alive' : 'close',
    'protocol': 'not reported: package:http has no field for it',
    'redirects': response.isRedirect
        ? 'the final response is itself a 3xx'
        : 'followed silently; package:http does not count them',
    'cookie jar': spec.sendCookies
        ? '$storedCookies stored, ${_jar.length} held '
              '(app-side: package:http keeps none)'
        : 'off for this request',
    if (spec.totalTimeout != null)
      'total timeout':
          'enforced by completing Abortable.abortTrigger; package:http has no '
          'timeout of its own',
    if (!spec.acceptEncoding)
      'accept-encoding': 'sent as identity, but a gzip reply would still be '
          'decoded transparently: see capabilities.notes',
  };

  static http.MultipartFile _multipartFile(
    String field,
    String path,
    MultipartPart part,
  ) {
    final file = File(path);
    return http.MultipartFile(
      field,
      http.ByteStream(file.openRead()),
      file.lengthSync(),
      filename: path.split(RegExp(r'[/\\]')).last,
      contentType: part.contentType == null
          ? null
          : http.MediaType.parse(part.contentType!),
    );
  }

  /// Classifies a `package:http` failure.
  ///
  /// Everything transport-level arrives wrapped in a [http.ClientException], so
  /// the work is in unwrapping it: `IOClient` re-throws a `SocketException` as
  /// a `ClientException` that still *implements* `SocketException`, which is
  /// what lets the shared `dart:io` classifier see through the wrapper and put
  /// a refused connection in the same bucket every other sender puts it in.
  static SendFailureKind _kindOf(Object error) {
    if (error is http.RequestAbortedException) return SendFailureKind.cancelled;
    if (error is SendAborted) return SendFailureKind.cancelled;
    if (error is http.ClientException) {
      final classified = classifyIoFailure(error);
      if (classified != SendFailureKind.unknown) return classified;
      // A redirect limit and a truncated response both surface as a bare
      // `ClientException` carrying nothing but a sentence.
      return error.message.toLowerCase().contains('redirect')
          ? SendFailureKind.unknown
          : SendFailureKind.connection;
    }
    return classifyIoFailure(error);
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

/// Wraps [source] so the sender can count bytes as they leave.
http.ByteStream _counted(
  http.ByteStream source,
  void Function(int written)? report,
) {
  if (report == null) return source;
  var written = 0;
  return http.ByteStream(
    source.map((List<int> chunk) {
      written += chunk.length;
      report(written);
      return chunk;
    }),
  );
}

/// [http.Request] that can be aborted and reports upload progress.
///
/// `package:http` ships neither behaviour on its concrete request types:
/// `Abortable` is a mixin you are expected to apply yourself, and progress has
/// no hook at all short of overriding [http.BaseRequest.finalize].
final class _CountedRequest extends http.Request with http.Abortable {
  _CountedRequest(super.method, super.url, this.abortTrigger, this._report);

  @override
  final Future<void>? abortTrigger;
  final void Function(int written)? _report;

  @override
  http.ByteStream finalize() => _counted(super.finalize(), _report);
}

/// [http.MultipartRequest] with the same two additions.
final class _CountedMultipart extends http.MultipartRequest
    with http.Abortable {
  _CountedMultipart(super.method, super.url, this.abortTrigger, this._report);

  @override
  final Future<void>? abortTrigger;
  final void Function(int written)? _report;

  @override
  http.ByteStream finalize() => _counted(super.finalize(), _report);
}

/// A request whose body is pulled from a stream of known length.
///
/// `package:http`'s own `StreamedRequest` is a sink you push into, which cannot
/// express "here is a source, pull from it as fast as the socket drains".
/// Overriding [http.BaseRequest.finalize] can, and that is what keeps a file or
/// a synthetic 200 MB payload off the heap.
final class _CountedStreamRequest extends http.BaseRequest with http.Abortable {
  _CountedStreamRequest(
    super.method,
    super.url,
    this.abortTrigger,
    this._report,
    this._source,
    int length,
  ) {
    contentLength = length;
  }

  @override
  final Future<void>? abortTrigger;
  final void Function(int written)? _report;
  final Stream<List<int>> _source;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return _counted(http.ByteStream(_source), _report);
  }
}

/// What `package:http` can do.
const SenderCapabilities packageHttpCapabilities = SenderCapabilities(
  perRequestConnectTimeout: false,
  notes: <String, String>{
    'perRequestConnectTimeout':
        'package:http has no timeout API at all — not per request, not per '
        'client. A whole-request deadline can be built out of '
        'Abortable.abortTrigger, which this sender does, but that clock starts '
        'at send() and cannot be told to cover only the connect phase: the API '
        'has no "connected" event to stop it at. A real connect timeout lives '
        'on the dart:io HttpClient you would construct yourself and hand to '
        'IOClient, which is outside the portable interface.',
    'acceptEncoding':
        'Only half honoured. Turning it off sends Accept-Encoding: identity, '
        'which is all package:http can express — but if the server compresses '
        'anyway, the dart:io client underneath still decodes it, because '
        'autoUncompress lives on an HttpClient this sender deliberately does '
        'not construct. Compare the dart:io row, where one flag covers both '
        'halves and the raw gzip bytes come back undecoded.',
    'fileBodyWithoutHeap':
        'The file is streamed with File.openRead() through an overridden '
        'finalize(), so nothing buffers the whole file, but every chunk is '
        'copied into the Dart heap on its way to the socket.',
    'phaseTimings':
        'package:http reports no timings. It also reports no redirect count '
        'and no negotiated protocol, both of which the dart:io client '
        'underneath does know — the portable interface simply has no field for '
        'them.',
    'diskCache':
        'No cache. package:http is a request/response interface and keeps '
        'nothing between calls.',
    'contentTypeOverride':
        'Applied to every body kind except multipart, whose content type '
        'carries the generated boundary and so can only come from the encoder.',
  },
);
