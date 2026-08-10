/// The request side of the console: four editors behind one tab strip.
library;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import '../../core/request_spec.dart';
import '../../core/senders/sender_registry.dart';
import 'body_editor.dart';
import 'console_bits.dart';
import 'console_controller.dart';
import 'example_requests.dart';
import 'key_value_editor.dart';
import 'settings_editor.dart';

/// Headers people type over and over, offered from a menu instead.
const List<RowPreset> _headerPresets = <RowPreset>[
  (name: 'Accept', value: 'application/json'),
  (name: 'Content-Type', value: 'application/json'),
  (name: 'Authorization', value: 'Bearer '),
  (name: 'User-Agent', value: 'nitro_http-console/1.0'),
  (name: 'X-Request-Id', value: 'console-1'),
  (name: 'Cache-Control', value: 'no-cache'),
];

/// The request editor pane.
class RequestEditorPane extends StatelessWidget {
  /// Creates the pane.
  const RequestEditorPane({super.key});

  /// The count or label shown beside a tab title.
  ///
  /// Read inside the header's `SignalBuilder`, so the strip refreshes when the
  /// thing it counts changes — which is what makes a row added on the Params tab
  /// visible while you are looking at Settings.
  static String? _badge(EditorTab tab) {
    switch (tab) {
      case EditorTab.params:
        final enabled = requestDraft.query.value
            .where((KeyValueRow row) => row.isUsable)
            .length;
        return enabled == 0 ? null : '$enabled';
      case EditorTab.headers:
        final enabled = requestDraft.headers.value
            .where((KeyValueRow row) => row.isUsable)
            .length;
        return enabled == 0 ? null : '$enabled';
      case EditorTab.body:
        final kind = requestDraft.bodyKind.value;
        return kind == RequestBodyKind.none ? null : kind.label;
      case EditorTab.settings:
        // Only non-defaults are worth a badge: a "6" that never changes is
        // decoration, a "1" that appears when you set a timeout is information.
        final changed = <bool>[
          requestDraft.responseMode.value != ResponseMode.buffered,
          !requestDraft.followRedirects.value,
          requestDraft.connectTimeout.value != null,
          requestDraft.totalTimeout.value != null,
          !requestDraft.sendCookies.value,
          !requestDraft.acceptEncoding.value,
        ].where((bool flag) => flag).length;
        return changed == 0 ? null : '$changed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final console = ConsoleScope.of(context);
    return ConsolePane(
      header: SignalBuilder(
        builder: (BuildContext context) => SegmentBar<EditorTab>(
          values: EditorTab.values,
          selected: console.editorTab.value,
          labelOf: (EditorTab tab) => tab.label,
          badgeOf: _badge,
          onSelected: (EditorTab tab) => console.editorTab.value = tab,
          trailing: const _ExamplesMenu(),
        ),
      ),
      child: SignalBuilder(
        builder: (BuildContext context) {
          final library = selectedLibrary.value;
          final capabilities = capabilitiesFor(library);
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Gap.lg),
              child: switch (console.editorTab.value) {
                EditorTab.params => KeyValueEditor(
                  rows: requestDraft.query,
                  title: 'Query parameters',
                  emptyTitle: 'No query parameters',
                  emptyDetail:
                      'Rows here are appended to the URL. The bar above always '
                      'shows the address they produce.',
                ),
                EditorTab.headers => KeyValueEditor(
                  rows: requestDraft.headers,
                  title: 'Request headers',
                  nameHint: 'header',
                  emptyTitle: 'No headers of your own',
                  emptyDetail:
                      'The client still sends its defaults. A row here replaces '
                      'the default of the same name.',
                  presets: _headerPresets,
                ),
                EditorTab.body => BodyEditor(capabilities: capabilities),
                EditorTab.settings => SettingsEditor(
                  library: library,
                  capabilities: capabilities,
                ),
              },
            ),
          );
        },
      ),
    );
  }
}

/// Loads a ready-made request into the draft.
class _ExamplesMenu extends StatelessWidget {
  const _ExamplesMenu();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<ExampleRequest>(
      tooltip: 'Load an example request',
      position: PopupMenuPosition.under,
      onSelected: (ExampleRequest example) => requestDraft.load(example.spec),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<ExampleRequest>>[
        for (final example in exampleRequests)
          PopupMenuItem<ExampleRequest>(
            value: example,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(example.label, style: theme.textTheme.bodyMedium),
                  Text(
                    example.blurb,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.sm,
          vertical: Gap.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome_motion_outlined, size: 16),
            // On a phone the tab strip and this button share one line, and the
            // tabs are the thing you reach for constantly. The label goes first.
            if (MediaQuery.sizeOf(context).width >= 500) ...[
              const SizedBox(width: Gap.xs + 2),
              Text('Examples', style: theme.textTheme.labelLarge),
            ],
          ],
        ),
      ),
    );
  }
}
