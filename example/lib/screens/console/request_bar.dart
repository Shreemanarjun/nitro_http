/// The always-visible top bar: verb, URL, client, Send.
///
/// It stays out of the pane layout entirely, because the one thing that must not
/// move when the window narrows is the control you press a hundred times an hour.
library;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import '../../core/http_library.dart';
import '../../core/senders/sender_registry.dart';
import '../../theme/app_theme.dart';
import '../../widgets/http_bits.dart';
import 'console_bits.dart';
import 'console_controller.dart';

/// The request bar.
class RequestBar extends StatelessWidget {
  /// Creates the bar.
  const RequestBar({super.key});

  @override
  Widget build(BuildContext context) {
    final console = ConsoleScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final stacked = constraints.maxWidth < 720;
              const method = _MethodField();
              const url = _UrlField();
              const library = _LibraryPicker();
              final send = _SendControls(console: console);
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(flex: 4, child: method),
                        const SizedBox(width: Gap.sm),
                        const Flexible(flex: 5, child: library),
                      ],
                    ),
                    const SizedBox(height: Gap.sm),
                    url,
                    const SizedBox(height: Gap.sm),
                    send,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Flexible(flex: 2, child: method),
                  const SizedBox(width: Gap.sm),
                  const Expanded(flex: 9, child: url),
                  const SizedBox(width: Gap.sm),
                  // A `Row` hands a non-flex child unbounded width, and the
                  // picker is an `InputDecorator`, which refuses to lay out
                  // without a bound. Loose flex gives it a ceiling and still
                  // lets it size to its label.
                  const Flexible(flex: 3, child: library),
                  const SizedBox(width: Gap.sm),
                  send,
                ],
              );
            },
          ),
          _TransferStrip(console: console),
        ],
      ),
    );
  }
}

/// The verb field: free text, with the common verbs one tap away.
///
/// A free string rather than a dropdown because `PROPFIND`, `PURGE` and
/// `MKCALENDAR` are real, and a console that cannot type one is a console that
/// cannot reproduce the bug you are chasing.
class _MethodField extends StatelessWidget {
  const _MethodField();

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final capabilities = capabilitiesFor(selectedLibrary.value);
        final method = requestDraft.method.value.trim().toUpperCase();
        final rejected =
            !capabilities.customMethods &&
            method.isNotEmpty &&
            !standardMethods.contains(method);
        return SignalTextField(
          read: () => requestDraft.method.value,
          write: (String value) => requestDraft.method.value = value,
          labelText: 'Method',
          inputFormatters: upperCaseVerb,
          textInputAction: TextInputAction.next,
          errorText: rejected ? capabilities.noteFor('customMethods') : null,
          suffixIcon: PopupMenuButton<String>(
            tooltip: 'Common verbs',
            icon: const Icon(Icons.arrow_drop_down),
            onSelected: (String verb) => requestDraft.method.value = verb,
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              for (final verb in const <String>[
                'GET',
                'HEAD',
                'POST',
                'PUT',
                'PATCH',
                'DELETE',
                'OPTIONS',
                'TRACE',
                'PROPFIND',
              ])
                PopupMenuItem<String>(
                  value: verb,
                  child: Row(
                    children: [
                      MethodPill(method: verb),
                      if (!capabilities.customMethods &&
                          !standardMethods.contains(verb)) ...[
                        const SizedBox(width: Gap.sm),
                        UnsupportedBadge(
                          note: capabilities.noteFor('customMethods'),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The URL field, which accepts a bare path.
///
/// The helper line always shows what will actually be requested, including the
/// query rows folded in — the difference between `/echo` and
/// `http://127.0.0.1:53219/echo?q=nitro` is exactly the thing people get wrong.
class _UrlField extends StatelessWidget {
  const _UrlField();

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final base = baseUrl.value;
        final spec = requestDraft.spec.value;
        final resolved = spec.resolve(baseUrl: base);
        final typed = spec.url.trim();
        final String helper;
        if (base.isEmpty) {
          helper = 'Waiting for the demo server to start…';
        } else if (typed.isEmpty) {
          helper = 'A path such as /echo resolves against $base';
        } else if (resolved == null) {
          helper = 'Not a URL yet';
        } else {
          helper = resolved.toString();
        }
        return SignalTextField(
          read: () => requestDraft.url.value,
          write: (String value) => requestDraft.url.value = value,
          labelText: 'URL or path',
          hintText: '/echo',
          helperText: helper,
          errorText: typed.isNotEmpty && resolved == null && base.isNotEmpty
              ? 'Absolute URLs need a host; anything else is a path on the '
                    'demo server.'
              : null,
          textInputAction: TextInputAction.done,
        );
      },
    );
  }
}

/// Switches the client every send goes through.
class _LibraryPicker extends StatelessWidget {
  const _LibraryPicker();

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final current = selectedLibrary.value;
        return PopupMenuButton<HttpLibrary>(
          tooltip: 'Send through a different client',
          position: PopupMenuPosition.under,
          onSelected: (HttpLibrary next) => selectedLibrary.value = next,
          itemBuilder: (BuildContext context) => <PopupMenuEntry<HttpLibrary>>[
            for (final option in HttpLibrary.values)
              PopupMenuItem<HttpLibrary>(
                value: option,
                child: Row(
                  children: [
                    Flexible(
                      child: LibraryChip(
                        library: option,
                        selected: option == current,
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    if (option == current) const Icon(Icons.check, size: 16),
                  ],
                ),
              ),
          ],
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Client',
              contentPadding: EdgeInsets.symmetric(
                horizontal: Gap.md,
                vertical: Gap.sm,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The client names run to eighteen characters and the picker is
                // the first thing a narrow layout squeezes. Scaling down beats
                // both an overflow stripe and an ellipsis that hides which
                // client is selected.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: LibraryChip(library: current, selected: true),
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Send, and the cancel affordance that replaces nothing while a send is in
/// flight.
class _SendControls extends StatelessWidget {
  const _SendControls({required this.console});

  final ConsoleController console;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final sending = isSending.value;
        final reason = sendBlockedReason(
          spec: requestDraft.spec.value,
          baseUrl: baseUrl.value,
          capabilities: capabilitiesFor(selectedLibrary.value),
        );
        final blocked = reason != null;
        final send = Tooltip(
          message: blocked
              ? reason
              : 'Send this request  ·  ⌘↵ on macOS, Ctrl+↵ elsewhere',
          child: FilledButton.icon(
            onPressed: blocked || sending ? null : console.send,
            icon: sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, size: 18),
            label: Text(sending ? 'Sending' : 'Send'),
          ),
        );
        if (!sending) return send;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            send,
            const SizedBox(width: Gap.sm),
            Tooltip(
              message:
                  'Ask the client to abort. Clients that cannot stop mid-'
                  'transfer will finish anyway and report the result.',
              child: OutlinedButton.icon(
                onPressed: console.cancelSend,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Cancel'),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The progress line, present only while bytes are moving.
class _TransferStrip extends StatelessWidget {
  const _TransferStrip({required this.console});

  final ConsoleController console;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SignalBuilder(
      builder: (BuildContext context) {
        if (!isSending.value) return const SizedBox.shrink();
        final sample = console.progress.value;
        final total = sample?.receiveTotal;
        final fraction = sample == null || total == null || total <= 0
            ? null
            : (sample.received / total).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: fraction, minHeight: 4),
              ),
              const SizedBox(height: Gap.xs),
              Text(
                sample == null
                    ? 'Waiting for the first byte…'
                    : 'sent ${formatBytes(sample.sent)}'
                          '${sample.sendTotal != null ? ' / ${formatBytes(sample.sendTotal)}' : ''}'
                          '   ·   received ${formatBytes(sample.received)}'
                          '${total != null ? ' / ${formatBytes(total)}' : ''}',
                style: codeStyle(context, size: 11).copyWith(
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
