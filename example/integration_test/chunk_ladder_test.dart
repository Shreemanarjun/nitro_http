// Does the chunk ladder's shape survive measurement?
//
// `adaptiveCoalesceBytes` steps 64 KiB → 256 KiB above 16 MiB → 512 KiB above
// 128 MiB. The 64 KiB step is measured: it took a 32 MiB download from 143.9 ms
// to 134.6 ms. **The two upper steps were picked by reasoning, not measured**,
// and the size sweep then put 32 MiB at 143 ms — worse than the 138.6 ms the
// benchmark reported — which is exactly the kind of hint that says a guess was
// wrong.
//
// This sweeps chunk size against body size directly, using the public
// `StreamChunkSettings` API, so the ladder can be read off data instead of
// argued about. For each body size the winning chunk size is the one the ladder
// should return at that size.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/chunk_ladder_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

/// Bodies to test, in MiB. Each straddles or sits inside a ladder step.
const List<int> _bodyMiB = [8, 32, 64, 128, 256];

/// Chunk sizes to try, in KiB. `0` means "stream every block as it arrives",
/// which is the no-batching baseline the ladder has to beat.
const List<int> _chunkKiB = [0, 16, 64, 128, 256, 512, 1024];

/// Bytes each cell is allowed to move, so a 256 MiB row does not run as often as
/// an 8 MiB one.
const int _budgetMiB = int.fromEnvironment('LADDER_BUDGET_MIB', defaultValue: 96);

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

  testWidgets('chunk size against body size', (tester) async {
    // ignore: avoid_print
    print('| body | chunk | n | median | MiB/s |');
    // ignore: avoid_print
    print('|---|---|---:|---:|---:|');

    final best = <int, (int, double)>{};

    for (final mib in _bodyMiB) {
      final bytes = mib * 1024 * 1024;
      final repeats = ((_budgetMiB / mib).floor()).clamp(2, 20);

      for (final chunkKiB in _chunkKiB) {
        // `immediate` is the honest way to express "no batching"; a fixed size
        // of 0 is not a legal setting.
        final settings = ClientSettings(
          baseUrl: server.baseUrl,
          streamChunks: chunkKiB == 0
              ? const StreamChunkSettings.immediate()
              : StreamChunkSettings.fixed(
                  chunkKiB * 1024,
                  // Force batching on regardless of size so the cell measures
                  // the chunk size and nothing else.
                  minContentLength: 1,
                ),
        );
        final client = NitroHttpClient(settings: settings);

        // Warm the connection for this client before timing it.
        await client.get('/bytes/1024');

        final samples = <int>[];
        for (var i = 0; i < repeats; i++) {
          final sw = Stopwatch()..start();
          final res = await client.requestStream(
            HttpMethod.get,
            '/bytes/$bytes',
          );
          var total = 0;
          await for (final chunk in res.body) {
            total += chunk.length;
          }
          sw.stop();
          expect(total, bytes);
          samples.add(sw.elapsedMicroseconds);
        }
        client.dispose();

        final median = _median(samples);
        final mibs = bytes / (median / 1e6) / (1024 * 1024);
        final prior = best[mib];
        if (prior == null || mibs > prior.$2) best[mib] = (chunkKiB, mibs);

        // ignore: avoid_print
        print(
          '| ${mib}MiB | ${chunkKiB == 0 ? 'none' : '${chunkKiB}KiB'} '
          '| $repeats | ${(median / 1000).toStringAsFixed(2)} ms '
          '| ${mibs.toStringAsFixed(1)} |',
        );
      }
    }

    // ignore: avoid_print
    print('\nLADDER — fastest chunk size per body size:');
    for (final mib in _bodyMiB) {
      final (chunk, mibs) = best[mib]!;
      // ignore: avoid_print
      print(
        '  ${mib}MiB → ${chunk == 0 ? 'no batching' : '${chunk}KiB'} '
        '(${mibs.toStringAsFixed(1)} MiB/s)',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}
