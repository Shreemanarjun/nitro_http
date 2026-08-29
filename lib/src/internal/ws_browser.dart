/// The browser-backed [WsExecutor], and the demux that feeds it.
///
/// A page cannot open a socket, so the engine's `WsSession` has nothing to run
/// on. The browser's own `WebSocket` is the only transport available, and it is
/// enough: `NitroWebSocket` already implements `package:web_socket`'s interface,
/// so delegating to that package's browser implementation keeps the same API.
///
/// The socket is injected rather than constructed here so this library imports
/// nothing browser-only and can be tested on the VM against a fake.
/// `ws_web.dart` supplies the real one.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket/web_socket.dart' as ws;

import '../api/exceptions.dart';
import '../nitro_http.native.dart';
import 'ws_runner.dart';

/// Opens the underlying socket. Replaced in tests.
typedef BrowserSocketFactory =
    Future<ws.WebSocket> Function(Uri url, Iterable<String> protocols);

/// Drives a [ws.WebSocket] behind the [WsExecutor] seam.
final class BrowserWsExecutor implements WsExecutor {
  /// Creates an executor for [socketId] that opens sockets with [open].
  BrowserWsExecutor(this.socketId, this.open);

  /// Identifies this socket to the demux, matching the native path.
  final int socketId;

  /// How the socket is opened.
  final BrowserSocketFactory open;

  ws.WebSocket? _socket;
  var _disposed = false;

  @override
  Future<RawWsHandshake> connect(RawWsConfig config) async {
    _rejectUnsupported(config);
    final demux = BrowserWsFrameDemux.instance;
    try {
      final socket = await open(
        Uri.parse(config.url),
        config.protocols,
      );
      _socket = socket;

      socket.events.listen(
        (event) => demux.push(_eventOf(event)),
        onError: (Object error) => demux.push(
          WsFrameEvent(
            socketId: socketId,
            opcode: WsOpcode.transportError,
            fin: true,
            payload: Uint8List.fromList('$error'.codeUnits),
          ),
        ),
        onDone: () => demux.push(_closeFrame(1006, 'connection closed')),
      );

      return RawWsHandshake(
        socketId: socketId,
        errorKind: RawErrorKind.none,
        errorMessage: '',
        engineErrorCode: 0,
        // The browser never exposes the upgrade response, so 101 is reported as
        // the fact it stands for: the upgrade happened.
        statusCode: 101,
        negotiatedProtocol: socket.protocol,
        responseHeaders: const [],
      );
    } on ws.WebSocketException catch (error) {
      return RawWsHandshake(
        socketId: socketId,
        errorKind: RawErrorKind.io,
        errorMessage: error.message,
        engineErrorCode: 0,
        statusCode: 0,
        negotiatedProtocol: '',
        responseHeaders: const [],
      );
    }
  }

  WsFrameEvent _eventOf(ws.WebSocketEvent event) => switch (event) {
    ws.TextDataReceived(:final text) => WsFrameEvent(
      socketId: socketId,
      opcode: WsOpcode.text,
      fin: true,
      payload: Uint8List.fromList(text.codeUnits),
    ),
    ws.BinaryDataReceived(:final data) => WsFrameEvent(
      socketId: socketId,
      opcode: WsOpcode.binary,
      fin: true,
      payload: data,
    ),
    ws.CloseReceived(:final code, :final reason) => _closeFrame(
      code ?? 1005,
      reason,
    ),
  };

  WsFrameEvent _closeFrame(int code, String reason) => WsFrameEvent(
    socketId: socketId,
    opcode: WsOpcode.close,
    fin: true,
    payload: Uint8List.fromList([
      (code >> 8) & 0xFF,
      code & 0xFF,
      ...reason.codeUnits,
    ]),
  );

  void _rejectUnsupported(RawWsConfig config) {
    // The browser owns the handshake: a page cannot set request headers on it,
    // pin a certificate, or choose a ping interval. Saying so beats accepting
    // the setting and doing nothing with it.
    final unsupported = <String>[
      if (config.headers.isNotEmpty) 'headers',
      if (config.pingIntervalMs > 0) 'pingInterval',
      if (config.tls.pinnedSpkiSha256.isNotEmpty) 'tlsSettings.pinnedSpkiSha256',
      if (config.tls.trustedRootsPem.isNotEmpty) 'tlsSettings.trustedRootsPem',
      if (!config.tls.verifyCertificates) 'tlsSettings.insecure()',
    ];
    if (unsupported.isEmpty) return;
    throw NitroHttpConfigurationException(
      engineMessage:
          'not available for a browser WebSocket: ${unsupported.join(', ')}. '
          'The browser performs the upgrade and owns its TLS and keepalive.',
    );
  }

  @override
  int send(int opcode, Uint8List payload) {
    final socket = _socket;
    if (socket == null || _disposed) return 0;
    if (opcode == WsOpcode.text.wire) {
      socket.sendText(String.fromCharCodes(payload));
    } else {
      socket.sendBytes(payload);
    }
    return payload.length;
  }

  @override
  void close(int code, String reason) {
    unawaited(_socket?.close(code, reason));
  }

  /// The browser applies its own backpressure, so there is no credit window.
  @override
  void grantCredit(int frameCount, int ackedFrames) {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_socket?.close());
    BrowserWsFrameDemux.instance.release(socketId);
  }
}

/// The browser counterpart of the native frame demux.
final class BrowserWsFrameDemux implements WsFrameDemux {
  BrowserWsFrameDemux._();

  /// The process-wide instance, matching the native demux's shape.
  static final BrowserWsFrameDemux instance = BrowserWsFrameDemux._();

  final _controllers = <int, StreamController<WsFrameEvent>>{};

  StreamController<WsFrameEvent> _controllerFor(int socketId) =>
      _controllers.putIfAbsent(socketId, StreamController<WsFrameEvent>.new);

  /// Hands one frame to whoever is reading [WsFrameEvent.socketId].
  void push(WsFrameEvent event) {
    final controller = _controllerFor(event.socketId);
    if (!controller.isClosed) controller.add(event);
  }

  @override
  Stream<WsFrameEvent> frames(int socketId) => _controllerFor(socketId).stream;

  @override
  void release(int socketId) {
    unawaited(_controllers.remove(socketId)?.close());
  }
}
