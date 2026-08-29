import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/ws_browser.dart';
import 'package:nitro_http/src/internal/ws_runner.dart';
import 'package:nitro_http/src/nitro_http.native.dart';
import 'package:web_socket/web_socket.dart' as ws;

/// The browser WebSocket executor, driven on the VM against a fake socket.
///
/// `ws_web.dart` only picks `package:web_socket`'s browser implementation;
/// every decision — how a frame is turned into a `WsFrameEvent`, what a close
/// carries, which settings a page cannot honour — lives here, so it is testable
/// without a browser.
class FakeSocket implements ws.WebSocket {
  FakeSocket({this.protocol = ''});

  final _events = StreamController<ws.WebSocketEvent>.broadcast();
  final sentText = <String>[];
  final sentBytes = <Uint8List>[];
  final closes = <({int? code, String? reason})>[];

  @override
  final String protocol;

  @override
  Stream<ws.WebSocketEvent> get events => _events.stream;

  void emit(ws.WebSocketEvent event) => _events.add(event);
  void emitError(Object error) => _events.addError(error);
  void endStream() => _events.close();

  @override
  void sendText(String s) => sentText.add(s);

  @override
  void sendBytes(Uint8List b) => sentBytes.add(b);

  @override
  Future<void> close([int? code, String? reason]) async {
    closes.add((code: code, reason: reason));
  }
}

void main() {
  RawWsConfig config({
    String url = 'wss://example.com/socket',
    List<String> protocols = const [],
    List<RawHeader> headers = const [],
    int pingIntervalMs = 0,
    RawTlsConfig? tls,
  }) => RawWsConfig(
    socketId: 1,
    url: url,
    protocols: protocols,
    headers: headers,
    pingIntervalMs: pingIntervalMs,
    maxFrameBytes: 1 << 20,
    connectTimeoutMs: 5000,
    tls:
        tls ??
        const RawTlsConfig(
          verifyCertificates: true,
          rootCaSource: 0,
          trustedRootsPem: '',
          pinnedSpkiSha256: [],
          clientCertPem: '',
          clientKeyPem: '',
          clientKeyPassword: '',
          minTlsVersion: 0,
          maxTlsVersion: 0,
          sniHostname: '',
        ),
  );

  late FakeSocket socket;
  BrowserWsExecutor make({String protocol = ''}) {
    socket = FakeSocket(protocol: protocol);
    return BrowserWsExecutor(1, (url, protocols) async => socket);
  }

  tearDown(() => BrowserWsFrameDemux.instance.release(1));

  group('handshake', () {
    test('a connected socket reports 101 and its protocol', () async {
      final handshake = await make(protocol: 'chat.v2').connect(
        config(protocols: const ['chat.v2']),
      );

      expect(handshake.errorKind, RawErrorKind.none);
      // The browser never exposes the upgrade response, so 101 stands for the
      // fact that the upgrade happened.
      expect(handshake.statusCode, 101);
      expect(handshake.negotiatedProtocol, 'chat.v2');
    });

    test('a refused connection becomes an error handshake, not a throw',
        () async {
      final executor = BrowserWsExecutor(
        1,
        (url, protocols) async => throw ws.WebSocketException('refused'),
      );

      final handshake = await executor.connect(config());
      expect(handshake.errorKind, RawErrorKind.io);
      expect(handshake.errorMessage, contains('refused'));
      expect(handshake.statusCode, 0);
    });
  });

  group('frames', () {
    test('text and binary reach the demux with their opcodes', () async {
      final executor = make();
      final frames = <WsFrameEvent>[];
      BrowserWsFrameDemux.instance.frames(1).listen(frames.add);
      await executor.connect(config());

      socket
        ..emit(ws.TextDataReceived('hello'))
        ..emit(ws.BinaryDataReceived(Uint8List.fromList([1, 2, 3])));
      await pumpEventQueue();

      expect(frames, hasLength(2));
      expect(frames[0].opcode, WsOpcode.text);
      expect(String.fromCharCodes(frames[0].payload), 'hello');
      expect(frames[1].opcode, WsOpcode.binary);
      expect(frames[1].payload, [1, 2, 3]);
    });

    test('a close carries its code big-endian, as the frame format has it',
        () async {
      final executor = make();
      final frames = <WsFrameEvent>[];
      BrowserWsFrameDemux.instance.frames(1).listen(frames.add);
      await executor.connect(config());

      socket.emit(ws.CloseReceived(4321, 'bye'));
      await pumpEventQueue();

      final close = frames.single;
      expect(close.opcode, WsOpcode.close);
      expect((close.payload[0] << 8) | close.payload[1], 4321);
      expect(String.fromCharCodes(close.payload.skip(2)), 'bye');
    });

    test('a close with no code reports 1005, not a fabricated one', () async {
      final executor = make();
      final frames = <WsFrameEvent>[];
      BrowserWsFrameDemux.instance.frames(1).listen(frames.add);
      await executor.connect(config());

      socket.emit(ws.CloseReceived(null, ''));
      await pumpEventQueue();

      expect((frames.single.payload[0] << 8) | frames.single.payload[1], 1005);
    });

    test('a transport error arrives in band, not as an unhandled throw',
        () async {
      final executor = make();
      final frames = <WsFrameEvent>[];
      BrowserWsFrameDemux.instance.frames(1).listen(frames.add);
      await executor.connect(config());

      socket.emitError(StateError('socket died'));
      await pumpEventQueue();

      expect(frames.single.opcode, WsOpcode.transportError);
      expect(String.fromCharCodes(frames.single.payload), contains('died'));
    });

    test('a stream that just ends is an abnormal 1006 closure', () async {
      final executor = make();
      final frames = <WsFrameEvent>[];
      BrowserWsFrameDemux.instance.frames(1).listen(frames.add);
      await executor.connect(config());

      socket.endStream();
      await pumpEventQueue();

      expect(frames.single.opcode, WsOpcode.close);
      expect((frames.single.payload[0] << 8) | frames.single.payload[1], 1006);
    });

    test('two sockets do not see each other traffic', () async {
      final first = FakeSocket();
      final second = FakeSocket();
      final a = BrowserWsExecutor(1, (u, p) async => first);
      final b = BrowserWsExecutor(2, (u, p) async => second);
      addTearDown(() => BrowserWsFrameDemux.instance.release(2));

      final seenA = <WsFrameEvent>[];
      final seenB = <WsFrameEvent>[];
      BrowserWsFrameDemux.instance.frames(1).listen(seenA.add);
      BrowserWsFrameDemux.instance.frames(2).listen(seenB.add);
      await a.connect(config());
      await b.connect(config());

      first.emit(ws.TextDataReceived('to-a'));
      second.emit(ws.TextDataReceived('to-b'));
      await pumpEventQueue();

      expect(String.fromCharCodes(seenA.single.payload), 'to-a');
      expect(String.fromCharCodes(seenB.single.payload), 'to-b');
    });
  });

  group('sending', () {
    test('text and binary go out on the matching call', () async {
      final executor = make();
      await executor.connect(config());

      executor.send(WsOpcode.text.wire, Uint8List.fromList('hi'.codeUnits));
      executor.send(WsOpcode.binary.wire, Uint8List.fromList([9, 9]));

      expect(socket.sentText, ['hi']);
      expect(socket.sentBytes, [
        [9, 9],
      ]);
    });

    test('close passes the code and reason through', () async {
      final executor = make();
      await executor.connect(config());

      executor.close(1000, 'done');
      expect(socket.closes.single.code, 1000);
      expect(socket.closes.single.reason, 'done');
    });

    test('sending after dispose is dropped rather than throwing', () async {
      final executor = make();
      await executor.connect(config());
      executor.dispose();

      expect(
        executor.send(WsOpcode.text.wire, Uint8List.fromList('late'.codeUnits)),
        0,
      );
      expect(socket.sentText, isEmpty);
    });
  });

  group('what a browser cannot do', () {
    test('headers, pingInterval and TLS settings are refused', () async {
      // The browser performs the upgrade, so a page cannot add request headers,
      // choose a keepalive, or pin a certificate. Accepting these and ignoring
      // them would be the worse failure.
      final executor = make();

      await expectLater(
        executor.connect(
          config(headers: const [RawHeader(name: 'x-a', value: 'b')]),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      await expectLater(
        executor.connect(config(pingIntervalMs: 500)),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      await expectLater(
        executor.connect(
          config(
            tls: const RawTlsConfig(
              verifyCertificates: true,
              rootCaSource: 0,
              trustedRootsPem: '',
              pinnedSpkiSha256: ['sha256//abc'],
              clientCertPem: '',
              clientKeyPem: '',
              clientKeyPassword: '',
              minTlsVersion: 0,
              maxTlsVersion: 0,
              sniHostname: '',
            ),
          ),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
    });

    test('a plain configuration connects', () async {
      final handshake = await make().connect(config());
      expect(handshake.errorKind, RawErrorKind.none);
    });
  });
}
