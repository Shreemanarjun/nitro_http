/// Widget-level proof that the benchmark screen lays out and reacts.
///
/// Nothing here sends a request: `TestWidgetsFlutterBinding` answers every
/// `HttpClient` call with a 400, so a real run belongs in `benchmark_test.dart`
/// where there is no widget binding. What this file catches is the other half —
/// a comparison bar that collapses to nothing under a `Stack`'s loose
/// constraints, a row that overflows in the narrow setup column, a chip that can
/// empty the client selection. Those are invisible to an analyzer and fatal to
/// the screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http_example/benchmark/benchmark.dart';
import 'package:nitro_http_example/benchmark/execution.dart';
import 'package:nitro_http_example/core/app_state.dart';
import 'package:nitro_http_example/core/http_library.dart';
import 'package:nitro_http_example/screens/benchmark/benchmark_results.dart';
import 'package:nitro_http_example/screens/benchmark/benchmark_screen.dart';
import 'package:nitro_http_example/theme/app_theme.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.light),
  home: Scaffold(body: child),
);

/// A result with [count] plausible latencies, so the sparkline has something to
/// draw and the percentiles are not all the same sample.
BenchmarkResult _row(
  HttpLibrary library, {
  required String scenario,
  required int microseconds,
  int count = 40,
}) => BenchmarkResult(
  scenario: scenario,
  library: library,
  iterations: count,
  latencies: [
    for (var i = 0; i < count; i++)
      // A steady base with one deliberate spike, which is exactly the shape a
      // max-reducing sparkline exists to show.
      Duration(microseconds: microseconds + (i == count ~/ 2 ? 9000 : i * 5)),
  ],
  wallClock: Duration(microseconds: microseconds * count),
  bytes: 1024 * count,
);

BenchmarkReport _report({bool withFailure = false}) => BenchmarkReport(
  baseUrl: 'http://127.0.0.1:1234',
  startedAt: DateTime.utc(2026),
  duration: const Duration(seconds: 4),
  config: const BenchmarkConfig(
    warmupRequests: 2,
    iterations: 40,
    execution: BenchmarkExecution.concurrent,
    concurrency: 8,
    libraries: [HttpLibrary.dartIo, HttpLibrary.packageHttp, HttpLibrary.dio],
  ),
  results: [
    _row(HttpLibrary.dartIo, scenario: 'small GET', microseconds: 400),
    _row(HttpLibrary.packageHttp, scenario: 'small GET', microseconds: 900),
    if (withFailure)
      BenchmarkResult.failed(
        scenario: 'small GET',
        library: HttpLibrary.dio,
        error: 'engine not built on this host',
      )
    else
      _row(HttpLibrary.dio, scenario: 'small GET', microseconds: 1600),
  ],
);

void main() {
  tearDown(() {
    // The app-global signals outlive any one test, so a test that changes one
    // has to put it back or it silently configures the next.
    baseUrl.value = '';
  });

  testWidgets('the screen builds and explains what to do first', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const BenchmarkScreen()));

    expect(find.text('No run yet'), findsOneWidget);
    expect(find.text('Run benchmark'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(
      find.text('Waiting for the demo server to come up.'),
      findsOneWidget,
      reason: 'a disabled Run button must say why it is disabled',
    );

    final run = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Run benchmark'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(run.onPressed, isNull);
  });

  testWidgets('Run enables once the server is up', (
    WidgetTester tester,
  ) async {
    baseUrl.value = 'http://127.0.0.1:9999';
    await tester.pumpWidget(_host(const BenchmarkScreen()));

    final run = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Run benchmark'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(run.onPressed, isNotNull);
  });

  testWidgets('the client selection can be narrowed but never emptied', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const BenchmarkScreen()));
    await tester.scrollUntilVisible(find.text('Clients'), 300);

    Future<void> deselect(HttpLibrary library) async {
      await tester.tap(find.text(library.label), warnIfMissed: false);
      await tester.pump();
    }

    for (final library in HttpLibrary.values) {
      await deselect(library);
    }

    final chips = tester
        .widgetList<FilterChip>(find.byType(FilterChip))
        .toList(growable: false);
    expect(chips.where((FilterChip c) => c.selected), hasLength(1));
    expect(
      chips.singleWhere((FilterChip c) => c.selected).onSelected,
      isNull,
      reason: 'the surviving chip must be inert, not merely ignored on tap',
    );
    expect(
      find.textContaining('The last client cannot be removed'),
      findsOneWidget,
    );
  });

  testWidgets('the concurrency limit is live only for concurrent dispatch', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const BenchmarkScreen()));

    // The execution card is built first, so its knob is the first slider.
    Slider concurrencyKnob() =>
        tester.widget<Slider>(find.byType(Slider).first);

    expect(find.text(BenchmarkExecution.serial.description), findsOneWidget);
    expect(
      concurrencyKnob().onChanged,
      isNull,
      reason: 'serial dispatch has no limit to apply, so the control is inert '
          'rather than silently ignored',
    );
    expect(
      find.textContaining('Only concurrent dispatch has a limit to apply'),
      findsOneWidget,
    );

    await tester.tap(find.text('Concurrent'));
    await tester.pump();

    expect(
      find.text(BenchmarkExecution.concurrent.description),
      findsOneWidget,
    );
    expect(concurrencyKnob().onChanged, isNotNull);
  });

  testWidgets('results lay out: bars, sparkline, table', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: BenchmarkResultsView(report: _report()),
        ),
      ),
    );

    expect(find.text('small GET'), findsWidgets);
    expect(find.text('fastest'), findsOneWidget);
    expect(find.text('Copy as Markdown'), findsOneWidget);
    expect(find.text('Consistent'), findsOneWidget);
    expect(
      find.byType(CustomPaint).evaluate().isNotEmpty,
      isTrue,
      reason: 'the sparkline is painted per comparison row',
    );

    // The bar track must occupy real width; the whole point of the strip is a
    // length you can compare at a glance.
    final tracks = tester
        .renderObjectList<RenderBox>(
          find.descendant(
            of: find.byType(FractionallySizedBox),
            matching: find.byType(Container),
          ),
        )
        .toList(growable: false);
    expect(tracks, isNotEmpty);
    for (final track in tracks) {
      expect(track.size.width, greaterThan(0));
      expect(track.size.height, 26);
    }
  });

  testWidgets('a run that failed its gate says so before it shows numbers', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: BenchmarkResultsView(report: _report(withFailure: true)),
        ),
      ),
    );

    expect(
      find.text('This run failed its own consistency gate'),
      findsOneWidget,
    );
    expect(
      find.textContaining('engine not built on this host'),
      findsWidgets,
      reason: 'the failing row must name its own error, not just be missing',
    );
    expect(find.text('Failed its gate'), findsOneWidget);

    final banner = tester.getTopLeft(
      find.text('This run failed its own consistency gate'),
    );
    final table = tester.getTopLeft(find.byType(DataTable));
    expect(
      banner.dy,
      lessThan(table.dy),
      reason: 'the verdict has to be read before the numbers it invalidates',
    );
  });
}
