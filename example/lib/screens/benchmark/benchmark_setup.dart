/// The controls that decide what the next run measures.
///
/// Every numeric control is a bounded slider with fine-step buttons rather than a
/// text field. That is not a styling choice: a benchmark configured with zero
/// iterations or two hundred thousand does not fail, it produces a table that
/// looks like a result — so the input simply cannot express one.
library;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../benchmark/execution.dart';
import '../../core/app_state.dart';
import '../../core/http_library.dart';
import '../../theme/app_theme.dart';
import '../../widgets/http_bits.dart';
import 'benchmark_controller.dart';

/// Start/stop plus the live progress of a run.
///
/// The progress half is one small [SignalBuilder] on purpose: a loopback run
/// completes hundreds of iterations a second and this is the only subtree that
/// should be rebuilding at that rate.
class RunControls extends StatelessWidget {
  /// Creates controls driving [controller].
  const RunControls({required this.controller, super.key});

  /// The screen's controller.
  final BenchmarkController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SignalBuilder(
        builder: (BuildContext context) {
          final running = controller.running.value;
          final progress = controller.progress.value;
          final overall = controller.overall.value;
          final elapsed = controller.elapsed.value;
          final remaining = controller.remaining.value;
          final stopping = controller.stopping.value;
          final ready = controller.canRun;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A Wrap, not a Row: while a run is live this line carries two
              // buttons AND two metrics, which is wider than a phone. Given the
              // room they sit on one line pushed apart; below it the metrics
              // drop to their own line rather than overflowing the header.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(
                        onPressed: ready ? controller.start : null,
                        icon: Icon(
                          running ? Icons.hourglass_top : Icons.play_arrow,
                          size: 20,
                        ),
                        label: Text(running ? 'Running…' : 'Run benchmark'),
                      ),
                      if (running) ...[
                        const SizedBox(width: 10),
                        Tooltip(
                          message:
                              'Stops at the next iteration boundary. A transfer '
                              'already on the wire finishes first — aborting it '
                              'would leave a byte count that means nothing.',
                          child: OutlinedButton.icon(
                            onPressed: stopping ? null : controller.cancel,
                            icon: const Icon(
                              Icons.stop_circle_outlined,
                              size: 20,
                            ),
                            label: Text(stopping ? 'Stopping…' : 'Cancel'),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MetricTile(
                        label: 'Elapsed',
                        value: formatDuration(elapsed),
                        hint: 'Wall clock since the run started.',
                      ),
                      if (running && remaining != null) ...[
                        const SizedBox(width: 16),
                        MetricTile(
                          label: 'Remaining',
                          value: '~${formatDuration(remaining)}',
                          hint:
                              'Extrapolated from the scenario/client pairs that '
                              'have finished. Steps differ enormously in size, '
                              'so it only appears once two have landed and it '
                              'sharpens as the run goes on.',
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              if (running) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: overall,
                  // A determinate bar the moment the first pair starts: an
                  // indeterminate one for a run that can last minutes tells a
                  // reader nothing except that the app has not frozen.
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 8),
                if (progress == null)
                  Text(
                    'Starting…',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  Row(
                    children: [
                      // The step counter is the one part that must stay
                      // readable, so it keeps its intrinsic width and the
                      // scenario label ellipsises into whatever is left.
                      Expanded(
                        child: Row(
                          children: [
                            LibraryChip(
                              library: progress.library,
                              selected: true,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                progress.scenario,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                progress.total > 0
                                    ? '${progress.completed} / '
                                          '${progress.total} iterations'
                                    : 'single transfer',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'step ${progress.step} of ${progress.stepCount}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
              ] else if (!ready)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    baseUrl.value.isEmpty
                        ? 'Waiting for the demo server to come up.'
                        : 'Select at least one client.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Picks the dispatch mode and explains what it measures.
class ExecutionPicker extends StatelessWidget {
  /// Creates a picker driving [controller].
  const ExecutionPicker({required this.controller, super.key});

  /// The screen's controller.
  final BenchmarkController controller;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final mode = controller.execution.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<BenchmarkExecution>(
              segments: [
                for (final option in BenchmarkExecution.values)
                  ButtonSegment<BenchmarkExecution>(
                    value: option,
                    label: Text(option.label),
                  ),
              ],
              selected: <BenchmarkExecution>{mode},
              // The selected segment is already tinted, and the check icon
              // costs the ~24 px per segment that decides whether three labels
              // fit the setup column at its narrowest.
              showSelectedIcon: false,
              onSelectionChanged: (Set<BenchmarkExecution> selection) =>
                  controller.execution.value = selection.first,
            ),
            const SizedBox(height: 8),
            Text(
              mode.description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'All three run on one Dart isolate — they change how many '
              'requests are in flight, not how many threads Dart uses. The two '
              'native engines do their transfers on their own OS threads, which '
              'is exactly what concurrent dispatch exposes.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            IntKnob(
              label: 'Concurrency limit',
              value: controller.concurrency,
              bounds: BenchmarkBounds.concurrency,
              step: 4,
              enabled: mode == BenchmarkExecution.concurrent,
              disabledReason:
                  'Only concurrent dispatch has a limit to apply: serial is '
                  'always one, parallel is always all of them.',
            ),
          ],
        );
      },
    );
  }
}

/// A bounded integer control: a slider, fine-step buttons, and the reason the
/// range stops where it does.
class IntKnob extends StatelessWidget {
  /// Creates a knob over [value].
  const IntKnob({
    required this.label,
    required this.value,
    required this.bounds,
    this.step = 1,
    this.suffix = '',
    this.enabled = true,
    this.disabledReason,
    super.key,
  });

  /// The caption.
  final String label;

  /// The signal this control writes.
  final Signal<int> value;

  /// The accepted range.
  final Bounds bounds;

  /// How much the `−`/`+` buttons move.
  final int step;

  /// A unit shown after the number, such as `MiB`.
  final String suffix;

  /// Whether the control accepts input.
  final bool enabled;

  /// Shown instead of [Bounds.why] when [enabled] is false.
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SignalBuilder(
      builder: (BuildContext context) {
        final current = bounds.clamp(value.value);
        void set(int next) => value.value = bounds.clamp(next);

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: enabled
                            ? null
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    suffix.isEmpty ? '$current' : '$current $suffix',
                    style: codeStyle(context, size: 13),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: enabled && current > bounds.min
                        ? () => set(current - step)
                        : null,
                    icon: const Icon(Icons.remove),
                    tooltip: 'Down $step',
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: Slider(
                      value: current.toDouble(),
                      min: bounds.min.toDouble(),
                      max: bounds.max.toDouble(),
                      // Divisions only where they help: 5000 of them is a
                      // continuous slider with extra snapping work.
                      divisions: (bounds.max - bounds.min) <= 256
                          ? bounds.max - bounds.min
                          : null,
                      onChanged: enabled
                          ? (double raw) => set(raw.round())
                          : null,
                    ),
                  ),
                  IconButton(
                    onPressed: enabled && current < bounds.max
                        ? () => set(current + step)
                        : null,
                    icon: const Icon(Icons.add),
                    tooltip: 'Up $step',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              Text(
                enabled ? bounds.why : (disabledReason ?? bounds.why),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Chooses which clients take part.
class LibraryPicker extends StatelessWidget {
  /// Creates a picker driving [controller].
  const LibraryPicker({required this.controller, super.key});

  /// The screen's controller.
  final BenchmarkController controller;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final selected = controller.libraries.value;
        final last = selected.length == 1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final library in HttpLibrary.values)
                  FilterChip(
                    selected: selected.contains(library),
                    avatar: Icon(
                      library.native ? Icons.memory : Icons.code,
                      size: 16,
                    ),
                    label: Text(library.label),
                    tooltip: library.native
                        ? 'Needs a native library in the process; reports '
                              'unsupported when it is missing'
                        : 'Pure Dart',
                    onSelected:
                        last && selected.contains(library)
                        ? null
                        : (bool _) => controller.toggleLibrary(library),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              last
                  ? 'The last client cannot be removed — a run with none is a '
                        'blank table, not a shorter one.'
                  : 'Dropping a client drops its rows and its share of the '
                        'wall clock.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

/// Turns the console's current request into a sixth scenario.
class ConsoleRequestSwitch extends StatelessWidget {
  /// Creates the toggle driving [controller].
  const ConsoleRequestSwitch({required this.controller, super.key});

  /// The screen's controller.
  final BenchmarkController controller;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final spec = requestDraft.spec.value;
        final base = baseUrl.value;
        final sendable = base.isNotEmpty && spec.isSendable(baseUrl: base);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: sendable && controller.includeConsoleRequest.value,
              onChanged: sendable
                  ? (bool on) => controller.includeConsoleRequest.value = on
                  : null,
              title: const Text('Also measure the console request'),
              subtitle: Text(
                sendable
                    ? describeSpec(spec)
                    : 'The console needs a method and a resolvable URL before '
                          'its request can be measured.',
              ),
            ),
            Text(
              'Runs whatever the console currently holds — any verb, any body, '
              'any headers — through every selected client, at the iteration '
              'count and dispatch mode above. Unlike the built-in scenarios it '
              'goes through the shared sender seam, so its absolute numbers '
              'carry a little uniform overhead; the comparison between clients '
              'is unaffected.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}
