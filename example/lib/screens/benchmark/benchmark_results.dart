/// Everything that renders a finished [BenchmarkReport].
///
/// A percentile table is the honest record, but nobody reads thirteen columns
/// across five clients and comes away with a ranking. So the table is kept and a
/// comparison strip is put in front of it: one bar per client, longest is
/// fastest, and a sparkline of the per-iteration latencies underneath so a run
/// whose mean is fine but whose tail is not cannot hide behind its own average.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/execution.dart';
import '../../core/http_library.dart';
import '../../theme/app_theme.dart';
import '../../widgets/http_bits.dart';
import '../../widgets/panels.dart';

/// The report, from consistency gate to raw numbers.
class BenchmarkResultsView extends StatelessWidget {
  /// Creates a view of [report].
  const BenchmarkResultsView({required this.report, super.key});

  /// The finished run.
  final BenchmarkReport report;

  @override
  Widget build(BuildContext context) {
    final problems = report.consistencyProblems();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (problems.isNotEmpty) ...[
          ConsistencyBanner(problems: problems),
          const SizedBox(height: 12),
        ],
        RunSummary(report: report, trustworthy: problems.isEmpty),
        for (final scenario in report.scenarios) ...[
          const SizedBox(height: 12),
          ScenarioCard(
            scenario: scenario,
            rows: report.results
                .where((BenchmarkResult r) => r.scenario == scenario)
                .toList(growable: false),
          ),
        ],
      ],
    );
  }
}

/// The run's own verdict on itself, and the Markdown escape hatch.
class RunSummary extends StatelessWidget {
  /// Creates a summary of [report].
  const RunSummary({
    required this.report,
    required this.trustworthy,
    super.key,
  });

  /// The finished run.
  final BenchmarkReport report;

  /// Whether [BenchmarkReport.consistencyProblems] came back empty.
  final bool trustworthy;

  @override
  Widget build(BuildContext context) {
    final config = report.config;
    final inFlight = config.execution == BenchmarkExecution.concurrent
        ? '${config.execution.label} · ${config.concurrency} in flight'
        : config.execution.label;
    return SectionCard(
      title: 'Run',
      trailing: FilledButton.tonalIcon(
        onPressed: () async {
          await Clipboard.setData(
            ClipboardData(text: report.toMarkdownTable()),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Report copied as Markdown')),
            );
          }
        },
        icon: const Icon(Icons.copy_all_outlined, size: 18),
        label: const Text('Copy as Markdown'),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 12,
        children: [
          MetricTile(
            label: 'Verdict',
            value: trustworthy ? 'Consistent' : 'Failed its gate',
            hint: trustworthy
                ? 'Every client completed every scenario and moved the same '
                      'bytes.'
                : 'See the problems listed above.',
          ),
          MetricTile(
            label: 'Wall clock',
            value: formatDuration(report.duration),
            hint: 'Total time for the whole run, warm-up included.',
          ),
          MetricTile(
            label: 'Execution',
            value: inFlight,
            hint: config.execution.description,
          ),
          MetricTile(
            label: 'Clients',
            value: '${config.libraries.length}',
            hint: config.libraries
                .map((HttpLibrary l) => l.label)
                .join(', '),
          ),
          MetricTile(
            label: 'Scenarios',
            value: '${report.scenarios.length}',
            hint: report.scenarios.join(', '),
          ),
        ],
      ),
    );
  }
}

/// The consistency gate's findings, rendered so a bad run cannot look good.
class ConsistencyBanner extends StatelessWidget {
  /// Creates a banner listing [problems].
  const ConsistencyBanner({required this.problems, super.key});

  /// The lines from [BenchmarkReport.consistencyProblems].
  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.report_problem_outlined, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This run failed its own consistency gate',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Timings below are not comparable. A client that skipped work, '
            'moved fewer bytes or never ran can look fast for the wrong reason.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 10),
          for (final problem in problems)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '• $problem',
                style: codeStyle(
                  context,
                  size: 11.5,
                ).copyWith(color: scheme.onErrorContainer),
              ),
            ),
        ],
      ),
    );
  }
}

/// One scenario: the ranking strip, then the numbers behind it.
class ScenarioCard extends StatelessWidget {
  /// Creates a card for [scenario] over [rows].
  const ScenarioCard({required this.scenario, required this.rows, super.key});

  /// The scenario name.
  final String scenario;

  /// Every client's result for this scenario, in report order.
  final List<BenchmarkResult> rows;

  @override
  Widget build(BuildContext context) {
    final measured = rows
        .where((BenchmarkResult r) => r.error == null && r.latencies.isNotEmpty)
        .toList(growable: false);
    // Rank on p50 rather than the mean: one 200 ms scheduling hiccup in a
    // thousand loopback requests moves a mean by a fifth and a median by nothing.
    var fastest = Duration.zero;
    var slowestLatency = Duration.zero;
    for (final row in measured) {
      if (fastest == Duration.zero || row.p50 < fastest) fastest = row.p50;
      if (row.max > slowestLatency) slowestLatency = row.max;
    }
    final transfer = scenario == 'download' || scenario == 'upload';

    return SectionCard(
      title: scenario,
      trailing: Text(
        transfer ? 'longer bar = faster transfer' : 'longer bar = lower p50',
        style: Theme.of(context).textTheme.labelSmall,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Podium(measured: measured),
          const SizedBox(height: 12),
          for (final row in rows)
            _ComparisonRow(
              result: row,
              fastest: fastest,
              worstLatency: slowestLatency,
              transfer: transfer,
            ),
          const SizedBox(height: 10),
          _ScenarioTable(rows: rows),
        ],
      ),
    );
  }
}

/// Winner, runner-up and third place for one scenario.
///
/// The bars below rank the same data, but reading a rank off a bar chart is a
/// comparison the reader has to perform; this states it. The gap column is the
/// part that stops a podium being misleading — "2nd" means something very
/// different at +1 % than at +90 %, and on this project's own numbers both occur.
class _Podium extends StatelessWidget {
  const _Podium({required this.measured});

  /// Rows that actually produced a measurement, in report order. A failed row
  /// has no latency and must never place.
  final List<BenchmarkResult> measured;

  /// Below this the three places stack instead of sharing a row.
  static const double _wideEnough = 560;

  @override
  Widget build(BuildContext context) {
    if (measured.isEmpty) return const SizedBox.shrink();

    // Ranked on p50, ascending — lower is faster in every scenario, including
    // the transfer ones where p50 is the duration of one transfer.
    final ranked = [...measured]
      ..sort((BenchmarkResult a, BenchmarkResult b) => a.p50.compareTo(b.p50));
    final top = ranked.take(3).toList(growable: false);
    final winner = top.first.p50.inMicroseconds;

    final places = <Widget>[
      for (var i = 0; i < top.length; i++)
        _PodiumPlace(
          place: i + 1,
          result: top[i],
          // Percent slower than the winner. Guarded against a zero winner,
          // which only happens if a scenario somehow measured 0 us.
          gapPercent: winner == 0
              ? 0
              : 100 * (top[i].p50.inMicroseconds - winner) / winner,
        ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < _wideEnough) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < places.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                places[i],
              ],
            ],
          );
        }
        // `IntrinsicHeight`, because `stretch` needs a bounded height to
        // stretch to. This Row sits inside a scrolling Column, so its incoming
        // constraint is `0 <= h <= Infinity`, and stretching against infinity
        // throws `BoxConstraints forces an infinite height`. Measuring the
        // tallest card first gives the cross axis a real number, which is what
        // lets the three cards share a height and keeps their footers aligned.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < places.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: places[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _PodiumPlace extends StatelessWidget {
  const _PodiumPlace({
    required this.place,
    required this.result,
    required this.gapPercent,
  });

  final int place;
  final BenchmarkResult result;
  final double gapPercent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final first = place == 1;

    // Only the winner is tinted. Three competing accent colours would read as
    // three categories rather than one ordering.
    final border = first ? scheme.primary : scheme.outlineVariant;
    final fill = first
        ? scheme.primary.withValues(alpha: 0.08)
        : scheme.surfaceContainerLow;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: first ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _RankBadge(place: place),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: LibraryChip(library: result.library, selected: first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  formatDuration(result.p50),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: codeStyle(context, size: 14).copyWith(
                    fontWeight: first ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                first ? 'fastest' : '+${gapPercent.toStringAsFixed(1)}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: first ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: first ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The 1 / 2 / 3 marker. A numeral, not a medal emoji — emoji render at wildly
/// different sizes across the platforms this example runs on.
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.place});

  final int place;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = place == 1;
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: first ? scheme.primary : scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$place',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: first ? scheme.onPrimary : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ComparisonRow extends StatelessWidget {
  const _ComparisonRow({
    required this.result,
    required this.fastest,
    required this.worstLatency,
    required this.transfer,
  });

  final BenchmarkResult result;
  final Duration fastest;
  final Duration worstLatency;
  final bool transfer;

  /// Below this the label and two number columns (172 + 108 + 92 plus gaps)
  /// leave nothing for the bar, so the row stacks instead. A phone card is
  /// roughly 300 pt wide; a desktop window is far past this.
  static const double _wideEnough = 460;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: constraints.maxWidth >= _wideEnough
              ? _wide(context)
              : _narrow(context),
        );
      },
    );
  }

  /// One line: label, bar, then the two figures right-aligned in fixed columns.
  Widget _wide(BuildContext context) {
    final error = result.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Fixed column so every bar starts at the same x — a comparison strip
        // whose bars begin in different places is not a comparison. The
        // FittedBox is the guard that a long client name or a large text
        // scale shrinks instead of overflowing.
        SizedBox(
          width: 172,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: LibraryChip(library: result.library),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (error != null)
          Expanded(child: _errorText(context, error))
        else ...[
          Expanded(child: _bar(context)),
          const SizedBox(width: 10),
          SizedBox(
            width: 108,
            child: Text(
              formatDuration(result.p50),
              textAlign: TextAlign.right,
              style: codeStyle(context, size: 12),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 92, child: _rate(context, TextAlign.right)),
        ],
      ],
    );
  }

  /// Two lines: label and figures above, bar full width below. The bars still
  /// share a left edge — they simply share the card's edge rather than a column
  /// boundary — so the visual comparison the strip exists for survives.
  Widget _narrow(BuildContext context) {
    final error = result.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: LibraryChip(library: result.library),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (error == null) ...[
              Text(formatDuration(result.p50), style: codeStyle(context, size: 12)),
              const SizedBox(width: 10),
              _rate(context, TextAlign.right),
            ],
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _errorText(context, error),
          )
        else ...[
          const SizedBox(height: 6),
          _bar(context),
        ],
      ],
    );
  }

  Widget _errorText(BuildContext context, String error) => Text(
    error,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
  );

  Widget _rate(BuildContext context, TextAlign align) => Text(
    transfer
        ? '${result.megabytesPerSecond.toStringAsFixed(1)} MiB/s'
        : '${result.requestsPerSecond.toStringAsFixed(0)} req/s',
    textAlign: align,
    style: codeStyle(
      context,
      size: 12,
    ).copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
  );

  Widget _bar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Relative speed, not absolute time: the fastest client fills the track and
    // a client half as fast fills half of it, which is the comparison a reader
    // is actually making.
    final ratio = fastest == Duration.zero || result.p50 == Duration.zero
        ? 1.0
        : (fastest.inMicroseconds / result.p50.inMicroseconds).clamp(0.02, 1.0);
    final winner = ratio >= 0.999;
    final fill = winner
        ? scheme.primary
        : scheme.primary.withValues(alpha: 0.42);

    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        // Explicit width: a Stack lays non-positioned children out with loose
        // constraints, so a Container with only a height collapses to nothing
        // and the track disappears.
        Container(
          height: 26,
          width: double.infinity,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        FractionallySizedBox(
          widthFactor: ratio,
          child: Container(
            height: 26,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: CustomPaint(
              painter: LatencySparkline(
                latencies: result.latencies,
                worst: worstLatency,
                color: winner
                    ? scheme.onPrimary.withValues(alpha: 0.8)
                    : scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
        if (winner)
          Positioned(
            right: 6,
            child: Pill(
              text: 'fastest',
              background: scheme.onPrimary.withValues(alpha: 0.22),
              foreground: scheme.onPrimary,
            ),
          ),
      ],
    );
  }
}

/// Per-iteration latency drawn inside the comparison bar.
///
/// Buckets are reduced by *maximum*, not by average: an averaged sparkline of a
/// thousand samples is a flat line, and the spikes it erases are the reason
/// anybody looks at a latency distribution in the first place.
class LatencySparkline extends CustomPainter {
  /// Creates a painter over [latencies], scaled against [worst].
  LatencySparkline({
    required this.latencies,
    required this.worst,
    required this.color,
  });

  /// The per-iteration samples, in issue order.
  final List<Duration> latencies;

  /// The largest latency in the scenario, so every client shares one scale.
  final Duration worst;

  /// The line colour.
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (latencies.length < 8 || size.width < 8 || size.height <= 0) return;
    final ceiling = worst.inMicroseconds;
    if (ceiling <= 0) return;

    final columns = size.width.floor().clamp(2, latencies.length);
    final perColumn = latencies.length / columns;
    final path = Path();
    for (var column = 0; column < columns; column++) {
      final start = (column * perColumn).floor();
      var end = ((column + 1) * perColumn).ceil();
      if (end > latencies.length) end = latencies.length;
      var peak = 0;
      for (var i = start; i < end; i++) {
        final micros = latencies[i].inMicroseconds;
        if (micros > peak) peak = micros;
      }
      final x = size.width * column / (columns - 1);
      final y = size.height * (1 - (peak / ceiling).clamp(0.0, 1.0));
      if (column == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(LatencySparkline oldDelegate) =>
      !identical(oldDelegate.latencies, latencies) ||
      oldDelegate.worst != worst ||
      oldDelegate.color != color;
}

class _ScenarioTable extends StatelessWidget {
  const _ScenarioTable({required this.rows});

  final List<BenchmarkResult> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final numeric = codeStyle(context, size: 11.5);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 32,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 30,
        horizontalMargin: 8,
        columnSpacing: 18,
        columns: const [
          DataColumn(label: Text('Client')),
          DataColumn(label: Text('n'), numeric: true),
          DataColumn(label: Text('min'), numeric: true),
          DataColumn(label: Text('mean'), numeric: true),
          DataColumn(label: Text('p50'), numeric: true),
          DataColumn(label: Text('p90'), numeric: true),
          DataColumn(label: Text('p95'), numeric: true),
          DataColumn(label: Text('p99'), numeric: true),
          DataColumn(label: Text('max'), numeric: true),
          DataColumn(label: Text('sd'), numeric: true),
          DataColumn(label: Text('MiB/s'), numeric: true),
          DataColumn(label: Text('req/s'), numeric: true),
          DataColumn(label: Text('TTFB'), numeric: true),
        ],
        rows: [
          for (final row in rows)
            DataRow(
              cells: row.error != null
                  ? [
                      DataCell(
                        Tooltip(
                          message: row.error!,
                          child: Text(
                            row.library.label,
                            style: numeric.copyWith(color: scheme.error),
                          ),
                        ),
                      ),
                      for (var i = 0; i < 12; i++)
                        DataCell(Text('—', style: numeric)),
                    ]
                  : [
                      DataCell(Text(row.library.label, style: numeric)),
                      DataCell(Text('${row.iterations}', style: numeric)),
                      DataCell(Text(formatDuration(row.min), style: numeric)),
                      DataCell(Text(formatDuration(row.mean), style: numeric)),
                      DataCell(Text(formatDuration(row.p50), style: numeric)),
                      DataCell(Text(formatDuration(row.p90), style: numeric)),
                      DataCell(Text(formatDuration(row.p95), style: numeric)),
                      DataCell(Text(formatDuration(row.p99), style: numeric)),
                      DataCell(Text(formatDuration(row.max), style: numeric)),
                      DataCell(Text(formatDuration(row.stdDev), style: numeric)),
                      DataCell(
                        Text(
                          row.megabytesPerSecond.toStringAsFixed(1),
                          style: numeric,
                        ),
                      ),
                      DataCell(
                        Text(
                          row.requestsPerSecond.toStringAsFixed(0),
                          style: numeric,
                        ),
                      ),
                      DataCell(
                        Text(
                          formatDuration(row.timeToFirstByte),
                          style: numeric,
                        ),
                      ),
                    ],
            ),
        ],
      ),
    );
  }
}

/// The pairs that have finished, shown while the run is still going.
///
/// The full [BenchmarkReport] only exists once every pair has been measured, and
/// a run takes minutes. Waiting for it means the screen shows nothing but a
/// progress bar while results that are already known sit in memory — so this
/// renders them as they land, grouped by scenario, with the current leader
/// marked.
///
/// Deliberately plainer than [BenchmarkResultsView]: a partial run has no
/// consistency verdict and no cross-client comparison worth drawing, and
/// dressing incomplete data to look final is how a half-finished run gets quoted.
class LiveResultsView extends StatelessWidget {
  /// Creates the in-progress view over [results], in completion order.
  const LiveResultsView({required this.results, super.key});

  /// Pairs measured so far.
  final List<BenchmarkResult> results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Grouped by scenario, preserving the order scenarios first appeared.
    final byScenario = <String, List<BenchmarkResult>>{};
    for (final r in results) {
      byScenario.putIfAbsent(r.scenario, () => <BenchmarkResult>[]).add(r);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'Measuring — ${results.length} pair'
              '${results.length == 1 ? '' : 's'} done',
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Partial. A leader here can still change: the remaining clients for a '
          'scenario have not run yet.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        for (final entry in byScenario.entries) ...[
          _LiveScenarioCard(scenario: entry.key, results: entry.value),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _LiveScenarioCard extends StatelessWidget {
  const _LiveScenarioCard({required this.scenario, required this.results});

  final String scenario;
  final List<BenchmarkResult> results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // The fastest so far, ignoring rows that failed — a failed pair has no
    // latency and must never read as a win.
    final ok = results.where((BenchmarkResult r) => r.error == null).toList();
    Duration? best;
    for (final r in ok) {
      if (best == null || r.p50 < best) best = r.p50;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(scenario, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final r in results)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  LibraryChip(
                    library: r.library,
                    selected: r.error == null && r.p50 == best,
                  ),
                  const SizedBox(width: 10),
                  if (r.error != null)
                    Expanded(
                      child: Text(
                        r.error!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    )
                  else ...[
                    Text(
                      formatDuration(r.p50),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight:
                            r.p50 == best ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'p50',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const Spacer(),
                    Text(
                      '${r.requestsPerSecond.toStringAsFixed(0)} req/s',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
