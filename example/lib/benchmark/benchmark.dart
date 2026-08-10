/// Latency and throughput benchmarks for `nitro_http` against every other HTTP
/// client a Flutter app realistically chooses: `dart:io`'s `HttpClient`,
/// `package:http`, `dio`, and `rhttp` (Rust/`reqwest` behind
/// `flutter_rust_bridge`).
///
/// Pure Dart on purpose — no Flutter import anywhere in this file — so the same
/// code runs from the benchmark screen, from a headless test host, and from CI.
/// The one shared type it does reach for is [HttpLibrary], which is a bare enum
/// with no imports of its own: the console and the benchmark must agree on what
/// "dio" means, and two enums for one concept is how those two lists drift.
///
/// Every scenario hits [BenchmarkRunner.baseUrl], which is expected to be the
/// example's own `LocalServer`. Benchmarking across the internet measures
/// somebody else's load balancer, not this client.
///
/// How the iterations of a scenario are dispatched — one at a time, N in flight,
/// or all at once — is [BenchmarkConfig.execution]; read the honest description
/// of what that does and does not parallelise on [BenchmarkExecution].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:http/http.dart' as http;
import 'package:nitro_http/nitro_http.dart';
// rhttp's model names collide with ours almost one for one (ClientSettings,
// HttpBody, HttpMethod, HttpVersionPref, HttpHeaders, CancelToken, …), so it is
// always prefixed.
import 'package:rhttp/rhttp.dart' as rhttp;

import '../core/http_library.dart';
import '../server/local_server.dart' show deterministicByteStream;
import 'execution.dart';

/// How hard each scenario pushes, and how its iterations are dispatched.
///
/// The defaults are the numbers the design document specifies. [quick] exists
/// because nobody wants to wait for a 100 MB download while poking at the UI.
final class BenchmarkConfig {
  /// Creates a configuration; every field has the documented default.
  const BenchmarkConfig({
    this.warmupRequests = 50,
    this.iterations = 10000,
    this.burstRequests = 64,
    this.burstRepeats = 10,
    this.transferRepeats = 10,
    this.downloadBytes = 100 * 1024 * 1024,
    this.uploadBytes = 10 * 1024 * 1024,
    this.mixedRequests = 200,
    this.smallBodyBytes = 1024,
    this.execution = BenchmarkExecution.serial,
    this.concurrency = 16,
    this.libraries = HttpLibrary.values,
  });

  /// A configuration small enough to run interactively.
  const BenchmarkConfig.quick()
    : warmupRequests = 10,
      iterations = 100,
      burstRequests = 32,
      burstRepeats = 3,
      transferRepeats = 1,
      downloadBytes = 8 * 1024 * 1024,
      uploadBytes = 1024 * 1024,
      mixedRequests = 40,
      smallBodyBytes = 1024,
      execution = BenchmarkExecution.serial,
      concurrency = 16,
      libraries = HttpLibrary.values;

  /// Requests discarded before measuring, so connection setup and JIT warm-up
  /// do not land in the p50.
  final int warmupRequests;

  /// Iterations of the small-GET scenario, and of the console-request scenario
  /// when one is included.
  final int iterations;

  /// Requests the burst scenario puts in flight simultaneously.
  final int burstRequests;

  /// Times the burst scenario repeats its burst.
  ///
  /// The burst used to fire exactly once, straight after a warm-up that is
  /// strictly serial — so the pool held ONE warm connection and the other
  /// [burstRequests] − 1 connections were established inside the measurement
  /// window. That made this row a connection-establishment benchmark wearing a
  /// concurrency benchmark's label, and the two answer different questions: the
  /// same client measured 8.07 ms as a one-shot cold burst and 4.95 ms once the
  /// pool was already at burst width.
  ///
  /// Pool depth is still exercised — the discarded priming burst pays exactly
  /// the same cost for every client — but it is no longer inside the numbers.
  final int burstRepeats;

  /// Times the download and upload scenarios each repeat their transfer.
  ///
  /// These used to run exactly once, which made them the least trustworthy rows
  /// in the table: a single 32 MiB transfer has no p50 to speak of, and a lone GC
  /// pause in the in-process server moved a row by 10 % with nothing else
  /// changed. Repeating gives them a distribution like every other scenario.
  ///
  /// Kept far below [iterations] because the unit of work is enormous by
  /// comparison — ten 32 MiB downloads across five clients already moves 1.6 GiB.
  final int transferRepeats;

  /// Body size of the throughput download.
  final int downloadBytes;

  /// Body size of the streamed upload.
  final int uploadBytes;

  /// Iterations of the mixed scenario.
  final int mixedRequests;

  /// Body size of a "small" request in the latency scenarios.
  final int smallBodyBytes;

  /// How the iteration-based scenarios dispatch their work.
  ///
  /// Applies to `small GET`, `mixed` and the console-request scenario. The
  /// `burst GET` row is pinned to [BenchmarkExecution.parallel] and `download`
  /// and `upload` are single transfers, so neither has iterations to dispatch.
  final BenchmarkExecution execution;

  /// The in-flight cap for [BenchmarkExecution.concurrent]. Ignored by the other
  /// two modes, which have no cap to apply.
  final int concurrency;

  /// Which clients take part, in report order.
  ///
  /// Configurable because a run that only compares two libraries finishes in two
  /// fifths of the time, and because a machine with no native engine built has
  /// two rows that can only ever say "unsupported".
  final List<HttpLibrary> libraries;

  /// How many of [count] iterations may be in flight under [execution].
  int inFlight(int count) => switch (execution) {
    BenchmarkExecution.serial => 1,
    BenchmarkExecution.concurrent => concurrency < count ? concurrency : count,
    BenchmarkExecution.parallel => count,
  };

  @override
  String toString() =>
      'BenchmarkConfig(warmup: $warmupRequests, iterations: $iterations, '
      'burst: $burstRequests × $burstRepeats, download: $downloadBytes B, '
      'upload: $uploadBytes B, mixed: $mixedRequests, '
      'execution: ${execution.label}, concurrency: $concurrency, '
      'clients: ${libraries.length})';
}

/// One scenario measured against one client.
final class BenchmarkResult {
  /// Creates a successful measurement.
  BenchmarkResult({
    required this.scenario,
    required this.library,
    required this.iterations,
    required this.latencies,
    required this.wallClock,
    required this.bytes,
    this.timeToFirstByte,
    this.bytesVaryByClient = false,
  }) : error = null;

  /// Creates a failed measurement, carrying [error] instead of numbers.
  ///
  /// A missing native library must not blank out the baseline columns, so a
  /// failure is a row rather than an exception.
  BenchmarkResult.failed({
    required this.scenario,
    required this.library,
    required this.error,
  }) : iterations = 0,
       latencies = const <Duration>[],
       wallClock = Duration.zero,
       bytes = 0,
       timeToFirstByte = null,
       bytesVaryByClient = false;

  /// The scenario name, matching the row label in the report.
  final String scenario;

  /// Which client was measured.
  final HttpLibrary library;

  /// How many requests the scenario issued, excluding warm-up.
  final int iterations;

  /// Per-request latencies, unsorted.
  final List<Duration> latencies;

  /// Wall-clock time for the whole scenario, including any queuing.
  final Duration wallClock;

  /// Body bytes transferred, summed over every iteration.
  final int bytes;

  /// Time from issuing the request to the first response byte, when the
  /// scenario measured it.
  final Duration? timeToFirstByte;

  /// Whether this scenario's byte count is expected to differ slightly between
  /// clients.
  ///
  /// True for anything that echoes the request back: `/echo` embeds the request
  /// headers, and each client sends its own `User-Agent`. The consistency gate
  /// then bounds the spread instead of demanding equality, which would be
  /// demanding that five clients pick the same product name.
  final bool bytesVaryByClient;

  /// Why the scenario did not run, or `null` when it did.
  final String? error;

  /// Fastest observed latency.
  Duration get min => _percentile(0.0);

  /// Median latency, or [Duration.zero] when nothing was measured.
  Duration get p50 => _percentile(0.50);

  /// 90th-percentile latency.
  Duration get p90 => _percentile(0.90);

  /// 95th-percentile latency, or [Duration.zero] when nothing was measured.
  Duration get p95 => _percentile(0.95);

  /// 99th-percentile latency. Meaningless below ~100 samples, which is why the
  /// default sequential scenario runs at least that many.
  Duration get p99 => _percentile(0.99);

  /// Slowest observed latency.
  Duration get max => _percentile(1.0);

  /// Arithmetic mean latency.
  Duration get mean {
    if (latencies.isEmpty) return Duration.zero;
    var total = 0;
    for (final l in latencies) {
      total += l.inMicroseconds;
    }
    return Duration(microseconds: total ~/ latencies.length);
  }

  /// Sample standard deviation of the latencies. Reported because a mean without
  /// a spread hides exactly the tail behaviour that matters under load.
  Duration get stdDev {
    if (latencies.length < 2) return Duration.zero;
    final m = mean.inMicroseconds;
    var sumSquares = 0.0;
    for (final l in latencies) {
      final d = l.inMicroseconds - m;
      sumSquares += d * d;
    }
    return Duration(
      microseconds: (sumSquares / (latencies.length - 1)).abs().toInt() == 0
          ? 0
          : _sqrt(sumSquares / (latencies.length - 1)).round(),
    );
  }

  static double _sqrt(double v) {
    if (v <= 0) return 0;
    var x = v;
    var last = 0.0;
    // Newton-Raphson; converges in a handful of steps for our magnitudes and
    // avoids importing dart:math into a file that otherwise has no maths.
    while ((x - last).abs() > 1e-6) {
      last = x;
      x = 0.5 * (x + v / x);
    }
    return x;
  }

  /// Throughput over [wallClock] in mebibytes per second.
  double get megabytesPerSecond {
    final micros = wallClock.inMicroseconds;
    if (micros == 0 || bytes == 0) return 0;
    return bytes / (1024 * 1024) / (micros / 1000000);
  }

  /// Completed requests per second over [wallClock].
  double get requestsPerSecond {
    final micros = wallClock.inMicroseconds;
    if (micros == 0 || iterations == 0) return 0;
    return iterations / (micros / 1000000);
  }

  Duration _percentile(double fraction) {
    if (latencies.isEmpty) return Duration.zero;
    final sorted = [...latencies]..sort();
    // Nearest-rank: index = ceil(p * n) - 1, clamped. With n == 1 both p50 and
    // p95 are the single sample, which is the honest answer for a one-shot
    // throughput run.
    var index = (fraction * sorted.length).ceil() - 1;
    if (index < 0) index = 0;
    if (index >= sorted.length) index = sorted.length - 1;
    return sorted[index];
  }

  @override
  String toString() =>
      'BenchmarkResult($scenario/${library.label}: '
      '${error ?? 'p50 ${_ms(p50)} p95 ${_ms(p95)}'})';
}

/// A full benchmark run: the configuration it used and every measurement.
final class BenchmarkReport {
  /// Creates a report.
  const BenchmarkReport({
    required this.baseUrl,
    required this.startedAt,
    required this.duration,
    required this.config,
    required this.results,
    this.cancelled = false,
    this.notes = const <String>[],
  });

  /// The server every scenario targeted.
  final String baseUrl;

  /// When the run started.
  final DateTime startedAt;

  /// How long the whole run took.
  final Duration duration;

  /// The configuration the run used.
  final BenchmarkConfig config;

  /// Every measurement, grouped by scenario in run order.
  final List<BenchmarkResult> results;

  /// Whether the run was stopped before it finished.
  ///
  /// A cancelled report still carries whatever it measured, because a partial
  /// table is useful — but it can never be a *valid* comparison, so the
  /// consistency gate fails it outright.
  final bool cancelled;

  /// Extra preamble lines describing scenarios the harness does not own, such as
  /// a console-authored request.
  final List<String> notes;

  /// Distinct scenario names in run order.
  List<String> get scenarios {
    final seen = <String>{};
    return [
      for (final result in results)
        if (seen.add(result.scenario)) result.scenario,
    ];
  }

  /// Everything that makes this report untrustworthy, as human-readable lines.
  ///
  /// Empty means every client completed every scenario and moved the same bytes,
  /// which is the only basis on which their timings can be compared. It lives
  /// here rather than in the integration test because the release runner has no
  /// `package:test` to assert with and must apply exactly the same gate — a fast
  /// number from a client that quietly skipped the work is worse than no number.
  List<String> consistencyProblems() {
    final problems = <String>[
      if (cancelled) 'the run was cancelled before it finished',
      for (final r in results)
        if (r.error != null)
          '${r.scenario}/${r.library.label} failed: ${r.error}',
    ];

    for (final r in results.where((BenchmarkResult r) => r.error == null)) {
      final where = '${r.scenario}/${r.library.label}';
      if (r.iterations <= 0) problems.add('$where ran zero iterations');
      if (r.bytes <= 0) problems.add('$where moved zero bytes');
    }

    for (final scenario in scenarios) {
      final rows = results
          .where((BenchmarkResult r) => r.scenario == scenario && r.error == null)
          .toList(growable: false);
      if (rows.isEmpty) continue;
      final byteCounts = rows.map((BenchmarkResult r) => r.bytes).toList()..sort();

      if (!rows.first.bytesVaryByClient) {
        if (byteCounts.first != byteCounts.last) {
          problems.add(
            '$scenario moved different byte counts per client: '
            '${rows.map((BenchmarkResult r) => '${r.library.label}=${r.bytes}').join(', ')}',
          );
        }
        continue;
      }

      // An echoing scenario cannot be held to exact equality, so bound the
      // spread instead: within 0.1 % proves every client did the same work
      // without pretending their User-Agents match.
      if (byteCounts.first > 0 &&
          (byteCounts.last - byteCounts.first) / byteCounts.first >= 0.001) {
        problems.add(
          '$scenario byte counts differ by more than header noise: '
          '${rows.map((BenchmarkResult r) => '${r.library.label}=${r.bytes}').join(', ')}',
        );
      }
    }

    return problems;
  }

  /// Renders the report as GitHub-flavoured Markdown.
  ///
  /// The preamble states the iteration counts and the dispatch mode, because a
  /// latency number without its sample size and its concurrency is decoration.
  String toMarkdownTable() {
    final inFlight = config.execution == BenchmarkExecution.concurrent
        ? '${config.execution.label} (up to ${config.concurrency} in flight)'
        : config.execution.label;
    final out = StringBuffer()
      ..writeln('## nitro_http benchmark')
      ..writeln();
    if (cancelled) {
      out
        ..writeln('> **CANCELLED** — this run was stopped early. The rows below '
            'are partial and are not a valid comparison.')
        ..writeln();
    }
    out
      ..writeln('* target: `$baseUrl` (in-process loopback server)')
      ..writeln('* started: ${startedAt.toIso8601String()}')
      ..writeln('* wall clock: ${_seconds(duration)}')
      ..writeln('* clients: '
          '${config.libraries.map((HttpLibrary l) => l.label).join(', ')}')
      ..writeln('* execution: $inFlight')
      ..writeln('* warm-up per client: ${config.warmupRequests} requests '
          '(discarded)')
      ..writeln('* small GET: ${config.iterations} × '
          '${config.smallBodyBytes} B GET')
      ..writeln('* burst GET: ${config.burstRequests} × '
          '${config.smallBodyBytes} B GET in flight, '
          '${config.burstRepeats} bursts, pool primed to burst width first')
      ..writeln('* download: ${_mib(config.downloadBytes)} streamed')
      ..writeln('* upload: ${_mib(config.uploadBytes)} streamed')
      ..writeln('* mixed: ${config.mixedRequests} interleaved requests');
    for (final note in notes) {
      out.writeln('* $note');
    }
    out
      ..writeln()
      ..writeln(
        '| Scenario | Client | n | min | mean | p50 | p90 | p95 | p99 | max '
        '| sd | MiB/s | req/s | TTFB |',
      )
      ..writeln(
        '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|',
      );

    for (final scenario in scenarios) {
      for (final result in results.where(
        (BenchmarkResult r) => r.scenario == scenario,
      )) {
        if (result.error != null) {
          out.writeln(
            '| $scenario | ${result.library.label} '
            '| — | — | — | — | — | — | — | — | — | — | — '
            '| ${_escapeCell(result.error!)} |',
          );
          continue;
        }
        out.writeln(
          '| $scenario '
          '| ${result.library.label} '
          '| ${result.iterations} '
          '| ${_ms(result.min)} '
          '| ${_ms(result.mean)} '
          '| ${_ms(result.p50)} '
          '| ${_ms(result.p90)} '
          '| ${_ms(result.p95)} '
          '| ${_ms(result.p99)} '
          '| ${_ms(result.max)} '
          '| ${_ms(result.stdDev)} '
          '| ${result.megabytesPerSecond.toStringAsFixed(1)} '
          '| ${result.requestsPerSecond.toStringAsFixed(0)} '
          '| ${result.timeToFirstByte == null ? '—' : _ms(result.timeToFirstByte!)} |',
        );
      }
    }
    return out.toString();
  }

  @override
  String toString() => toMarkdownTable();
}

/// Runs every built-in scenario against every selected client.
final class BenchmarkRunner {
  /// Creates a runner pointed at [baseUrl].
  BenchmarkRunner({
    required this.baseUrl,
    this.config = const BenchmarkConfig(),
  });

  /// Root URL of the server to benchmark, without a trailing slash.
  final String baseUrl;

  /// How hard to push.
  final BenchmarkConfig config;

  /// The built-in scenario names, in report order.
  static List<String> get scenarioNames => [
    for (final scenario in _scenarios) scenario.name,
  ];

  /// Runs the whole suite.
  ///
  /// [onProgress] fires before each scenario/client pair and once per completed
  /// iteration, so a UI can show both what is running and how far in it is. It
  /// can fire hundreds of times a second on a loopback run — coalesce on the
  /// receiving end rather than asking the harness to guess a rate.
  ///
  /// [onResult] fires once per scenario/client pair, the moment that pair
  /// finishes. A run takes minutes, and a progress bar cannot answer the
  /// question a reader actually has while waiting — which client is ahead — so
  /// the UI fills its table in as the pairs land rather than all at once at the
  /// end.
  ///
  /// [cancel] stops the run at the next iteration boundary. The report still
  /// comes back, carrying whatever was measured and marked
  /// [BenchmarkReport.cancelled] so nothing downstream can mistake it for a
  /// finished comparison.
  Future<BenchmarkReport> run({
    void Function(BenchmarkProgress)? onProgress,
    void Function(BenchmarkResult)? onResult,
    BenchmarkCancellation? cancel,
  }) async {
    final startedAt = DateTime.now();
    final overall = Stopwatch()..start();
    final results = <BenchmarkResult>[];
    final libraries = config.libraries;
    final stepCount = _scenarios.length * libraries.length;
    var step = 0;

    pairs:
    for (final (scenarioIndex, scenario) in _scenarios.indexed) {
      // ROTATED, not fixed. Iterating `libraries` in enum order every time makes
      // one client permanently first, and first is not a neutral position: it
      // absorbs whatever the previous scenario left behind. A 512-connection
      // burst leaves the loopback server draining and the OS holding sockets in
      // TIME_WAIT, and the next client to connect eats that recovery — which is
      // how a 256 MiB download came back `Connection refused` for the first
      // client while the other four, running seconds later, all succeeded.
      // Rotating by scenario index spreads that cost so no client is
      // systematically penalised, and makes the "who went first" question
      // disappear from every row rather than just the one that failed loudly.
      final ordered = <HttpLibrary>[
        for (var i = 0; i < libraries.length; i++)
          libraries[(i + scenarioIndex) % libraries.length],
      ];
      for (final library in ordered) {
        if (cancel != null && cancel.isCancelled) break pairs;
        step++;
        final total = scenario.plannedIterations(config);
        var completed = 0;
        void report() => onProgress?.call(
          BenchmarkProgress(
            scenario: scenario.name,
            library: library,
            completed: completed,
            total: total,
            step: step,
            stepCount: stepCount,
          ),
        );
        report();

        // Construction is inside the guard because it is itself a native call:
        // without the plugin's library loaded, `NitroHttpClient()` throws here
        // and the baseline columns must still be measured.
        // Let the previous pair's sockets drain before this one is measured.
        // Without it the loopback server can still be working through a burst's
        // backlog, and that shows up as latency — or a refused connection —
        // belonging to whoever is measured next rather than to whoever caused it.
        // Outside the stopwatch by construction: nothing here is timed.
        if (step > 1) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        _Subject? subject;
        try {
          subject = _subjectFor(library, baseUrl);
          await subject.warmup(config);
          final result = await scenario.run(
            subject,
            _Context(
              config: config,
              cancel: cancel,
              onIteration: () {
                completed++;
                report();
              },
            ),
          );
          results.add(result);
          onResult?.call(result);
        } on Object catch (error) {
          final failure = BenchmarkResult.failed(
            scenario: scenario.name,
            library: library,
            error: '$error',
          );
          results.add(failure);
          onResult?.call(failure);
        } finally {
          await subject?.close();
        }
      }
    }

    return BenchmarkReport(
      baseUrl: baseUrl,
      startedAt: startedAt,
      duration: overall.elapsed,
      config: config,
      results: results,
      cancelled: cancel != null && cancel.isCancelled,
    );
  }

  static _Subject _subjectFor(HttpLibrary library, String baseUrl) =>
      switch (library) {
        HttpLibrary.nitroHttp => _NitroSubject(baseUrl),
        HttpLibrary.dartIo => _DartIoSubject(baseUrl),
        HttpLibrary.packageHttp => _PackageHttpSubject(baseUrl),
        HttpLibrary.dio => _DioSubject(baseUrl),
        HttpLibrary.rhttp => _RhttpSubject(baseUrl),
      };

  static final List<_Scenario> _scenarios = [
    _Scenario('small GET', (BenchmarkConfig c) => c.iterations, _runSmallGet),
    _Scenario(
      'burst GET',
      (BenchmarkConfig c) => c.burstRequests * c.burstRepeats,
      _runBurst,
    ),
    _Scenario('download', (BenchmarkConfig c) => c.transferRepeats, _runDownload),
    _Scenario('upload', (BenchmarkConfig c) => c.transferRepeats, _runUpload),
    _Scenario('mixed', (BenchmarkConfig c) => c.mixedRequests, _runMixed),
  ];

  // ── Scenarios ──────────────────────────────────────────────────────────────

  /// The latency scenario: many small GETs, dispatched however the run asked.
  static Future<BenchmarkResult> _runSmallGet(
    _Subject subject,
    _Context ctx,
  ) async {
    final config = ctx.config;
    final path = '/bytes/${config.smallBodyBytes}';
    final wall = Stopwatch()..start();
    final samples = await runIterations<(Duration, int)>(
      count: config.iterations,
      mode: config.execution,
      concurrency: config.concurrency,
      cancel: ctx.cancel,
      onIteration: ctx.onIteration,
      body: (int _) async {
        final one = Stopwatch()..start();
        final received = await subject.getBytes(path);
        return (one.elapsed, received);
      },
    );
    return _fromSamples('small GET', subject, samples, wall.elapsed);
  }

  /// The queueing scenario, pinned to all-at-once whatever the run asked for.
  ///
  /// Deliberately not configurable: it is the fixed reference point that makes
  /// the configurable rows readable. Without one row whose dispatch never
  /// changes, two runs at different settings share no comparable number.
  static Future<BenchmarkResult> _runBurst(
    _Subject subject,
    _Context ctx,
  ) async {
    final config = ctx.config;
    final path = '/bytes/${config.smallBodyBytes}';

    // Prime the pool to burst width, discarded. `warmup` is serial, so without
    // this the first burst opens `burstRequests` - 1 connections while the
    // stopwatches are already running — see [BenchmarkConfig.burstRepeats].
    await Future.wait(<Future<int>>[
      for (var i = 0; i < config.burstRequests; i++) subject.getBytes(path),
    ]);

    final samples = <(Duration, int)>[];
    final wall = Stopwatch()..start();
    for (var repeat = 0; repeat < config.burstRepeats; repeat++) {
      if (ctx.cancel?.isCancelled ?? false) break;
      // One `runIterations` call per repeat, so the bursts stay separate: a
      // single call with count = requests × repeats would put every request of
      // every repeat in flight at once, which is a different scenario.
      samples.addAll(
        await runIterations<(Duration, int)>(
          count: config.burstRequests,
          mode: BenchmarkExecution.parallel,
          concurrency: config.burstRequests,
          cancel: ctx.cancel,
          onIteration: ctx.onIteration,
          body: (int _) async {
            final one = Stopwatch()..start();
            final received = await subject.getBytes(path);
            return (one.elapsed, received);
          },
        ),
      );
    }
    return _fromSamples('burst GET', subject, samples, wall.elapsed);
  }

  static Future<BenchmarkResult> _runDownload(
    _Subject subject,
    _Context ctx,
  ) async {
    final repeats = ctx.config.transferRepeats;
    final latencies = <Duration>[];
    final ttfbs = <Duration>[];
    var bytes = 0;

    final wall = Stopwatch()..start();
    for (var i = 0; i < repeats; i++) {
      final clock = Stopwatch()..start();
      final (received, ttfb) = await subject.download(
        '/bytes/${ctx.config.downloadBytes}',
      );
      latencies.add(clock.elapsed);
      ttfbs.add(ttfb);
      // Every repeat must move the same bytes; the reported total is one
      // transfer's worth so the MiB/s column stays comparable across configs.
      bytes = received;
      ctx.onIteration();
    }
    wall.stop();

    ttfbs.sort();
    return BenchmarkResult(
      scenario: 'download',
      library: subject.library,
      iterations: repeats,
      latencies: latencies,
      wallClock: wall.elapsed,
      bytes: bytes,
      timeToFirstByte: ttfbs[ttfbs.length ~/ 2],
    );
  }

  static Future<BenchmarkResult> _runUpload(
    _Subject subject,
    _Context ctx,
  ) async {
    final repeats = ctx.config.transferRepeats;
    final latencies = <Duration>[];
    var bytes = 0;

    final wall = Stopwatch()..start();
    for (var i = 0; i < repeats; i++) {
      final clock = Stopwatch()..start();
      bytes = await subject.upload('/upload', ctx.config.uploadBytes);
      latencies.add(clock.elapsed);
      ctx.onIteration();
    }
    wall.stop();

    return BenchmarkResult(
      scenario: 'upload',
      library: subject.library,
      iterations: repeats,
      latencies: latencies,
      wallClock: wall.elapsed,
      bytes: bytes,
    );
  }

  /// A deliberately ugly load: small GETs, a redirect chain, a slow endpoint and
  /// a 256 KiB download, dispatched however the run asked. Nothing in production
  /// is uniform.
  static Future<BenchmarkResult> _runMixed(
    _Subject subject,
    _Context ctx,
  ) async {
    final config = ctx.config;
    final wall = Stopwatch()..start();
    final samples = await runIterations<(Duration, int)>(
      count: config.mixedRequests,
      mode: config.execution,
      concurrency: config.concurrency,
      cancel: ctx.cancel,
      onIteration: ctx.onIteration,
      // Returns rather than accumulating into a captured variable: `bytes +=
      // await` reads before the suspension and writes after it, so overlapping
      // iterations lose each other's updates.
      body: (int i) async {
        final clock = Stopwatch()..start();
        final int transferred;
        switch (i % 4) {
          case 0:
            transferred = await subject.getBytes(
              '/bytes/${config.smallBodyBytes}',
            );
          case 1:
            transferred = await subject.getBytes('/redirect/2');
          case 2:
            transferred = await subject.getBytes('/slow/5');
          // Required: `i % 4` is an int, and the default also gives the analyzer
          // the definite assignment of `transferred`.
          default:
            final (downloaded, _) = await subject.download(
              '/bytes/${256 * 1024}',
            );
            transferred = downloaded;
        }
        return (clock.elapsed, transferred);
      },
    );
    // The `/redirect/2` hop lands on `/echo`, which reflects the request
    // headers back — so each client's own User-Agent ends up in the body and
    // the byte counts differ by a few hundred out of several megabytes. Header
    // noise, not payload, so the gate bounds the spread instead of demanding
    // that five clients agree on their product name.
    return _fromSamples(
      'mixed',
      subject,
      samples,
      wall.elapsed,
      bytesVaryByClient: true,
    );
  }

  static BenchmarkResult _fromSamples(
    String scenario,
    _Subject subject,
    List<(Duration, int)> samples,
    Duration wallClock, {
    bool bytesVaryByClient = false,
  }) => BenchmarkResult(
    scenario: scenario,
    library: subject.library,
    // The sample count, not the requested count: a cancelled scenario returns
    // fewer, and reporting the request would silently inflate req/s.
    iterations: samples.length,
    latencies: [for (final (latency, _) in samples) latency],
    wallClock: wallClock,
    bytes: samples.fold<int>(
      0,
      (int sum, (Duration, int) sample) => sum + sample.$2,
    ),
    bytesVaryByClient: bytesVaryByClient,
  );
}

/// What a scenario is allowed to know about the run it belongs to.
final class _Context {
  const _Context({
    required this.config,
    required this.cancel,
    required this.onIteration,
  });

  final BenchmarkConfig config;
  final BenchmarkCancellation? cancel;
  final void Function() onIteration;
}

/// A named scenario, how many iterations it plans, and the closure that measures
/// it.
final class _Scenario {
  const _Scenario(this.name, this._plan, this._run);

  final String name;
  final int Function(BenchmarkConfig) _plan;
  final Future<BenchmarkResult> Function(_Subject, _Context) _run;

  /// How many iterations this scenario will attempt, so progress has a
  /// denominator before the first request goes out.
  int plannedIterations(BenchmarkConfig config) => _plan(config);

  Future<BenchmarkResult> run(_Subject subject, _Context ctx) =>
      _run(subject, ctx);
}

/// The four operations every benchmarked client has to provide.
abstract interface class _Subject {
  HttpLibrary get library;

  /// Fetches [path] and returns the received body length.
  Future<int> getBytes(String path);

  /// Streams [path], returning the body length and the time to the first byte.
  Future<(int, Duration)> download(String path);

  /// Streams [byteCount] bytes to [path], returning the bytes sent.
  Future<int> upload(String path, int byteCount);

  /// Issues and discards `config.warmupRequests` small GETs.
  Future<void> warmup(BenchmarkConfig config);

  Future<void> close();
}

/// Shared warm-up so the three subjects cannot drift apart.
mixin _WarmupMixin implements _Subject {
  @override
  Future<void> warmup(BenchmarkConfig config) async {
    for (var i = 0; i < config.warmupRequests; i++) {
      await getBytes('/bytes/${config.smallBodyBytes}');
    }
  }
}

final class _NitroSubject with _WarmupMixin implements _Subject {
  _NitroSubject(String baseUrl)
    : _client = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: baseUrl,
          // Compression off: the payload is incompressible random bytes, so
          // gzip would only add CPU to both ends and skew the comparison.
          enableCompression: false,
          poolSettings: const PoolSettings(maxConnectionsPerHost: 64),
        ),
      );

  final NitroHttpClient _client;

  @override
  HttpLibrary get library => HttpLibrary.nitroHttp;

  @override
  Future<int> getBytes(String path) async {
    final res = await _client.requestBytes(HttpMethod.get, path);
    return res.bodyBytes.length;
  }

  @override
  Future<(int, Duration)> download(String path) async {
    final clock = Stopwatch()..start();
    final res = await _client.requestStream(HttpMethod.get, path);
    Duration? ttfb;
    var total = 0;
    await for (final chunk in res.body) {
      ttfb ??= clock.elapsed;
      total += chunk.length;
    }
    return (total, ttfb ?? clock.elapsed);
  }

  @override
  Future<int> upload(String path, int byteCount) async {
    await _client.post(
      path,
      body: HttpBody.stream(
        deterministicByteStream(byteCount),
        contentLength: byteCount,
        contentType: 'application/octet-stream',
      ),
    );
    return byteCount;
  }

  @override
  Future<void> close() async => _client.dispose();
}

final class _DartIoSubject with _WarmupMixin implements _Subject {
  _DartIoSubject(this.baseUrl)
    : _client = HttpClient()
        ..autoUncompress = false
        ..maxConnectionsPerHost = 64;

  final String baseUrl;
  final HttpClient _client;

  @override
  HttpLibrary get library => HttpLibrary.dartIo;

  @override
  Future<int> getBytes(String path) async {
    final request = await _client.getUrl(Uri.parse('$baseUrl$path'));
    final response = await request.close();
    return response.fold<int>(0, (sum, chunk) => sum + chunk.length);
  }

  @override
  Future<(int, Duration)> download(String path) async {
    final clock = Stopwatch()..start();
    final request = await _client.getUrl(Uri.parse('$baseUrl$path'));
    final response = await request.close();
    Duration? ttfb;
    var total = 0;
    await for (final chunk in response) {
      ttfb ??= clock.elapsed;
      total += chunk.length;
    }
    return (total, ttfb ?? clock.elapsed);
  }

  @override
  Future<int> upload(String path, int byteCount) async {
    final request = await _client.postUrl(Uri.parse('$baseUrl$path'));
    request.headers.contentType = ContentType('application', 'octet-stream');
    request.contentLength = byteCount;
    await request.addStream(deterministicByteStream(byteCount));
    final response = await request.close();
    await response.drain<void>();
    return byteCount;
  }

  @override
  Future<void> close() async => _client.close(force: true);
}

final class _PackageHttpSubject with _WarmupMixin implements _Subject {
  _PackageHttpSubject(this.baseUrl) : _client = http.Client();

  final String baseUrl;
  final http.Client _client;

  @override
  HttpLibrary get library => HttpLibrary.packageHttp;

  @override
  Future<int> getBytes(String path) async {
    final response = await _client.get(Uri.parse('$baseUrl$path'));
    return response.bodyBytes.length;
  }

  @override
  Future<(int, Duration)> download(String path) async {
    final clock = Stopwatch()..start();
    final response = await _client.send(
      http.Request('GET', Uri.parse('$baseUrl$path')),
    );
    Duration? ttfb;
    var total = 0;
    await for (final chunk in response.stream) {
      ttfb ??= clock.elapsed;
      total += chunk.length;
    }
    return (total, ttfb ?? clock.elapsed);
  }

  @override
  Future<int> upload(String path, int byteCount) async {
    final request = http.StreamedRequest('POST', Uri.parse('$baseUrl$path'))
      ..contentLength = byteCount
      ..headers['content-type'] = 'application/octet-stream';
    // `StreamedRequest` exposes a sink rather than accepting a stream, so the
    // pump has to run alongside `send` instead of before it.
    final pump = deterministicByteStream(byteCount)
        .forEach(request.sink.add)
        .whenComplete(request.sink.close);
    final response = await _client.send(request);
    await response.stream.drain<void>();
    await pump;
    return byteCount;
  }

  @override
  Future<void> close() async => _client.close();
}

final class _DioSubject with _WarmupMixin implements _Subject {
  _DioSubject(String baseUrl)
    : _dio = dio.Dio(
        dio.BaseOptions(
          baseUrl: baseUrl,
          // Match every other subject: hand back raw bytes and do not let dio
          // spend time turning them into a String or JSON.
          responseType: dio.ResponseType.bytes,
          // dio throws on a non-2xx by default; the fixture only ever answers
          // 200, but an exception on a slow-CI hiccup would abort a whole run.
          validateStatus: (_) => true,
        ),
      );

  final dio.Dio _dio;

  @override
  HttpLibrary get library => HttpLibrary.dio;

  @override
  Future<int> getBytes(String path) async {
    final response = await _dio.get<List<int>>(path);
    return response.data?.length ?? 0;
  }

  @override
  Future<(int, Duration)> download(String path) async {
    final clock = Stopwatch()..start();
    final response = await _dio.get<dio.ResponseBody>(
      path,
      options: dio.Options(responseType: dio.ResponseType.stream),
    );
    Duration? ttfb;
    var total = 0;
    await for (final chunk in response.data!.stream) {
      ttfb ??= clock.elapsed;
      total += chunk.length;
    }
    return (total, ttfb ?? clock.elapsed);
  }

  @override
  Future<int> upload(String path, int byteCount) async {
    await _dio.post<void>(
      path,
      data: deterministicByteStream(byteCount),
      options: dio.Options(
        contentType: 'application/octet-stream',
        headers: <String, Object>{dio.Headers.contentLengthHeader: byteCount},
      ),
    );
    return byteCount;
  }

  @override
  Future<void> close() async => _dio.close(force: true);
}

final class _RhttpSubject implements _Subject {
  _RhttpSubject(this.baseUrl);

  final String baseUrl;
  rhttp.RhttpClient? _client;

  rhttp.RhttpClient get _c => _client!;

  @override
  HttpLibrary get library => HttpLibrary.rhttp;

  /// `RhttpClient.create` is async and `Rhttp.init()` must run once before it,
  /// which the sync subject factory cannot express — so construction happens
  /// here, inside the warm-up that every subject runs first anyway. The clients
  /// it builds are therefore created outside the measured window, exactly like
  /// the others.
  /// `Rhttp.init()` installs the flutter_rust_bridge runtime and throws
  /// "Should not initialize flutter_rust_bridge twice" on a second call. The
  /// runner builds a fresh subject per scenario, so the guard has to be static.
  static bool _bridgeReady = false;

  @override
  Future<void> warmup(BenchmarkConfig config) async {
    if (!_bridgeReady) {
      await rhttp.Rhttp.init();
      _bridgeReady = true;
    }
    _client = await rhttp.RhttpClient.create(
      settings: rhttp.ClientSettings(
        baseUrl: baseUrl,
        // Parity with the other subjects: no status-code exceptions, and no
        // implicit compression of incompressible random bytes.
        throwOnStatusCode: false,
        httpVersionPref: rhttp.HttpVersionPref.http1_1,
      ),
    );
    for (var i = 0; i < config.warmupRequests; i++) {
      await getBytes('/bytes/${config.smallBodyBytes}');
    }
  }

  @override
  Future<int> getBytes(String path) async {
    final response = await _c.getBytes(path);
    return response.body.length;
  }

  @override
  Future<(int, Duration)> download(String path) async {
    final clock = Stopwatch()..start();
    final response = await _c.getStream(path);
    Duration? ttfb;
    var total = 0;
    await for (final chunk in response.body) {
      ttfb ??= clock.elapsed;
      total += chunk.length;
    }
    return (total, ttfb ?? clock.elapsed);
  }

  @override
  Future<int> upload(String path, int byteCount) async {
    await _c.post(
      path,
      body: rhttp.HttpBody.stream(
        deterministicByteStream(byteCount),
        length: byteCount,
      ),
      headers: const rhttp.HttpHeaders.rawMap(<String, String>{
        'content-type': 'application/octet-stream',
      }),
    );
    return byteCount;
  }

  @override
  Future<void> close() async => _client?.dispose();
}

String _ms(Duration d) => '${(d.inMicroseconds / 1000).toStringAsFixed(2)} ms';

String _seconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

String _mib(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB ($bytes B)';

/// Keeps a multi-line engine error from breaking the Markdown table.
String _escapeCell(String value) {
  final oneLine = const LineSplitter().convert(value).join(' ').replaceAll('|', '\\|');
  return oneLine.length <= 80 ? oneLine : '${oneLine.substring(0, 77)}...';
}
