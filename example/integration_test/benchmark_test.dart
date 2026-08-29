// The benchmark, run as an integration test so it executes on a real device
// with the real plugin — and, for `rhttp`, with its real Rust library.
//
// It is a test only because that is the only way Flutter will build and launch
// the native side for us. It asserts almost nothing about timing (numbers on
// somebody else's CI box are not a contract); what it does assert is that every
// client returned the right number of bytes, so a "fast" result cannot come from
// a client that quietly failed.
//
// Run it in PROFILE mode. `flutter test` always builds debug, and debug timings
// are wrong in shape as well as slow: they tax whichever client does more of its
// work in Dart, which flattered this one on some rows and penalised it badly on
// others (the same 8 MiB upload reports 49 MiB/s debug, 76 MiB/s profile).
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/benchmark_test.dart
//
// Iteration counts and dispatch mode are overridable so the same file serves a
// quick sanity run and a long one:
//
//   flutter test -d macos integration_test/benchmark_test.dart \
//     --dart-define=BENCH_ITERATIONS=1000 --dart-define=BENCH_DOWNLOAD_MIB=100
//
//   # the same suite, with 32 requests in flight instead of one at a time
//   flutter test -d macos integration_test/benchmark_test.dart \
//     --dart-define=BENCH_EXECUTION=concurrent --dart-define=BENCH_CONCURRENCY=32
//
// Release-mode numbers are the only ones worth quoting; a debug build carries
// JIT warm-up and assertion overhead in the Dart layer of every client equally,
// but it still is not what ships.

@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/benchmark/benchmark.dart';
import 'package:nitro_http_example/benchmark/execution.dart';
import 'package:nitro_http_example/server/local_server.dart';

/// 10 000 by default. A p99 needs hundreds of samples to be more than noise,
/// and a mean needs far more than that to survive one GC pause — the Android
/// stall put a single 1003 ms outlier in 500 requests and dragged the mean from
/// 0.63 ms to 2.77 ms. Override it downward for a quick sanity run.
const int _iterations =
    int.fromEnvironment('BENCH_ITERATIONS', defaultValue: 10000);
const int _burst = int.fromEnvironment('BENCH_BURST', defaultValue: 64);

/// How many times the download and upload scenarios repeat their transfer.
///
/// Small on purpose: the unit of work is a whole 32 MiB body, so ten repeats
/// across five clients already move 1.6 GiB. It only has to be enough for a
/// median to mean something, which one transfer never was.
const int _transfers = int.fromEnvironment('BENCH_TRANSFERS', defaultValue: 10);
const int _mixed = int.fromEnvironment('BENCH_MIXED', defaultValue: 100);
const int _downloadMiB = int.fromEnvironment('BENCH_DOWNLOAD_MIB', defaultValue: 32);
const int _uploadMiB = int.fromEnvironment('BENCH_UPLOAD_MIB', defaultValue: 8);
const int _warmup = int.fromEnvironment('BENCH_WARMUP', defaultValue: 20);
const int _concurrency =
    int.fromEnvironment('BENCH_CONCURRENCY', defaultValue: 16);
const String _executionName =
    String.fromEnvironment('BENCH_EXECUTION', defaultValue: 'serial');

/// Whether to print one line per iteration. Off by default because it costs the
/// results table on Android — see the comment at the `runner.run` call.
const bool _showProgress =
    bool.fromEnvironment('BENCH_PROGRESS', defaultValue: false);

/// Falls back rather than throwing: a typo in a `--dart-define` must not turn a
/// half-hour device run into a failure on the first line.
BenchmarkExecution get _execution => BenchmarkExecution.values.firstWhere(
      (BenchmarkExecution mode) => mode.name == _executionName,
      orElse: () => BenchmarkExecution.serial,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('benchmark: nitro_http vs dart:io vs http vs dio vs rhttp',
      (tester) async {
    final runner = BenchmarkRunner(
      baseUrl: server.baseUrl,
      config: BenchmarkConfig(
        warmupRequests: _warmup,
        iterations: _iterations,
        burstRequests: _burst,
        transferRepeats: _transfers,
        mixedRequests: _mixed,
        downloadBytes: _downloadMiB * 1024 * 1024,
        uploadBytes: _uploadMiB * 1024 * 1024,
        execution: _execution,
        concurrency: _concurrency,
      ),
    );

    // Silenced on Android by default. `flutter drive` reads a device's stdout
    // through `adb logcat`, whose ring buffer drops the oldest lines when a
    // burst overruns it — and one line per iteration is a burst: at
    // BENCH_ITERATIONS=500 across five clients the progress alone is tens of
    // thousands of lines. The run completes and reports "All tests passed", but
    // the results table, printed last, is gone by the time the host reads the
    // log. Pass --dart-define=BENCH_PROGRESS=true to get it back.
    final report = await runner.run(
      onProgress: _showProgress
          // ignore: avoid_print
          ? (BenchmarkProgress p) => print(p.message)
          : null,
    );

    // One `print` per line, not one for the whole table. Android's logcat caps a
    // single message at roughly 4 KB and silently truncates the rest, which ate
    // every row after the third on a five-client run — the table looked like the
    // benchmark had crashed halfway when it had actually finished.
    for (final line in report.toMarkdownTable().split('\n')) {
      // ignore: avoid_print
      print(line);
    }
    // ignore: avoid_print
    print(_engineLine());

    // Correctness gate, shared verbatim with the release runner so both paths
    // apply the same standard: a client that returned the wrong number of bytes
    // did not do the work, and its latency must not be reported as a win.
    final problems = report.consistencyProblems();
    for (final problem in problems) {
      // ignore: avoid_print
      print('PROBLEM $problem');
    }
    expect(
      problems,
      isEmpty,
      reason: 'every client must complete every scenario and move the same '
          'bytes for the numbers to be comparable',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));
}

String _engineLine() =>
    '\nengine: ${NitroHttp.engineVersion}\n'
    'http3=${NitroHttp.supportsHttp3} '
    'brotli=${NitroHttp.supportsBrotli} '
    'zstd=${NitroHttp.supportsZstd}';
