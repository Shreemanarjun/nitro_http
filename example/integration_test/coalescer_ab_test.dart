// Does coalescing completions actually pay, and does it cost anything serially?
//
// `handoff_cost_test` measured the per-call bridge round trip at 37 us and put
// it at 74 % of everything this client spends outside curl. `NitroCoalescer`
// (nitro 0.6.0, issue #39) is the fix: instead of one `ReceivePort` post per
// call, the engine buffers completions and posts each drained batch as one
// `kArray`, so a burst shares one isolate wake.
//
// Two questions, and the second matters as much as the first:
//
//   1. BURST — does batching help when many complete together? This is what it
//      is for, and where upstream measured 559 us -> ~99 us.
//   2. SERIAL — does it HURT when calls arrive one at a time? A batch of one is
//      still one post, so it should be a wash; but the coalesced path adds a
//      `releaseRecord` FFI call that the generated unpack does for free. If
//      serial regresses, coalescing has to become opt-in rather than default.
//
// Both paths live in the same binary behind `NativeRequestExecutor
// .coalesceCompletions`, so this is a true A/B: same machine, same run, same
// warm pool, interleaved rather than one after the other.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/coalescer_ab_test.dart

@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
// ignore: implementation_imports
import 'package:nitro_http/src/internal/executor_native.dart';
import 'package:nitro_http_example/server/local_server.dart';

const int _serialIterations = 2000;
const int _burstWidth = 64;
const int _burstRounds = 40;
const int _warmup = 300;

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

  tearDownAll(() async {
    NativeRequestExecutor.coalesceCompletions = true;
    server.stop();
  });

  /// Serial p50 — one request at a time, so every completion is a batch of one.
  Future<Duration> serial(NitroHttpClient client) async {
    const path = '/bytes/1024';
    for (var i = 0; i < _warmup; i++) {
      await client.get(path);
    }
    final samples = <Duration>[];
    for (var i = 0; i < _serialIterations; i++) {
      final sw = Stopwatch()..start();
      await client.get(path);
      samples.add(sw.elapsed);
    }
    return _median(samples);
  }

  /// Burst p50 — 64 in flight, pool primed to that width first so no round pays
  /// connection setup.
  Future<Duration> burst(NitroHttpClient client) async {
    const path = '/bytes/1024';
    for (var i = 0; i < 3; i++) {
      await Future.wait(<Future<void>>[
        for (var j = 0; j < _burstWidth; j++) client.get(path),
      ]);
    }
    final samples = <Duration>[];
    for (var round = 0; round < _burstRounds; round++) {
      samples.addAll(
        await Future.wait(<Future<Duration>>[
          for (var i = 0; i < _burstWidth; i++)
            () async {
              final one = Stopwatch()..start();
              await client.get(path);
              return one.elapsed;
            }(),
        ]),
      );
    }
    return _median(samples);
  }

  testWidgets('coalesced vs per-call completion', (tester) async {
    final results = <String, Map<bool, Duration>>{
      'serial': <bool, Duration>{},
      'burst': <bool, Duration>{},
    };

    // Interleaved, and each mode gets a FRESH client: a client built while
    // coalescing was on has already created its coalescer, and reusing it would
    // measure a warm port against a cold one.
    for (final coalesced in <bool>[false, true, false, true]) {
      NativeRequestExecutor.coalesceCompletions = coalesced;

      final serialClient = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.baseUrl),
      );
      results['serial']![coalesced] = await serial(serialClient);
      serialClient.dispose();

      final burstClient = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.baseUrl),
      );
      results['burst']![coalesced] = await burst(burstClient);
      burstClient.dispose();
    }

    // ignore: avoid_print
    print('COALESCER_AB serial n=$_serialIterations '
        'burst=${_burstWidth}x$_burstRounds');
    // ignore: avoid_print
    print('| scenario | per-call | coalesced | change |');
    // ignore: avoid_print
    print('|---|---:|---:|---:|');
    for (final scenario in <String>['serial', 'burst']) {
      final off = results[scenario]![false]!.inMicroseconds;
      final on = results[scenario]![true]!.inMicroseconds;
      final delta = 100 * (on - off) / off;
      // ignore: avoid_print
      print(
        '| $scenario | ${(off / 1000).toStringAsFixed(3)} ms '
        '| ${(on / 1000).toStringAsFixed(3)} ms '
        '| ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}% |',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}
