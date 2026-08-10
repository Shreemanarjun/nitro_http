/// The console's own small widgets: the pieces that appear in more than one of
/// its panes but are too console-specific to belong in `widgets/http_bits.dart`.
///
/// Everything here takes its colour and metrics from the theme. If a value looks
/// hardcoded it is a layout constant (a gutter, a column width), never a colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../theme/app_theme.dart';

/// The console's spacing rhythm, in logical pixels.
///
/// Four steps on a 4 px grid, named rather than sprinkled, so a reviewer can see
/// at a glance that a gap is deliberate and not somebody's 7.
abstract final class Gap {
  /// Between a label and the thing it labels.
  static const double xs = 4;

  /// Between controls in a row.
  static const double sm = 8;

  /// Between rows in a group.
  static const double md = 12;

  /// Between groups.
  static const double lg = 16;

  /// Around a pane's content.
  static const double xl = 24;
}

/// A pane: a fixed header over a body that fills whatever height is left.
///
/// The console is three of these side by side, and they all scroll internally
/// rather than growing, which is what keeps the layout stable when a response
/// body turns out to be a megabyte of JSON.
class ConsolePane extends StatelessWidget {
  /// Creates a pane titled by [header] around [child].
  const ConsolePane({required this.header, required this.child, super.key});

  /// The pane's fixed top strip.
  final Widget header;

  /// The scrollable content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [header, const Divider(height: 1), Expanded(child: child)],
      ),
    );
  }
}

/// A pane's title strip: a name, a line of context, and optional actions.
class PaneTitle extends StatelessWidget {
  /// Creates a title strip.
  const PaneTitle({
    required this.title,
    this.subtitle,
    this.trailing,
    super.key,
  });

  /// The pane name.
  final String title;

  /// One line of context under it.
  final String? subtitle;

  /// Actions pinned to the right.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.sm, Gap.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A horizontally scrollable tab strip.
///
/// Not a `TabBar`: this one is driven by a signal rather than a `TabController`,
/// keeps its selection when the pane is rebuilt into a different layout, and
/// scrolls instead of squeezing when five tabs meet a 380 px window.
class SegmentBar<T> extends StatelessWidget {
  /// Creates a strip over [values].
  const SegmentBar({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.badgeOf,
    this.trailing,
    super.key,
  });

  /// Every choice, in display order.
  final List<T> values;

  /// The active choice.
  final T selected;

  /// The title for a choice.
  final String Function(T value) labelOf;

  /// Called with the tapped choice.
  final void Function(T value) onSelected;

  /// An optional count shown beside a title, for "Headers 3".
  final String? Function(T value)? badgeOf;

  /// Optional actions pinned to the right of the strip.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final strip = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in values)
            _Segment(
              label: labelOf(value),
              badge: badgeOf?.call(value),
              selected: value == selected,
              onTap: () => onSelected(value),
            ),
        ],
      ),
    );
    final actions = trailing;
    if (actions == null) return strip;
    return Row(
      children: [
        Expanded(child: strip),
        Padding(
          padding: const EdgeInsets.only(right: Gap.sm),
          child: actions,
        ),
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.badge,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: selected ? scheme.primary : Colors.transparent,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Gap.md,
              Gap.md,
              Gap.md,
              Gap.md - 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: Gap.xs + 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      badge!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The badge shown next to a control the selected client cannot honour.
///
/// The tooltip carries the client's own explanation from
/// `SenderCapabilities.noteFor`, because "unsupported" on its own reads as a bug
/// in the app rather than a property of the library.
class UnsupportedBadge extends StatelessWidget {
  /// Creates a badge explaining itself with [note].
  const UnsupportedBadge({required this.note, super.key});

  /// The capability note, or null when the client gave no reason.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: note ?? 'The selected client does not support this.',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.do_not_disturb_on_outlined,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Gap.xs),
          Text(
            'unsupported',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// One labelled setting: a name, an optional explanation, and its control.
///
/// Stacks below 460 px rather than letting a label and a dropdown fight over the
/// same 200 px, which is what breaks a settings list on a phone.
class SettingRow extends StatelessWidget {
  /// Creates a row.
  const SettingRow({
    required this.label,
    required this.control,
    this.description,
    this.supported = true,
    this.note,
    this.caveat,
    super.key,
  });

  /// The setting's name.
  final String label;

  /// What it does, in one line.
  final String? description;

  /// The control itself, already disabled when [supported] is false.
  final Widget control;

  /// Whether the selected client honours this setting.
  final bool supported;

  /// The client's explanation, shown when [supported] is false.
  final String? note;

  /// A caveat that applies even though the control still works.
  ///
  /// Distinct from [note], which explains a control that is switched off. Some
  /// clients honour half of a setting — advertising `Accept-Encoding: identity`
  /// and then decoding the response anyway — and half-honoured is neither
  /// "supported" nor "unsupported".
  final String? caveat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: supported
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (!supported) ...[
              const SizedBox(width: Gap.sm),
              UnsupportedBadge(note: note),
            ],
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: 2),
          Text(
            description!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (caveat != null) ...[
          const SizedBox(height: Gap.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 14,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: Gap.xs + 2),
              Expanded(
                child: Text(
                  caveat!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
    final gated = supported
        ? control
        : Tooltip(
            message: note ?? 'The selected client does not support this.',
            child: control,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < 460) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: Gap.sm),
                Align(alignment: Alignment.centerLeft, child: gated),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: title),
              const SizedBox(width: Gap.lg),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Align(alignment: Alignment.centerRight, child: gated),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A heading inside a scrolling editor, above a group of related controls.
class EditorHeading extends StatelessWidget {
  /// Creates a heading reading [text].
  const EditorHeading(this.text, {this.trailing, super.key});

  /// The heading.
  final String text;

  /// An optional action pinned to the right.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A text field bound to signals in both directions.
///
/// [read] is called inside an `effect`, so it may read any number of signals and
/// the field will follow all of them — that is how loading a request out of the
/// history refills eighteen fields at once.
///
/// The loop that this shape avoids: comparing the incoming value against the
/// controller's text would fight any [write] that is lossy — a size field that
/// parses `""` to "no change" would snap back to the old number on the first
/// backspace. Comparing against the last value *this field* produced instead
/// means an unchanged signal never touches the cursor, and a genuinely external
/// change always does.
class SignalTextField extends StatefulWidget {
  /// Creates a bound field.
  const SignalTextField({
    required this.read,
    required this.write,
    this.labelText,
    this.hintText,
    this.helperText,
    this.errorText,
    this.prefixIcon,
    this.suffixText,
    this.suffixIcon,
    this.enabled = true,
    this.monospace = true,
    this.minLines,
    this.maxLines = 1,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.onSubmitted,
    super.key,
  });

  /// Reads the value to display. Tracked, so it may read signals.
  final String Function() read;

  /// Called on every keystroke with the field's text.
  final void Function(String value) write;

  /// The floating label.
  final String? labelText;

  /// Placeholder text.
  final String? hintText;

  /// A line of guidance below the field.
  final String? helperText;

  /// A problem with the current text; colours the field.
  final String? errorText;

  /// A leading glyph.
  final Widget? prefixIcon;

  /// A unit or hint pinned to the right inside the field.
  final String? suffixText;

  /// A trailing control inside the field.
  final Widget? suffixIcon;

  /// Whether the field accepts input.
  final bool enabled;

  /// Whether to render the text monospaced. False for prose-ish fields.
  final bool monospace;

  /// Minimum visible lines.
  final int? minLines;

  /// Maximum visible lines; null grows without bound.
  final int? maxLines;

  /// The soft keyboard type.
  final TextInputType? keyboardType;

  /// Input filters, for numeric or upper-case-only fields.
  final List<TextInputFormatter>? inputFormatters;

  /// The action key's meaning.
  final TextInputAction? textInputAction;

  /// Called when the action key is pressed.
  final ValueChanged<String>? onSubmitted;

  @override
  State<SignalTextField> createState() => _SignalTextFieldState();
}

class _SignalTextFieldState extends State<SignalTextField> {
  late final TextEditingController _controller;
  late final EffectCleanup _stopSync;
  late String _lastWritten;

  @override
  void initState() {
    super.initState();
    _lastWritten = widget.read();
    _controller = TextEditingController(text: _lastWritten);
    _stopSync = effect(() {
      final next = widget.read();
      if (next == _lastWritten) return;
      _lastWritten = next;
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }, options: const EffectOptions(name: 'console.fieldSync'));
  }

  @override
  void dispose() {
    _stopSync();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _lastWritten = value;
    widget.write(value);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      enabled: widget.enabled,
      onChanged: _onChanged,
      onSubmitted: widget.onSubmitted,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      textInputAction: widget.textInputAction,
      style: widget.monospace ? codeStyle(context, size: 13) : null,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        helperText: widget.helperText,
        helperMaxLines: 3,
        errorText: widget.errorText,
        errorMaxLines: 3,
        prefixIcon: widget.prefixIcon,
        suffixText: widget.suffixText,
        suffixIcon: widget.suffixIcon,
      ),
    );
  }
}

/// Parses a human-written byte size such as `1 MiB`, `512k` or `1048576`.
///
/// Binary multipliers throughout, including for a bare `k` or `MB`: this is a
/// transfer-size field in a developer tool, where 1 MB meaning 1 000 000 would be
/// a surprise rather than a standards win. Returns null when the text is not a
/// size, which is what lets the field show an error instead of guessing.
int? parseByteSize(String input) {
  final text = input.trim().toLowerCase().replaceAll(',', '');
  if (text.isEmpty) return null;
  final match = RegExp(
    r'^([0-9]+(?:\.[0-9]+)?)\s*(b|k|kb|kib|m|mb|mib|g|gb|gib)?$',
  ).firstMatch(text);
  if (match == null) return null;
  final amount = double.tryParse(match.group(1)!);
  if (amount == null || amount < 0) return null;
  final multiplier = switch (match.group(2)) {
    null || 'b' => 1,
    'k' || 'kb' || 'kib' => 1024,
    'm' || 'mb' || 'mib' => 1024 * 1024,
    _ => 1024 * 1024 * 1024,
  };
  final bytes = amount * multiplier;
  if (bytes > 1024 * 1024 * 1024) return null;
  return bytes.round();
}

/// Only digits, for numeric fields.
final List<TextInputFormatter> digitsOnly = <TextInputFormatter>[
  FilteringTextInputFormatter.digitsOnly,
];

/// Upper-cases as you type, for the method field.
final List<TextInputFormatter> upperCaseVerb = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp('[A-Za-z-]')),
  TextInputFormatter.withFunction(
    (TextEditingValue previous, TextEditingValue next) =>
        next.copyWith(text: next.text.toUpperCase()),
  ),
];
