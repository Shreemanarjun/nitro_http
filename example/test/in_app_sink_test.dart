/// The in-app upload sink answers the way `tool/bench_native/sink` does: it
/// reads the body it was promised and reports the count as `{"bytes": N}`.
///
/// Plain `test`s, for the reason given in `benchmark_test.dart`: a widget
/// binding would answer every `HttpClient` request itself.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http_example/server/in_app_sink.dart';

void main() {
  late Uri sink;
  late HttpClient client;
  late int localPort;

  setUpAll(() async {
    sink = Uri.parse('${await startInAppSink()}/upload/sink');
  });
  setUp(() => client = HttpClient());
  tearDown(() => client.close(force: true));

  Future<Object?> post(int bytes) async {
    final request = await client.postUrl(sink);
    request.contentLength = bytes;
    request.add(Uint8List(bytes));
    final response = await request.close();
    localPort = response.connectionInfo!.localPort;
    expect(response.statusCode, 200);
    return jsonDecode(await utf8.decodeStream(response));
  }

  test('counts a body larger than its buffer', () async {
    const bytes = 3 * 1024 * 1024 + 7;
    expect(await post(bytes), {'bytes': bytes});
  });

  test('answers every upload on a connection that is kept open', () async {
    final ports = <int>{};
    for (final bytes in const [0, 1, 70000, 1 << 20]) {
      expect(await post(bytes), {'bytes': bytes});
      ports.add(localPort);
    }
    expect(ports, hasLength(1), reason: 'one connection carried all four');
  });

  test('serves connections that arrive together', () async {
    final answers = await Future.wait([
      for (var i = 0; i < 8; i++) post(200000 + i),
    ]);
    expect(answers, [
      for (var i = 0; i < 8; i++) {'bytes': 200000 + i},
    ]);
  });

  test('reads a head that arrives in pieces, whatever its case', () async {
    final socket = await Socket.connect(sink.host, sink.port);
    addTearDown(socket.destroy);
    socket.add(ascii.encode('POST /upload/sink HTTP/1.1\r\nCONTENT-'));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    socket.add(ascii.encode('LENGTH: 5\r\n\r\nhello'));
    await socket.flush();
    final answer = await socket.map(ascii.decode).first;
    expect(answer, startsWith('HTTP/1.1 200 OK\r\n'));
    expect(answer, endsWith('{"bytes":5}'));
  });

  test('outlives a client that leaves in the middle of a body', () async {
    final socket = await Socket.connect(sink.host, sink.port);
    socket.add(
      ascii.encode(
        'POST /upload/sink HTTP/1.1\r\nContent-Length: 999\r\n\r\nx',
      ),
    );
    await socket.flush();
    socket.destroy();
    expect(await post(1234), {'bytes': 1234});
  });
}
