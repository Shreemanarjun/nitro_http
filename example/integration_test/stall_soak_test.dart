// Reproduce and localise the ~1 s Android stall.
//
// The final benchmark saw one request in 500 take 1003.64 ms on a physical
// Android device, against a p99 of 3.59 ms and competitor maxima of 3-11 ms.
// `CurlEngine.cpp`'s `kPollTimeoutMs` is 1000, which makes a blocking
// `curl_multi_poll` that nothing woke the obvious suspect.
//
// Guessing which half is at fault is what this avoids. Every response already
// carries the split:
//
//   timings.queue  — Dart handed the request over → the loop thread picked it up
//   timings.total  — CURLINFO_TOTAL_TIME, the transfer as libcurl saw it
//
// So a stalled request localises itself:
//
//   queue ≈ 1000 ms  → the op sat in the inbox; the loop was asleep in poll and
//                      the wakeup did not arrive or was not enough.
//   total ≈ 1000 ms  → the op started promptly and the stall is inside curl —
//                      a socket or resolver event the poll set missed.
//   neither          → the time went somewhere else entirely (Dart scheduling,
//                      the isolate, or the device descheduling the thread), and
//                      the poll timeout is a red herring.
//
// Run it long enough to catch a 1-in-500 event several times over:
//
//   cd example
//   flutter drive --profile -d <android-device> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/stall_soak_test.dart \
//     --dart-define=SOAK_ITERATIONS=20000

@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

const int _iterations =
    int.fromEnvironment('SOAK_ITERATIONS', defaultValue: 20000);

/// Anything slower than this is a stall worth a line of output, not a slow
/// request. p99 on the device was 3.59 ms.
const int _stallThresholdUs =
    int.fromEnvironment('SOAK_STALL_US', defaultValue: 50000);

class _Sample {
  const _Sample(this.index, this.wallUs, this.queueUs, this.totalUs);
  final int index;
  final int wallUs;
  final int queueUs;
  final int totalUs;

  /// Time the request spent neither queued nor inside curl.
  int get unaccountedUs => wallUs - queueUs - totalUs;

  @override
  String toString() =>
      '#$index wall ${wallUs}us = queue ${queueUs}us + curl ${totalUs}us '
      '+ unaccounted ${unaccountedUs}us';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('soak for stalls', (tester) async {
    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(client.dispose);

    for (var i = 0; i < 200; i++) {
      await client.get('/bytes/1024');
    }

    final stalls = <_Sample>[];
    final walls = <int>[];
    var worst = const _Sample(-1, 0, 0, 0);

    for (var i = 0; i < _iterations; i++) {
      final sw = Stopwatch()..start();
      final res = await client.get('/bytes/1024');
      sw.stop();
      expect(res.statusCode, 200);

      final sample = _Sample(
        i,
        sw.elapsedMicroseconds,
        res.timings.queue.inMicroseconds,
        res.timings.total.inMicroseconds,
      );
      walls.add(sample.wallUs);
      if (sample.wallUs > worst.wallUs) worst = sample;
      if (sample.wallUs >= _stallThresholdUs) {
        stalls.add(sample);
        // ignore: avoid_print
        print('STALL $sample');
      }
    }

    walls.sort();
    // ignore: avoid_print
    print(
      'SOAK n=$_iterations '
      'p50 ${walls[walls.length ~/ 2]}us '
      'p99 ${walls[(walls.length * 99) ~/ 100]}us '
      'max ${walls.last}us '
      'stalls(>=${_stallThresholdUs}us) ${stalls.length}',
    );
    // ignore: avoid_print
    print('SOAK worst — $worst');

    if (stalls.isEmpty) {
      // ignore: avoid_print
      print('SOAK verdict — no stall reproduced in this run');
    } else {
      final queueBound = stalls.where((s) => s.queueUs >= s.totalUs).length;
      // ignore: avoid_print
      print(
        'SOAK verdict — $queueBound/${stalls.length} stalls were queue-bound '
        '(op waiting in the inbox); the rest were inside curl or unaccounted',
      );
    }

    expect(walls, isNotEmpty);
  });
}
