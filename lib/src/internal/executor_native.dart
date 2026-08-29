/// The FFI-backed [RequestExecutor] and [StreamDemux].
///
/// Split out of `request_runner.dart` so the runner itself carries no
/// `dart:ffi` import: web selects `executor_web.dart` instead, and a library
/// that imports `dart:ffi` at all cannot be compiled for the browser.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:nitro/nitro.dart' show NitroCoalescer, RecordReader;

import '../api/exceptions.dart';
import '../nitro_http.native.dart';
import 'instance_keys.dart';
import 'native_attach.dart';
import '../api/settings.dart';
import 'request_runner.dart';

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

    final int address;
    try {
      address = await coalescer.submit(
        (int callId, int port) =>
            _native.sendBufferedCoalesced(callId, request, body, port),
      );
    } on StateError catch (error) {
      // nitro 0.6.1 settles a call the coalescer can no longer deliver — the
      // client was disposed mid-request — with a StateError rather than
      // dropping it, which is what used to leave the Future hanging forever
      // (nitro_ecosystem#47). Only the type is ours to improve: a caller should
      // see this API's disposed exception, not the runtime's internal error.
      throw NitroHttpDisposedException(engineMessage: error.message);
    }

    if (address == 0) {
      // The batch wire has no null, so zero is how native says "could not even
      // encode the error envelope" — the coalesced twin of `postNull`.
      throw StateError(
        'sendBufferedCoalesced: native could not encode the response record',
      );
    }
    try {
      return RawResponseRecordExt.fromReader(
        RecordReader.fromNative(Pointer<Uint8>.fromAddress(address)),
      );
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

    // `NitroCoalescer.dispose()` drains what native already posted before
    // closing, and fails anything genuinely lost, so nothing here has to.
    unawaited(_coalescer?.dispose() ?? Future<void>.value());
    _coalescer = null;
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


/// The executor a client gets on a platform with `dart:ffi`.
RequestExecutor defaultExecutor(int clientId, ClientSettings settings) =>
    NativeRequestExecutor(clientId);

/// The demux a client gets on a platform with `dart:ffi`.
StreamDemux get defaultDemux => NativeStreamDemux.instance;
