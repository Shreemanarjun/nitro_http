/// The row editor behind the Params and Headers tabs.
///
/// One widget for both, because a query parameter and a header are the same
/// three fields — enabled, name, value — and giving them two editors would mean
/// two sets of bugs.
library;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import '../../core/request_spec.dart';
import '../../theme/app_theme.dart';
import '../../widgets/http_bits.dart';
import 'console_bits.dart';

/// A name/value pair offered from the "add a common one" menu.
typedef RowPreset = ({String name, String value});

/// An add/remove/reorder editor over a list signal of [KeyValueRow].
///
/// Mutation goes through the list's own methods — `add`, `removeAt`, `[]=` —
/// never through reassignment. `ListSignal` compares deeply, so
/// `rows.value = [...rows.value]` is a no-op that would silently stop the UI from
/// updating; in-place mutation is the only thing that notifies.
class KeyValueEditor extends StatelessWidget {
  /// Creates an editor over [rows].
  const KeyValueEditor({
    required this.rows,
    required this.title,
    required this.emptyTitle,
    required this.emptyDetail,
    this.nameHint = 'name',
    this.valueHint = 'value',
    this.presets = const <RowPreset>[],
    this.enabled = true,
    super.key,
  });

  /// The rows being edited.
  final ListSignal<KeyValueRow> rows;

  /// The group heading.
  final String title;

  /// Headline for the empty state.
  final String emptyTitle;

  /// What to do about the empty state.
  final String emptyDetail;

  /// Placeholder in the name column.
  final String nameHint;

  /// Placeholder in the value column.
  final String valueHint;

  /// Common rows offered from a menu, so nobody types `Content-Type` again.
  final List<RowPreset> presets;

  /// Whether the editor accepts input at all.
  final bool enabled;

  void _add([RowPreset? preset]) {
    rows.add(
      KeyValueRow(name: preset?.name ?? '', value: preset?.value ?? ''),
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    // `onReorderItem` hands over the destination already corrected for the
    // removal, unlike the deprecated `onReorder` which needed the caller to
    // subtract one when dragging downwards.
    if (newIndex == oldIndex) return;
    batch(() {
      final moved = rows.removeAt(oldIndex);
      rows.insert(newIndex, moved);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final current = rows.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EditorHeading(
              title,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (presets.isNotEmpty)
                    PopupMenuButton<RowPreset>(
                      enabled: enabled,
                      tooltip: 'Add a common $nameHint',
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      onSelected: _add,
                      itemBuilder: (BuildContext context) => <
                        PopupMenuEntry<RowPreset>
                      >[
                        for (final preset in presets)
                          PopupMenuItem<RowPreset>(
                            value: preset,
                            child: Text(
                              preset.value.isEmpty
                                  ? preset.name
                                  : '${preset.name}: ${preset.value}',
                              style: codeStyle(context),
                            ),
                          ),
                      ],
                    ),
                  if (current.isNotEmpty)
                    IconButton(
                      tooltip: 'Remove every row',
                      onPressed: enabled ? rows.clear : null,
                      icon: const Icon(Icons.playlist_remove, size: 18),
                    ),
                  TextButton.icon(
                    onPressed: enabled ? _add : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
            ),
            if (current.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.lg),
                child: EmptyHint(
                  icon: Icons.playlist_add,
                  title: emptyTitle,
                  detail: emptyDetail,
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: current.length,
                onReorderItem: _reorder,
                itemBuilder: (BuildContext context, int index) => _RowTile(
                  key: ValueKey<int>(index),
                  rows: rows,
                  index: index,
                  nameHint: nameHint,
                  valueHint: valueHint,
                  enabled: enabled,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({
    required this.rows,
    required this.index,
    required this.nameHint,
    required this.valueHint,
    required this.enabled,
    super.key,
  });

  final ListSignal<KeyValueRow> rows;
  final int index;
  final String nameHint;
  final String valueHint;
  final bool enabled;

  /// This row, or null when it has just been removed.
  ///
  /// The removal case is real: a bound field's effect can run a microtask before
  /// the widget is disposed, and an out-of-range read there would throw inside a
  /// signal effect rather than anywhere a stack trace would help.
  KeyValueRow? get _row {
    final current = rows.value;
    return index < current.length ? current[index] : null;
  }

  void _update(KeyValueRow Function(KeyValueRow row) change) {
    final row = _row;
    if (row == null) return;
    rows[index] = change(row);
  }

  @override
  Widget build(BuildContext context) {
    final drag = ReorderableDragStartListener(
      index: index,
      enabled: enabled,
      child: Tooltip(
        message: 'Drag to reorder',
        child: Icon(
          Icons.drag_indicator,
          size: 18,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
    final toggle = SignalBuilder(
      builder: (BuildContext context) => Checkbox(
        value: _row?.enabled ?? false,
        onChanged: enabled
            ? (bool? next) =>
                  _update((KeyValueRow row) => row.copyWith(enabled: next ?? false))
            : null,
      ),
    );
    final name = SignalTextField(
      read: () => _row?.name ?? '',
      write: (String value) =>
          _update((KeyValueRow row) => row.copyWith(name: value)),
      hintText: nameHint,
      enabled: enabled,
    );
    final value = SignalTextField(
      read: () => _row?.value ?? '',
      write: (String text) =>
          _update((KeyValueRow row) => row.copyWith(value: text)),
      hintText: valueHint,
      enabled: enabled,
    );
    final remove = IconButton(
      tooltip: 'Remove this row',
      onPressed: enabled && index < rows.value.length
          ? () => rows.removeAt(index)
          : null,
      icon: const Icon(Icons.close, size: 18),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Two fields, a checkbox, a drag handle and a delete button do not fit
          // across a phone without each field becoming a six-character slot, so
          // below this width the pair stacks instead.
          if (constraints.maxWidth < 460) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Gap.md),
                  child: drag,
                ),
                toggle,
                Expanded(
                  child: Column(
                    children: [name, const SizedBox(height: Gap.sm), value],
                  ),
                ),
                remove,
              ],
            );
          }
          return Row(
            children: [
              drag,
              toggle,
              Expanded(flex: 4, child: name),
              const SizedBox(width: Gap.sm),
              Expanded(flex: 6, child: value),
              remove,
            ],
          );
        },
      ),
    );
  }
}
