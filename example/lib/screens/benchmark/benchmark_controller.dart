/// The benchmark screen's state: every knob, the live progress of a run, and the
/// orchestration that turns the two into a report.
///
/// Separated from the widgets because a run is a minutes-long async process with
/// a cancel path and a progress feed, and none of that wants to live inside a
/// `build`. The widgets read signals; this decides what goes in them.
library;

import 'dart:async';

import 'package:signals_flutter/signals_flutter.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/execution.dart';
import '../../benchmark/spec_benchmark.dart';
import '../../core/app_state.dart';
import '../../core/http_library.dart';
import '../../core/request_spec.dart';

/// An inclusive integer range a control may produce, with the reason it stops
/// where it does.
///
/// The reason is not decoration: a slider that silently refuses to go past 5000
/// looks broken, and a slider that lets you ask for 0 iterations produces a table
/// of zeroes that looks like a bug in the library rather than in the request.
final class Bounds {
  /// Creates a range from [min] to [max] inclusive, explained by [why].
  const Bounds(this.min, this.max, {required this.why});

  /// Smallest accepted value.
  final int min;

  /// Largest accepted value.
  final int max;

  /// Why the range ends where it does, shown next to the control.
  final String why;

  /// [value] forced into range.
  int clamp(int value) => value < min ? min : (value > max ? max : value);
}

/// Every bound the setup panel enforces.
///
/// Collected in one place so the reason a number is capped is reviewable without
/// reading five widgets.
abstract final class BenchmarkBounds {
  /// Discarded requests issued before the measured ones.
  static const warmup = Bounds(
    0,
    200,
    why: 'Discarded before measuring. Zero measures a cold connection pool, '
        'which is a different question from steady-state latency.',
  );

  /// Iterations of the small-GET and console-request scenarios.
  static const iterations = Bounds(
    1,
    5000,
    why: 'p95 needs roughly 100 samples and p99 roughly 1000 before it stops '
        'being a synonym for "the slowest one".',
  );

  /// Requests the burst scenario puts in flight at once.
  static const burst = Bounds(
    1,
    512,
    why: 'All dispatched simultaneously, so this is also how deep the client '
        'connection pool gets pushed.',
  );

  /// The in-flight cap for concurrent dispatch.
  static const concurrency = Bounds(
    1,
    256,
    why: 'Only applies to concurrent execution. Above the server\'s own '
        'accept backlog you are measuring the fixture, not the client.',
  );

  /// Iterations of the mixed scenario.
  static const mixed = Bounds(
    1,
    2000,
    why: 'Every fourth iteration downloads 256 KiB, so this one costs more '
        'wall clock per iteration than it looks.',
  );

  /// Streamed download size, in mebibytes.
  static const downloadMiB = Bounds(
    1,
    256,
    why: 'One streamed response. Large enough to measure throughput rather '
        'than handshake, small enough not to page out a phone.',
  );

  /// Streamed upload size, in mebibytes.
  static const uploadMiB = Bounds(
    1,
    128,
    why: 'One streamed request body, generated on the fly rather than held in '
        'the heap.',
  );
}

/// Owns the benchmark screen's signals and runs the benchmark.
///
/// Screen-scoped, so every signal here is disposed in [dispose] — `autoDispose`
/// is off by default in signals 7 and these would otherwise outlive the screen.
final class BenchmarkController {
  /// Creates a controller with the interactive defaults.
  ///
  /// The defaults are deliberately the quick profile rather than the design
  /// document's: a first press should produce a table in seconds, and anybody
  /// who wants the hundred-megabyte run can say so.
  BenchmarkController();

  /// Discarded requests per client, per scenario.
  final warmup = signal<int>(
    10,
    options: const SignalOptions(name: 'bench.warmup'),
  );

  /// Iterations of the small-GET and console-request scenarios.
  final iterations = signal<int>(
    200,
    options: const SignalOptions(name: 'bench.iterations'),
  );

  /// Requests in flight at once in the burst scenario.
  final burst = signal<int>(
    32,
    options: const SignalOptions(name: 'bench.burst'),
  );

  /// In-flight cap for [BenchmarkExecution.concurrent].
  final concurrency = signal<int>(
    16,
    options: const SignalOptions(name: 'bench.concurrency'),
  );

  /// Iterations of the mixed scenario.
  final mixed = signal<int>(
    40,
    options: const SignalOptions(name: 'bench.mixed'),
  );

  /// Streamed download size, in mebibytes.
  final downloadMiB = signal<int>(
    8,
    options: const SignalOptions(name: 'bench.downloadMiB'),
  );

  /// Streamed upload size, in mebibytes.
  final uploadMiB = signal<int>(
    1,
    options: const SignalOptions(name: 'bench.uploadMiB'),
  );

  /// How the iteration-based scenarios dispatch.
  final execution = signal<BenchmarkExecution>(
    BenchmarkExecution.serial,
    options: const SignalOptions(name: 'bench.execution'),
  );

  /// Which clients take part, kept in enum order so the report is stable.
  ///
  /// A `listSignal` because it notifies on in-place mutation; reassigning an
  /// equal list would not, since collection signals compare deeply.
  final libraries = listSignal<HttpLibrary>(
    <HttpLibrary>[...HttpLibrary.values],
    options: const ListSignalOptions(name: 'bench.libraries'),
  );

  /// Whether the console's current request is measured as a sixth scenario.
  final includeConsoleRequest = signal<bool>(
    false,
    options: const SignalOptions(name: 'bench.includeConsoleRequest'),
  );

  /// Whether a run is in flight.
  final running = signal<bool>(
    false,
    options: const SignalOptions(name: 'bench.running'),
  );

  /// Whether a stop has been asked for but the run has not unwound yet.
  ///
  /// Worth its own flag: cancellation lands at the next iteration boundary, so
  /// pressing Cancel during a hundred-megabyte download does nothing visible
  /// until that transfer finishes. A button that stays labelled "Cancel" after
  /// being pressed reads as a button that did not work.
  final stopping = signal<bool>(
    false,
    options: const SignalOptions(name: 'bench.stopping'),
  );

  /// What is executing right now, or null when idle.
  final progress = signal<BenchmarkProgress?>(
    null,
    options: const SignalOptions(name: 'bench.progress'),
  );

  /// Pairs that have finished so far, in completion order.
  ///
  /// A run takes minutes and the full report only exists at the end, so without
  /// this the screen can only show a bar. The question a reader actually has
  /// while waiting is which client is ahead, and that is answerable the moment
  /// each pair lands.
  final liveResults = signal<List<BenchmarkResult>>(
    const <BenchmarkResult>[],
    options: const SignalOptions(name: 'bench.liveResults'),
  );

  /// Estimated time left, or null before there is enough to extrapolate from.
  ///
  /// Derived from completed steps rather than iterations: a download step and a
  /// small-GET step are wildly different sizes, so iteration counts do not
  /// extrapolate, and even steps only settle once a few have landed.
  final remaining = signal<Duration?>(
    null,
    options: const SignalOptions(name: 'bench.remaining'),
  );

  /// Overall completion in `0..1`, across the built-in and console scenarios.
  final overall = signal<double>(
    0,
    options: const SignalOptions(name: 'bench.overall'),
  );

  /// Wall clock of the current or most recent run.
  final elapsed = signal<Duration>(
    Duration.zero,
    options: const SignalOptions(name: 'bench.elapsed'),
  );

  /// The most recent report, or null before the first run.
  final report = signal<BenchmarkReport?>(
    null,
    options: const SignalOptions(name: 'bench.report'),
  );

  /// A run that could not start or died outside a scenario's own guard.
  final error = signal<String?>(
    null,
    options: const SignalOptions(name: 'bench.error'),
  );

  BenchmarkCancellation? _cancellation;
  Timer? _ticker;
  final Stopwatch _throttle = Stopwatch()..start();
  int _lastPushMs = 0;

  /// Whether the current selection can produce a run.
  ///
  /// Reads `libraries.value` rather than `libraries.isNotEmpty` so the
  /// dependency is unambiguous to whichever `SignalBuilder` asks.
  bool get canRun =>
      !running.value && baseUrl.value.isNotEmpty && libraries.value.isNotEmpty;

  /// Toggles [library] in the selection, refusing to empty it.
  ///
  /// A run with no clients is not a smaller run, it is a blank table — so the
  /// last chip simply does not turn off.
  void toggleLibrary(HttpLibrary library) {
    if (libraries.contains(library)) {
      if (libraries.length == 1) return;
      libraries.remove(library);
      return;
    }
    libraries
      ..add(library)
      // Enum order, so the report columns do not reorder themselves depending
      // on which chip was pressed last.
      ..sort((HttpLibrary a, HttpLibrary b) => a.index.compareTo(b.index));
  }

  /// The configuration the next run would use.
  BenchmarkConfig buildConfig() => BenchmarkConfig(
    warmupRequests: BenchmarkBounds.warmup.clamp(warmup.value),
    iterations: BenchmarkBounds.iterations.clamp(iterations.value),
    burstRequests: BenchmarkBounds.burst.clamp(burst.value),
    mixedRequests: BenchmarkBounds.mixed.clamp(mixed.value),
    downloadBytes:
        BenchmarkBounds.downloadMiB.clamp(downloadMiB.value) * 1024 * 1024,
    uploadBytes: BenchmarkBounds.uploadMiB.clamp(uploadMiB.value) * 1024 * 1024,
    execution: execution.value,
    concurrency: BenchmarkBounds.concurrency.clamp(concurrency.value),
    libraries: List<HttpLibrary>.unmodifiable(libraries.value),
  );

  /// Asks the current run to stop at the next iteration boundary.
  ///
  /// An iteration already on the wire is allowed to finish: aborting it would
  /// leave a half-read socket and a byte count that means nothing.
  void cancel() {
    if (_cancellation == null) return;
    _cancellation?.cancel();
    stopping.value = true;
  }

  /// Runs the built-in suite, then the console request when it is included.
  Future<void> start() async {
    if (running.value) return;
    final base = baseUrl.value;
    if (base.isEmpty) {
      error.value = 'The demo server is not up yet.';
      return;
    }

    final config = buildConfig();
    final spec = includeConsoleRequest.value ? requestDraft.spec.value : null;
    if (spec != null && !spec.isSendable(baseUrl: base)) {
      error.value =
          'The console request is not sendable: check its method and URL.';
      return;
    }

    final cancellation = BenchmarkCancellation();
    _cancellation = cancellation;
    batch(() {
      running.value = true;
      stopping.value = false;
      error.value = null;
      report.value = null;
      progress.value = null;
      overall.value = 0;
      elapsed.value = Duration.zero;
      liveResults.value = const <BenchmarkResult>[];
      remaining.value = null;
    });

    final startedAt = DateTime.now();
    final clock = Stopwatch()..start();
    // The elapsed readout is a clock, not a progress event: driving it from the
    // iteration feed would make it stutter on a slow scenario and freeze
    // entirely during a hundred-megabyte download.
    _ticker = Timer.periodic(
      const Duration(milliseconds: 200),
      (Timer _) => elapsed.value = clock.elapsed,
    );

    try {
      final builtinSteps =
          BenchmarkRunner.scenarioNames.length * config.libraries.length;
      final totalSteps =
          builtinSteps + (spec == null ? 0 : config.libraries.length);
      final results = <BenchmarkResult>[];

      final builtin = await BenchmarkRunner(baseUrl: base, config: config).run(
        cancel: cancellation,
        onProgress: (BenchmarkProgress p) => _push(p, 0, totalSteps),
        onResult: (BenchmarkResult r) => _pushResult(r, clock, totalSteps),
      );
      results.addAll(builtin.results);

      if (spec != null && !cancellation.isCancelled) {
        results.addAll(
          await runSpecBenchmark(
            spec: spec,
            baseUrl: base,
            config: config,
            cancel: cancellation,
            onProgress: (BenchmarkProgress p) =>
                _push(p, builtinSteps, totalSteps),
            onResult: (BenchmarkResult r) =>
                _pushResult(r, clock, totalSteps),
          ),
        );
      }

      report.value = BenchmarkReport(
        baseUrl: base,
        startedAt: startedAt,
        duration: clock.elapsed,
        config: config,
        results: results,
        cancelled: cancellation.isCancelled,
        notes: <String>[
          if (spec != null) consoleScenarioNote(spec, config),
        ],
      );
    } on Object catch (failure) {
      error.value = '$failure';
    } finally {
      _ticker?.cancel();
      _ticker = null;
      _cancellation = null;
      batch(() {
        running.value = false;
        stopping.value = false;
        elapsed.value = clock.elapsed;
        progress.value = null;
        overall.value = 1;
      });
    }
  }

  /// Publishes a progress sample, at most sixteen times a second.
  ///
  /// A loopback run finishes several hundred iterations a second and each one
  /// Publishes a finished pair and re-estimates the time left.
  ///
  /// Cheap and unthrottled, unlike [_push]: this fires once per scenario/client
  /// pair — a couple of dozen times across a whole run — not once per iteration.
  void _pushResult(BenchmarkResult result, Stopwatch clock, int totalSteps) {
    final next = <BenchmarkResult>[...liveResults.value, result];
    liveResults.value = next;

    // Extrapolate from completed steps. Only after two, because the first pair
    // carries the run's start-up cost and would badly over-estimate the rest.
    final done = next.length;
    if (done >= 2 && done < totalSteps) {
      final perStep = clock.elapsed.inMilliseconds / done;
      remaining.value =
          Duration(milliseconds: (perStep * (totalSteps - done)).round());
    } else if (done >= totalSteps) {
      remaining.value = Duration.zero;
    }
  }

  /// fires this. Writing every sample would queue more rebuilds than the display
  /// can retire — so samples are dropped on time, except when the scenario or
  /// client changes, which is the one update a reader will actually notice
  /// missing.
  void _push(BenchmarkProgress sample, int stepOffset, int totalSteps) {
    final current = progress.value;
    final movedOn =
        current == null ||
        current.scenario != sample.scenario ||
        current.library != sample.library;
    final now = _throttle.elapsedMilliseconds;
    if (!movedOn && now - _lastPushMs < 60) return;
    _lastPushMs = now;

    final within = sample.total <= 0
        ? 0.0
        : (sample.completed / sample.total).clamp(0.0, 1.0);
    final fraction = totalSteps <= 0
        ? 0.0
        : ((stepOffset + sample.step - 1 + within) / totalSteps).clamp(
            0.0,
            1.0,
          );

    // One batch, so a progress tick is one rebuild of the progress strip rather
    // than two.
    batch(() {
      progress.value = sample;
      overall.value = fraction;
    });
  }

  /// Releases every signal and stops the clock.
  void dispose() {
    _ticker?.cancel();
    _cancellation?.cancel();
    warmup.dispose();
    iterations.dispose();
    burst.dispose();
    concurrency.dispose();
    mixed.dispose();
    downloadMiB.dispose();
    uploadMiB.dispose();
    execution.dispose();
    libraries.dispose();
    includeConsoleRequest.dispose();
    running.dispose();
    stopping.dispose();
    progress.dispose();
    overall.dispose();
    elapsed.dispose();
    report.dispose();
    error.dispose();
  }
}

/// A one-line summary of [spec], for the console-request toggle's subtitle.
String describeSpec(RequestSpec spec) {
  final url = spec.url.trim();
  return '${spec.method.toUpperCase()} ${url.isEmpty ? '(no URL)' : url}';
}
