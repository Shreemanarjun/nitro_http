/// Fakes for the two `nitro_http` transport seams, so the dio adapter can be
/// exercised end to end with no native library loaded.
///
/// The parent package deliberately funnels every native call through
/// `RequestExecutor` and every native stream through `StreamDemux` for exactly
/// this purpose; these fakes stand in for both.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// The two seams and the wire records are `src/` on purpose: they are internal
// to `nitro_http`'s public API but are its documented testing surface, and
// there is no other way to run the adapter without an engine.
// ignore: implementation_imports
import 'package:nitro_http/src/internal/request_runner.dart';
// ignore: implementation_imports
import 'package:nitro_http/src/nitro_http.native.dart';

/// All-zero timings, which is what the engine reports when none were asked for.
const RawTimings zeroTimings = RawTimings(
  queueMs: 0,
  dnsMs: 0,
  connectMs: 0,
  tlsMs: 0,
  firstByteMs: 0,
  redirectMs: 0,
  totalMs: 0,
);

/// Builds a [RawResponseHead] with sensible defaults for a 200 response.
RawResponseHead makeHead({
  required int requestId,
  int statusCode = 200,
  RawErrorKind errorKind = RawErrorKind.none,
  String errorMessage = '',
  int engineErrorCode = 0,
  List<RawHeader> headers = const <RawHeader>[],
  String finalUrl = 'https://example.test/',
  int redirectCount = 0,
  int contentLength = -1,
  RawHttpVersion version = RawHttpVersion.http11,
  bool fromCache = false,
  String reasonPhrase = 'OK',
}) => RawResponseHead(
  requestId: requestId,
  errorKind: errorKind,
  errorMessage: errorMessage,
  engineErrorCode: engineErrorCode,
  statusCode: statusCode,
  reasonPhrase: reasonPhrase,
  version: version,
  finalUrl: finalUrl,
  redirectCount: redirectCount,
  headers: headers,
  fromCache: fromCache,
  contentLength: contentLength,
  primaryIp: '127.0.0.1',
  primaryPort: 443,
  timings: zeroTimings,
);

/// Per-request chunk and event streams the test drives by hand.
class FakeStreamDemux implements StreamDemux {
  final Map<int, StreamController<ChunkEvent>> _chunks =
      <int, StreamController<ChunkEvent>>{};
  final Map<int, StreamController<RawEvent>> _events =
      <int, StreamController<RawEvent>>{};

  /// Request ids passed to [release], in order.
  final List<int> released = <int>[];

  @override
  Stream<ChunkEvent> chunks(int requestId) => _chunkSink(requestId).stream;

  @override
  Stream<RawEvent> events(int requestId) => _eventSink(requestId).stream;

  @override
  void release(int requestId) {
    released.add(requestId);
    unawaited(_chunks.remove(requestId)?.close());
    unawaited(_events.remove(requestId)?.close());
  }

  /// Whether [requestId] still has open controllers.
  bool isLive(int requestId) => _chunks.containsKey(requestId);

  /// Delivers one body chunk.
  void pushData(int requestId, List<int> bytes) => _push(
    requestId,
    ChunkEvent(
      requestId: requestId,
      kind: RawChunkKind.data.index,
      aux: 0,
      bytes: Uint8List.fromList(bytes),
    ),
  );

  /// Ends the body cleanly.
  void pushDone(int requestId) => _push(
    requestId,
    ChunkEvent(
      requestId: requestId,
      kind: RawChunkKind.done.index,
      aux: 0,
      bytes: Uint8List(0),
    ),
  );

  /// Ends the body with a transfer failure.
  void pushError(int requestId, RawErrorKind kind, String message) => _push(
    requestId,
    ChunkEvent(
      requestId: requestId,
      kind: RawChunkKind.error.index,
      aux: kind.index,
      bytes: Uint8List.fromList(utf8.encode(message)),
    ),
  );

  void _push(int requestId, ChunkEvent event) {
    final sink = _chunks[requestId];
    // Released already: the transfer is over and native would not post either.
    if (sink == null || sink.isClosed) return;
    sink.add(event);
  }

  StreamController<ChunkEvent> _chunkSink(int requestId) =>
      _chunks[requestId] ??= StreamController<ChunkEvent>();

  StreamController<RawEvent> _eventSink(int requestId) =>
      _events[requestId] ??= StreamController<RawEvent>();
}

/// Records every call the runner makes and answers the streamed path from
/// script rather than from a socket.
class FakeRequestExecutor implements RequestExecutor {
  /// Creates an executor that delivers response bodies through [demux].
  FakeRequestExecutor(this.demux);

  /// The demux this executor pushes chunks into.
  final FakeStreamDemux demux;

  /// Configurations passed to [configureClient], in order.
  final List<RawClientConfig> configs = <RawClientConfig>[];

  /// Requests handed to [startStreamed], in order.
  final List<RawRequest> requests = <RawRequest>[];

  /// Request ids passed to [cancel], in order.
  final List<int> cancelled = <int>[];

  /// `(requestId, chunkCount, ackedChunks)` for every [grantCredit].
  final List<(int, int, int)> credits = <(int, int, int)>[];

  /// Body chunks pushed through [feedUploadChunk], in order.
  final List<Uint8List> uploaded = <Uint8List>[];

  /// How many times [cancelAll] was called.
  int cancelAllCount = 0;

  /// How many times [dispose] was called.
  int disposeCount = 0;

  /// How many times [finishUpload] was called.
  int finishUploadCount = 0;

  /// The head to answer with. Defaults to a 200 with no headers.
  RawResponseHead Function(RawRequest request)? headBuilder;

  /// Body chunks delivered after the head.
  List<List<int>> responseChunks = const <List<int>>[];

  /// When set, the body ends with this failure instead of a clean `done`.
  RawErrorKind? bodyFailure;

  /// The message carried by [bodyFailure].
  String bodyFailureMessage = 'the transfer broke';

  /// When true the body is left open after [responseChunks], so a test can
  /// cancel a transfer that is still on the wire.
  bool holdBodyOpen = false;

  /// The most recent request.
  RawRequest get lastRequest => requests.last;

  /// The options of the most recent request.
  RawRequestOptions get lastOptions => lastRequest.options;

  /// The headers of the most recent request as ordered `(name, value)` pairs.
  List<(String, String)> get lastHeaders => <(String, String)>[
    for (final header in lastRequest.headers) (header.name, header.value),
  ];

  @override
  void configureClient(RawClientConfig config) => configs.add(config);

  @override
  Future<RawResponseHead> startStreamed(
    RawRequest request,
    Uint8List body,
  ) async {
    requests.add(request);
    final head = headBuilder?.call(request) ?? makeHead(requestId: request.requestId);
    if (head.errorKind != RawErrorKind.none) return head;

    // The runner subscribes to the chunk stream before awaiting the head, and
    // the demux controller buffers, so scheduling the body here matches an
    // engine that answers head and first chunk in the same turn.
    scheduleMicrotask(() {
      for (final chunk in responseChunks) {
        demux.pushData(request.requestId, chunk);
      }
      final failure = bodyFailure;
      if (failure != null) {
        demux.pushError(request.requestId, failure, bodyFailureMessage);
      } else if (!holdBodyOpen) {
        demux.pushDone(request.requestId);
      }
    });
    return head;
  }

  /// The dio adapter always takes the streamed path, so reaching this is a bug
  /// in the adapter rather than a gap in the fake.
  @override
  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body) =>
      throw UnsupportedError(
        'the dio adapter must never take the buffered path',
      );

  @override
  void cancel(int requestId) => cancelled.add(requestId);

  @override
  void cancelAll() => cancelAllCount++;

  /// `(tokenId, reason)` for every `cancelToken` call, in order. The list is
  /// what proves one token cancellation makes ONE native call however many
  /// requests are bound to it.
  final List<(int, String)> cancelledTokens = <(int, String)>[];

  /// Token ids passed to `releaseCancelToken`.
  final List<int> releasedTokens = <int>[];

  @override
  void cancelToken(int tokenId, String reason) =>
      cancelledTokens.add((tokenId, reason));

  @override
  void releaseCancelToken(int tokenId) => releasedTokens.add(tokenId);

  @override
  void grantCredit(int requestId, int chunkCount, int ackedChunks) =>
      credits.add((requestId, chunkCount, ackedChunks));

  @override
  int feedUploadChunk(int requestId, Uint8List chunk) {
    uploaded.add(chunk);
    // Bytes still buffered natively; zero keeps the pump below its high-water
    // mark so it never pauses the source.
    return 0;
  }

  @override
  void finishUpload(int requestId) => finishUploadCount++;

  @override
  void failUpload(int requestId, String message) => uploadFailures.add(message);

  /// Messages passed to [failUpload], in order.
  final List<String> uploadFailures = <String>[];

  @override
  List<RawCookie> getCookies(String url) => const <RawCookie>[];

  @override
  void setCookie(RawCookie cookie) => cookiesSet.add(cookie);

  /// Cookies passed to [setCookie], in order.
  final List<RawCookie> cookiesSet = <RawCookie>[];

  @override
  void clearCookies() => clearCookiesCount++;

  /// How many times [clearCookies] was called.
  int clearCookiesCount = 0;

  @override
  void flushCookies() => flushCookiesCount++;

  /// How many times [flushCookies] was called.
  int flushCookiesCount = 0;

  @override
  void dispose() => disposeCount++;
}
