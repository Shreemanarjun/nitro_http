/// Past sends, newest first.
///
/// The list is the app's `history` signal rather than a private copy, so the
/// benchmark and the console agree on what has been run. Tapping an entry loads
/// the request that produced it back into the draft — the fastest way to re-run
/// the same call through a different client, which is the comparison this whole
/// app exists to make.
library;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import '../../core/sent_response.dart';
import '../../theme/app_theme.dart';
import '../../widgets/http_bits.dart';
import 'console_bits.dart';

/// The history list.
class HistoryPane extends StatelessWidget {
  /// Creates the pane. [onReplay] fires after an entry is loaded, so a narrow
  /// layout can move the user to the request it just filled in, and [onCollapse]
  /// closes the rail on a wide one.
  const HistoryPane({this.onReplay, this.onCollapse, super.key});

  /// Called once an entry has been loaded into the draft.
  final VoidCallback? onReplay;

  /// Called by the collapse button; omit it to hide the button.
  final VoidCallback? onCollapse;

  void _replay(SendOutcome outcome) {
    // One batch, three writes: the draft, the client it ran on, and the result
    // shown beside it. Anything less and you would be looking at one request's
    // fields next to another request's response.
    batch(() {
      requestDraft.load(outcome.spec);
      selectedLibrary.value = outcome.library;
      lastOutcome.value = outcome;
    });
    onReplay?.call();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final entries = history.value;
        return ConsolePane(
          header: PaneTitle(
            title: 'History',
            subtitle: entries.isEmpty
                ? 'Nothing sent yet'
                : '${entries.length} of the last $historyLimit',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entries.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear the history',
                    onPressed: history.clear,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  ),
                if (onCollapse != null)
                  IconButton(
                    tooltip: 'Collapse the history rail',
                    onPressed: onCollapse,
                    icon: const Icon(Icons.chevron_left, size: 18),
                  ),
              ],
            ),
          ),
          child: entries.isEmpty
              ? const EmptyHint(
                  icon: Icons.history,
                  title: 'No sends yet',
                  detail:
                      'Every request you send lands here. Tap one to load it '
                      'back into the editor.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  itemCount: entries.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) =>
                      _HistoryTile(
                        outcome: entries[index],
                        onTap: () => _replay(entries[index]),
                      ),
                ),
        );
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.outcome, required this.onTap});

  final SendOutcome outcome;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteOf(context);
    final (Widget result, String elapsed) = switch (outcome) {
      SentResponse response => (
        StatusPill(statusCode: response.statusCode),
        formatDuration(response.timings.total),
      ),
      FailedSend failed => (
        Pill(
          text: failed.failure.kind.label,
          background: palette.serverError,
          foreground: palette.onServerError,
          icon: Icons.error_outline,
          tooltip: failed.failure.message,
        ),
        formatDuration(failed.failure.elapsed),
      ),
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MethodPill(method: outcome.spec.method),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    outcome.spec.url.isEmpty ? '(no url)' : outcome.spec.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: codeStyle(context, size: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Row(
              children: [
                result,
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    outcome.library.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(elapsed, style: codeStyle(context, size: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
