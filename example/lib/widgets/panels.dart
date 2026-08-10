/// Small presentation widgets shared by every tab.
///
/// They live in their own library rather than in `main.dart` so a tab does not
/// have to import the app shell that imports it.
library;

import 'package:flutter/material.dart';

/// A titled card wrapping arbitrary content.
class SectionCard extends StatelessWidget {
  /// Creates a card titled [title] around [child].
  const SectionCard({required this.title, required this.child, this.trailing, super.key});

  /// The card heading.
  final String title;

  /// The card content.
  final Widget child;

  /// An optional widget pinned to the right of the heading, typically a button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// Renders a failed native call as a readable card.
///
/// The prebuilt engine binaries are not published yet, so on a machine without
/// them every first native call throws. A red screen would tell a reader
/// nothing; this says which call failed and why.
class EngineErrorCard extends StatelessWidget {
  /// Creates a card describing [error], raised while doing [action].
  const EngineErrorCard({required this.action, required this.error, this.onRetry, super.key});

  /// What the app was trying to do, in the imperative: `configure the cache`.
  final String action;

  /// The object that was thrown.
  final Object error;

  /// Invoked by the retry button; omit it to hide the button.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Could not $action',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
                if (onRetry != null)
                  TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              '$error',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: scheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The native engine is built from source by the plugin; a missing '
              'symbol here means the library was never linked into this build.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A two-column table of labels and values.
class KeyValueTable extends StatelessWidget {
  /// Creates a table over [rows], rendered in iteration order.
  const KeyValueTable({required this.rows, super.key});

  /// The `(label, value)` pairs to show.
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text('—', style: Theme.of(context).textTheme.bodySmall);
    }
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (final (label, value) in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 12, bottom: 2),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: SelectableText(
                  value,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// A bounded, scrollable, selectable monospace block for payloads.
class CodeBlock extends StatelessWidget {
  /// Creates a block showing [text], at most [maxHeight] logical pixels tall.
  const CodeBlock({required this.text, this.maxHeight = 220, super.key});

  /// The content to show.
  final String text;

  /// Height cap before the block starts scrolling.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text.isEmpty ? '(empty)' : text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

/// A compact on/off pill used for capability flags.
class CapabilityChip extends StatelessWidget {
  /// Creates a chip labelled [label] reflecting [enabled].
  const CapabilityChip({required this.label, required this.enabled, super.key});

  /// The capability name.
  final String label;

  /// Whether the engine reports it as available.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Chip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: Icon(
          enabled ? Icons.check_circle : Icons.remove_circle_outline,
          size: 16,
          color: enabled ? scheme.primary : scheme.outline,
        ),
        label: Text(label, style: const TextStyle(fontSize: 11)),
      ),
    );
  }
}
