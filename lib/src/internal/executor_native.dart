/// The FFI-backed [RequestExecutor] and [StreamDemux].
///
/// Split out of `request_runner.dart` so the runner carries no transitive FFI
/// dependency: this library drives the native `NitroHttpNative` bindings, which
/// cannot compile for the browser, so web selects `executor_web.dart` instead.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:nitro/nitro.dart'
    show NitroBuffer, NitroConfig, NitroRuntime, nitroRegisterZeroCopyView;

import '../nitro_http.native.dart';
import 'instance_keys.dart';
import 'native_attach.dart';
import '../api/settings.dart';
import 'request_runner.dart';

// ── Zero-copy response bodies ────────────────────────────────────────────────

/// Held for good once the first body is adopted. On Android, Linux and Windows
/// `NitroRuntime.releaseLib` unmaps the library at refcount zero, and a body
/// still alive after that would run a finalizer that no longer exists.
final DynamicLibrary _pinnedLibrary = NitroRuntime.loadLib('nitro_http');

final Pointer<NativeFinalizerFunction> _freePayload = () {
  _pinnedLibrary;
  return Pointer<NativeFinalizerFunction>.fromAddress(
    NitroHttpNative.engine.chunkFinalizerAddress(),
  );
}();

/// Takes [view], native memory the engine frees once it is acked, out of the
/// engine's hands: whole when the engine offered it under [owner], by copy
/// otherwise. Null when the engine released an offered block first, which it
/// only does for a request or socket it has already torn down.
Uint8List? takeNativeBytes(Uint8List view, int owner) {
  if (owner == 0) return Uint8List.fromList(view);
  final address = NitroHttpNative.engine.adoptChunk(owner);
  if (address == 0) return null;
  return Pointer<Uint8>.fromAddress(address)
      .asTypedList(view.length, finalizer: _freePayload);
}

/// Request bodies at least this large are written straight into a block the
/// engine keeps; below it the generated copy is as fast or faster.
const int _ownedBodyMinBytes = 16 * 1024;

// ── Completion spin ──────────────────────────────────────────────────────────

/// Runs [call] with nitro's completion spin off, then restores the setting.
/// The spin busy-waits for a result that is already there, which an HTTP
/// response never is. nitro reads the setting when the call is made, so other
/// nitro plugins keep their own.
T _withoutSpin<T>(T Function() call) {
  final cfg = NitroConfig.instance;
  final saved = cfg.nativeAsyncSpinUs;
  cfg.nativeAsyncSpinUs = 0;
  try {
    return call();
  } finally {
    cfg.nativeAsyncSpinUs = saved;
  }
}

// ── Native implementations ───────────────────────────────────────────────────

/// Wraps one `c:<clientId>` instance.
final class NativeRequestExecutor implements RequestExecutor {
  NativeRequestExecutor(this.clientId)
    : _native = attachedNative(clientKey(clientId));

  final int clientId;
  final NitroHttpNative _native;
  bool _disposed = false;

  @override
  void configureClient(RawClientConfig config) =>
      _native.configureClient(config);

  /// Finalizer of every adopted body; see `bodyFinalizerAddress`.
  late final Pointer<NativeFinalizerFunction> _freeBody = () {
    _pinnedLibrary;
    return Pointer<NativeFinalizerFunction>.fromAddress(
      _native.bodyFinalizerAddress(),
    );
  }();

  /// Takes ownership of a body the engine detached from the record (see
  /// `RawResponse.bodyOwner`), wrapping the native bytes without copying them.
  RawResponse _adoptBody(RawResponse r) {
    if (r.bodyOwner == 0) return r;
    final bytes = Pointer<Uint8>.fromAddress(r.bodyAddress).asTypedList(
      r.bodyLength,
      finalizer: _freeBody,
      token: Pointer<Void>.fromAddress(r.bodyOwner),
    );
    return RawResponse(
      requestId: r.requestId,
      errorKind: r.errorKind,
      errorMessage: r.errorMessage,
      engineErrorCode: r.engineErrorCode,
      statusCode: r.statusCode,
      reasonPhrase: r.reasonPhrase,
      version: r.version,
      finalUrl: r.finalUrl,
      redirectCount: r.redirectCount,
      headers: r.headers,
      body: bytes,
      fromCache: r.fromCache,
      revalidated: r.revalidated,
      primaryIp: r.primaryIp,
      primaryPort: r.primaryPort,
      timings: r.timings,
    );
  }

  /// Runs [send] with a large [body] in a block the engine keeps. The
  /// generated call passes a registered native view by address.
  T _withOwnedBody<T>(Uint8List body, T Function(Uint8List body) send) {
    if (body.length < _ownedBodyMinBytes) return send(body);
    final address = _native.allocRequestBody(body.length);
    if (address == 0) return send(body);
    final block = Pointer<Uint8>.fromAddress(address);
    final view = block.asTypedList(body.length)..setAll(0, body);
    try {
      return send(nitroRegisterZeroCopyView(view, block.cast()));
    } on Object {
      // The call threw before the engine took the block.
      _native.freeRequestBody(address);
      rethrow;
    }
  }

  @override
  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body) =>
      _withOwnedBody(
        body,
        (body) => _withoutSpin(() => _native.sendBuffered(request, body)),
      ).then(_adoptBody);

  @override
  Future<RawResponseHead> startStreamed(RawRequest request, Uint8List body) =>
      _withOwnedBody(
        body,
        (body) => _withoutSpin(() => _native.startStreamed(request, body)),
      );

  @override
  RawResponse cachedResponse(RawRequest request) =>
      _native.cachedResponse(request);

  @override
  UploadWriter? openUploadWriter(int requestId) =>
      _NativeUploadWriter(this, requestId);

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
    // `_native.dispose()` aborts every in-flight transfer; those abort
    // completions ride nitro's shared completion batch, which the runtime drains
    // and closes with the instance, so nothing is left hanging here.
    _native.dispose();
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
    final c = _chunkControllers[raw.requestId];
    // A cancelled request's tail can arrive after its controller is gone.
    // The engine frees it.
    if (c == null || c.isClosed) return;
    final bytes = takeNativeBytes(raw.bytes, raw.owner);
    if (bytes == null) return;
    c.add(
      ChunkEvent(
        requestId: raw.requestId,
        kind: raw.kind,
        aux: raw.aux,
        bytes: bytes,
      ),
    );
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

/// The FFI half of [UploadWriter]: a view over the region the engine lent out,
/// filled with one `setRange`, published with one call.
final class _NativeUploadWriter implements UploadWriter {
  _NativeUploadWriter(this._owner, this._requestId) {
    _out.bytes.fillRange(0, _out.bytes.length, 0);
  }

  /// What is reserved ahead for the next chunk. A larger chunk asks for its
  /// own room when it arrives; reserving its size ahead of time instead would
  /// leave a body that fits its pipe exactly asking for room past its own end
  /// after the last chunk, and the pipe growing to provide it.
  static const int _minReserve = 64 * 1024;

  final NativeRequestExecutor _owner;
  final int _requestId;

  /// Where the engine reports back: region address, bytes buffered, pause depth.
  final NitroBuffer _out = NitroBuffer(24);
  late final Int64List _reply = Int64List.sublistView(_out.bytes);

  var _address = 0;
  var _capacity = 0;
  var _highWaterMark = kUploadHighWaterMark;
  var _released = false;

  @override
  int get highWaterMark => _highWaterMark;

  /// Publishes [commit] bytes and asks for [reserve] more. False once the
  /// upload is closed, after which nothing here may be written to again.
  bool _exchange(int commit, int reserve) {
    final open =
        _owner._native.uploadWrite(
          _requestId,
          commit,
          reserve,
          _out.pointer.address,
        ) !=
        0;
    _address = open ? _reply[0] : 0;
    _capacity = open ? reserve : 0;
    if (open) _highWaterMark = _reply[2];
    return open;
  }

  @override
  int write(List<int> chunk) {
    // A disposed client's native instance is gone; calling into it hangs.
    if (_released || _owner._disposed) return -1;
    final n = chunk.length;
    if ((_address == 0 || _capacity < n) &&
        !_exchange(0, n > _minReserve ? n : _minReserve)) {
      return -1;
    }
    if (n > 0) {
      Pointer<Uint8>.fromAddress(_address).asTypedList(n).setRange(0, n, chunk);
    }
    return _exchange(n, _minReserve) ? _reply[1] : -1;
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    if (!_owner._disposed) _owner._native.uploadRelease(_requestId);
    _out.dispose();
  }
}
