/// Shared fakes and builders for the `nitro_http` unit suite.
///
/// Everything the runner, the client, the WebSocket and the `package:http`
/// adapter touch on the native side goes through one of three seams —
/// [RequestExecutor], [StreamDemux] and [WsExecutor]/[WsFrameDemux]. Faking
/// those seams is what lets the whole orchestration be exercised with no
/// dynamic library present, which is the point of this file.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/engine_runner.dart';
import 'package:nitro_http/src/internal/request_runner.dart';
import 'package:nitro_http/src/internal/ws_runner.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

// ── Record shapes for the recorded calls ─────────────────────────────────────

/// One `grantCredit(requestId, chunkCount, ackedChunks)` call.
///
/// A record rather than a class so a whole credit sequence can be asserted with
/// a single `expect(executor.credits, [...])`.
typedef CreditGrant = ({int requestId, int chunkCount, int ackedChunks});

/// One `sendBuffered` / `startStreamed` call.
typedef SentRequest = ({RawRequest request, Uint8List body});

/// One `feedUploadChunk` call.
typedef UploadChunk = ({int requestId, Uint8List bytes});

/// One `failUpload` call.
typedef UploadFailure = ({int requestId, String message});

/// One `wsSend` call.
typedef SentFrame = ({int opcode, Uint8List payload});

/// One `wsClose` call.
typedef SentClose = ({int code, String reason});

/// One `wsGrantCredit` call.
typedef FrameCredit = ({int frameCount, int ackedFrames});

// ── RequestExecutor ──────────────────────────────────────────────────────────

/// A [RequestExecutor] that records every call and hands out programmed
/// answers.
///
/// Responses come from [bufferedResponses] / [streamedHeads], or — when a test
/// needs to inspect the request first, or to control *when* the answer arrives
/// — from the [onSendBuffered] / [onStartStreamed] hooks.
final class FakeRequestExecutor implements RequestExecutor {
  /// Every configuration pushed through `configureClient`, in order.
  final List<RawClientConfig> configs = <RawClientConfig>[];

  /// Every buffered request, in order.
  final List<SentRequest> bufferedRequests = <SentRequest>[];

  /// Every streamed request, in order.
  final List<SentRequest> streamedRequests = <SentRequest>[];

  /// Request ids passed to `cancel`, in order.
  final List<int> cancelled = <int>[];

  /// How many times `cancelAll` was called.
  int cancelAllCount = 0;

  /// Every `grantCredit` call, in order.
  final List<CreditGrant> credits = <CreditGrant>[];

  /// Every upload chunk fed to the engine, in order.
  final List<UploadChunk> uploadChunks = <UploadChunk>[];

  /// Request ids whose upload was finished cleanly.
  final List<int> finishedUploads = <int>[];

  /// Every aborted upload, in order.
  final List<UploadFailure> failedUploads = <UploadFailure>[];

  /// Every URL passed to `getCookies`, in order.
  final List<String> cookieQueries = <String>[];

  /// Every cookie written through `setCookie`, in order.
  final List<RawCookie> cookiesSet = <RawCookie>[];

  /// How many times `clearCookies` was called.
  int clearCookiesCount = 0;

  /// How many times `flushCookies` was called.
  int flushCookiesCount = 0;

  /// How many times `dispose` was called.
  int disposeCount = 0;

  /// Answers handed to successive `sendBuffered` calls.
  final Queue<RawResponse> bufferedResponses = Queue<RawResponse>();

  /// Answers handed to successive `startStreamed` calls.
  final Queue<RawResponseHead> streamedHeads = Queue<RawResponseHead>();

  /// Overrides [bufferedResponses]; lets a test inspect the request, or return
  /// a future it completes later.
  FutureOr<RawResponse> Function(RawRequest request, Uint8List body)?
  onSendBuffered;

  /// Overrides [streamedHeads]. See [onSendBuffered].
  FutureOr<RawResponseHead> Function(RawRequest request, Uint8List body)?
  onStartStreamed;

  /// Bytes the fake reports as buffered in the native upload ring. Raise it
  /// above `kUploadHighWaterMark` to drive the pause path.
  int bufferedUploadBytes = 0;

  /// Per-chunk override of [bufferedUploadBytes].
  int Function(int requestId, Uint8List chunk)? onFeedUploadChunk;

  /// The jar `getCookies` reports.
  List<RawCookie> jar = const <RawCookie>[];

  @override
  void configureClient(RawClientConfig config) => configs.add(config);

  @override
  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body) async {
    bufferedRequests.add((request: request, body: body));
    final hook = onSendBuffered;
    if (hook != null) return hook(request, body);
    if (bufferedResponses.isEmpty) {
      throw StateError('no queued RawResponse for ${request.url}');
    }
    return bufferedResponses.removeFirst();
  }

  @override
  Future<RawResponseHead> startStreamed(
    RawRequest request,
    Uint8List body,
  ) async {
    streamedRequests.add((request: request, body: body));
    final hook = onStartStreamed;
    if (hook != null) return hook(request, body);
    if (streamedHeads.isEmpty) {
      throw StateError('no queued RawResponseHead for ${request.url}');
    }
    return streamedHeads.removeFirst();
  }

  @override
  void cancel(int requestId) => cancelled.add(requestId);

  @override
  void cancelAll() => cancelAllCount++;

  @override
  void grantCredit(int requestId, int chunkCount, int ackedChunks) => credits
      .add((
        requestId: requestId,
        chunkCount: chunkCount,
        ackedChunks: ackedChunks,
      ));

  @override
  int feedUploadChunk(int requestId, Uint8List chunk) {
    uploadChunks.add((requestId: requestId, bytes: chunk));
    return onFeedUploadChunk?.call(requestId, chunk) ?? bufferedUploadBytes;
  }

  @override
  void finishUpload(int requestId) => finishedUploads.add(requestId);

  @override
  void failUpload(int requestId, String message) =>
      failedUploads.add((requestId: requestId, message: message));

  @override
  List<RawCookie> getCookies(String url) {
    cookieQueries.add(url);
    return jar;
  }

  @override
  void setCookie(RawCookie cookie) => cookiesSet.add(cookie);

  @override
  void clearCookies() => clearCookiesCount++;

  @override
  void flushCookies() => flushCookiesCount++;

  @override
  void dispose() => disposeCount++;

  /// The total bytes fed through [feedUploadChunk].
  int get uploadedBytes =>
      uploadChunks.fold(0, (sum, c) => sum + c.bytes.length);
}

// ── StreamDemux ──────────────────────────────────────────────────────────────

/// A [StreamDemux] backed by per-request controllers a test can push into.
///
/// Faithful to `NativeStreamDemux` in the one way that matters: chunk
/// controllers are single-subscription (a body has exactly one consumer, and a
/// broadcast controller would drop chunks posted before the listener attaches)
/// while event controllers are broadcast (the progress wiring and the upload
/// pump both listen to the same request's events). Getting either wrong here
/// would let a genuine double-subscription bug pass.
final class FakeStreamDemux implements StreamDemux {
  /// Live chunk controllers, keyed by request id.
  final Map<int, StreamController<ChunkEvent>> chunkControllers =
      <int, StreamController<ChunkEvent>>{};

  /// Live event controllers, keyed by request id.
  final Map<int, StreamController<RawEvent>> eventControllers =
      <int, StreamController<RawEvent>>{};

  /// Request ids passed to [release], in order.
  final List<int> released = <int>[];

  /// The single-subscription chunk controller for [requestId], created on
  /// demand.
  StreamController<ChunkEvent> chunkController(int requestId) =>
      chunkControllers.putIfAbsent(requestId, StreamController<ChunkEvent>.new);

  /// The broadcast event controller for [requestId], created on demand.
  StreamController<RawEvent> eventController(int requestId) =>
      eventControllers.putIfAbsent(
        requestId,
        StreamController<RawEvent>.broadcast,
      );

  @override
  Stream<ChunkEvent> chunks(int requestId) => chunkController(requestId).stream;

  @override
  Stream<RawEvent> events(int requestId) => eventController(requestId).stream;

  @override
  void release(int requestId) {
    released.add(requestId);
    unawaited(chunkControllers.remove(requestId)?.close());
    unawaited(eventControllers.remove(requestId)?.close());
  }

  /// Delivers [event] on its request's chunk stream.
  void push(ChunkEvent event) => chunkController(event.requestId).add(event);

  /// Delivers [event] on its request's event stream.
  void pushEvent(RawEvent event) => eventController(event.requestId).add(event);

  /// Closes every remaining controller. Call from `tearDown`.
  ///
  /// The close futures are deliberately not awaited: a single-subscription
  /// controller that was never listened to only completes its `done` future
  /// once someone subscribes, so awaiting here would hang the teardown.
  void closeAll() {
    for (final c in chunkControllers.values) {
      unawaited(c.close());
    }
    for (final c in eventControllers.values) {
      unawaited(c.close());
    }
    chunkControllers.clear();
    eventControllers.clear();
  }
}

// ── EngineExecutor ───────────────────────────────────────────────────────────

/// An [EngineExecutor] that records the process-wide engine calls.
final class FakeEngineExecutor implements EngineExecutor {
  /// Creates a fake reporting the given capabilities.
  FakeEngineExecutor({
    this.engineVersion = 'libcurl/8.21.0 (fake)',
    this.supportsHttp3 = true,
    this.supportsWebSockets = true,
    this.supportsBrotli = true,
    this.supportsZstd = false,
  });

  @override
  final String engineVersion;

  @override
  final bool supportsHttp3;

  @override
  final bool supportsWebSockets;

  @override
  final bool supportsBrotli;

  @override
  final bool supportsZstd;

  /// How many times `resetNative` was called.
  int resetCount = 0;

  /// How many times `clearCache` was called.
  int clearCacheCount = 0;

  /// Every cache configuration applied, in order.
  final List<RawCacheConfig> cacheConfigs = <RawCacheConfig>[];

  /// Every prefetch request, in order.
  final List<RawRequest> prefetched = <RawRequest>[];

  /// The answer handed to `prefetch`.
  RawResponse prefetchResponse = rawResponse();

  /// The snapshot handed to `cacheStats`.
  RawCacheStats stats = const RawCacheStats(
    entryCount: 0,
    sizeBytes: 0,
    hitCount: 0,
    missCount: 0,
    revalidationCount: 0,
    evictionCount: 0,
  );

  @override
  void resetNative() => resetCount++;

  @override
  void configureCache(RawCacheConfig config) => cacheConfigs.add(config);

  @override
  Future<RawResponse> prefetch(RawRequest request) async {
    prefetched.add(request);
    return prefetchResponse;
  }

  @override
  void clearCache() => clearCacheCount++;

  @override
  RawCacheStats cacheStats() => stats;
}

// ── WebSocket seams ──────────────────────────────────────────────────────────

/// A [WsExecutor] that records every call and answers a programmed handshake.
final class FakeWsExecutor implements WsExecutor {
  /// Every configuration passed to `connect`, in order.
  final List<RawWsConfig> configs = <RawWsConfig>[];

  /// Every frame sent, in order.
  final List<SentFrame> sent = <SentFrame>[];

  /// Every `close` call, in order.
  final List<SentClose> closes = <SentClose>[];

  /// Every `grantCredit` call, in order.
  final List<FrameCredit> credits = <FrameCredit>[];

  /// How many times `dispose` was called.
  int disposeCount = 0;

  /// The handshake answer. Defaults to a successful upgrade.
  RawWsHandshake handshake = rawHandshake();

  /// Overrides [handshake]; lets a test inspect the config or fail the call.
  Future<RawWsHandshake> Function(RawWsConfig config)? onConnect;

  /// Bytes `send` reports as still queued for transmission.
  int queuedBytes = 0;

  @override
  Future<RawWsHandshake> connect(RawWsConfig config) async {
    configs.add(config);
    final hook = onConnect;
    return hook == null ? handshake : hook(config);
  }

  @override
  int send(int opcode, Uint8List payload) {
    sent.add((opcode: opcode, payload: payload));
    return queuedBytes;
  }

  @override
  void close(int code, String reason) =>
      closes.add((code: code, reason: reason));

  @override
  void grantCredit(int frameCount, int ackedFrames) =>
      credits.add((frameCount: frameCount, ackedFrames: ackedFrames));

  @override
  void dispose() => disposeCount++;
}

/// A [WsFrameDemux] backed by per-socket controllers a test can push into.
final class FakeWsFrameDemux implements WsFrameDemux {
  /// Live frame controllers, keyed by socket id.
  final Map<int, StreamController<WsFrameEvent>> controllers =
      <int, StreamController<WsFrameEvent>>{};

  /// Socket ids passed to [release], in order.
  final List<int> released = <int>[];

  /// The frame controller for [socketId], created on demand.
  StreamController<WsFrameEvent> controller(int socketId) =>
      controllers.putIfAbsent(socketId, StreamController<WsFrameEvent>.new);

  @override
  Stream<WsFrameEvent> frames(int socketId) => controller(socketId).stream;

  @override
  void release(int socketId) {
    released.add(socketId);
    unawaited(controllers.remove(socketId)?.close());
  }

  /// Delivers [event] on its socket's frame stream.
  void push(WsFrameEvent event) => controller(event.socketId).add(event);

  /// Closes every remaining controller. Call from `tearDown`.
  ///
  /// Not awaited, for the same reason as [FakeStreamDemux.closeAll].
  void closeAll() {
    for (final c in controllers.values) {
      unawaited(c.close());
    }
    controllers.clear();
  }
}

// ── Builders ─────────────────────────────────────────────────────────────────

/// A timing record with every phase at zero.
const RawTimings zeroTimings = RawTimings(
  queueMs: 0,
  dnsMs: 0,
  connectMs: 0,
  tlsMs: 0,
  firstByteMs: 0,
  redirectMs: 0,
  totalMs: 0,
);

/// Builds a buffered wire response.
///
/// The defaults describe a plain `200 OK` over HTTP/1.1 with no body; every
/// field a test cares about is a named argument.
RawResponse rawResponse({
  int requestId = 1,
  int status = 200,
  Uint8List? body,
  List<RawHeader> headers = const <RawHeader>[],
  RawErrorKind kind = RawErrorKind.none,
  String message = '',
  int engineCode = 0,
  String reasonPhrase = 'OK',
  RawHttpVersion version = RawHttpVersion.http11,
  String finalUrl = '',
  int redirectCount = 0,
  bool fromCache = false,
  bool revalidated = false,
  String primaryIp = '203.0.113.7',
  int primaryPort = 443,
  RawTimings timings = zeroTimings,
}) => RawResponse(
  requestId: requestId,
  errorKind: kind,
  errorMessage: message,
  engineErrorCode: engineCode,
  statusCode: status,
  reasonPhrase: reasonPhrase,
  version: version,
  finalUrl: finalUrl,
  redirectCount: redirectCount,
  headers: headers,
  body: body ?? Uint8List(0),
  fromCache: fromCache,
  revalidated: revalidated,
  primaryIp: primaryIp,
  primaryPort: primaryPort,
  timings: timings,
);

/// Builds a streamed wire response head.
RawResponseHead rawHead({
  int requestId = 1,
  int status = 200,
  List<RawHeader> headers = const <RawHeader>[],
  RawErrorKind kind = RawErrorKind.none,
  String message = '',
  int engineCode = 0,
  String reasonPhrase = 'OK',
  RawHttpVersion version = RawHttpVersion.http11,
  String finalUrl = '',
  int redirectCount = 0,
  bool fromCache = false,
  int contentLength = -1,
  String primaryIp = '203.0.113.7',
  int primaryPort = 443,
  RawTimings timings = zeroTimings,
}) => RawResponseHead(
  requestId: requestId,
  errorKind: kind,
  errorMessage: message,
  engineErrorCode: engineCode,
  statusCode: status,
  reasonPhrase: reasonPhrase,
  version: version,
  finalUrl: finalUrl,
  redirectCount: redirectCount,
  headers: headers,
  fromCache: fromCache,
  contentLength: contentLength,
  primaryIp: primaryIp,
  primaryPort: primaryPort,
  timings: timings,
);

/// Builds a WebSocket handshake result.
RawWsHandshake rawHandshake({
  int socketId = 1,
  RawErrorKind kind = RawErrorKind.none,
  String message = '',
  int engineCode = 0,
  int status = 101,
  String protocol = '',
  List<RawHeader> headers = const <RawHeader>[],
}) => RawWsHandshake(
  socketId: socketId,
  errorKind: kind,
  errorMessage: message,
  engineErrorCode: engineCode,
  statusCode: status,
  negotiatedProtocol: protocol,
  responseHeaders: headers,
);

/// A data chunk carrying [bytes] for [requestId].
ChunkEvent chunk(int requestId, List<int> bytes) => ChunkEvent(
  requestId: requestId,
  kind: RawChunkKind.data.index,
  aux: 0,
  bytes: Uint8List.fromList(bytes),
);

/// The terminal chunk for [requestId].
ChunkEvent doneChunk(int requestId) => ChunkEvent(
  requestId: requestId,
  kind: RawChunkKind.done.index,
  aux: 0,
  bytes: Uint8List(0),
);

/// An error chunk aborting [requestId] with [kind] and [message].
ChunkEvent errorChunk(int requestId, RawErrorKind kind, String message) =>
    ChunkEvent(
      requestId: requestId,
      kind: RawChunkKind.error.index,
      aux: kind.index,
      bytes: Uint8List.fromList(utf8.encode(message)),
    );

/// A progress event: [transferred] of [total] bytes, uploading when [upload].
RawEvent progressEvent(
  int requestId, {
  required int transferred,
  int total = -1,
  bool upload = false,
}) => RawEvent(
  requestId: requestId,
  kind: upload ? RawEventKind.uploadProgress : RawEventKind.downloadProgress,
  a: transferred,
  b: total,
  message: '',
);

/// An upload-drain event reporting [buffered] bytes still in the native ring.
RawEvent drainEvent(int requestId, int buffered) => RawEvent(
  requestId: requestId,
  kind: RawEventKind.uploadDrain,
  a: buffered,
  b: 0,
  message: '',
);

/// A WebSocket frame event.
WsFrameEvent wsFrame(
  int socketId,
  WsOpcode opcode,
  List<int> payload, {
  bool fin = true,
}) => WsFrameEvent(
  socketId: socketId,
  opcode: opcode,
  fin: fin,
  payload: Uint8List.fromList(payload),
);

/// A close frame with the 2-byte big-endian [code] prefix RFC 6455 mandates.
WsFrameEvent wsCloseFrame(int socketId, int code, String reason) => wsFrame(
  socketId,
  WsOpcode.close,
  <int>[(code >> 8) & 0xff, code & 0xff, ...utf8.encode(reason)],
);

/// A bare request, for tests that need one but do not care about its shape.
HttpRequest fakeRequest({
  String url = 'https://example.com/',
  HttpMethod method = HttpMethod.get,
  HttpHeaders? headers,
  HttpBody? body,
}) => HttpRequest(
  url: Uri.parse(url),
  method: method,
  headers: headers,
  body: body,
);

/// A ready-made text response, for interceptor and chain tests.
HttpTextResponse fakeTextResponse({
  int status = 200,
  String body = '',
  HttpRequest? request,
  HttpHeaders? headers,
}) => HttpTextResponse(
  meta: ResponseMetadata(
    request: request ?? fakeRequest(),
    statusCode: status,
    reasonPhrase: 'OK',
    version: HttpVersion.http11,
    headers: headers ?? HttpHeaders(),
    finalUrl: Uri.parse('https://example.com/'),
    redirectCount: 0,
    fromCache: false,
    revalidated: false,
    primaryIp: '203.0.113.7',
    primaryPort: 443,
    timings: const HttpTimings.zero(),
  ),
  bodyBytes: Uint8List.fromList(utf8.encode(body)),
);
