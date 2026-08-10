/// The request console: compose any request, send it through any of the five
/// clients, and read what came back.
///
/// ## Layout
///
/// One bar and three panes. Above roughly 900 px the panes are columns —
/// history, request, response — with a draggable divider between the two that
/// matter, because comparing an editor against its result is the whole job and
/// scrolling between them is not comparing. Below that they become destinations:
/// a phone that shows two half-panes shows two unusable panes.
///
/// Nothing here has a fixed height. Every pane bounds its own content and
/// scrolls internally, so a 200 % text scale makes the console taller to read
/// rather than clipping the third line of a helper string.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import 'console_bits.dart';
import 'console_controller.dart';
import 'history_pane.dart';
import 'request_bar.dart';
import 'request_editor.dart';
import 'response_pane.dart';

/// Below this width the panes stop being columns and become destinations.
const double _stackBelow = 900;

/// Above this width the history rail starts out open, unless it has been
/// toggled.
const double _historyOpensAbove = 1280;

/// The narrowest a pane may be dragged.
const double _minPaneWidth = 320;

/// The console screen.
///
/// Const-constructible and argument-free so the app shell can mount it as one of
/// its tabs; everything it needs comes from the app-wide signals in
/// `core/app_state.dart`.
class RequestConsoleScreen extends StatelessWidget {
  /// Creates the console.
  const RequestConsoleScreen({super.key});

  @override
  Widget build(BuildContext context) => const _Console();
}

class _Console extends StatefulWidget {
  const _Console();

  @override
  State<_Console> createState() => _ConsoleState();
}

class _ConsoleState extends State<_Console> {
  final ConsoleController _console = ConsoleController();

  @override
  void dispose() {
    _console.dispose();
    super.dispose();
  }

  void _sendShortcut() => unawaited(_console.send());

  @override
  Widget build(BuildContext context) {
    return ConsoleScope(
      controller: _console,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          // Both modifiers, both Enters: ⌘↵ is the macOS idiom, Ctrl+↵ the one
          // everywhere else, and a numpad Enter is still an Enter.
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              _sendShortcut,
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              _sendShortcut,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
              _sendShortcut,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
              _sendShortcut,
        },
        // A shortcut only fires when the focus chain passes through it, so the
        // console owns a focus node of its own. `skipTraversal` keeps it out of
        // the Tab order: it is a listener, not a control.
        child: Focus(
          autofocus: true,
          skipTraversal: true,
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: Column(
              children: [
                const RequestBar(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Gap.md,
                      0,
                      Gap.md,
                      Gap.md,
                    ),
                    child: LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) =>
                              constraints.maxWidth < _stackBelow
                              ? _StackedPanes(console: _console)
                              : _SideBySidePanes(
                                  console: _console,
                                  width: constraints.maxWidth,
                                ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The wide layout: history, request and response as columns.
class _SideBySidePanes extends StatelessWidget {
  const _SideBySidePanes({required this.console, required this.width});

  final ConsoleController console;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final historyOpen =
            console.historyPinned.value ?? (width >= _historyOpensAbove);
        final railWidth = historyOpen ? 268.0 : 52.0;
        final content = width - railWidth - Gap.sm - Gap.md;
        final splittable = content - _minPaneWidth * 2 > 0;
        final double editorWidth = splittable
            ? (content * console.splitFraction.value)
                  .clamp(_minPaneWidth, content - _minPaneWidth)
                  .toDouble()
            : content / 2;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: railWidth,
              child: historyOpen
                  ? HistoryPane(
                      onCollapse: () => console.historyPinned.value = false,
                    )
                  : _CollapsedHistoryRail(
                      onExpand: () => console.historyPinned.value = true,
                    ),
            ),
            const SizedBox(width: Gap.sm),
            SizedBox(
              width: editorWidth,
              child: const RequestEditorPane(),
            ),
            _SplitHandle(
              enabled: splittable,
              onDrag: (double delta) => console.splitFraction.value =
                  ((editorWidth + delta) / content).clamp(0.2, 0.8),
            ),
            const Expanded(child: ResponsePane()),
          ],
        );
      },
    );
  }
}

/// The narrow layout: one pane at a time, chosen from a strip.
class _StackedPanes extends StatelessWidget {
  const _StackedPanes({required this.console});

  final ConsoleController console;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final pane = console.narrowPane.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentBar<NarrowPane>(
              values: NarrowPane.values,
              selected: pane,
              labelOf: (NarrowPane value) => value.label,
              badgeOf: (NarrowPane value) => switch (value) {
                NarrowPane.history => history.value.isEmpty
                    ? null
                    : '${history.value.length}',
                NarrowPane.response => lastOutcome.value == null ? null : '1',
                NarrowPane.request => null,
              },
              onSelected: (NarrowPane value) => console.narrowPane.value = value,
            ),
            const SizedBox(height: Gap.sm),
            Expanded(
              child: switch (pane) {
                NarrowPane.request => const RequestEditorPane(),
                NarrowPane.response => const ResponsePane(),
                NarrowPane.history => HistoryPane(
                  // Loading a request only helps if you can then see it, and on
                  // a phone the editor is a different screen.
                  onReplay: () =>
                      console.narrowPane.value = NarrowPane.request,
                ),
              },
            ),
          ],
        );
      },
    );
  }
}

/// The history rail when it is closed: an icon, a count, and a way back.
class _CollapsedHistoryRail extends StatelessWidget {
  const _CollapsedHistoryRail({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: SignalBuilder(
        builder: (BuildContext context) {
          final count = history.value.length;
          return Column(
            children: [
              IconButton(
                tooltip: 'Show the history',
                onPressed: onExpand,
                icon: const Icon(Icons.history),
              ),
              if (count > 0)
                Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The draggable divider between the request and response panes.
class _SplitHandle extends StatelessWidget {
  const _SplitHandle({required this.onDrag, required this.enabled});

  final void Function(double delta) onDrag;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = Center(
      child: Container(
        width: 3,
        height: 42,
        decoration: BoxDecoration(
          color: scheme.outlineVariant,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
    if (!enabled) return SizedBox(width: Gap.md, child: line);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            onDrag(details.delta.dx),
        child: Semantics(
          label: 'Resize the request and response panes',
          child: SizedBox(width: Gap.md, child: line),
        ),
      ),
    );
  }
}
