// A body received in a worker isolate must stay valid after `Isolate.run`
// hands it over and the worker exits: a list adopted there with a finalizer
// would be freed at the worker's exit (dart-lang/sdk#55800). Its own file: a second
// isolate using the plugin takes the stream registry with it, so it must not
// share a process with the streaming tests.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

const int _size = 4 * 1024 * 1024;

Uint8List _body(int byte) => Uint8List(_size)..fillRange(0, _size, byte);

/// Four GETs of [url] from a fresh client. A class so that `Isolate.run`
/// sends only the URL.
class _WorkerGets {
  _WorkerGets(this.url);

  final String url;

  Future<List<List<int>>> run() async {
    final worker = NitroHttpClient();
    final out = <List<int>>[];
    for (var i = 0; i < 4; i++) {
      out.add((await worker.get(url)).bodyBytes);
    }
    worker.dispose();
    return out;
  }
}

void main() {
  final lib = File('build/lib/libnitro_http.dylib');

  test('a body received in a worker isolate outlives that isolate', () async {
    DynamicLibrary.open(lib.absolute.path);
    // The churn below gets other bytes, so a worker body whose block was
    // freed and reused cannot still compare equal.
    final body = _body(0x5a);
    final churn = _body(0xa5);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add(request.uri.path == '/churn' ? churn : body);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/';

    final bodies = await Isolate.run(_WorkerGets(url).run);
    // Churn the allocator so a freed block would be reused or unmapped.
    final client = NitroHttpClient();
    addTearDown(client.dispose);
    for (var i = 0; i < 8; i++) {
      await client.get('${url}churn');
    }
    for (final received in bodies) {
      expect(received, body);
    }
  }, skip: lib.existsSync() ? null : 'build/lib/libnitro_http.dylib missing');
}
