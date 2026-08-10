/// Small HTTP-specific display atoms shared by the console and the benchmark.
///
/// They exist because both screens independently need to render a status code, a
/// verb, a library name, a duration and a byte count, and five slightly different
/// versions of each is how a UI stops looking designed. Everything here draws its
/// colour from `HttpPalette` and its type from the theme, so restyling happens in
/// one place.
library;

import 'package:flutter/material.dart';

import '../core/http_library.dart';
import '../theme/app_theme.dart';

/// A rounded label with a semantic background.
class Pill extends StatelessWidget {
  /// Creates a pill.
  const Pill({
    required this.text,
    required this.background,
    required this.foreground,
    this.icon,
    this.tooltip,
    super.key,
  });

  /// The label.
  final String text;

  /// The fill colour.
  final Color background;

  /// The text and icon colour.
  final Color foreground;

  /// An optional leading icon.
  final IconData? icon;

  /// An optional tooltip.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    final message = tooltip;
    return message == null ? child : Tooltip(message: message, child: child);
  }
}

/// An HTTP status code, coloured by class.
class StatusPill extends StatelessWidget {
  /// Creates a status pill.
  const StatusPill({required this.statusCode, this.reasonPhrase = '', super.key});

  /// The code.
  final int statusCode;

  /// The reason phrase, appended when the server sent one.
  final String reasonPhrase;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = paletteOf(context).forStatus(statusCode);
    final label = reasonPhrase.isEmpty
        ? '$statusCode'
        : '$statusCode $reasonPhrase';
    return Pill(
      text: label,
      background: bg,
      foreground: fg,
      tooltip: reasonPhrase.isEmpty
          // Not an error, and worth saying: HTTP/2 removed the reason phrase from
          // the protocol, so its absence is normal rather than missing data.
          ? 'No reason phrase — HTTP/2 and HTTP/3 removed it from the wire'
          : null,
    );
  }
}

/// An HTTP verb, coloured by whether it mutates.
class MethodPill extends StatelessWidget {
  /// Creates a method pill.
  const MethodPill({required this.method, super.key});

  /// The verb.
  final String method;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = paletteOf(context).forMethod(method);
    return Pill(text: method.toUpperCase(), background: bg, foreground: fg);
  }
}

/// A library name, with a marker when it needs a native library loaded.
class LibraryChip extends StatelessWidget {
  /// Creates a chip for [library].
  const LibraryChip({required this.library, this.selected = false, super.key});

  /// Which client.
  final HttpLibrary library;

  /// Whether to render it as the active choice.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pill(
      text: library.label,
      icon: library.native ? Icons.memory : Icons.code,
      background: selected ? scheme.primary : scheme.surfaceContainerHighest,
      foreground: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
      tooltip: library.native
          ? 'Needs a native library in the process'
          : 'Pure Dart',
    );
  }
}

/// Formats a duration the way a developer reads latency.
///
/// Sub-millisecond work is where the interesting differences live on loopback, so
/// microseconds are shown rather than rounded away to `0 ms`.
String formatDuration(Duration? d) {
  if (d == null) return '—';
  final us = d.inMicroseconds;
  if (us < 1000) return '$us µs';
  if (us < 100000) return '${(us / 1000).toStringAsFixed(2)} ms';
  if (us < 10000000) return '${(us / 1000).toStringAsFixed(0)} ms';
  return '${(us / 1000000).toStringAsFixed(2)} s';
}

/// Formats a byte count in binary units.
String formatBytes(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KiB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(2)} MiB';
  return '${(mib / 1024).toStringAsFixed(2)} GiB';
}

/// A label above a value, for dense metric strips.
class MetricTile extends StatelessWidget {
  /// Creates a metric.
  const MetricTile({required this.label, required this.value, this.hint, super.key});

  /// The caption.
  final String label;

  /// The value, rendered monospaced so columns line up.
  final String value;

  /// An optional tooltip.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 2),
        Text(value, style: codeStyle(context, size: 13)),
      ],
    );
    final message = hint;
    return message == null ? content : Tooltip(message: message, child: content);
  }
}

/// An empty state that says what to do next rather than just what is missing.
class EmptyHint extends StatelessWidget {
  /// Creates an empty state.
  const EmptyHint({required this.icon, required this.title, this.detail, super.key});

  /// A glyph.
  final IconData icon;

  /// The headline.
  final String title;

  /// An optional second line explaining the next action.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleSmall, textAlign: TextAlign.center),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
