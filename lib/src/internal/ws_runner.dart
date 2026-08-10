/// The WebSocket half of the bridge orchestration.
///
/// Mirrors `request_runner.dart`: a per-socket executor seam plus one
/// process-wide demultiplexer over the module-global `wsFrames` stream. Frame
/// payloads are copied on arrival and acked through `wsGrantCredit`, for exactly
/// the reason the chunk stream needs it — the generated release symbol frees
/// only the struct shell.
library;

import 'dart:async';
import 'dart:typed_data';

import '../nitro_http.native.dart';
import 'instance_keys.dart';

/// RFC 6455 opcodes, plus the sentinel the engine uses to surface a transport
/// failure on the same stream instead of inventing a second channel.
///
/// An enum rather than a set of `static const int`s so that a `switch` over it is
/// checked for exhaustiveness. As bare ints the compiler could not tell a
/// complete handler from an incomplete one, so [unknown] existed only as an
/// unnamed `default` branch and a new engine-side opcode would have fallen
/// through it silently.
enum WsOpcode {
  continuation(0),
  text(1),
  binary(2),
  close(8),
  ping(9),
  pong(10),

  /// Not an RFC opcode: the engine's own signal that the socket failed at the
  /// transport level, delivered in-band so a caller has one stream to watch.
  transportError(255),

  /// Anything this build does not recognise. Reserved RFC opcodes land here, and
  /// so would a value from a newer engine than this Dart layer.
  ///
  /// [wire] is deliberately not a real opcode: it exists so the enum is total
  /// over `int` without pretending an unknown frame can be sent.
  unknown(-1);

  const WsOpcode(this.wire);

  /// The value that travels over the bridge.
  final int wire;

  /// Maps a wire value onto the enum, collapsing everything unrecognised to
  /// [unknown]. This is the single place an `int` becomes a typed opcode.
  static WsOpcode fromWire(int value) => switch (value) {
    0 => continuation,
    1 => text,
    2 => binary,
    8 => close,
    9 => ping,
    10 => pong,
    255 => transportError,
    _ => unknown,
  };
}

/// A frame whose payload has already been copied out of native memory.
final class WsFrameEvent {
  WsFrameEvent({
    required this.socketId,
    required this.opcode,
    required this.fin,
    required this.payload,
  });

  final int socketId;
  final WsOpcode opcode;
  final bool fin;
  final Uint8List payload;
}

/// Per-socket native calls.
abstract interface class WsExecutor {
  Future<RawWsHandshake> connect(RawWsConfig config);
  int send(int opcode, Uint8List payload);
  void close(int code, String reason);
  void grantCredit(int frameCount, int ackedFrames);
  void dispose();
}

abstract interface class WsFrameDemux {
  Stream<WsFrameEvent> frames(int socketId);
  void release(int socketId);
}

final class NativeWsExecutor implements WsExecutor {
  NativeWsExecutor(this.socketId)
    : _native = NitroHttpNative.forKey(socketKey(socketId));

  final int socketId;
  final NitroHttpNative _native;
  var _disposed = false;

  @override
  Future<RawWsHandshake> connect(RawWsConfig config) =>
      _native.wsConnect(config);

  @override
  int send(int opcode, Uint8List payload) => _native.wsSend(opcode, payload);

  @override
  void close(int code, String reason) => _native.wsClose(code, reason);

  @override
  void grantCredit(int frameCount, int ackedFrames) =>
      _native.wsGrantCredit(frameCount, ackedFrames);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _native.dispose();
  }
}

/// Exactly one instance, exactly one subscription to `wsFrames`.
final class NativeWsFrameDemux implements WsFrameDemux {
  NativeWsFrameDemux._() {
    _sub = NitroHttpNative.engine.wsFrames.listen(_onFrame);
  }

  static NativeWsFrameDemux? _instance;

  static NativeWsFrameDemux get instance =>
      _instance ??= NativeWsFrameDemux._();

  late final StreamSubscription<RawWsFrame> _sub;
  final _controllers = <int, StreamController<WsFrameEvent>>{};

  void _onFrame(RawWsFrame raw) {
    // COPY FIRST — the payload is native-owned until we ack it.
    final event = WsFrameEvent(
      socketId: raw.socketId,
      // The one place a wire int becomes a typed opcode.
      opcode: WsOpcode.fromWire(raw.opcode),
      fin: (raw.flags & 1) != 0,
      payload: Uint8List.fromList(raw.payload),
    );
    final c = _controllers[event.socketId];
    if (c != null && !c.isClosed) c.add(event);
  }

  @override
  Stream<WsFrameEvent> frames(int socketId) => _controllers
      .putIfAbsent(socketId, () => StreamController<WsFrameEvent>())
      .stream;

  @override
  void release(int socketId) {
    _controllers.remove(socketId)?.close();
  }

  /// Test-only teardown.
  Future<void> disposeForTesting() async {
    await _sub.cancel();
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
    _instance = null;
  }
}
