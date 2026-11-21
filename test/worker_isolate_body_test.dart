// A body adopted with a finalizer in a worker isolate must stay valid after
// `Isolate.run` hands it over and the worker exits. Its own file: a second
// isolate using the plugin takes the stream registry with it, so it must not
// share a process with the streaming tests.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

const int _size = 4 * 1024 * 1024;

Uint8List _body() => Uint8List(_size)..fillRange(0, _size, 0x5a);

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
    final body = _body();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add(body);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/';

    final bodies = await Isolate.run(_WorkerGets(url).run);
    // Churn the allocator so a freed block would be reused or unmapped.
    final client = NitroHttpClient();
    addTearDown(client.dispose);
    for (var i = 0; i < 8; i++) {
      await client.get(url);
    }
    for (final received in bodies) {
      expect(received, body);
    }
  }, skip: lib.existsSync() ? null : 'build/lib/libnitro_http.dylib missing');
}
