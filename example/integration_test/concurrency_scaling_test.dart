// Is one engine thread the ceiling on concurrency?
//
// Burst is the last row where this client is clearly behind: 64 concurrent GETs
// measure 8.07 ms against rhttp's 5.48 ms. The architectural suspicion is
// structural rather than a missed optimisation — `curl_multi` is single-threaded
// by design, so one `NitroHttpClient` drives every one of its in-flight
// transfers, all their callbacks and all their response building on ONE loop
// thread. rhttp sits on reqwest/hyper over a multi-threaded Tokio runtime and
// spreads the same work across cores.
//
// That hypothesis is testable with no code change at all, because each client
// owns an engine and therefore a loop thread. Issue the same 64 requests split
// across 1, 2, 4 and 8 clients:
//
//   • If time falls as clients rise, the loop thread was the ceiling and the
//     answer is sharding (internally, or documented as "use a client per core").
//   • If it is flat, the thread is not saturated and the gap is somewhere else —
//     per-request setup, the bridge, or the server — and sharding would be
//     pure complexity for nothing.
//
// The server is shared and identical in every case, so it cancels out; and it
// demonstrably serves faster than 8 ms, since rhttp and package:http both do.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/concurrency_scaling_test.dart

@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

/// Requests in flight per round, held constant across every shard count.
const int _inFlight = int.fromEnvironment('BURST', defaultValue: 64);
const int _rounds = int.fromEnvironment('ROUNDS', defaultValue: 15);

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

  testWidgets('burst against engine count', (tester) async {
    // ignore: avoid_print
    print('cores: ${Platform.numberOfProcessors}, in flight: $_inFlight');
    // ignore: avoid_print
    print('| clients | per client | median | vs 1 client |');
    // ignore: avoid_print
    print('|---|---:|---:|---:|');

    int? baseline;

    for (final shards in <int>[1, 2, 4, 8]) {
      final clients = <NitroHttpClient>[
        for (var i = 0; i < shards; i++)
          NitroHttpClient(settings: ClientSettings(baseUrl: server.baseUrl)),
      ];
      // Warm every connection pool before timing: a cold shard would pay
      // connection setup that the single-client case already paid.
      for (final c in clients) {
        await Future.wait([
          for (var i = 0; i < 8; i++) c.get('/bytes/1024'),
        ]);
      }

      final samples = <int>[];
      for (var round = 0; round < _rounds; round++) {
        final sw = Stopwatch()..start();
        await Future.wait([
          for (var i = 0; i < _inFlight; i++)
            clients[i % shards].get('/bytes/1024'),
        ]);
        sw.stop();
        samples.add(sw.elapsedMicroseconds);
      }
      for (final c in clients) {
        c.dispose();
      }

      final med = _median(samples);
      baseline ??= med;
      final ratio = med / baseline;
      // ignore: avoid_print
      print(
        '| $shards | ${_inFlight ~/ shards} | '
        '${(med / 1000).toStringAsFixed(2)} ms | '
        '${ratio.toStringAsFixed(2)}x |',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
