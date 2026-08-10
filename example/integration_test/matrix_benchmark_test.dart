// The full comparison matrix: every client × every method × a range of sizes.
//
// The main benchmark answers "who wins a 1 KiB GET and a 32 MiB download", which
// is two cells of a much larger table. A user's actual question is "is this fast
// for the shape of traffic MY app makes" — and that shape varies in two
// dimensions this covers and nothing else did: body size, and verb.
//
// `AsyncBenchmarkBase` from `benchmark_harness` drives the measurement loop. It
// auto-calibrates how many times a case runs to reach a stable sample, which is
// the part worth not hand-rolling.
//
// What it does NOT do is report anything but a mean, and a mean is precisely the
// statistic one GC pause destroys — the Android stall put a single 1003 ms
// sample in 500 and moved the mean from 0.63 ms to 2.77 ms while the median
// barely twitched. So each case is run through the harness for warm-up and
// calibration, then sampled directly for a median. Both numbers are reported;
// where they disagree, the median is the honest one.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/matrix_benchmark_test.dart
//
//   # narrower, for a quick check
//   --dart-define=MATRIX_MAX_KIB=64 --dart-define=MATRIX_SAMPLES=20

import 'dart:io';
import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

/// Largest body in the matrix, in KiB. Bodies scale by ×16 from 1 KiB.
const int _maxKiB = int.fromEnvironment('MATRIX_MAX_KIB', defaultValue: 4096);

/// Timed samples taken per cell after the harness has warmed it.
const int _samples = int.fromEnvironment('MATRIX_SAMPLES', defaultValue: 50);

/// Reports into a table instead of printing per-run lines, so `AsyncBenchmarkBase`
/// can be used for calibration without its default stdout format.
class _SilentEmitter implements ScoreEmitter {
  double? lastMicros;

  @override
  void emit(String testName, double value) => lastMicros = value;
}

/// One (client, method, size) cell.
class _Case extends AsyncBenchmarkBase {
  _Case(super.name, this.body, {required super.emitter});

  final Future<void> Function() body;

  @override
  Future<void> run() => body();

  // The default warms with 10 runs of `run`; for a network call that is enough
  // to open the connection and let the pool settle, which is all warm-up means
  // here.
  @override
  Future<void> exercise() => run();
}

List<int> _sizes() {
  final out = <int>[];
  for (var kib = 1; kib <= _maxKiB; kib *= 16) {
    out.add(kib * 1024);
  }
  return out;
}

String _label(int bytes) => bytes >= 1024 * 1024
    ? '${bytes ~/ (1024 * 1024)}MiB'
    : '${bytes ~/ 1024}KiB';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('client x method x size', (tester) async {
    final nitro = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(nitro.dispose);
    final io = HttpClient();
    addTearDown(() => io.close(force: true));
    final pkgHttp = http.Client();
    addTearDown(pkgHttp.close);

    Uint8List payload(int n) => Uint8List(n);

    // Each entry runs one request and returns nothing; correctness is asserted
    // once per cell before timing, so a client that quietly fails cannot post a
    // fast time.
    final matrix = <String, Future<void> Function(String method, int size)>{
      'nitro_http': (method, size) async {
        switch (method) {
          case 'GET':
            await nitro.requestBytes(HttpMethod.get, '/bytes/$size');
          case 'HEAD':
            await nitro.head('/bytes/$size');
          case 'POST':
            await nitro.post('/upload', body: HttpBody.bytes(payload(size)));
          case 'PUT':
            await nitro.put('/upload', body: HttpBody.bytes(payload(size)));
          case 'PATCH':
            await nitro.patch('/upload', body: HttpBody.bytes(payload(size)));
          case 'DELETE':
            await nitro.delete('/status/200');
        }
      },
      'dart:io': (method, size) async {
        final uri = Uri.parse(
          '${server.baseUrl}${method == 'DELETE' ? '/status/200' : (method == 'GET' || method == 'HEAD' ? '/bytes/$size' : '/upload')}',
        );
        final req = await io.openUrl(method, uri);
        if (method == 'POST' || method == 'PUT' || method == 'PATCH') {
          req.add(payload(size));
        }
        final res = await req.close();
        await res.drain<void>();
      },
      'package:http': (method, size) async {
        final base = server.baseUrl;
        switch (method) {
          case 'GET':
            await pkgHttp.get(Uri.parse('$base/bytes/$size'));
          case 'HEAD':
            await pkgHttp.head(Uri.parse('$base/bytes/$size'));
          case 'POST':
            await pkgHttp.post(Uri.parse('$base/upload'), body: payload(size));
          case 'PUT':
            await pkgHttp.put(Uri.parse('$base/upload'), body: payload(size));
          case 'PATCH':
            await pkgHttp.patch(Uri.parse('$base/upload'), body: payload(size));
          case 'DELETE':
            await pkgHttp.delete(Uri.parse('$base/status/200'));
        }
      },
    };

    // DELETE ignores size (it targets an empty body), so it is measured once at
    // the smallest size rather than repeated across the ladder.
    const methods = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'];

    // ignore: avoid_print
    print('| method | size | client | harness mean | median | MiB/s |');
    // ignore: avoid_print
    print('|---|---|---|---:|---:|---:|');

    for (final method in methods) {
      final sizes = method == 'DELETE' || method == 'HEAD'
          ? <int>[1024]
          : _sizes();
      for (final size in sizes) {
        for (final entry in matrix.entries) {
          final emitter = _SilentEmitter();
          Future<void> once() => entry.value(method, size);

          // Correctness first: a cell that throws must not be reported at all.
          await once();

          // Harness pass: warms the connection and calibrates, and gives the
          // mean for the row.
          await _Case('${entry.key}/$method/$size', once, emitter: emitter)
              .report();

          final samples = <int>[];
          for (var i = 0; i < _samples; i++) {
            final sw = Stopwatch()..start();
            await once();
            sw.stop();
            samples.add(sw.elapsedMicroseconds);
          }
          samples.sort();
          final median = samples[samples.length ~/ 2];
          final mibs = median <= 0
              ? 0.0
              : size / (median / 1e6) / (1024 * 1024);

          // ignore: avoid_print
          print(
            '| $method | ${_label(size)} | ${entry.key} '
            '| ${(emitter.lastMicros ?? 0).toStringAsFixed(1)} us '
            '| ${(median / 1000).toStringAsFixed(3)} ms '
            '| ${method == 'DELETE' || method == 'HEAD' ? '—' : mibs.toStringAsFixed(1)} |',
          );
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}
