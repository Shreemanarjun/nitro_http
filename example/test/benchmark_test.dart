/// Host-VM proof that the benchmark harness measures what it claims to.
///
/// Two halves. The first pins the dispatch semantics of [BenchmarkExecution],
/// which is pure scheduling and needs no server: "at most N in flight" is a
/// promise the UI makes on every run, and the only way it can be broken is
/// silently. The second runs the real harness against the local server.
///
/// The `nitro_http` and `rhttp` rows need a native library and are expected to
/// carry an error here; the three pure-Dart baselines are real measurements
/// against the local server, so a bug in the accounting — a lost update, a zeroed
/// byte count, a p95 below the p50 — fails this test rather than shipping a
/// plausible-looking table.
///
/// Deliberately *not* in the same file as a `testWidgets` case:
/// `TestWidgetsFlutterBinding` installs an `HttpOverrides` that answers every
/// `HttpClient` request with a 400, which would break both baselines.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http_example/benchmark/benchmark.dart';
import 'package:nitro_http_example/benchmark/execution.dart';
import 'package:nitro_http_example/benchmark/spec_benchmark.dart';
import 'package:nitro_http_example/core/http_library.dart';
import 'package:nitro_http_example/core/request_spec.dart';
import 'package:nitro_http_example/server/local_server.dart';

/// Runs [count] iterations under [mode], returning the peak overlap observed and
/// the indices that completed, in completion-list order.
Future<({int peakInFlight, List<int> completed})> _dispatch({
  required int count,
  required BenchmarkExecution mode,
  required int concurrency,
  BenchmarkCancellation? cancel,
  void Function(int index)? onBody,
}) async {
  var inFlight = 0;
  var peak = 0;
  final completed = await runIterations<int>(
    count: count,
    mode: mode,
    concurrency: concurrency,
    cancel: cancel,
    body: (int index) async {
      inFlight++;
      if (inFlight > peak) peak = inFlight;
      // Two hops, so a mode that only *looks* overlapped because everything
      // resolves in one microtask cannot pass by accident.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      onBody?.call(index);
      inFlight--;
      return index;
    },
  );
  return (peakInFlight: peak, completed: completed);
}

void main() {
  group('dispatch', () {
    test('serial keeps exactly one request in flight', () async {
      final run = await _dispatch(
        count: 12,
        mode: BenchmarkExecution.serial,
        concurrency: 8,
      );
      expect(run.peakInFlight, 1);
      expect(run.completed, List<int>.generate(12, (int i) => i));
    });

    test('concurrent never exceeds its limit and still runs everything',
        () async {
      final run = await _dispatch(
        count: 40,
        mode: BenchmarkExecution.concurrent,
        concurrency: 6,
      );
      expect(run.peakInFlight, lessThanOrEqualTo(6));
      expect(
        run.peakInFlight,
        6,
        reason: 'a limit that is never reached is a serial run wearing a label',
      );
      expect(
        run.completed,
        List<int>.generate(40, (int i) => i),
        reason: 'results are returned by index, not by completion order',
      );
    });

    test('concurrent falls back to the iteration count when it is smaller',
        () async {
      final run = await _dispatch(
        count: 3,
        mode: BenchmarkExecution.concurrent,
        concurrency: 64,
      );
      expect(run.peakInFlight, 3);
    });

    test('parallel dispatches every iteration before any completes', () async {
      final run = await _dispatch(
        count: 25,
        mode: BenchmarkExecution.parallel,
        concurrency: 1,
        );
      expect(
        run.peakInFlight,
        25,
        reason: 'parallel ignores the concurrency limit by definition',
      );
      expect(run.completed, hasLength(25));
    });

    test('cancelling stops the loop and returns only completed iterations',
        () async {
      final cancel = BenchmarkCancellation();
      final run = await _dispatch(
        count: 500,
        mode: BenchmarkExecution.serial,
        concurrency: 1,
        cancel: cancel,
        onBody: (int index) {
          if (index == 4) cancel.cancel();
        },
      );
      expect(
        run.completed,
        List<int>.generate(5, (int i) => i),
        reason: 'the in-flight iteration finishes; the next one never starts',
      );
    });

    test('a cancelled token runs nothing at all', () async {
      final cancel = BenchmarkCancellation()..cancel();
      for (final mode in BenchmarkExecution.values) {
        final run = await _dispatch(
          count: 10,
          mode: mode,
          concurrency: 4,
          cancel: cancel,
        );
        expect(run.completed, isEmpty, reason: mode.label);
      }
    });
  });

  test('the harness measures its baselines and renders a table', () async {
    final server = await LocalServer.start();
    addTearDown(server.stop);

    final report = await BenchmarkRunner(
      baseUrl: server.baseUrl,
      config: const BenchmarkConfig(
        warmupRequests: 2,
        iterations: 20,
        burstRequests: 16,
        downloadBytes: 2 * 1024 * 1024,
        uploadBytes: 256 * 1024,
        mixedRequests: 16,
      ),
    ).run();

    expect(report.scenarios, hasLength(5));
    expect(report.cancelled, isFalse);
    expect(
      report.results,
      hasLength(5 * HttpLibrary.values.length),
      reason: 'every scenario × client pair yields a row, failures included',
    );

    // The two clients whose transport is native cannot load here.
    const native = {HttpLibrary.nitroHttp, HttpLibrary.rhttp};
    for (final result in report.results.where(
      (BenchmarkResult r) => native.contains(r.library),
    )) {
      expect(
        result.error,
        isNotNull,
        reason: '${result.scenario}/${result.library.label} has no native '
            'library on the test host and must report that, not a timing',
      );
    }

    final baselines = report.results.where(
      (BenchmarkResult r) => !native.contains(r.library),
    );
    expect(baselines, hasLength(5 * (HttpLibrary.values.length - 2)));
    for (final result in baselines) {
      final label = '${result.scenario}/${result.library.label}';
      expect(result.error, isNull, reason: label);
      expect(result.iterations, greaterThan(0), reason: label);
      expect(result.p50, greaterThan(Duration.zero), reason: label);
      expect(result.p95, greaterThanOrEqualTo(result.p50), reason: label);
      expect(result.bytes, greaterThan(0), reason: label);
      expect(result.megabytesPerSecond, greaterThan(0), reason: label);
      expect(result.requestsPerSecond, greaterThan(0), reason: label);
      expect(result.latencies, hasLength(result.iterations), reason: label);
    }

    // Only the download scenario measures time to first byte, and it must be no
    // later than the transfer it is part of.
    final downloads = report.results.where(
      (BenchmarkResult result) =>
          result.scenario == 'download' && !native.contains(result.library),
    );
    for (final result in downloads) {
      expect(result.timeToFirstByte, isNotNull);
      expect(result.timeToFirstByte, lessThanOrEqualTo(result.wallClock));
      expect(result.bytes, 2 * 1024 * 1024);
    }

    final markdown = report.toMarkdownTable();
    expect(
      markdown,
      contains('| Scenario | Client | n | min | mean | p50 |'),
    );
    expect(
      markdown,
      contains('small GET: 20 × 1024 B GET'),
      reason: 'the preamble must state the sample sizes',
    );
    expect(markdown, contains('warm-up per client: 2 requests (discarded)'));
    expect(
      markdown,
      contains('* execution: Serial'),
      reason: 'a latency table without its dispatch mode is not reproducible',
    );
    for (final library in HttpLibrary.values) {
      expect(markdown, contains(library.label));
    }
    // A multi-line engine error must not break the table's column count.
    for (final line in markdown.split('\n').where(
      (String l) => l.startsWith('| '),
    )) {
      expect(line.split('|'), hasLength(16), reason: line);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('overlapped dispatch measures the same work as serial', () async {
    final server = await LocalServer.start();
    addTearDown(server.stop);

    // Only the pure-Dart clients: the native two cannot load on this host and
    // would contribute two identical error rows to both runs.
    const baselines = [
      HttpLibrary.dartIo,
      HttpLibrary.packageHttp,
      HttpLibrary.dio,
    ];
    const iterations = 24;

    Future<Map<String, int>> bytesPerRow(BenchmarkExecution execution) async {
      final report = await BenchmarkRunner(
        baseUrl: server.baseUrl,
        config: BenchmarkConfig(
          warmupRequests: 1,
          iterations: iterations,
          burstRequests: 8,
          mixedRequests: 8,
          downloadBytes: 256 * 1024,
          uploadBytes: 64 * 1024,
          execution: execution,
          concurrency: 4,
          libraries: baselines,
        ),
      ).run();
      return {
        for (final r in report.results)
          '${r.scenario}/${r.library.name}': r.bytes,
      };
    }

    final serial = await bytesPerRow(BenchmarkExecution.serial);
    for (final execution in const [
      BenchmarkExecution.concurrent,
      BenchmarkExecution.parallel,
    ]) {
      expect(
        await bytesPerRow(execution),
        serial,
        reason: 'dispatching ${execution.name} must move exactly the same '
            'bytes as serial — `bytes += await` across overlapping iterations '
            'is precisely how a benchmark silently under-counts and reports a '
            'client as fast for doing less work',
      );
    }

    // Guard the guard: the counts compared above must not all be zero.
    expect(serial, hasLength(5 * baselines.length));
    expect(serial.values, everyElement(greaterThan(0)));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an arbitrary console request becomes a measurable scenario', () async {
    final server = await LocalServer.start();
    addTearDown(server.stop);

    const spec = RequestSpec(
      method: 'POST',
      url: '/echo',
      headers: [KeyValueRow(name: 'X-Benchmark', value: 'console')],
      bodyKind: RequestBodyKind.json,
      bodyText: '{"hello":"world"}',
    );
    const iterations = 8;

    final results = await runSpecBenchmark(
      spec: spec,
      baseUrl: server.baseUrl,
      config: const BenchmarkConfig(
        warmupRequests: 1,
        iterations: iterations,
        execution: BenchmarkExecution.concurrent,
        concurrency: 3,
      ),
    );

    expect(
      results.map((BenchmarkResult r) => r.library),
      HttpLibrary.values,
      reason: 'one row per client, in enum order, failures included — a client '
          'that cannot issue the request must not remove the others',
    );

    const native = {HttpLibrary.nitroHttp, HttpLibrary.rhttp};
    for (final result in results) {
      expect(result.scenario, consoleScenario);
      if (native.contains(result.library)) {
        expect(
          result.error,
          isNotNull,
          reason: '${result.library.label} has no native library on this host',
        );
        continue;
      }
      final label = result.library.label;
      expect(result.error, isNull, reason: label);
      expect(result.iterations, iterations, reason: label);
      expect(result.latencies, hasLength(iterations), reason: label);
      expect(result.bytes, greaterThan(0), reason: label);
      expect(
        result.bytesVaryByClient,
        isTrue,
        reason: 'an arbitrary request is usually an echo, and every client '
            'sends its own User-Agent',
      );
    }

    expect(
      consoleScenarioNote(spec, const BenchmarkConfig(iterations: iterations)),
      'console request: 8 × POST /echo (JSON body, buffered response)',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
