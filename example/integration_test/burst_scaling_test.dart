// Does burst latency come from ONE loop thread serialising per-request work?
//
// The gap ledger after the burst-methodology fix leaves exactly one scenario
// unexplained. `small GET` is 50 us behind dart:io and that 50 us is accounted
// for (37 us bridge + 13 us engine, `handoff_cost_test`); download and mixed are
// wins; upload is a tie. Burst is 4.06 ms against rhttp's 3.63 ms — 430 us with
// no owner.
//
// The suspicion is that the 13 us of per-request engine work, which is trivial
// when a request runs alone, is NOT trivial in a burst: one `curl_multi` loop
// thread runs it for every transfer, so it serialises. The median request in a
// burst of N waits behind roughly N/2 of them, and 430 us / 32 is 13.4 us — the
// same number. rhttp spreads that work over a Tokio pool, so it does not stack
// the same way.
//
// If that is right, per-request p50 must grow LINEARLY with burst width, and the
// slope is the per-request loop-thread cost. If p50 is flat, or grows far slower
// than linearly, the loop thread is not the constraint and the 430 us is
// somewhere else entirely.
//
// Reading the slope: p50(N) ~= intercept + slope * N/2, so
//   slope_per_request = 2 * d(p50) / d(N).
// Compare that against the 13 us `handoff_cost_test` attributes to engine work.
//
// The pool is primed to the widest burst before timing, so no step pays
// connection setup — the same correction the benchmark's burst scenario now
// makes.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/burst_scaling_test.dart

@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

const List<int> _widths = <int>[8, 16, 32, 64, 128];
const int _rounds = 30;

Duration _median(List<Duration> xs) {
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

  testWidgets('per-request p50 against burst width', (tester) async {
    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(client.dispose);

    const path = '/bytes/1024';
    final widest = _widths.reduce((int a, int b) => a > b ? a : b);
    // Prime to the WIDEST burst, so no step below it pays connection setup and
    // every step is compared on the same warm pool.
    for (var i = 0; i < 3; i++) {
      await Future.wait(<Future<void>>[
        for (var j = 0; j < widest; j++) client.get(path),
      ]);
    }

    // ignore: avoid_print
    print('BURST_SCALING rounds=$_rounds');
    // ignore: avoid_print
    print('| width | per-request p50 | p50/width | implied per-request |');
    // ignore: avoid_print
    print('|---:|---:|---:|---:|');

    final results = <int, Duration>{};
    for (final width in _widths) {
      final samples = <Duration>[];
      for (var round = 0; round < _rounds; round++) {
        final latencies = await Future.wait(<Future<Duration>>[
          for (var i = 0; i < width; i++)
            () async {
              final one = Stopwatch()..start();
              await client.get(path);
              return one.elapsed;
            }(),
        ]);
        samples.addAll(latencies);
      }
      final p50 = _median(samples);
      results[width] = p50;
      // p50 ~= intercept + slope * width/2  ->  slope ~= 2 * p50 / width once
      // the intercept is small, which this column makes visible: a serialising
      // loop keeps it roughly CONSTANT across widths, and anything else does not.
      final implied = 2 * p50.inMicroseconds / width;
      // ignore: avoid_print
      print(
        '| $width | ${(p50.inMicroseconds / 1000).toStringAsFixed(2)} ms | '
        '${(p50.inMicroseconds / width).toStringAsFixed(1)} us | '
        '${implied.toStringAsFixed(1)} us |',
      );
    }

    // Least-squares slope over the whole sweep, which is less sensitive to any
    // single width than differencing the endpoints.
    final n = _widths.length;
    final meanX = _widths.reduce((int a, int b) => a + b) / n;
    final meanY =
        _widths.map((int w) => results[w]!.inMicroseconds).reduce((a, b) => a + b) /
        n;
    var num = 0.0;
    var den = 0.0;
    for (final w in _widths) {
      num += (w - meanX) * (results[w]!.inMicroseconds - meanY);
      den += (w - meanX) * (w - meanX);
    }
    final slope = num / den;
    // ignore: avoid_print
    print(
      'BURST_SCALING slope ${slope.toStringAsFixed(2)} us per unit width '
      '-> ${(slope * 2).toStringAsFixed(1)} us of serialised work per request',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));
}
