/// How a scenario's iterations are dispatched, and the plumbing that reports and
/// stops a run in progress.
///
/// Pure Dart — no Flutter import — so the harness in `benchmark.dart` stays
/// runnable from a test host as well as from the UI.
library;

import 'dart:async';

import '../core/http_library.dart';

/// How the iterations of one scenario are issued.
///
/// ## All three are single-isolate async concurrency
///
/// This is worth being blunt about, because the words are borrowed from a world
/// that has threads. Dart runs this benchmark on one isolate, so [concurrent]
/// and [parallel] do not add a second Dart thread and cannot make Dart-side work
/// — building a request, decoding a body, running a `dio` interceptor — overlap.
/// Real Dart parallelism would mean isolates, and isolates cannot share an
/// `HttpClient`, a `Dio` or a `NitroHttpClient`, so a per-isolate benchmark would
/// be measuring five separate connection pools rather than five clients.
///
/// What the modes actually change is how many requests are *in flight* while the
/// event loop pumps them. That is not a technicality: underneath the event loop,
/// `nitro_http` runs libcurl on its own native threads and `rhttp` runs
/// `reqwest`'s Tokio pool on its own, so overlapped requests really do execute on
/// several OS threads for those two — while `dart:io`, `package:http` and `dio`
/// interleave on the one Dart thread and its socket I/O. Measuring that
/// difference is precisely the point of the [concurrent] row: it is the only
/// place where "the engine has real threads" shows up as a number.
enum BenchmarkExecution {
  /// One request at a time; iteration `n + 1` starts after `n` completes.
  ///
  /// The cleanest latency measurement, because no iteration is ever queued
  /// behind another one.
  serial('Serial', 'One request at a time — the cleanest per-request latency.'),

  /// At most `concurrency` requests in flight, refilled as each completes.
  ///
  /// The realistic shape of an app under load, and the mode where a client's
  /// connection pool and its threading model start to matter.
  concurrent(
    'Concurrent',
    'A fixed number in flight, refilled as each completes.',
  ),

  /// Every iteration dispatched at once, then awaited together.
  ///
  /// A deliberate stress test: it lets the client's own queueing dominate, which
  /// is how pool limits and head-of-line blocking become visible.
  parallel('Parallel', 'Everything dispatched at once — a queueing stress test.');

  const BenchmarkExecution(this.label, this.description);

  /// Human-readable name for pickers and report preambles.
  final String label;

  /// One line explaining what this mode measures, shown under the picker.
  final String description;
}

/// A cooperative stop flag shared by a run and whatever wants to end it.
///
/// A plain flag rather than a `Future`, because the dispatch loops need to make
/// the decision *synchronously* between iterations: a future's completion is only
/// observable after an `await`, by which point another thousand requests may
/// already be on the wire.
final class BenchmarkCancellation {
  /// Creates a live token.
  BenchmarkCancellation();

  bool _cancelled = false;

  /// Whether a stop has been requested.
  bool get isCancelled => _cancelled;

  /// Requests a stop. Idempotent.
  ///
  /// Iterations already in flight are allowed to finish — aborting them would
  /// leave half-read sockets and byte counts that mean nothing.
  void cancel() => _cancelled = true;
}

/// What a run is doing right now.
///
/// Carries the numbers a progress display needs rather than a pre-formatted
/// string, so the UI can render a bar and the release runner can render a log
/// line from the same event.
final class BenchmarkProgress {
  /// Creates a progress sample.
  const BenchmarkProgress({
    required this.scenario,
    required this.library,
    required this.completed,
    required this.total,
    required this.step,
    required this.stepCount,
  });

  /// The scenario in flight.
  final String scenario;

  /// The client in flight.
  final HttpLibrary library;

  /// Iterations of this scenario finished so far.
  final int completed;

  /// Iterations this scenario plans to run, or 0 when it is a single transfer
  /// whose progress is not counted in requests.
  final int total;

  /// How many scenario/client pairs have been started, one-based.
  final int step;

  /// How many scenario/client pairs the run will do in total.
  final int stepCount;

  /// Overall completion in `0..1`, counting a partially finished pair.
  double get fraction {
    if (stepCount <= 0) return 0;
    final within = total <= 0 ? 0.0 : (completed / total).clamp(0.0, 1.0);
    return (((step - 1) + within) / stepCount).clamp(0.0, 1.0);
  }

  /// A single log line, for callers with nowhere to draw a bar.
  String get message => total <= 0
      ? '$scenario — ${library.label}'
      : '$scenario — ${library.label} ($completed/$total)';
}

/// Runs [count] iterations of [body] under [mode] and returns their results.
///
/// [onIteration] fires once per completed iteration, so a UI can count without
/// the body knowing anything about the UI. [cancel] is checked before each
/// iteration starts; the returned list is then short, which is what tells the
/// caller the run was cut off rather than measured.
Future<List<T>> runIterations<T extends Object>({
  required int count,
  required BenchmarkExecution mode,
  required int concurrency,
  required Future<T> Function(int index) body,
  BenchmarkCancellation? cancel,
  void Function()? onIteration,
}) async {
  if (count <= 0) return <T>[];
  switch (mode) {
    case BenchmarkExecution.serial:
      final results = <T>[];
      for (var i = 0; i < count; i++) {
        if (cancel != null && cancel.isCancelled) break;
        results.add(await body(i));
        onIteration?.call();
      }
      return results;

    case BenchmarkExecution.parallel:
      if (cancel != null && cancel.isCancelled) return <T>[];
      // Every future is created before the first await, which is what makes this
      // "all at once" rather than a very fast serial loop.
      return Future.wait<T>([
        for (var i = 0; i < count; i++)
          body(i).then((T value) {
            onIteration?.call();
            return value;
          }),
      ]);

    case BenchmarkExecution.concurrent:
      // Slots rather than an accumulating list: workers finish out of order and
      // `list.add` after an await would interleave unpredictably.
      final slots = List<T?>.filled(count, null);
      var next = 0;
      Future<void> worker() async {
        while (true) {
          if (cancel != null && cancel.isCancelled) return;
          // Claim-then-check, all synchronous, so two workers can never take the
          // same index across the await below.
          final index = next++;
          if (index >= count) return;
          slots[index] = await body(index);
          onIteration?.call();
        }
      }

      final workers = concurrency < count ? concurrency : count;
      await Future.wait<void>([for (var w = 0; w < workers; w++) worker()]);
      return <T>[
        for (final slot in slots) ?slot,
      ];
  }
}
