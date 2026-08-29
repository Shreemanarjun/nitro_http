/// WebSocket support, implementing the Dart team's `package:web_socket`
/// interchange interface.
///
/// Implementing [WebSocket] rather than inventing another API buys free
/// interoperability with `web_socket_channel` (via its `.fromWebSocket`
/// adapter) and with anything else built against the official interface, at the
/// cost of a dependency that is pure Dart and a few hundred lines.
///
/// **Known limitation, stated plainly:** the transport is an HTTP/1.1 Upgrade.
/// RFC 8441 (WebSockets over HTTP/2) is not implemented — neither libcurl nor
/// reqwest implements it either.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket/web_socket.dart';

import '../internal/instance_keys.dart';
import '../internal/ws_default.dart';
import '../internal/ws_runner.dart';
import '../nitro_http.native.dart';
import '../internal/raw_mapping.dart';
import 'headers.dart';
import 'settings.dart';

export 'package:web_socket/web_socket.dart'
    show
        BinaryDataReceived,
        CloseReceived,
        TextDataReceived,
        WebSocket,
        WebSocketConnectionClosed,
        WebSocketEvent,
        WebSocketException;

/// Flow control: frames the engine may emit before it stops reading the socket.
/// Small on purpose — the point is to let the TCP window close rather than to
/// buffer in Dart.
const int _kInitialFrameCredits = 32;
const int _kFrameCreditBatch = 16;

/// A WebSocket whose framing, masking and close handshake run in C++ over a
/// libcurl-established (and libcurl-TLS-terminated) connection.
final class NitroWebSocket implements WebSocket {
  NitroWebSocket._({
    required this._socketId,
    required this._executor,
    required this._demux,
    required this.protocol,
    required this._responseHeaders,
    required this._statusCode,
  });

  /// Opens a connection.
  ///
  /// [url] must use the `ws` or `wss` scheme. [protocols] are offered to the
  /// peer; the selected one is available as [protocol].
  ///
  /// [pingInterval] enables automatic keepalive pings from the native side; the
  /// peer's pings are answered automatically regardless. [maxFrameBytes] is both
  /// the outgoing fragment size and the cap on an incoming *reassembled
  /// message*: a peer exceeding it closes the connection with code 1009. That is
  /// deliberate — an unbounded reassembly buffer is a denial of service waiting
  /// to happen.
  static Future<NitroWebSocket> connect(
    Uri url, {
    Iterable<String>? protocols,
    HttpHeaders? headers,
    Duration? pingInterval,
    Duration connectTimeout = const Duration(seconds: 30),
    int maxFrameBytes = 1 << 20,
    /// TLS for a `wss://` URL. Ignored for `ws://`.
    ///
    /// Defaults to the same thing a `NitroHttpClient` with untouched settings
    /// uses: verification on, platform roots. Pass a configured [TlsSettings]
    /// to pin, supply a client certificate, or trust a private CA — none of
    /// which a WebSocket could do before, because the wire config had no TLS
    /// block and the engine hardcoded these defaults.
    TlsSettings tlsSettings = const TlsSettings(),
    WsExecutor? executor,
    WsFrameDemux? demux,
  }) async {
    if (url.scheme != 'ws' && url.scheme != 'wss') {
      throw ArgumentError.value(
        url.toString(),
        'url',
        'must use the ws or wss scheme',
      );
    }

    final socketId = Ids.nextSocket();
    final exec = executor ?? defaultWsExecutor(socketId);
    final dmx = demux ?? defaultWsDemux;

    // Subscribe before connecting: a chatty server can push a frame in the same
    // turn the handshake completes.
    final frames = dmx.frames(socketId);

    final RawWsHandshake handshake;
    try {
      handshake = await exec.connect(
        RawWsConfig(
          socketId: socketId,
          url: url.toString(),
          protocols: List<String>.unmodifiable(protocols ?? const <String>[]),
          headers: <RawHeader>[
            for (final (name, value)
                in headers?.entries ?? const <(String, String)>[])
              RawHeader(name: name, value: value),
          ],
          pingIntervalMs: pingInterval?.inMilliseconds ?? 0,
          maxFrameBytes: maxFrameBytes,
          tls: toRawTls(tlsSettings),
          connectTimeoutMs: connectTimeout.inMilliseconds,
        ),
      );
    } on Object {
      dmx.release(socketId);
      exec.dispose();
      rethrow;
    }

    if (handshake.errorKind != RawErrorKind.none) {
      dmx.release(socketId);
      exec.dispose();
      throw WebSocketException(
        handshake.errorMessage.isEmpty
            ? 'WebSocket handshake to $url failed'
            : handshake.errorMessage,
      );
    }

    final responseHeaders = HttpHeaders();
    for (final h in handshake.responseHeaders) {
      responseHeaders.add(h.name, h.value);
    }

    final socket = NitroWebSocket._(
      socketId: socketId,
      executor: exec,
      demux: dmx,
      protocol: handshake.negotiatedProtocol,
      responseHeaders: responseHeaders,
      statusCode: handshake.statusCode,
    );
    socket._start(frames);
    return socket;
  }

  final int _socketId;
  final WsExecutor _executor;
  final WsFrameDemux _demux;
  final HttpHeaders _responseHeaders;
  final int _statusCode;

  @override
  final String protocol;

  /// Headers from the 101 response. Useful for servers that carry session state
  /// on the upgrade, which the official interface has no slot for.
  HttpHeaders get handshakeHeaders => _responseHeaders;

  /// The upgrade response's status code — 101 on success.
  int get handshakeStatusCode => _statusCode;

  final _events = StreamController<WebSocketEvent>();

  /// Resolves when the engine's terminal frame has been processed.
  ///
  /// Separate from `_events.done` on purpose. `_events` is single-subscription,
  /// so its `done` future only completes once a listener has drained every
  /// buffered event — and a `StreamQueue` with no outstanding request pauses its
  /// subscription, which would deadlock `close()` against a consumer that is
  /// waiting for `close()` to return. Teardown is an engine fact; it must not be
  /// gated on what the application does with the stream.
  final _closedByEngine = Completer<void>();

  StreamSubscription<WsFrameEvent>? _sub;
  var _received = 0;
  var _outstanding = 0;
  var _closed = false;
  var _closeSent = false;

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  void _start(Stream<WsFrameEvent> frames) {
    _sub = frames.listen(_onFrame, onDone: () => _finish(1006, ''));
    _topUp();
  }

  void _topUp() {
    if (_closed) return;
    final deficit = _kInitialFrameCredits - _outstanding;
    if (deficit <= 0) return;
    _outstanding += deficit;
    _executor.grantCredit(deficit, _received);
  }

  void _onFrame(WsFrameEvent frame) {
    if (_closed) return;
    _received++;
    _outstanding--;

    switch (frame.opcode) {
      case WsOpcode.text:
        // The engine reassembles fragments, so a delivered text frame is a
        // complete message. Malformed UTF-8 is tolerated rather than fatal:
        // dropping a whole connection over one bad byte is worse.
        _events.add(
          TextDataReceived(utf8.decode(frame.payload, allowMalformed: true)),
        );
      case WsOpcode.binary:
        _events.add(BinaryDataReceived(frame.payload));
      case WsOpcode.close:
        final (code, reason) = _decodeClose(frame.payload);
        _finish(code, reason);
        return;
      case WsOpcode.transportError:
        // 1006 is the RFC's "abnormal closure, no close frame received", which
        // is exactly what a transport failure is.
        _finish(
          1006,
          utf8.decode(frame.payload, allowMalformed: true),
        );
        return;
      case WsOpcode.ping:
      case WsOpcode.pong:
        // Answered natively; nothing for the application to see.
        break;
      case WsOpcode.continuation:
      case WsOpcode.unknown:
        // Named rather than swept up by a `default`, which is the whole point of
        // `WsOpcode` being an enum: the engine reassembles fragments before it
        // ever posts a frame, so a continuation reaching Dart would be an engine
        // bug, and a reserved or newer opcode carries nothing this build can act
        // on. Both are dropped deliberately — and if a new opcode is added to the
        // enum, this switch stops compiling instead of silently ignoring it.
        break;
    }

    if (_outstanding <= _kInitialFrameCredits - _kFrameCreditBatch) _topUp();
  }

  static (int, String) _decodeClose(Uint8List payload) {
    if (payload.length < 2) return (1005, '');
    final code = (payload[0] << 8) | payload[1];
    final reason = payload.length > 2
        ? utf8.decode(payload.sublist(2), allowMalformed: true)
        : '';
    return (code, reason);
  }

  void _finish(int? code, String reason) {
    if (_closed) return;
    _closed = true;
    _sub?.cancel();
    // Release whatever the engine is still holding for this socket.
    _executor.grantCredit(0, _received);
    _events.add(CloseReceived(code, reason));
    // Not awaited: a controller with no listener, or one whose listener is
    // paused, keeps this future pending until somebody drains it.
    unawaited(_events.close());
    _demux.release(_socketId);
    _executor.dispose();
    if (!_closedByEngine.isCompleted) _closedByEngine.complete();
  }

  @override
  void sendText(String s) {
    _requireOpen();
    _executor.send(WsOpcode.text.wire, Uint8List.fromList(utf8.encode(s)));
  }

  @override
  void sendBytes(Uint8List b) {
    _requireOpen();
    _executor.send(WsOpcode.binary.wire, b);
  }

  /// Sends an unsolicited ping. Not part of the official interface, but a
  /// server-liveness probe is a common need and the transport already has it.
  void ping([Uint8List? payload]) {
    _requireOpen();
    _executor.send(WsOpcode.ping.wire, payload ?? Uint8List(0));
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed || _closeSent) {
      throw WebSocketConnectionClosed();
    }
    if (code != null && code != 1000 && (code < 3000 || code > 4999)) {
      throw ArgumentError.value(code, 'code', 'must be 1000 or 3000-4999');
    }
    final reasonBytes = reason == null
        ? const <int>[]
        : utf8.encode(reason);
    if (reasonBytes.length > 123) {
      throw ArgumentError.value(
        reason,
        'reason',
        'must be at most 123 bytes when UTF-8 encoded',
      );
    }
    _closeSent = true;
    _executor.close(code ?? 1000, reason ?? '');
    // The engine waits briefly for the peer's mirrored close frame and then
    // synthesises a terminal one, so this always resolves — and it resolves on
    // the engine's teardown rather than on the application draining [events].
    await _closedByEngine.future;
  }

  void _requireOpen() {
    if (_closed || _closeSent) {
      throw WebSocketConnectionClosed();
    }
  }
}
