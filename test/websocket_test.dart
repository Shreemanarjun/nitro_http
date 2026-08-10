import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/ws_runner.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'support/fakes.dart';

/// The engine's frame window, mirrored from `websocket.dart`. Private there
/// because it is not configurable; restated here so the assertions are exact.
const int kFrameCredits = 32;
const int kFrameCreditBatch = 16;

late FakeWsExecutor executor;
late FakeWsFrameDemux demux;

/// The id the socket under test was allocated. Top level because a getter
/// cannot be declared inside a function body.
int get socketId => executor.configs.single.socketId;

Future<NitroWebSocket> connect({
  String url = 'wss://example.com/ws',
  Iterable<String>? protocols,
  HttpHeaders? headers,
  Duration? pingInterval,
  int maxFrameBytes = 1 << 20,
}) => NitroWebSocket.connect(
  Uri.parse(url),
  protocols: protocols,
  headers: headers,
  pingInterval: pingInterval,
  maxFrameBytes: maxFrameBytes,
  executor: executor,
  demux: demux,
);

void main() {
  setUp(() {
    executor = FakeWsExecutor();
    demux = FakeWsFrameDemux();
  });

  tearDown(() => demux.closeAll());

  group('handshake', () {
    test('rejects a non-WebSocket scheme before touching the engine', () async {
      await expectLater(
        connect(url: 'https://example.com/ws'),
        throwsA(isA<ArgumentError>()),
      );
      expect(executor.configs, isEmpty);
    });

    test('a failed handshake throws and releases both seams', () async {
      executor.handshake = rawHandshake(
        kind: RawErrorKind.connectionRefused,
        message: 'upgrade refused',
        status: 502,
      );

      await expectLater(
        connect(),
        throwsA(
          isA<WebSocketException>().having(
            (e) => e.message,
            'message',
            'upgrade refused',
          ),
        ),
      );
      expect(demux.released, <int>[socketId]);
      expect(executor.disposeCount, 1);
    });

    test('a failure with no engine text still names the target', () async {
      executor.handshake = rawHandshake(kind: RawErrorKind.timeoutConnect);

      await expectLater(
        connect(),
        throwsA(
          isA<WebSocketException>().having(
            (e) => e.message,
            'message',
            contains('wss://example.com/ws'),
          ),
        ),
      );
    });

    test('a throwing connect releases both seams and rethrows', () async {
      executor.onConnect = (_) async => throw StateError('no transport');

      await expectLater(connect(), throwsStateError);
      expect(demux.released, <int>[socketId]);
      expect(executor.disposeCount, 1);
    });

    test('a successful handshake exposes the negotiated protocol and headers', () async {
      executor.handshake = rawHandshake(
        protocol: 'chat.v2',
        headers: const <RawHeader>[
          RawHeader(name: 'X-Session', value: 'abc'),
        ],
      );

      final socket = await connect(
        protocols: const <String>['chat.v1', 'chat.v2'],
        headers: HttpHeaders()..add('Origin', 'https://app.test'),
        pingInterval: const Duration(seconds: 20),
        maxFrameBytes: 4096,
      );

      expect(socket.protocol, 'chat.v2');
      expect(socket.handshakeStatusCode, 101);
      expect(socket.handshakeHeaders['x-session'], 'abc');

      final config = executor.configs.single;
      expect(config.url, 'wss://example.com/ws');
      expect(config.protocols, <String>['chat.v1', 'chat.v2']);
      expect(config.headers.single.name, 'Origin');
      expect(config.headers.single.value, 'https://app.test');
      expect(config.pingIntervalMs, 20000);
      expect(config.maxFrameBytes, 4096);
      expect(config.connectTimeoutMs, 30000);

      demux.push(wsCloseFrame(socketId, 1000, ''));
      await socket.events.drain<void>();
    });
  });

  group('inbound frames', () {
    test('a text frame becomes TextDataReceived', () async {
      final socket = await connect();
      final events = socket.events.toList();

      demux
        ..push(wsFrame(socketId, WsOpcode.text, utf8.encode('héllo')))
        ..push(wsCloseFrame(socketId, 1000, 'bye'));

      expect(await events, <WebSocketEvent>[
        TextDataReceived('héllo'),
        CloseReceived(1000, 'bye'),
      ]);
    });

    test('a binary frame becomes BinaryDataReceived', () async {
      final socket = await connect();
      final events = socket.events.toList();

      demux
        ..push(wsFrame(socketId, WsOpcode.binary, <int>[1, 2, 3]))
        ..push(wsCloseFrame(socketId, 1000, ''));

      expect(await events, <WebSocketEvent>[
        BinaryDataReceived(Uint8List.fromList(<int>[1, 2, 3])),
        CloseReceived(1000, ''),
      ]);
    });

    test('a close frame decodes the big-endian code and closes the stream', () async {
      final socket = await connect();
      final events = socket.events.toList();

      // 0x0F 0xA1 == 4001.
      demux.push(
        wsFrame(socketId, WsOpcode.close, <int>[0x0f, 0xa1, ...utf8.encode('done')]),
      );

      expect(await events, <WebSocketEvent>[CloseReceived(4001, 'done')]);
      expect(demux.released, <int>[socketId]);
      expect(executor.disposeCount, 1);
    });

    test('a close frame shorter than two bytes reports 1005', () async {
      final socket = await connect();
      final events = socket.events.toList();

      demux.push(wsFrame(socketId, WsOpcode.close, <int>[]));

      expect(await events, <WebSocketEvent>[CloseReceived(1005, '')]);
    });

    test('a transport error becomes an abnormal 1006 closure', () async {
      final socket = await connect();
      final events = socket.events.toList();

      demux.push(
        wsFrame(socketId, WsOpcode.transportError, utf8.encode('socket died')),
      );

      expect(await events, <WebSocketEvent>[CloseReceived(1006, 'socket died')]);
    });

    test('the frame stream ending is also an abnormal closure', () async {
      final socket = await connect();
      final events = socket.events.toList();

      await demux.controller(socketId).close();

      expect(await events, <WebSocketEvent>[CloseReceived(1006, '')]);
    });

    test('ping and pong frames produce no application event', () async {
      final socket = await connect();
      final events = socket.events.toList();

      demux
        ..push(wsFrame(socketId, WsOpcode.ping, <int>[1]))
        ..push(wsFrame(socketId, WsOpcode.pong, <int>[2]))
        ..push(wsCloseFrame(socketId, 1000, ''));

      expect(await events, <WebSocketEvent>[CloseReceived(1000, '')]);
    });

    test('malformed UTF-8 in a text frame is replaced, not fatal', () async {
      final socket = await connect();
      final events = socket.events.toList();

      demux
        ..push(wsFrame(socketId, WsOpcode.text, <int>[0xff, 0xfe]))
        ..push(wsCloseFrame(socketId, 1000, ''));

      final received = (await events).first as TextDataReceived;
      expect(received.text, '\u{FFFD}\u{FFFD}');
    });
  });

  group('frame credits', () {
    test('grants the initial window, tops up per batch, and releases at the end', () async {
      final socket = await connect();
      final events = socket.events.toList();

      expect(executor.credits, <FrameCredit>[
        (frameCount: kFrameCredits, ackedFrames: 0),
      ]);

      for (var i = 0; i < kFrameCreditBatch; i++) {
        demux.push(wsFrame(socketId, WsOpcode.text, <int>[i]));
      }
      await pumpEventQueue();

      expect(executor.credits, <FrameCredit>[
        (frameCount: kFrameCredits, ackedFrames: 0),
        (frameCount: kFrameCreditBatch, ackedFrames: kFrameCreditBatch),
      ]);

      demux.push(wsCloseFrame(socketId, 1000, ''));
      await events;

      expect(executor.credits.last, (
        frameCount: 0,
        ackedFrames: kFrameCreditBatch + 1,
      ));
    });
  });

  group('outbound', () {
    test('sendText and sendBytes reach the engine with the right opcodes', () async {
      final socket = await connect()
        ..sendText('hi')
        ..sendBytes(Uint8List.fromList(<int>[7]))
        ..ping(Uint8List.fromList(<int>[9]));

      // Compared as WIRE values, not enum members: what the engine receives is
      // an int, and this pins that we put the RFC 6455 numbers on it.
      expect(executor.sent.map((f) => f.opcode), <int>[
        WsOpcode.text.wire,
        WsOpcode.binary.wire,
        WsOpcode.ping.wire,
      ]);
      expect(<int>[
        WsOpcode.text.wire,
        WsOpcode.binary.wire,
        WsOpcode.ping.wire,
      ], <int>[1, 2, 9]);
      expect(utf8.decode(executor.sent.first.payload), 'hi');
      expect(executor.sent[1].payload, <int>[7]);
      expect(executor.sent[2].payload, <int>[9]);

      final events = socket.events.toList();
      demux.push(wsCloseFrame(socketId, 1000, ''));
      await events;
    });

    test('sending after the peer closed throws WebSocketConnectionClosed', () async {
      final socket = await connect();
      final events = socket.events.toList();

      demux.push(wsCloseFrame(socketId, 1000, ''));
      await events;

      expect(() => socket.sendText('x'), throwsA(isA<WebSocketConnectionClosed>()));
      expect(
        () => socket.sendBytes(Uint8List(0)),
        throwsA(isA<WebSocketConnectionClosed>()),
      );
      expect(() => socket.ping(), throwsA(isA<WebSocketConnectionClosed>()));
      await expectLater(
        socket.close(),
        throwsA(isA<WebSocketConnectionClosed>()),
      );
    });

    test('close sends the code and completes on the peer close frame', () async {
      final socket = await connect();
      final events = socket.events.toList();

      final closing = socket.close(3001, 'going away');
      expect(executor.closes.single, (code: 3001, reason: 'going away'));

      // The engine echoes the peer's close frame, which resolves the future.
      demux.push(wsCloseFrame(socketId, 3001, 'going away'));
      await closing;

      expect(await events, <WebSocketEvent>[CloseReceived(3001, 'going away')]);
    });

    test('close defaults to 1000 with an empty reason', () async {
      final socket = await connect();
      final events = socket.events.toList();

      final closing = socket.close();
      expect(executor.closes.single, (code: 1000, reason: ''));

      demux.push(wsCloseFrame(socketId, 1000, ''));
      await closing;
      await events;
    });

    test('a second close throws instead of sending twice', () async {
      final socket = await connect();
      final events = socket.events.toList();

      final closing = socket.close();
      await expectLater(
        socket.close(),
        throwsA(isA<WebSocketConnectionClosed>()),
      );

      demux.push(wsCloseFrame(socketId, 1000, ''));
      await closing;
      await events;
      expect(executor.closes, hasLength(1));
    });

    group('close validation', () {
      test('rejects a reserved status code', () async {
        final socket = await connect();

        for (final code in const <int>[999, 1001, 1005, 2999, 5000]) {
          await expectLater(
            socket.close(code),
            throwsA(isA<ArgumentError>()),
            reason: 'code $code',
          );
        }
        expect(executor.closes, isEmpty);

        final events = socket.events.toList();
        demux.push(wsCloseFrame(socketId, 1000, ''));
        await events;
      });

      test('accepts 1000 and the 3000-4999 private range', () async {
        for (final code in const <int>[1000, 3000, 4999]) {
          // Fresh seams per iteration: `socketId` reads the single recorded
          // config, and each socket allocates a new id.
          executor = FakeWsExecutor();
          demux = FakeWsFrameDemux();

          final socket = await connect();
          final events = socket.events.toList();

          final closing = socket.close(code);
          demux.push(wsCloseFrame(socketId, code, ''));
          await closing;
          await events;

          expect(executor.closes.single.code, code);
        }
      });

      test('rejects a reason longer than 123 UTF-8 bytes', () async {
        final socket = await connect();

        await expectLater(
          socket.close(1000, 'x' * 124),
          throwsA(isA<ArgumentError>()),
        );
        // 62 two-byte characters is 124 bytes, even though it is 62 runes.
        await expectLater(
          socket.close(1000, 'é' * 62),
          throwsA(isA<ArgumentError>()),
        );
        expect(executor.closes, isEmpty);

        final events = socket.events.toList();
        final closing = socket.close(1000, 'x' * 123);
        demux.push(wsCloseFrame(socketId, 1000, ''));
        await closing;
        await events;
        expect(executor.closes, hasLength(1));
      });
    });
  });
}
