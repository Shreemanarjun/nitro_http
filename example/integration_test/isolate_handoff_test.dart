// The hand-off from the root isolate, woken through the platform's message
// loop, against a spawned one, woken by the VM's thread pool: the empty round
// trip of handoff_cost_test, and a 1 KiB GET.
//
//   cd example
//   flutter drive --profile -d <device> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/isolate_handoff_test.dart

@Tags(['benchmark'])
library;

import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

int _median(List<int> xs) {
  xs.sort();
  return xs[xs.length ~/ 2];
}

/// `[empty round trip, 1 KiB GET]`, median microseconds.
Future<List<int>> _measure(String baseUrl) async {
  final client = NitroHttpClient(settings: ClientSettings(baseUrl: baseUrl));
  Future<void> empty() async {
    try {
      await client.get(
        '/bytes/1024',
        options: const RequestOptions(cacheMode: CacheMode.onlyIfCached),
      );
    } on NitroHttpCacheMissException {
      // The engine answered without touching the network.
    }
  }

  Future<int> p50(Future<void> Function() once) async {
    final micros = <int>[];
    final watch = Stopwatch();
    for (var i = 0; i < 2300; i++) {
      watch
        ..reset()
        ..start();
      await once();
      watch.stop();
      if (i >= 300) micros.add(watch.elapsedMicroseconds);
    }
    return _median(micros);
  }

  final result = [await p50(empty), await p50(() => client.get('/bytes/1024'))];
  client.dispose();
  return result;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('root isolate vs spawned isolate', (tester) async {
    NitroHttp.reset();
    final server = await IsolatedServer.start();
    final baseUrl = server.baseUrl;
    for (var round = 0; round < 2; round++) {
      final root = await _measure(baseUrl);
      final spawned = await Isolate.run(() => _measure(baseUrl));
      // ignore: avoid_print
      print('ISOLATE_HANDOFF us — root: empty ${root[0]} get ${root[1]} | '
          'spawned: empty ${spawned[0]} get ${spawned[1]}');
    }
    await server.stop();
  });
}
