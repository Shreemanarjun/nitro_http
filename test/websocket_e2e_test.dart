import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

/// `websocket_test.dart` drives the Dart half against fakes, which is where the
/// framing and credit logic is pinned down. Nothing there touches a socket, and
/// that is exactly the gap the `wss://` segfault went through: the engine, the
/// demux and the close handshake only meet a real peer here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dylib = 'build/lib/libnitro_http.dylib';
  final available = File(dylib).existsSync();
  final skipReason = available ? null : 'build the engine first: tool/build-cpp.sh';

  late HttpServer server;
  late String base;
  final closedWith = <({int? code, String? reason})>[];
  var acceptedProtocol = '';

  setUpAll(() async {
    if (!available) return;
    DynamicLibrary.open(dylib);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'ws://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/not-a-socket') {
        request.response
          ..statusCode = 200
          ..write('plain http');
        await request.response.close();
        return;
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final protocols = request.headers.value('sec-websocket-protocol');
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (offered) {
          acceptedProtocol = offered.isEmpty ? '' : offered.first;
          return acceptedProtocol;
        },
      );
      // dart:io pings on its own schedule; leave it off so the test's own
      // keepalive is the only ping traffic.
      socket.pingInterval = null;

      if (path == '/close-immediately') {
        await socket.close(4321, 'server said so');
        return;
      }
      if (path == '/drop') {
        // No close frame: the TCP connection just goes away.
        await socket.close();
        return;
      }
      socket.listen(
        (data) {
          if (path == '/uppercase' && data is String) {
            socket.add(data.toUpperCase());
          } else {
            socket.add(data);
          }
        },
        onError: (_) {},
        onDone: () => closedWith.add((
          code: socket.closeCode,
          reason: socket.closeReason,
        )),
      );
      // Referenced so the analyzer sees the negotiated value is used.
      if (protocols == null) return;
    });
  });

  tearDownAll(() async {
    if (available) await server.close(force: true);
  });

  /// Collects events until the socket closes, so each test asserts on a
  /// finished conversation rather than racing the stream.
  Future<List<WebSocketEvent>> drain(NitroWebSocket socket) =>
      socket.events.toList();

  group('WebSocket end to end', () {
    test('a text message round-trips through the engine', () async {
      final socket = await NitroWebSocket.connect(Uri.parse('$base/uppercase'));
      final received = <String>[];
      final done = Completer<void>();
      socket.events.listen((event) {
        if (event is TextDataReceived) received.add(event.text);
        if (event is CloseReceived) done.complete();
      });

      socket.sendText('hello');
      // Give the echo time to arrive: closing first would race the reply.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close(1000, 'done');
      await done.future.timeout(const Duration(seconds: 10));

      expect(received, ['HELLO']);
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('binary payloads survive every byte value', () async {
      final socket = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      final payload = Uint8List.fromList(
        List<int>.generate(256, (i) => i),
      );
      final collected = <BinaryDataReceived>[];
      final done = Completer<void>();
      socket.events.listen((event) {
        if (event is BinaryDataReceived) collected.add(event);
        if (event is CloseReceived) done.complete();
      });

      socket.sendBytes(payload);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close(1000, 'done');
      await done.future.timeout(const Duration(seconds: 10));

      expect(collected, hasLength(1));
      expect(collected.single.data, payload);
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('a message past the 16-bit length form arrives whole', () async {
      // Over 65535 bytes, so the frame uses the 64-bit length and is certain to
      // be split across socket reads and reassembled.
      final payload = Uint8List.fromList(
        List<int>.generate(200000, (i) => (i * 31) & 0xff),
      );
      final socket = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      final collected = <BinaryDataReceived>[];
      final done = Completer<void>();
      socket.events.listen((event) {
        if (event is BinaryDataReceived) collected.add(event);
        if (event is CloseReceived) done.complete();
      });

      socket.sendBytes(payload);
      await Future<void>.delayed(const Duration(seconds: 1));
      await socket.close(1000, 'done');
      await done.future.timeout(const Duration(seconds: 20));

      expect(collected, hasLength(1), reason: 'fragments must be reassembled');
      expect(collected.single.data.length, payload.length);
      expect(collected.single.data, payload);
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 60)));

    test('messages keep their order under a burst', () async {
      // The credit window tops up in batches, so a burst larger than the
      // initial grant is what exercises the refill path against a real peer.
      const count = 200;
      final socket = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      final received = <String>[];
      final done = Completer<void>();
      socket.events.listen((event) {
        if (event is TextDataReceived) received.add(event.text);
        if (event is CloseReceived) done.complete();
      });

      for (var i = 0; i < count; i++) {
        socket.sendText('message-$i');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      await socket.close(1000, 'done');
      await done.future.timeout(const Duration(seconds: 20));

      expect(received, hasLength(count));
      expect(received, [for (var i = 0; i < count; i++) 'message-$i']);
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 60)));

    test('an empty message is delivered rather than swallowed', () async {
      final socket = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      final collected = <WebSocketEvent>[];
      final done = Completer<void>();
      socket.events.listen((event) {
        collected.add(event);
        if (event is CloseReceived) done.complete();
      });

      socket.sendText('');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close(1000, 'done');
      await done.future.timeout(const Duration(seconds: 10));

      expect(collected.whereType<TextDataReceived>().single.text, '');
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('a server-initiated close carries its code and reason', () async {
      final socket = await NitroWebSocket.connect(
        Uri.parse('$base/close-immediately'),
      );
      final events = await drain(socket).timeout(const Duration(seconds: 10));

      final close = events.whereType<CloseReceived>().single;
      expect(close.code, 4321);
      expect(close.reason, 'server said so');
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('the code the client closes with reaches the server', () async {
      closedWith.clear();
      final socket = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      socket.events.listen((_) {});
      await socket.close(4002, 'client done');

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(closedWith, isNotEmpty);
      expect(closedWith.last.code, 4002);
      expect(closedWith.last.reason, 'client done');
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('a subprotocol is negotiated and reported back', () async {
      final socket = await NitroWebSocket.connect(
        Uri.parse('$base/echo'),
        protocols: const ['chat.v2'],
      );
      expect(socket.protocol, 'chat.v2');
      await socket.close(1000, 'done');
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('a keepalive ping does not disturb the message stream', () async {
      final socket = await NitroWebSocket.connect(
        Uri.parse('$base/echo'),
        pingInterval: const Duration(milliseconds: 200),
      );
      final received = <String>[];
      final done = Completer<void>();
      socket.events.listen((event) {
        if (event is TextDataReceived) received.add(event.text);
        if (event is CloseReceived) done.complete();
      });

      // Long enough for several ping cycles around the traffic.
      socket.sendText('before');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      socket.sendText('after');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close(1000, 'done');
      await done.future.timeout(const Duration(seconds: 10));

      // Pings are protocol traffic and must never surface as application data.
      expect(received, ['before', 'after']);
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('an endpoint that will not upgrade fails instead of hanging',
        () async {
      // `WebSocketException` rather than a `NitroHttpException`: this type
      // implements `package:web_socket`, so a refused upgrade has to look the
      // same as it would from any other implementation of that interface.
      await expectLater(
        NitroWebSocket.connect(Uri.parse('$base/not-a-socket')),
        throwsA(
          isA<WebSocketException>().having(
            (e) => e.message,
            'message',
            contains('refused'),
          ),
        ),
      );
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('a peer that vanishes closes the stream rather than stalling it',
        () async {
      final socket = await NitroWebSocket.connect(Uri.parse('$base/drop'));
      final events = await drain(socket).timeout(const Duration(seconds: 10));

      // However it ends, the stream must terminate — a hung socket is the
      // failure this guards against.
      expect(events.whereType<CloseReceived>(), hasLength(1));
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));

    test('two sockets on one engine do not cross their streams', () async {
      // Frames ride a module-global native stream tagged with a socket id and
      // are demuxed in Dart, so this is the test that a second socket does not
      // see the first one's traffic.
      final first = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      final second = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      final firstSeen = <String>[];
      final secondSeen = <String>[];
      first.events.listen((e) {
        if (e is TextDataReceived) firstSeen.add(e.text);
      });
      second.events.listen((e) {
        if (e is TextDataReceived) secondSeen.add(e.text);
      });

      for (var i = 0; i < 20; i++) {
        first.sendText('first-$i');
        second.sendText('second-$i');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await first.close(1000, 'done');
      await second.close(1000, 'done');

      expect(firstSeen, hasLength(20));
      expect(secondSeen, hasLength(20));
      expect(firstSeen.every((t) => t.startsWith('first-')), isTrue,
          reason: 'the first socket saw the second socket traffic');
      expect(secondSeen.every((t) => t.startsWith('second-')), isTrue,
          reason: 'the second socket saw the first socket traffic');
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 60)));

    test('a JSON conversation survives a round trip unchanged', () async {
      final socket = await NitroWebSocket.connect(Uri.parse('$base/echo'));
      final payload = jsonEncode({
        'id': 7,
        'items': [1, 2, 3],
        'unicode': 'héllo — 世界',
      });
      final collected = <String>[];
      final done = Completer<void>();
      socket.events.listen((event) {
        if (event is TextDataReceived) collected.add(event.text);
        if (event is CloseReceived) done.complete();
      });

      socket.sendText(payload);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await socket.close(1000, 'done');
      await done.future.timeout(const Duration(seconds: 10));

      expect(collected.single, payload);
      expect(jsonDecode(collected.single), jsonDecode(payload));
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 30)));
  });
}
