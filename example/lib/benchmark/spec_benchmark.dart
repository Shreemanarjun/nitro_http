/// Benchmarks an arbitrary [RequestSpec] — the request the console is currently
/// holding — across every selected client.
///
/// The built-in scenarios in `benchmark.dart` are five fixed shapes tuned for
/// throughput, each written directly against its client's lowest-overhead API.
/// This one goes through the shared [HttpSender] seam instead, which costs a
/// little uniform overhead on every row and buys the thing the fixed scenarios
/// cannot give: *any* request the console can build becomes a measurable
/// scenario. A `PROPFIND` with three headers and a multipart body is one press
/// away from a five-client comparison.
///
/// It lives beside the harness rather than inside it because reaching the
/// registry means reaching `core/`, which imports `package:flutter/foundation`.
/// Keeping that import out of `benchmark.dart` is what lets the fixed scenarios
/// keep running on a plain test host.
library;

import 'dart:async';

import '../core/http_sender.dart';
import '../core/request_spec.dart';
import '../core/sent_response.dart';
import '../core/senders/sender_registry.dart';
import 'benchmark.dart';
import 'execution.dart';

/// The scenario name a console-authored request is reported under.
const String consoleScenario = 'console request';

/// A one-line description of the console scenario, for the report preamble.
///
/// The table row only says `console request`, which on its own tells a reader
/// nothing about what was measured; this is what makes the report readable a
/// week later.
String consoleScenarioNote(RequestSpec spec, BenchmarkConfig config) {
  final body = spec.bodyKind == RequestBodyKind.none
      ? 'no body'
      : '${spec.bodyKind.label} body';
  return '$consoleScenario: ${config.iterations} × '
      '${spec.method.toUpperCase()} ${spec.url} '
      '($body, ${spec.responseMode.label.toLowerCase()} response)';
}

/// One measured send.
final class _Sample {
  const _Sample(this.latency, this.bytes, this.firstByte);

  final Duration latency;
  final int bytes;
  final Duration? firstByte;
}

/// Measures [spec] against every client in [config], one [BenchmarkResult] each.
///
/// Never throws and never aborts a later client because an earlier one failed:
/// a client that cannot issue this request gets a failed row carrying its own
/// error text, which for the two native engines on a machine with nothing built
/// is the normal, expected outcome.
///
/// [onProgress] reports `step` as `1..config.libraries.length`; a caller running
/// this after the built-in suite is responsible for offsetting it into whatever
/// overall progress it is showing.
/// A result list that notifies as it grows.
///
/// A thin wrapper rather than editing every `results.add` call site: the adds are
/// scattered across the probe, failure and success paths, and missing one would
/// mean a pair that never appears in the live table.
class _Publishing {
  _Publishing(this._onResult);

  final void Function(BenchmarkResult)? _onResult;
  final List<BenchmarkResult> _items = <BenchmarkResult>[];

  void add(BenchmarkResult result) {
    _items.add(result);
    _onResult?.call(result);
  }

  List<BenchmarkResult> toList() => _items;
}

Future<List<BenchmarkResult>> runSpecBenchmark({
  required RequestSpec spec,
  required String baseUrl,
  required BenchmarkConfig config,
  void Function(BenchmarkProgress)? onProgress,
  void Function(BenchmarkResult)? onResult,
  BenchmarkCancellation? cancel,
}) async {
  // Mirrors `BenchmarkRunner.run`: every append is also published so the screen
  // can fill its table in as pairs land rather than only at the end.
  final results = _Publishing(onResult);
  final stepCount = config.libraries.length;
  var step = 0;

  for (final library in config.libraries) {
    if (cancel != null && cancel.isCancelled) break;
    step++;
    var completed = 0;
    void report() => onProgress?.call(
      BenchmarkProgress(
        scenario: consoleScenario,
        library: library,
        completed: completed,
        total: config.iterations,
        step: step,
        stepCount: stepCount,
      ),
    );
    report();

    HttpSender? opened;
    try {
      final sender = createSender(library);
      opened = sender;

      // At least one discarded send, whatever the warm-up count says. It is not
      // only warm-up: it is the probe that decides whether this client can issue
      // this request at all, which is what keeps an "unsupported" answer out of
      // the measured samples instead of averaged into them.
      final probes = config.warmupRequests < 1 ? 1 : config.warmupRequests;
      final rejection = await _probe(sender, spec, baseUrl, probes, cancel);
      if (rejection != null) {
        results.add(
          BenchmarkResult.failed(
            scenario: consoleScenario,
            library: library,
            error: rejection,
          ),
        );
        continue;
      }

      final measured = sender;
      SendFailure? firstFailure;
      final wall = Stopwatch()..start();
      final samples = await runIterations<_Sample>(
        count: config.iterations,
        mode: config.execution,
        concurrency: config.concurrency,
        cancel: cancel,
        onIteration: () {
          completed++;
          report();
        },
        body: (int _) async {
          final clock = Stopwatch()..start();
          final outcome = await measured.send(spec, baseUrl: baseUrl);
          final elapsed = clock.elapsed;
          switch (outcome) {
            case SentResponse():
              return _Sample(
                elapsed,
                outcome.byteCount,
                outcome.timings.firstByte,
              );
            case FailedSend():
              firstFailure ??= outcome.failure;
              return _Sample(elapsed, 0, null);
          }
        },
      );
      final elapsed = wall.elapsed;

      // Read once into a local: `firstFailure` is written inside the closure
      // above, so the analyzer cannot promote the field itself.
      final failure = firstFailure;
      if (failure != null) {
        results.add(
          BenchmarkResult.failed(
            scenario: consoleScenario,
            library: library,
            error: '${failure.kind.label}: ${failure.message}',
          ),
        );
        continue;
      }

      results.add(
        BenchmarkResult(
          scenario: consoleScenario,
          library: library,
          iterations: samples.length,
          latencies: [for (final sample in samples) sample.latency],
          wallClock: elapsed,
          bytes: samples.fold<int>(
            0,
            (int sum, _Sample sample) => sum + sample.bytes,
          ),
          timeToFirstByte: _medianFirstByte(samples),
          // An arbitrary request is very often `/echo`, which reflects the
          // request headers back — and every client sends its own User-Agent. The
          // consistency gate therefore bounds the spread instead of demanding
          // that five clients agree on their product name.
          bytesVaryByClient: true,
        ),
      );
    } on Object catch (error) {
      // `HttpSender.send` is contractually non-throwing, but `createSender` is
      // not, and a benchmark row is a much better place to learn that than a
      // crashed screen.
      results.add(
        BenchmarkResult.failed(
          scenario: consoleScenario,
          library: library,
          error: '$error',
        ),
      );
    } finally {
      await opened?.close();
    }
  }

  return results.toList();
}

/// Issues [count] discarded sends, returning the first refusal or null.
Future<String?> _probe(
  HttpSender sender,
  RequestSpec spec,
  String baseUrl,
  int count,
  BenchmarkCancellation? cancel,
) async {
  for (var i = 0; i < count; i++) {
    if (cancel != null && cancel.isCancelled) return null;
    final outcome = await sender.send(spec, baseUrl: baseUrl);
    switch (outcome) {
      case SentResponse():
        continue;
      case FailedSend():
        return '${outcome.failure.kind.label}: ${outcome.failure.message}';
    }
  }
  return null;
}

/// The median of whichever samples reported a first byte, or null when none did.
///
/// Median rather than mean: only `nitro_http` reports this phase today, and a
/// single scheduling hiccup in a thousand samples should not move the number a
/// reader compares across runs.
Duration? _medianFirstByte(List<_Sample> samples) {
  final reported = <Duration>[
    for (final sample in samples) ?sample.firstByte,
  ]..sort();
  if (reported.isEmpty) return null;
  return reported[(reported.length - 1) ~/ 2];
}
