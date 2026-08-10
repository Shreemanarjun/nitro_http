/// Runs the benchmark in a RELEASE build and prints the result to the platform
/// log.
///
/// `flutter drive` refuses to run in release mode — "Flutter Driver (non-web)
/// does not support running in release mode" — because a release engine has no
/// Dart VM service for the driver to attach to. That leaves exactly one way to
/// measure a real release build: put the benchmark inside the app, start it from
/// `main`, and read the numbers out of the platform log.
///
/// Enabled by a compile-time define so the normal app is byte-for-byte unchanged
/// when it is off, and so it survives release-mode tree shaking (a
/// `bool.fromEnvironment` is a const the compiler folds):
///
/// ```sh
/// # macOS — stdout of the built binary
/// flutter build macos --release --dart-define=NITRO_HTTP_BENCHMARK=1
/// # (=1, =true, =yes and =on all work; =0/=false/=no/=off turn it off)
/// ./build/macos/Build/Products/Release/nitro_http_example.app/Contents/MacOS/nitro_http_example
///
/// # Android — logcat
/// flutter build apk --release --dart-define=NITRO_HTTP_BENCHMARK=1
/// adb install -r build/app/outputs/flutter-apk/app-release.apk
/// adb logcat -c && adb shell am start -n <pkg>/.MainActivity
/// adb logcat -s flutter:I
///
/// # iOS physical device — release is only possible here
/// flutter build ios --release --dart-define=NITRO_HTTP_BENCHMARK=1
/// # install via Xcode or devicectl, then:
/// xcrun devicectl device console --device <udid> | grep NITRO_BENCH
///
/// # iOS simulator — DEBUG ONLY. Flutter has no AOT snapshot for the simulator,
/// # so `--release` and `--profile` are both rejected there and any numbers a
/// # simulator produces are debug numbers. Useful for proving the wiring, not
/// # for comparing clients.
/// flutter run --debug -d <simulator udid> --dart-define=NITRO_HTTP_BENCHMARK=1
/// ```
///
/// Every line is prefixed so a noisy log can be filtered down to just the
/// report, and the run is bracketed by [beginMarker] / [endMarker] so a harness
/// can tell a finished run from a truncated one.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:nitro_http/nitro_http.dart';

import '../server/local_server.dart';
import 'benchmark.dart';
import 'execution.dart';

/// Whether this build was compiled to run the benchmark instead of the UI.
///
/// Read as a String rather than with `bool.fromEnvironment`, which accepts only
/// the exact literals `true` and `false` and silently yields its default for
/// anything else. `--dart-define=NITRO_HTTP_BENCHMARK=1` therefore compiled a
/// perfectly ordinary UI app that ignored the flag — a silent no-op, and the
/// worst possible failure for a switch whose whole job is to change what the
/// binary does. Anything other than empty or an explicit off value turns it on.
const String _benchmarkFlag =
    String.fromEnvironment('NITRO_HTTP_BENCHMARK');
const bool kBenchmarkMode = _benchmarkFlag != '' &&
    _benchmarkFlag != '0' &&
    _benchmarkFlag != 'false' &&
    _benchmarkFlag != 'no' &&
    _benchmarkFlag != 'off';

/// Printed once the run has started, after the server is up.
const String beginMarker = 'NITRO_BENCH_BEGIN';

/// Printed once, last, and only on a run that produced a full report.
const String endMarker = 'NITRO_BENCH_END';

/// Printed instead of [endMarker] when the report failed its own consistency
/// gate, so a harness can never mistake a bad run for a good one.
const String failMarker = 'NITRO_BENCH_FAIL';

/// The report is also written here, inside the app's documents directory.
///
/// Required, not a convenience: an iOS RELEASE build emits no `print` output at
/// all. Neither `devicectl process launch --console` nor `idevicesyslog` captures
/// a single line, so on the one platform where release is the only mode worth
/// measuring, the log channel does not exist. A file in the app container can be
/// pulled off the device afterwards:
///
/// ```sh
/// xcrun devicectl device copy from --device <udid> \
///   --domain-type appDataContainer --domain-identifier <bundle-id> \
///   --source Documents/nitro_benchmark.md --destination /tmp/report.md
/// ```
///
/// On Android the same file is reachable with
/// `adb exec-out run-as <pkg> cat /data/data/<pkg>/app_flutter/nitro_benchmark.md`,
/// and on macOS it lands under the app's sandboxed Documents directory. The log
/// output is kept as well, because where it works it is far more convenient.
const String reportFileName = 'nitro_benchmark.md';

/// Overridable from the same command line, so one build serves a quick sanity
/// run and a long one.
const int _warmup = int.fromEnvironment('BENCH_WARMUP', defaultValue: 50);
const int _iterations =
    int.fromEnvironment('BENCH_ITERATIONS', defaultValue: 10000);
const int _burst = int.fromEnvironment('BENCH_BURST', defaultValue: 64);
const int _burstRepeats =
    int.fromEnvironment('BENCH_BURST_REPEATS', defaultValue: 10);

/// How many times the download and upload scenarios repeat their transfer.
///
/// Small on purpose: the unit of work is a whole 32 MiB body, so ten repeats
/// across five clients already move 1.6 GiB. It only has to be enough for a
/// median to mean something, which one transfer never was.
const int _transfers = int.fromEnvironment('BENCH_TRANSFERS', defaultValue: 10);
const int _mixed = int.fromEnvironment('BENCH_MIXED', defaultValue: 100);
const int _downloadMiB = int.fromEnvironment('BENCH_DOWNLOAD_MIB',
    defaultValue: 32);
const int _uploadMiB = int.fromEnvironment('BENCH_UPLOAD_MIB', defaultValue: 8);

/// How the iteration-based scenarios dispatch, as `serial`, `concurrent` or
/// `parallel`.
///
/// Serial by default: it is the only mode where a per-request latency is not
/// contending with the run's own other requests, which is what a cross-platform
/// measurement wants as its baseline.
const String _executionName =
    String.fromEnvironment('BENCH_EXECUTION', defaultValue: 'serial');

/// The in-flight cap that `BENCH_EXECUTION=concurrent` uses.
const int _concurrency =
    int.fromEnvironment('BENCH_CONCURRENCY', defaultValue: 16);

/// Resolves [_executionName], falling back rather than throwing: a typo in a
/// `--dart-define` must not turn a twenty-minute device run into a crash on
/// launch. The chosen mode is printed in the preamble either way.
BenchmarkExecution get _execution => BenchmarkExecution.values.firstWhere(
      (BenchmarkExecution mode) => mode.name == _executionName,
      orElse: () => BenchmarkExecution.serial,
    );

/// The mode this binary was actually compiled in.
///
/// Read from the build, never hardcoded: the entire purpose of this runner is
/// that nobody mistakes debug numbers for release ones, so the marker must not be
/// able to claim `release` while running under the JIT. iOS simulators can only
/// ever run debug, so this really does vary.
String get _buildMode {
  if (kReleaseMode) return 'release';
  if (kProfileMode) return 'profile';
  return 'debug';
}

void _emit(String line) {
  // `debugPrint` is not stripped in release and routes through the platform log
  // on every target, which is the only channel a release build has. Splitting by
  // line keeps Android's 4 KiB-per-message logcat truncation from eating the
  // middle of the table.
  for (final part in line.split('\n')) {
    debugPrint('NITRO_BENCH $part');
  }
}

/// Writes the report where a harness can retrieve it even when logging is dead.
Future<void> _writeReport(
  BenchmarkReport report,
  List<String> problems,
) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$reportFileName');
    await file.writeAsString(
      <String>[
        '<!-- mode=$_buildMode -->',
        if (!kReleaseMode)
          '> WARNING $_buildMode build: these timings are not comparable with '
              'release numbers.',
        '',
        'engine: ${NitroHttp.engineVersion}',
        'http3=${NitroHttp.supportsHttp3} brotli=${NitroHttp.supportsBrotli} '
            'zstd=${NitroHttp.supportsZstd}',
        '',
        report.toMarkdownTable(),
        '',
        if (problems.isEmpty)
          endMarker
        else ...[
          for (final problem in problems) 'PROBLEM $problem',
          '$failMarker ${problems.length} problem(s)',
        ],
      ].join('\n'),
    );
    _emit('report written to ${file.path}');
  } on Object catch (error) {
    // Never fatal: the log may still have carried the table.
    _emit('could not write the report file: $error');
  }
}

/// Runs every scenario against every client and prints the report.
///
/// Never throws: a release build that dies in `main` cannot say why, so failures
/// are printed and marked instead.
Future<void> runReleaseBenchmark() async {
  LocalServer? server;
  try {
    NitroHttp.reset();
    server = await LocalServer.start();
    _emit('$beginMarker mode=$_buildMode '
        'engine=${NitroHttp.engineVersion.replaceAll('\n', ' ')}');
    if (!kReleaseMode) {
      _emit('WARNING this is a $_buildMode build. Its timings are not '
          'comparable with release numbers and must not be pooled with them: '
          'debug taxes whichever client does most of its work in Dart.');
    }
    _emit('http3=${NitroHttp.supportsHttp3} '
        'brotli=${NitroHttp.supportsBrotli} '
        'zstd=${NitroHttp.supportsZstd}');

    final started = Stopwatch()..start();
    final report = await BenchmarkRunner(
      baseUrl: server.baseUrl,
      config: BenchmarkConfig(
        warmupRequests: _warmup,
        iterations: _iterations,
        burstRequests: _burst,
        burstRepeats: _burstRepeats,
        transferRepeats: _transfers,
        mixedRequests: _mixed,
        downloadBytes: _downloadMiB * 1024 * 1024,
        uploadBytes: _uploadMiB * 1024 * 1024,
        execution: _execution,
        concurrency: _concurrency,
      ),
    ).run(onProgress: _heartbeat(started));

    _emit(report.toMarkdownTable());

    final problems = report.consistencyProblems();
    await _writeReport(report, problems);
    if (problems.isEmpty) {
      _emit(endMarker);
    } else {
      for (final problem in problems) {
        _emit('PROBLEM $problem');
      }
      _emit('$failMarker ${problems.length} problem(s)');
    }
    exitCode = problems.isEmpty ? 0 : 1;
  } on Object catch (error, stack) {
    _emit('$failMarker $error');
    _emit('$stack');
    exitCode = 1;
  } finally {
    await server?.stop();
    await _quit();
  }
}

/// Ends the process once the report is out.
///
/// A benchmark build is a batch job wearing an app's clothes: it runs for about
/// twenty seconds and then has nothing left to do. Without this it called
/// `runApp` and sat there forever, so every invocation had to be killed by hand
/// and a `for` loop over several runs blocked on the first one — which is how a
/// five-run comparison came back with one usable run and four truncated files.
///
/// The exit code carries the consistency verdict, so a script can branch on it
/// rather than grepping for [endMarker].
///
/// `exit` is deliberate here and would be wrong in a shipped app — Apple rejects
/// binaries that terminate themselves — but this path only exists in a build
/// compiled with `NITRO_HTTP_BENCHMARK`, which is never shipped. The flush delay
/// is not decoration: `debugPrint` and the report file both need a turn of the
/// event loop to reach the platform log and the disk, and exiting first loses the
/// table on exactly the platforms whose log channel is slowest.
Future<void> _quit() async {
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exit(exitCode);
}

/// A readable progress feed for a headless run.
///
/// The obvious `onProgress: (p) => _emit(p.message)` emits one line per
/// iteration, which at the default settings is tens of thousands of lines: a
/// 437 KB log for a single macOS run, and on Android enough of a burst to
/// overrun logcat's ring buffer and take the results table with it.
///
/// It is also useless for the thing a long headless run actually needs, which is
/// "how far along is this and is it still moving". So the feed is throttled to a
/// heartbeat: one line whenever the scenario or client changes, and otherwise at
/// most one every [_heartbeatInterval], each carrying the overall percentage and
/// the elapsed time.
void Function(BenchmarkProgress) _heartbeat(Stopwatch clock) {
  String? lastPair;
  var lastEmit = Duration.zero;

  return (BenchmarkProgress p) {
    final pair = '${p.scenario}/${p.library.name}';
    final elapsed = clock.elapsed;
    final changed = pair != lastPair;
    if (!changed && elapsed - lastEmit < _heartbeatInterval) return;
    lastPair = pair;
    lastEmit = elapsed;

    final done = p.total > 0 ? '${p.completed}/${p.total}' : 'transfer';
    // `step` counts scenario/client pairs, so it is the only honest measure of
    // overall progress — iterations within a pair are not comparable across
    // scenarios.
    final overall = p.stepCount > 0
        ? ' ${(100 * p.step / p.stepCount).toStringAsFixed(0)}%'
        : '';
    _emit(
      '[${_mmss(elapsed)}]$overall step ${p.step}/${p.stepCount} '
      '${p.scenario} — ${p.library.name} ($done)',
    );
  };
}

/// Longest a headless run goes without saying anything.
const Duration _heartbeatInterval = Duration(seconds: 2);

String _mmss(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:'
    '${(d.inSeconds % 60).toString().padLeft(2, '0')}';
