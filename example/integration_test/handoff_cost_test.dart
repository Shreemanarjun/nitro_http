// Is the unexplained per-request cost the native→Dart handoff?
//
// The budget for a 1 KiB loopback GET is wall 164 us = queue 6 + curl 111 +
// glue 47. Of that glue, the Dart side accounts for ~2.4 us, record marshalling
// ~0.9 us, the per-call `ReceivePort` ~4 us, and easy-handle pooling turned out
// to be worth only ~1-2 us. That leaves ~38 us with no owner.
//
// The hypothesis is that it is the bridge itself: the Dart thread queues an op
// and wakes the loop thread, the loop thread does the work and calls
// `Dart_PostCObject_DL`, and the isolate's event loop then has to be woken to
// receive it. `kSpinWindow` already removed the wakeup on the submit side —
// `queue` is single-digit microseconds — but nothing can keep the *Dart* isolate
// warm, so the completion side still pays a scheduler round trip.
//
// Measuring it needs a request that travels the whole path and does no work.
// `cacheMode: onlyIfCached` against a cold cache is exactly that: the engine
// answers `cacheMiss` from `tryServeFromCache` on the loop thread without
// opening a socket, resolving a name, or touching curl at all. No wire change
// and no clock reconciliation — one Dart `Stopwatch` spans the whole round trip.
//
// Read the result as: `handoff` is the floor this architecture pays per request.
// Whatever `glue` is above it belongs to the engine and can be optimised;
// whatever `handoff` itself costs is structural.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/handoff_cost_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

int _median(List<int> xs) {
  xs.sort();
  return xs[xs.length ~/ 2];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('bridge round trip with no work in it', (tester) async {
    const iterations = 2000;
    const warmup = 300;

    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(client.dispose);

    // 1. The empty round trip: Dart → inbox → loop thread → post → Dart.
    Future<void> emptyRoundTrip() async {
      try {
        await client.get(
          '/bytes/1024',
          options: const RequestOptions(cacheMode: CacheMode.onlyIfCached),
        );
        fail('onlyIfCached against a cold cache must miss');
      } on NitroHttpCacheMissException {
        // Expected: the engine answered without touching the network.
      }
    }

    for (var i = 0; i < warmup; i++) {
      await emptyRoundTrip();
    }
    final handoff = <int>[];
    for (var i = 0; i < iterations; i++) {
      final sw = Stopwatch()..start();
      await emptyRoundTrip();
      sw.stop();
      handoff.add(sw.elapsedMicroseconds);
    }

    // 2. The same client doing the real request, for the comparison.
    for (var i = 0; i < warmup; i++) {
      await client.get('/bytes/1024');
    }
    final wall = <int>[];
    final queue = <int>[];
    final curlTotal = <int>[];
    for (var i = 0; i < iterations; i++) {
      final sw = Stopwatch()..start();
      final res = await client.get('/bytes/1024');
      sw.stop();
      expect(res.statusCode, 200);
      wall.add(sw.elapsedMicroseconds);
      queue.add(res.timings.queue.inMicroseconds);
      curlTotal.add(res.timings.total.inMicroseconds);
    }

    final h = _median(handoff);
    final w = _median(wall);
    final glue = w - _median(queue) - _median(curlTotal);

    // ignore: avoid_print
    print(
      'HANDOFF us — emptyRoundTrip $h | wall $w | glue $glue | '
      'engineWorkInGlue ${glue - h} | '
      'handoffShareOfGlue ${(100 * h / glue).toStringAsFixed(0)}%',
    );

    expect(h, greaterThan(0));
  });
}
