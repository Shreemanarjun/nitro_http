// Throughput across the whole transfer-size range, for every client.
//
// The benchmark measures two fixed sizes — a 1 KiB GET and a 32 MiB download —
// which says nothing about the sizes in between, and those are where the
// engine's behaviour actually changes. `nitro_http` batches streamed chunks on a
// ladder keyed to `Content-Length` (immediate below 1 MiB, then 64 KiB, 256 KiB
// past 16 MiB, 512 KiB past 128 MiB), so a sweep is the only way to see whether
// each step earns its place and whether any step leaves a hole a competitor
// walks through.
//
// It also answers the question a user actually has, which is not "who wins a
// 32 MiB download" but "is this fast for MY payload size".
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/size_sweep_test.dart
//
// The default ladder stops at 256 MiB so a run stays a few minutes. Push it to
// 1 GiB when the question is sustained throughput rather than the shape of the
// curve:
//
//   --dart-define=SWEEP_MAX_MIB=1024
//
// Nothing is buffered: the server generates pages lazily and every client counts
// bytes as they stream, so a 1 GiB row costs 1 GiB of transfer and no allocation
// on either side.

@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';
import 'package:integration_test/integration_test.dart';

/// Largest size in the sweep, in MiB.
const int _maxMiB = int.fromEnvironment('SWEEP_MAX_MIB', defaultValue: 256);

/// Total bytes each size is allowed to move, per client.
///
/// Repeats are derived from this rather than fixed, so a 1 KiB row gets enough
/// samples for a median while a 1 GiB row still runs once. Without it a sweep
/// either takes hours at the top or is statistically worthless at the bottom.
const int _budgetMiB = int.fromEnvironment('SWEEP_BUDGET_MIB', defaultValue: 64);

/// Sizes to sweep, in bytes. Chosen to straddle every step of the engine's
/// chunk ladder and the boundary below it.
List<int> _sizes() {
  const candidates = <int>[
    1024, // 1 KiB    — pure per-request overhead
    64 * 1024, // 64 KiB
    512 * 1024, // 512 KiB  — just under the batching threshold
    1024 * 1024, // 1 MiB    — batching turns on here
    8 * 1024 * 1024, // 8 MiB
    32 * 1024 * 1024, // 32 MiB   — the benchmark's size
    128 * 1024 * 1024, // 128 MiB  — 512 KiB chunks from here
    256 * 1024 * 1024,
    512 * 1024 * 1024,
    1024 * 1024 * 1024, // 1 GiB
  ];
  final cap = _maxMiB * 1024 * 1024;
  return candidates.where((s) => s <= cap).toList();
}

int _repeatsFor(int size) {
  final budget = _budgetMiB * 1024 * 1024;
  final n = budget ~/ size;
  return n.clamp(1, 50);
}

double _mibPerSecond(int bytes, Duration elapsed) {
  final seconds = elapsed.inMicroseconds / 1e6;
  if (seconds <= 0) return 0;
  return bytes / seconds / (1024 * 1024);
}

typedef _Download = Future<int> Function(String url);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('throughput across transfer sizes', (tester) async {
    final nitro = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(nitro.dispose);
    final io = HttpClient();
    addTearDown(() => io.close(force: true));
    final pkgHttp = http.Client();
    addTearDown(pkgHttp.close);

    // Every client streams and counts; none accumulates, so a 1 GiB row is
    // bounded memory and the comparison is like for like.
    final clients = <String, _Download>{
      'nitro_http': (url) async {
        final res = await nitro.requestStream(HttpMethod.get, url);
        var total = 0;
        await for (final chunk in res.body) {
          total += chunk.length;
        }
        return total;
      },
      'dart:io': (url) async {
        final req = await io.getUrl(Uri.parse('${server.baseUrl}$url'));
        final res = await req.close();
        var total = 0;
        await for (final chunk in res) {
          total += chunk.length;
        }
        return total;
      },
      'package:http': (url) async {
        final res = await pkgHttp.send(
          http.Request('GET', Uri.parse('${server.baseUrl}$url')),
        );
        var total = 0;
        await for (final chunk in res.stream) {
          total += chunk.length;
        }
        return total;
      },
    };

    // Warm every connection so the first row is not measuring TCP setup.
    for (final download in clients.values) {
      await download('/bytes/1024');
    }

    // ignore: avoid_print
    print('| size | client | n | median | MiB/s |');
    // ignore: avoid_print
    print('|---|---|---:|---:|---:|');

    for (final size in _sizes()) {
      final repeats = _repeatsFor(size);
      final label = size >= 1024 * 1024
          ? '${size ~/ (1024 * 1024)} MiB'
          : '${size ~/ 1024} KiB';

      for (final entry in clients.entries) {
        final samples = <Duration>[];
        for (var i = 0; i < repeats; i++) {
          final sw = Stopwatch()..start();
          final got = await entry.value('/bytes/$size');
          sw.stop();
          expect(got, size, reason: '${entry.key} at $label returned $got');
          samples.add(sw.elapsed);
        }
        samples.sort();
        final median = samples[samples.length ~/ 2];
        // ignore: avoid_print
        print(
          '| $label | ${entry.key} | $repeats | '
          '${(median.inMicroseconds / 1000).toStringAsFixed(2)} ms | '
          '${_mibPerSecond(size, median).toStringAsFixed(1)} |',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}
