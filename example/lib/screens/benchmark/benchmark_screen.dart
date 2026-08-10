/// The benchmark screen: configure a run, watch it, read the comparison.
///
/// Setup and results sit side by side wherever there is room, because the whole
/// workflow is "change a number, run again, see whether the ranking moved" — and
/// a layout that makes you scroll back up to the sliders to do that turns a
/// two-second loop into a ten-second one.
library;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../widgets/http_bits.dart';
import '../../widgets/panels.dart';
import 'benchmark_controller.dart';
import 'benchmark_results.dart';
import 'benchmark_setup.dart';

/// Compares every HTTP client across the built-in scenarios and, on request, the
/// console's own request.
class BenchmarkScreen extends StatelessWidget {
  /// Creates the screen.
  const BenchmarkScreen({super.key});

  @override
  Widget build(BuildContext context) => const _BenchmarkView();
}

/// Stateful only to own the controller's lifetime.
///
/// The controller's signals are screen-scoped and `autoDispose` is off by
/// default in signals 7, so they have to be disposed by hand from a `State`.
class _BenchmarkView extends StatefulWidget {
  const _BenchmarkView();

  @override
  State<_BenchmarkView> createState() => _BenchmarkViewState();
}

class _BenchmarkViewState extends State<_BenchmarkView> {
  final BenchmarkController _controller = BenchmarkController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Outside the scroll view: a run takes minutes and Cancel must never be
        // somewhere you have to scroll to find.
        RunControls(controller: _controller),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final side = constraints.maxWidth >= 1000;
              if (!side) {
                // Results first when there is only one column. The loop is run,
                // read, adjust, run again — and burying the outcome under six
                // cards of sliders means scrolling past the whole setup panel
                // every time a run finishes. Action (pinned above), outcome,
                // then configuration.
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _Results(controller: _controller),
                    const SizedBox(height: 12),
                    ..._setup(),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 400,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: _setup(),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [_Results(controller: _controller)],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _setup() => [
    SectionCard(
      title: 'Execution',
      child: ExecutionPicker(controller: _controller),
    ),
    const SizedBox(height: 12),
    SectionCard(
      title: 'Workload',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntKnob(
            label: 'Warm-up requests',
            value: _controller.warmup,
            bounds: BenchmarkBounds.warmup,
            step: 5,
          ),
          IntKnob(
            label: 'Iterations — small GET & console request',
            value: _controller.iterations,
            bounds: BenchmarkBounds.iterations,
            step: 25,
          ),
          IntKnob(
            label: 'Burst GET — requests in flight',
            value: _controller.burst,
            bounds: BenchmarkBounds.burst,
            step: 8,
          ),
          IntKnob(
            label: 'Mixed iterations',
            value: _controller.mixed,
            bounds: BenchmarkBounds.mixed,
            step: 10,
          ),
          IntKnob(
            label: 'Download size',
            value: _controller.downloadMiB,
            bounds: BenchmarkBounds.downloadMiB,
            step: 4,
            suffix: 'MiB',
          ),
          IntKnob(
            label: 'Upload size',
            value: _controller.uploadMiB,
            bounds: BenchmarkBounds.uploadMiB,
            step: 1,
            suffix: 'MiB',
          ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    SectionCard(
      title: 'Clients',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LibraryPicker(controller: _controller),
          const Divider(height: 24),
          ConsoleRequestSwitch(controller: _controller),
        ],
      ),
    ),
  ];
}

class _Results extends StatelessWidget {
  const _Results({required this.controller});

  final BenchmarkController controller;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final failure = controller.error.value;
        if (failure != null) {
          return EngineErrorCard(
            action: 'run the benchmark',
            error: failure,
            onRetry: controller.start,
          );
        }
        final report = controller.report.value;
        if (report == null) {
          // Mid-run: show the pairs that have already landed. The full report
          // only exists at the end, and a run takes minutes — leaving the panel
          // empty until then hides results that are already measured.
          final live = controller.liveResults.value;
          if (live.isNotEmpty) {
            return LiveResultsView(results: live);
          }
          return const EmptyHint(
            icon: Icons.speed_outlined,
            title: 'No run yet',
            detail:
                'Pick a dispatch mode and press Run. Five built-in scenarios '
                'measure every selected client against the in-process demo '
                'server; switch on the console request to measure whatever the '
                'console is holding as a sixth.',
          );
        }
        return BenchmarkResultsView(report: report);
      },
    );
  }
}
