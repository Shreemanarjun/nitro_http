/// Orchestration between the public API and the Nitro bridge.
///
/// Everything genuinely subtle about this package lives here:
///
/// * **Single-subscriber demux.** The generated bridge keeps a port registry per
///   stream NAME and discards the instance id, so `chunks` and `events` are
///   module-global broadcasts. Subscribing twice would duplicate delivery and,
///   for the zero-copy structs, hand two Dart views the same native payload.
///   [NativeStreamDemux] therefore holds exactly one subscription per stream for
///   the whole process and fans out by `requestId`.
///
/// * **Eager copy, then ack.** `nitro_http_release_RawChunk` frees only the
///   struct shell; the payload stays native-owned. The demux copies each
///   chunk's bytes the moment it arrives, and the runner reports the cumulative
///   copied count back through `grantCredit(id, credits, acked)`, which is what
///   lets native free those payloads without ever racing a Dart read.
///
/// * **Credit loop.** Native emits at most `credits` chunks then returns
///   `CURL_WRITEFUNC_PAUSE`, closing the TCP window. Consumer backpressure —
///   `StreamSubscription.pause()` — translates into withholding credits, so a
///   slow consumer slows the server rather than filling Dart's heap.
///
/// * **Upload pump.** Chunks are fed until the native ring exceeds a high-water
///   mark, then the source is paused and resumed on an `uploadDrain` event.
///
/// * **Exactly-once completion.** Native guarantees one post per accepted
///   request. The runner never adds a timeout of its own that could resolve a
///   future the engine will also resolve.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:nitro/nitro.dart' show NitroCoalescer;

import '../api/cancel_token.dart';
import '../api/exceptions.dart';
import '../api/headers.dart';
import '../api/request.dart';
import '../api/response.dart';
import '../api/settings.dart';
import '../nitro_http.native.dart';
import 'instance_keys.dart';
import 'native_attach.dart';
import 'raw_mapping.dart';

/// Per-client native calls. The seam that lets the whole orchestration below be
/// unit-tested with no native library present.
abstract interface class RequestExecutor {
  void configureClient(RawClientConfig config);

  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body);
  Future<RawResponseHead> startStreamed(RawRequest request, Uint8List body);

  void cancel(int requestId);
  void cancelAll();

  /// Cancels every transfer bound to [tokenId], on every client.
  void cancelToken(int tokenId, String reason);

  /// Drops [tokenId]'s native state. Safe while transfers are still bound.
  void releaseCancelToken(int tokenId);

  void grantCredit(int requestId, int chunkCount, int ackedChunks);

  int feedUploadChunk(int requestId, Uint8List chunk);
  void finishUpload(int requestId);
  void failUpload(int requestId, String message);

  List<RawCookie> getCookies(String url);
  void setCookie(RawCookie cookie);
  void clearCookies();
  void flushCookies();

  void dispose();
}

/// A body chunk that has already been copied out of native memory.
///
/// The copy is not an optimisation failure — it is the mechanism that makes the
/// zero-copy struct safe. See the library doc.
final class ChunkEvent {
  ChunkEvent({
    required this.requestId,
    required this.kind,
    required this.aux,
    required this.bytes,
  });

  final int requestId;

  /// `RawChunkKind` index: 0 data, 1 done, 2 error.
  final int kind;

  /// For an error chunk, the `RawErrorKind` index.
  final int aux;

  /// Data for `kind == 0`; a UTF-8 message for `kind == 2`.
  final Uint8List bytes;

  bool get isData => kind == 0;
  bool get isDone => kind == 1;
  bool get isError => kind == 2;
}

/// Demultiplexes the module-global streams into per-request streams.
abstract interface class StreamDemux {
  Stream<ChunkEvent> chunks(int requestId);
  Stream<RawEvent> events(int requestId);

  /// Closes and forgets both controllers for [requestId]. Safe to call twice.
  void release(int requestId);
}

// ── Native implementations ───────────────────────────────────────────────────

/// Wraps one `c:<clientId>` instance.
final class NativeRequestExecutor implements RequestExecutor {
  NativeRequestExecutor(this.clientId)
    : _native = attachedNative(clientKey(clientId));

  /// Whether buffered completions are batched through a [NitroCoalescer].
  ///
  /// A benchmark seam, not a user setting: the two paths are behaviourally
  /// identical, so the only reason to switch is to measure them against each
  /// other on the same machine in the same run. Flipping it mid-flight is safe —
  /// each request captures its route at submit time — but the coalescer is
  /// created lazily and never torn down until the executor is disposed.
  static bool coalesceCompletions = true;

  final int clientId;
  final NitroHttpNative _native;
  bool _disposed = false;

  /// Created on first coalesced send, so a client that only streams never opens
  /// a port for this.
  NitroCoalescer? _coalescer;

  /// Completers this executor owns, one per coalesced send still awaiting its
  /// result. See `_sendCoalesced` for why the coalescer's own completers are
  /// not enough.
  final Set<Completer<int>> _inFlightCoalesced = <Completer<int>>{};

  @override
  void configureClient(RawClientConfig config) =>
      _native.configureClient(config);

  @override
  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body) {
    if (!coalesceCompletions) return _native.sendBuffered(request, body);
    return _sendCoalesced(request, body);
  }

  /// One post per BURST instead of one per request.
  ///
  /// `sendBuffered` opens a `ReceivePort` per call, so 64 requests finishing
  /// together wake the isolate 64 times — measured at 37 us each and 74 % of
  /// everything this client spends outside curl. Here the engine buffers
  /// completions and posts each drained batch as a single `kArray`.
  ///
  /// The value carried back is the response blob's ADDRESS, because a coalescer
  /// is int64-only. That is the same pointer the non-coalesced path posts; the
  /// difference is that ownership is now explicit — decode it, then release it
  /// through the engine's own allocator.
  Future<RawResponse> _sendCoalesced(RawRequest request, Uint8List body) async {
    final coalescer = _coalescer ??= NitroCoalescer();

    // The caller awaits OUR completer, not the coalescer's.
    //
    // `NitroCoalescer.dispose()` closes the port and then `_pending.clear()`s —
    // it drops the completers it is holding without completing them, which is
    // documented but fatal here: a Future that never resolves is worse than one
    // that fails. Native posts its shutdown completions before the port closes,
    // but `dispose()` is synchronous, so the isolate has not had a turn to
    // deliver them and closing discards the lot. Owning the completer is what
    // lets disposal report a definite outcome for every request instead of
    // leaving the caller waiting forever.
    final completer = Completer<int>();
    _inFlightCoalesced.add(completer);
    coalescer
        .submit(
          (int callId, int port) =>
              _native.sendBufferedCoalesced(callId, request, body, port),
        )
        .then(
          (int value) {
            if (!completer.isCompleted) completer.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            if (!completer.isCompleted) completer.completeError(error, stack);
          },
        );

    final int address;
    try {
      address = await completer.future;
    } finally {
      _inFlightCoalesced.remove(completer);
    }

    if (address == 0) {
      // The batch wire has no null, so zero is how native says "could not even
      // encode the error envelope" — the coalesced twin of `postNull`.
      throw StateError(
        'sendBufferedCoalesced: native could not encode the response record',
      );
    }
    try {
      return RawResponseRecordExt.fromNative(Pointer<Uint8>.fromAddress(address));
    } finally {
      _shared.releaseRecord(address);
    }
  }

  @override
  Future<RawResponseHead> startStreamed(RawRequest request, Uint8List body) =>
      _native.startStreamed(request, body);

  @override
  void cancel(int requestId) => _native.cancel(requestId);

  @override
  void cancelAll() => _native.cancelAll();

  /// Process-wide operations go through the ENGINE role, not this client's
  /// instance.
  ///
  /// A token is process-wide: cancelling it reaches every client, and the
  /// engine resolves it through a global registry that no client owns. Routing
  /// it through the client that happened to bind it first is wrong twice over.
  /// It is silently wrong when two clients share a token and that first client
  /// is disposed — the cancel would then be dropped for the others. And it is
  /// loudly wrong on its own: the listener is registered per token and lives as
  /// long as the token does, so a token tripped after its client was disposed
  /// called into a disposed native instance, which hangs the app rather than
  /// throwing. Disposing a screen's client and then cancelling its token on the
  /// way out is a perfectly ordinary thing to do.
  ///
  /// `releaseRecord` rides here for the same reason: natively it is a bare
  /// `std::free` on the module's allocator, with nothing client-specific about
  /// it. Freeing through the client meant a completion that arrived DURING
  /// disposal — exactly the shutdown-abort case — threw `has been disposed`
  /// from the `finally`, replacing the real error with a StateError and leaking
  /// the blob it was trying to free.
  ///
  /// The engine role is a process singleton, so it is alive whenever any client
  /// is, and this static is cleared by a hot restart along with everything else.
  static NitroHttpNative? _sharedRoute;
  static NitroHttpNative get _shared =>
      _sharedRoute ??= attachedNative(kEngineKey);

  @override
  void cancelToken(int tokenId, String reason) =>
      _shared.cancelToken(tokenId, reason);

  @override
  void releaseCancelToken(int tokenId) =>
      _shared.releaseCancelToken(tokenId);

  @override
  void grantCredit(int requestId, int chunkCount, int ackedChunks) =>
      _native.grantCredit(requestId, chunkCount, ackedChunks);

  @override
  int feedUploadChunk(int requestId, Uint8List chunk) =>
      _native.feedUploadChunk(requestId, chunk);

  @override
  void finishUpload(int requestId) => _native.finishUpload(requestId);

  @override
  void failUpload(int requestId, String message) =>
      _native.failUpload(requestId, message);

  @override
  List<RawCookie> getCookies(String url) => _native.getCookies(url);

  @override
  void setCookie(RawCookie cookie) => _native.setCookie(cookie);

  @override
  void clearCookies() => _native.clearCookies();

  @override
  void flushCookies() => _native.flushCookies();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Flushing before disposal is what persists the cookie jar for a client
    // that was configured with one.
    try {
      _native.flushCookies();
    } on Object {
      // A client that never issued a request may have no jar; disposal must not
      // fail because of it.
    }
    // Native first, Dart second. `_native.dispose()` aborts every in-flight
    // transfer, and those abort completions still go through the batch — closing
    // the coalescer first would drop the port they are posted to, and every one
    // of those blobs would leak with its Future left hanging.
    _native.dispose();

    final coalescer = _coalescer;
    _coalescer = null;
    if (coalescer != null) unawaited(_drainThenCloseCoalescer(coalescer));
  }

  /// Lets the shutdown completions land, then closes the port and fails
  /// whatever never arrived.
  ///
  /// `_native.dispose()` joins the engine thread, so by the time it returns
  /// every completion has been POSTED — but posting only queues a message, and
  /// this isolate cannot deliver one until it reaches the event loop. Closing
  /// the port in the same turn therefore throws away results that already
  /// exist. Yielding first is what turns "hangs forever" into "resolves with
  /// the real abort error".
  ///
  /// The loop is bounded because a lost message must not strand the caller
  /// either: anything still outstanding afterwards is completed with a definite
  /// failure, so every request ends exactly once no matter which way it went.
  Future<void> _drainThenCloseCoalescer(NitroCoalescer coalescer) async {
    for (var turn = 0; turn < 8 && coalescer.pendingCount > 0; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    await coalescer.dispose();

    for (final completer in _inFlightCoalesced.toList()) {
      if (completer.isCompleted) continue;
      completer.completeError(
        NitroHttpDisposedException(
          engineMessage:
              'the client was disposed before this request completed, and its '
              'result did not arrive in time to be delivered',
        ),
      );
    }
    _inFlightCoalesced.clear();
  }
}

/// The process-wide demultiplexer. Exactly one instance, exactly one
/// subscription per module-global stream.
final class NativeStreamDemux implements StreamDemux {
  NativeStreamDemux._() {
    final engine = NitroHttpNative.engine;
    _chunkSub = engine.chunks.listen(_onChunk);
    _eventSub = engine.events.listen(_onEvent);
  }

  static NativeStreamDemux? _instance;

  /// Creates the demux on first use. Subsequent calls return the same object —
  /// creating a second one would register a second port and duplicate delivery.
  static NativeStreamDemux get instance =>
      _instance ??= NativeStreamDemux._();

  static bool get isInitialised => _instance != null;

  late final StreamSubscription<RawChunk> _chunkSub;
  late final StreamSubscription<RawEvent> _eventSub;

  final _chunkControllers = <int, StreamController<ChunkEvent>>{};
  final _eventControllers = <int, StreamController<RawEvent>>{};

  void _onChunk(RawChunk raw) {
    // COPY FIRST. `raw` is a proxy over native memory whose payload is freed
    // once we ack it; reading it later would be a use-after-free.
    final event = ChunkEvent(
      requestId: raw.requestId,
      kind: raw.kind,
      aux: raw.aux,
      bytes: Uint8List.fromList(raw.bytes),
    );
    final c = _chunkControllers[event.requestId];
    // An unknown id is not an error: a cancelled request's tail can still be
    // in flight when its controller is already gone.
    if (c != null && !c.isClosed) c.add(event);
  }

  void _onEvent(RawEvent raw) {
    final c = _eventControllers[raw.requestId];
    if (c != null && !c.isClosed) c.add(raw);
  }

  /// Single-subscription on purpose: a body has exactly one consumer, and a
  /// broadcast controller would drop chunks emitted before the listener
  /// attaches — which is precisely the race the runner avoids by subscribing
  /// before it calls `startStreamed`.
  @override
  Stream<ChunkEvent> chunks(int requestId) => _chunkControllers
      .putIfAbsent(requestId, () => StreamController<ChunkEvent>())
      .stream;

  /// Broadcast, unlike [chunks]: one request can have two independent event
  /// consumers at once — the progress wiring and the upload pump's drain
  /// watcher. Losing an event posted before either attaches is fine, because
  /// progress is lossy by design and the runner synthesizes the terminal value
  /// from the completion path.
  @override
  Stream<RawEvent> events(int requestId) => _eventControllers
      .putIfAbsent(requestId, () => StreamController<RawEvent>.broadcast())
      .stream;

  @override
  void release(int requestId) {
    _chunkControllers.remove(requestId)?.close();
    _eventControllers.remove(requestId)?.close();
  }

  /// Test-only teardown. Never called in production: the demux lives as long as
  /// the isolate.
  Future<void> disposeForTesting() async {
    await _chunkSub.cancel();
    await _eventSub.cancel();
    for (final c in _chunkControllers.values) {
      await c.close();
    }
    for (final c in _eventControllers.values) {
      await c.close();
    }
    _chunkControllers.clear();
    _eventControllers.clear();
    _instance = null;
  }
}

// ── The runner ───────────────────────────────────────────────────────────────

/// Flow-control constants: the window a listener opens, and how much of it is
/// handed back at a time.
///
/// The window is denominated in CHUNKS, and a chunk is one curl write — 16 KiB
/// with curl's default read buffer, which the engine deliberately leaves alone.
/// 64 chunks is therefore about 1 MiB of native memory in flight per stream,
/// matching [kUploadHighWaterMark] so both directions are bounded alike.
///
/// Measured on a 32 MiB streamed download, release builds:
///
/// ```text
///                          macOS M1 Pro   Android emulator   OnePlus (real)
///   16 credits / batch 8       162 ms             —                 —
///   64 / 16                    144 ms          373 ms            244 ms
///   256 / 64                   139 ms          324 ms              —
///   512 / 128                    —            312 ms              —
///   64 KiB chunks, 16 cr       157 ms          421 ms              —
/// ```
///
/// Depth beats chunk count everywhere it was measured: a deeper window helps and
/// FEWER, LARGER chunks at the same depth hurts, so 64 KiB chunks are the worst
/// configuration on either platform. But the gains beyond 64 are small, and the
/// Android EMULATOR column is the reason this stops here rather than at 256.
///
/// That column is not trustworthy. It said this client lost the download row by
/// 1.75x-2.1x, deterministically, which looked like per-chunk crossing cost being
/// exposed by a slow core. Two later measurements on real hardware killed that
/// theory: an iPhone 12 (A14, a *slower* core than the M1) came in at 1.08x, and a
/// real OnePlus on Android 16 at 1.13x. The emulator's virtualised I/O was the
/// artefact, not the credit loop.
///
/// A window that ramped from 64 up to 256 was built and measured on that basis.
/// On the real device it changed the median by 1.1 % — 246.6 ms against
/// 243.8 ms — while widening the run-to-run spread from 6 ms to 100 ms, because
/// the first run after an install is a cold-start outlier. It was removed again:
/// more code and up to 4 MiB of in-flight memory for nothing measurable. If this
/// is ever revisited, measure on hardware, discard the first run, and take a
/// median of at least three.
const int kInitialCredits = 64;
const int kCreditBatch = 16;

/// Bytes buffered in the native upload ring before the Dart source is paused.
const int kUploadHighWaterMark = 1 << 20;

class RequestRunner {
  RequestRunner({
    required this._executor,
    required this._demux,
    required this.settings,
  });


  final RequestExecutor _executor;
  final StreamDemux _demux;

  /// The active configuration. Reassigned by [configure].
  ClientSettings settings;

  bool _disposed = false;

  /// Token ids already registered with the engine, so the listener and the
  /// finalizer are attached exactly once no matter how many requests share the
  /// token.
  final Set<int> _boundTokens = <int>{};

  /// Reclaims a token's native entry when the Dart token becomes unreachable.
  ///
  /// Without this a long-lived client that mints a token per screen would grow
  /// the native map forever: nothing else can know a token will never be used
  /// again, since a token stays legal to cancel long after its requests finish.
  /// Releasing is safe at any moment — a transfer still bound holds its own
  /// reference to the state, so this can never revive a cancelled request.
  late final Finalizer<int> _tokenFinalizer = Finalizer<int>((int id) {
    _boundTokens.remove(id);
    // The engine is already gone after dispose, and its whole registry was
    // dropped with it.
    if (_disposed) return;
    _executor.releaseCancelToken(id);
  });

  /// Reconfigures the underlying engine. In-flight transfers keep the options
  /// they were built with.
  void configure(ClientSettings settings) {
    _checkAlive();
    this.settings = settings;
    _executor.configureClient(toRawClientConfig(settings));
  }

  void _checkAlive() {
    if (_disposed) {
      throw NitroHttpDisposedException(
        engineMessage: 'this NitroHttpClient has already been disposed',
      );
    }
  }

  /// Merges the body's implied headers into the caller's, without overriding
  /// anything the caller set explicitly.
  HttpHeaders _headersFor(HttpRequest request, EncodedBody body) {
    final headers = request.headers.clone();
    final contentType = body.contentType;
    if (contentType != null && headers.contentType == null) {
      headers.set('content-type', contentType);
    }
    return headers;
  }

  // ── Buffered path ──────────────────────────────────────────────────────────

  Future<HttpResponse> send(HttpRequest request) async {
    _checkAlive();
    return switch (request.expectedBody) {
      HttpExpectedBody.stream => sendStreamed(request),
      HttpExpectedBody.text => sendBuffered(request),
      HttpExpectedBody.bytes => sendBuffered(request),
    };
  }

  Future<HttpResponse> sendBuffered(HttpRequest request) async {
    _checkAlive();
    final requestId = Ids.nextRequest();
    final body = await encodeBody(request.body);
    final headers = _headersFor(request, body);
    final reportProgress =
        request.onSendProgress != null || request.onReceiveProgress != null;

    final raw = toRawRequest(
      requestId: requestId,
      request: request,
      headers: headers,
      body: body,
      reportProgress: reportProgress,
    );

    _bindCancelToken(request.cancelToken);
    StreamSubscription<RawEvent>? eventSub;
    if (reportProgress) {
      eventSub = _wireProgress(requestId, request);
    }

    try {
      final future = _executor.sendBuffered(raw, body.bytes);

      // Streamed request bodies are pumped while the response future is
      // outstanding — the engine returns immediately and reads from its ring.
      final pump = body.kind == RawBodyKind.streamed
          ? _pumpUpload(requestId, body.stream!)
          : null;

      final response = await future;
      // The pump may still be draining if the server responded early (a 413,
      // for example). Abandon it rather than waiting: the transfer is over.
      pump?.abandon();

      return _completeBuffered(request, response, reportProgress);
    } finally {
      await eventSub?.cancel();
      _demux.release(requestId);
    }
  }

  HttpResponse _completeBuffered(
    HttpRequest request,
    RawResponse response,
    bool reportProgress,
  ) {
    if (response.errorKind != RawErrorKind.none) {
      throw mapError(
        kind: response.errorKind,
        message: response.errorMessage,
        engineErrorCode: response.engineErrorCode,
        request: request,
      );
    }

    final meta = metadataFrom(
      request: request,
      statusCode: response.statusCode,
      reasonPhrase: response.reasonPhrase,
      version: response.version,
      headers: response.headers,
      finalUrl: response.finalUrl,
      redirectCount: response.redirectCount,
      fromCache: response.fromCache,
      revalidated: response.revalidated,
      primaryIp: response.primaryIp,
      primaryPort: response.primaryPort,
      timings: response.timings,
    );

    // NOT copied: the generated record decoder builds this with `sublist`, so it
    // is already a fresh Dart-owned `Uint8List` and a second copy bought nothing.
    // Removing it did not move the wall clock on a 32 MiB body (437 ms either
    // way) — the buffered path is bounded by the record codec's own passes over
    // the payload — but it does halve this step's peak footprint, which for a
    // large response is the difference between holding it once and twice.
    final bytes = response.body;

    if (reportProgress && request.onReceiveProgress != null) {
      // Progress events are lossy by design, so the terminal value is
      // synthesized from the completion path. Callers always see 100 %.
      request.onReceiveProgress!(bytes.length, bytes.length);
    }

    if (settings.throwOnStatusCode &&
        (meta.statusCode < 200 || meta.statusCode > 299)) {
      throw NitroHttpStatusCodeException(
        statusCode: meta.statusCode,
        headers: meta.headers,
        body: bytes,
        request: request,
      );
    }

    return switch (request.expectedBody) {
      HttpExpectedBody.bytes => HttpBytesResponse(meta: meta, bodyBytes: bytes),
      // `stream` never reaches the buffered path — `send` routes it to
      // `sendStreamed` — but the buffered text shape is the correct answer if
      // a future caller ever buffers a stream request anyway.
      HttpExpectedBody.text || HttpExpectedBody.stream => HttpTextResponse(
        meta: meta,
        bodyBytes: bytes,
      ),
    };
  }

  // ── Streamed path ──────────────────────────────────────────────────────────

  Future<HttpStreamResponse> sendStreamed(HttpRequest request) async {
    _checkAlive();
    final requestId = Ids.nextRequest();
    final body = await encodeBody(request.body);
    final headers = _headersFor(request, body);
    final reportProgress = request.onSendProgress != null;

    final raw = toRawRequest(
      requestId: requestId,
      request: request,
      headers: headers,
      body: body,
      reportProgress: reportProgress,
    );

    // Subscribe BEFORE starting: a fast server can deliver the first chunk in
    // the same turn the head arrives, and a late subscription would drop it.
    final chunkStream = _demux.chunks(requestId);

    _bindCancelToken(request.cancelToken);
    StreamSubscription<RawEvent>? eventSub;
    if (reportProgress) {
      eventSub = _wireProgress(requestId, request);
    }

    _UploadPump? pump;
    RawResponseHead head;
    try {
      final future = _executor.startStreamed(raw, body.bytes);
      if (body.kind == RawBodyKind.streamed) {
        pump = _pumpUpload(requestId, body.stream!);
      }
      head = await future;
    } on Object {
      pump?.abandon();
      await eventSub?.cancel();
      _demux.release(requestId);
      rethrow;
    }

    if (head.errorKind != RawErrorKind.none) {
      pump?.abandon();
      await eventSub?.cancel();
      _demux.release(requestId);
      throw mapError(
        kind: head.errorKind,
        message: head.errorMessage,
        engineErrorCode: head.engineErrorCode,
        request: request,
      );
    }

    final meta = metadataFrom(
      request: request,
      statusCode: head.statusCode,
      reasonPhrase: head.reasonPhrase,
      version: head.version,
      headers: head.headers,
      finalUrl: head.finalUrl,
      redirectCount: head.redirectCount,
      fromCache: head.fromCache,
      revalidated: false,
      primaryIp: head.primaryIp,
      primaryPort: head.primaryPort,
      timings: head.timings,
    );

    if (settings.throwOnStatusCode &&
        (meta.statusCode < 200 || meta.statusCode > 299)) {
      // Drain and discard so the caller gets the body in the exception rather
      // than a dangling transfer.
      final bytes = await _drain(requestId, chunkStream);
      pump?.abandon();
      await eventSub?.cancel();
      _demux.release(requestId);
      throw NitroHttpStatusCodeException(
        statusCode: meta.statusCode,
        headers: meta.headers,
        body: bytes,
        request: request,
      );
    }

    final bodyStream = _creditedBody(
      requestId: requestId,
      request: request,
      source: chunkStream,
      onDone: () async {
        pump?.abandon();
        await eventSub?.cancel();
        _demux.release(requestId);
      },
    );

    return HttpStreamResponse(
      meta: meta,
      body: bodyStream,
      contentLength: head.contentLength < 0 ? null : head.contentLength,
    );
  }

  /// Wraps the demultiplexed chunk stream in the credit loop.
  ///
  /// Credits are granted on listen and topped up every [kCreditBatch] chunks.
  /// `ackedChunks` is the count this side has copied, which is exactly the count
  /// it has received — the demux copies before it emits.
  Stream<List<int>> _creditedBody({
    required int requestId,
    required HttpRequest request,
    required Stream<ChunkEvent> source,
    required Future<void> Function() onDone,
  }) {
    late StreamController<List<int>> controller;
    StreamSubscription<ChunkEvent>? sub;
    var received = 0;
    var outstanding = 0;
    var closed = false;
    var receivedBytes = 0;

    void topUp() {
      // Withhold credits entirely while the consumer is paused: that is how
      // consumer backpressure reaches the TCP window.
      if (controller.isPaused || closed) return;
      final deficit = kInitialCredits - outstanding;
      if (deficit <= 0) return;
      outstanding += deficit;
      _executor.grantCredit(requestId, deficit, received);
    }

    Future<void> finish([Object? error, StackTrace? stack]) async {
      if (closed) return;
      closed = true;
      await sub?.cancel();
      // Release whatever native is still holding for this request.
      _executor.grantCredit(requestId, 0, received);
      if (error != null) {
        controller.addError(error, stack);
      }
      await onDone();
      await controller.close();
    }

    controller = StreamController<List<int>>(
      onListen: () {
        sub = source.listen(
          (chunk) {
            if (closed) return;
            if (chunk.isData) {
              received++;
              outstanding--;
              receivedBytes += chunk.bytes.length;
              controller.add(chunk.bytes);
              request.onReceiveProgress?.call(receivedBytes, null);
              if (outstanding <= kInitialCredits - kCreditBatch) topUp();
            } else if (chunk.isDone) {
              received++;
              finish();
            } else {
              received++;
              finish(
                mapError(
                  kind: RawErrorKind.values[chunk.aux],
                  message: String.fromCharCodes(chunk.bytes),
                  engineErrorCode: 0,
                  request: request,
                ),
                StackTrace.current,
              );
            }
          },
          onDone: () => finish(),
          onError: (Object e, StackTrace s) => finish(e, s),
        );
        topUp();
      },
      onPause: () {
        // Nothing to do: `topUp` refuses to grant while paused, so native runs
        // out of credit and pauses the socket by itself.
      },
      onResume: topUp,
      onCancel: () async {
        // The consumer walked away mid-body. Cancel the transfer so the socket
        // closes instead of downloading into a discarded stream.
        _executor.cancel(requestId);
        await finish();
      },
    );

    return controller.stream;
  }

  /// Collects a streamed body into memory. Used only for the error path, where
  /// the body is small by construction and belongs in the exception.
  Future<Uint8List> _drain(int requestId, Stream<ChunkEvent> source) async {
    final out = <int>[];
    var received = 0;
    _executor.grantCredit(requestId, kInitialCredits, 0);
    await for (final chunk in source) {
      received++;
      if (chunk.isData) {
        out.addAll(chunk.bytes);
        _executor.grantCredit(requestId, 1, received);
      } else {
        break;
      }
    }
    // The terminal ack is what releases the native payloads for this request —
    // including any the engine handed to its deferred registry when the task
    // tore down. It must happen on every exit from this loop, not only the
    // break, or a body that ends by stream closure leaks its chunks.
    _executor.grantCredit(requestId, 0, received);
    return Uint8List.fromList(out);
  }

  // ── Upload pump ────────────────────────────────────────────────────────────

  _UploadPump _pumpUpload(int requestId, Stream<List<int>> source) {
    final pump = _UploadPump(
      requestId: requestId,
      executor: _executor,
      events: _demux.events(requestId),
    );
    pump.start(source);
    return pump;
  }

  // ── Cancellation and progress wiring ───────────────────────────────────────

  /// Returns a disposer for the token listener, or null when there is no token.
  /// Registers the token with the engine once, ever.
  ///
  /// The listener is per TOKEN, not per request: the engine reaches every bound
  /// transfer from the token id alone, so a token shared by 100 in-flight
  /// requests needs one native call on cancel rather than 100. That is also why
  /// nothing is unregistered when a request finishes — the registration
  /// describes the token, not any one transfer, and re-adding it per request
  /// would reintroduce the fan-out this replaces.
  ///
  /// An already-cancelled token needs no listener at all: `cancelTokenId`
  /// travels inside the request, and the engine refuses it in `startTask`
  /// before opening a socket. The caller still gets exactly one completion,
  /// carrying the same `cancelled` error as any other cancellation.
  void _bindCancelToken(CancelToken? token) {
    if (token == null) return;
    final int id = token.nativeId;
    if (!_boundTokens.add(id)) return;

    // Attached before the cancelled-check below so even a token that is only
    // ever used post-cancellation still gets its native entry reclaimed.
    _tokenFinalizer.attach(token, id, detach: token);

    if (token.isCancelled) {
      _executor.cancelToken(id, token.reason ?? '');
      return;
    }
    token.addListener(() => _executor.cancelToken(id, token.reason ?? ''));
  }

  StreamSubscription<RawEvent> _wireProgress(
    int requestId,
    HttpRequest request,
  ) {
    return _demux.events(requestId).listen((event) {
      switch (event.kind) {
        case RawEventKind.downloadProgress:
          request.onReceiveProgress?.call(event.a, event.b < 0 ? null : event.b);
        case RawEventKind.uploadProgress:
          request.onSendProgress?.call(event.a, event.b < 0 ? null : event.b);
        case RawEventKind.uploadDrain:
        case RawEventKind.notice:
          break;
      }
    });
  }

  // ── Cookies ────────────────────────────────────────────────────────────────

  List<RawCookie> rawCookies(String url) {
    _checkAlive();
    return _executor.getCookies(url);
  }

  void setRawCookie(RawCookie cookie) {
    _checkAlive();
    _executor.setCookie(cookie);
  }

  void clearCookies() {
    _checkAlive();
    _executor.clearCookies();
  }

  void flushCookies() {
    _checkAlive();
    _executor.flushCookies();
  }

  void cancelAll() {
    if (_disposed) return;
    _executor.cancelAll();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _executor.cancelAll();
    _executor.dispose();
  }
}

/// Feeds a streamed request body into the native ring, pausing above the
/// high-water mark and resuming on `uploadDrain`.
class _UploadPump {
  _UploadPump({
    required this.requestId,
    required this._executor,
    required this._events,
  });

  final int requestId;
  final RequestExecutor _executor;
  final Stream<RawEvent> _events;

  StreamSubscription<List<int>>? _sub;
  StreamSubscription<RawEvent>? _drainSub;
  var _abandoned = false;

  void start(Stream<List<int>> source) {
    _drainSub = _events.listen((event) {
      if (event.kind == RawEventKind.uploadDrain &&
          event.a < kUploadHighWaterMark) {
        final sub = _sub;
        if (sub != null && sub.isPaused) sub.resume();
      }
    });

    _sub = source.listen(
      (data) {
        if (_abandoned) return;
        final bytes = data is Uint8List ? data : Uint8List.fromList(data);
        // Forwarded immediately, NOT coalesced. Batching source events into
        // larger feeds was measured on an 8 MiB streamed upload and made it
        // slower (122 ms -> 140 ms): the engine drains the ring the moment
        // anything lands, so any delay before feeding is time curl spends parked,
        // and one event-loop turn of accumulation costs more than the wake-up it
        // saves.
        final buffered = _executor.feedUploadChunk(requestId, bytes);
        if (buffered >= kUploadHighWaterMark) _sub?.pause();
      },
      onDone: () {
        if (_abandoned) return;
        _executor.finishUpload(requestId);
        _drainSub?.cancel();
      },
      onError: (Object e, StackTrace _) {
        if (_abandoned) return;
        // A failing source must abort the transfer, not silently truncate the
        // body into a server-visible short write.
        _executor.failUpload(requestId, e.toString());
        _drainSub?.cancel();
      },
      cancelOnError: true,
    );
  }

  void abandon() {
    if (_abandoned) return;
    _abandoned = true;
    _sub?.cancel();
    _drainSub?.cancel();
  }
}
