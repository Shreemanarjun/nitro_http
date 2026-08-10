/// WebSocket behaviour against the local `shelf_web_socket` echo endpoint.
///
/// Framing, masking, fragment reassembly and the close handshake all live in
/// C++; these tests exercise them through [NitroWebSocket], which implements the
/// Dart team's `package:web_socket` interface.
library;

import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUp(() async {
    server = await LocalServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  /// Connects to `/ws` and returns the socket plus a queue over its events.
  Future<(NitroWebSocket, StreamQueue<WebSocketEvent>)> connect({
    Iterable<String>? protocols = const ['echo'],
    Duration? pingInterval,
    int maxFrameBytes = 1 << 20,
    String path = '/ws',
  }) async {
    final socket = await NitroWebSocket.connect(
      server.wsUri(path),
      protocols: protocols,
      pingInterval: pingInterval,
      maxFrameBytes: maxFrameBytes,
    );
    // A StreamQueue lets each assertion await exactly the next event instead of
    // racing a listener against a timer.
    final events = StreamQueue<WebSocketEvent>(socket.events);
    addTearDown(events.cancel);
    return (socket, events);
  }

  testWidgets('the handshake reports 101 and the negotiated subprotocol',
      (_) async {
    final (socket, events) = await connect();
    addTearDown(() => socket.close().catchError((_) {}));

    expect(socket.handshakeStatusCode, 101);
    expect(socket.protocol, 'echo');
    expect(socket.handshakeHeaders['upgrade']?.toLowerCase(), 'websocket');
    // An echo server must not speak first; a spurious event here would mean the
    // demux is delivering another socket's frames.
    expect(
      await events.hasNext.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => false,
      ),
      isFalse,
    );
  });

  testWidgets('text messages echo back unchanged', (_) async {
    final (socket, events) = await connect();
    addTearDown(() => socket.close().catchError((_) {}));

    // Multibyte content on purpose: a broken UTF-8 path would survive ASCII.
    const message = 'héllo — 世界 🚀';
    socket.sendText(message);

    final event = await events.next;
    expect(event, isA<TextDataReceived>());
    expect((event as TextDataReceived).text, message);
  });

  testWidgets('binary messages echo back byte-for-byte', (_) async {
    final (socket, events) = await connect();
    addTearDown(() => socket.close().catchError((_) {}));

    final payload = deterministicBytes(4096);
    socket.sendBytes(payload);

    final event = await events.next;
    expect(event, isA<BinaryDataReceived>());
    expect((event as BinaryDataReceived).data, payload);
  });

  testWidgets('a message larger than the frame cap goes out fragmented',
      (_) async {
    // 16 KiB frames, 256 KiB message: the engine emits 16 fragments and the
    // peer must see ONE intact 256 KiB message.
    //
    // The peer cannot then hand it back. `maxFrameBytes` is one knob doing two
    // jobs, as `NitroWebSocket.connect` documents: the outgoing fragment size,
    // AND the ceiling on an incoming reassembled message. A 256 KiB echo is
    // over that ceiling, so the engine refuses it with 1009 rather than growing
    // an unbounded reassembly buffer. Asserting the round trip here would be
    // asserting that the DoS guard does not work.
    const frameCap = 16 * 1024;
    const messageBytes = 256 * 1024;
    final (socket, events) = await connect(maxFrameBytes: frameCap);
    addTearDown(() => socket.close().catchError((_) {}));

    final payload = deterministicBytes(messageBytes);
    socket.sendBytes(payload);

    final event = await events.next.timeout(const Duration(seconds: 30));
    expect(event, isA<CloseReceived>());
    expect(
      (event as CloseReceived).reason,
      contains('exceeds the configured maximum size'),
      reason: 'the incoming ceiling must be what ended this socket',
    );

    // The server's own view: the 16 fragments arrived, in order, and
    // reassembled into exactly the bytes that were sent.
    expect(server.lastWebSocketMessageBytes, messageBytes);
    expect(
      server.lastWebSocketMessageDigest,
      sha256.convert(payload).toString(),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a 256 KiB message round-trips under a cap that allows it',
      (_) async {
    // Past 64 KiB, so both directions have to use the 64-bit extended payload
    // length form — a different branch from the 16-bit one the 4 KiB case above
    // exercises.
    const messageBytes = 256 * 1024;
    final (socket, events) = await connect(maxFrameBytes: 1 << 20);
    addTearDown(() => socket.close().catchError((_) {}));

    final payload = deterministicBytes(messageBytes);
    socket.sendBytes(payload);

    final event = await events.next.timeout(const Duration(seconds: 30));
    expect(event, isA<BinaryDataReceived>());
    expect((event as BinaryDataReceived).data, payload);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('keepalive pings do not disturb the message stream', (_) async {
    final (socket, events) = await connect(
      pingInterval: const Duration(milliseconds: 200),
    );
    addTearDown(() => socket.close().catchError((_) {}));

    // Long enough for several automatic pings, plus one explicit probe. Pongs
    // are answered natively and must never surface as application events.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    socket.ping(Uint8List.fromList(const [0xAA, 0xBB]));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    socket.sendText('still here');
    final event = await events.next;
    expect(
      event,
      isA<TextDataReceived>(),
      reason: 'a ping or pong leaked into the event stream',
    );
    expect((event as TextDataReceived).text, 'still here');
  });

  testWidgets('a server-initiated close surfaces its code and reason', (_) async {
    final (socket, events) = await connect(path: '/ws/close', protocols: null);

    final event = await events.next.timeout(const Duration(seconds: 20));
    expect(event, isA<CloseReceived>());
    final close = event as CloseReceived;
    expect(close.code, 4001);
    expect(close.reason, 'server initiated close');

    // The socket is done: sending afterwards is a programming error.
    expect(() => socket.sendText('too late'), throwsA(isA<WebSocketConnectionClosed>()));
  });

  testWidgets('close() completes and ends the event stream', (_) async {
    final (socket, events) = await connect();

    // `close()` resolves only once the engine has finished the handshake and
    // torn the socket down, so everything below is settled by the time it
    // returns — no polling, no arbitrary delay.
    await socket.close(3001, 'test finished').timeout(const Duration(seconds: 20));

    final event = await events.next;
    expect(event, isA<CloseReceived>());
    expect(
      await events.hasNext,
      isFalse,
      reason: 'the event stream must be closed, not merely quiet',
    );
    expect(() => socket.sendText('after close'),
        throwsA(isA<WebSocketConnectionClosed>()));
    await expectLater(socket.close(), throwsA(isA<WebSocketConnectionClosed>()));
  });

  testWidgets('an invalid close code is rejected before it reaches the wire',
      (_) async {
    final (socket, _) = await connect();
    addTearDown(() => socket.close().catchError((_) {}));

    await expectLater(socket.close(1001), throwsA(isA<ArgumentError>()));
    await expectLater(
      socket.close(1000, 'x' * 200),
      throwsA(isA<ArgumentError>()),
    );
  });

  testWidgets('a non-ws scheme is rejected without a connection attempt',
      (_) async {
    await expectLater(
      NitroWebSocket.connect(server.uri('/ws')),
      throwsA(isA<ArgumentError>()),
    );
    expect(server.requestsFor('/ws'), 0);
  });

  testWidgets('connecting to a route that does not upgrade fails', (_) async {
    await expectLater(
      NitroWebSocket.connect(server.wsUri('/echo')),
      throwsA(isA<WebSocketException>()),
    );
  });
}
