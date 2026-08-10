/// The response inspector.
///
/// A failed send is rendered here as a first-class result rather than as a
/// snackbar or an exception dump: "connection refused after 1.2 ms" is a finding,
/// and comparing what five clients say about the same failure is half the point
/// of this app.
library;


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import '../../core/senders/sender_registry.dart';
import '../../core/sent_response.dart';
import '../../theme/app_theme.dart';
import '../../widgets/http_bits.dart';
import '../../widgets/panels.dart';
import 'console_bits.dart';
import 'console_controller.dart';
import 'example_requests.dart';

/// How much of a body is rendered before the view stops and says so.
///
/// A megabyte of JSON in a `SelectableText` janks the frame that builds it and
/// every frame that scrolls it. The cap is generous enough to read and small
/// enough to stay smooth; the byte count above always reports the whole thing.
const int _renderedBodyLimit = 200 * 1024;

/// How many bytes of a binary body get a hex preview.
const int _hexPreviewLimit = 1024;

/// The response side of the console.
class ResponsePane extends StatelessWidget {
  /// Creates the pane.
  const ResponsePane({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (BuildContext context) {
        final outcome = lastOutcome.value;
        return switch (outcome) {
          null => const _NoResponseYet(),
          SentResponse response => _ResponseDetail(response: response),
          FailedSend failure => _FailureDetail(failure: failure),
        };
      },
    );
  }
}

class _NoResponseYet extends StatelessWidget {
  const _NoResponseYet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConsolePane(
      header: const PaneTitle(
        title: 'Response',
        subtitle: 'Nothing sent yet',
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const EmptyHint(
              icon: Icons.bolt_outlined,
              title: 'No response yet',
              detail:
                  'Press Send — ⌘↵ on macOS, Ctrl+↵ elsewhere — or start from '
                  'one of these, which all hit the in-process demo server.',
            ),
            const SizedBox(height: Gap.md),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final example in exampleRequests.where(
                  (ExampleRequest e) => e.quick,
                ))
                  Tooltip(
                    message: example.blurb,
                    child: ActionChip(
                      label: Text(example.label),
                      onPressed: () => requestDraft.load(example.spec),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Gap.xl),
            Text(
              'Whatever you send here goes through the client picked in the bar '
              'above. Switching clients re-sends the same request object, which '
              'is the only way to compare them fairly.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResponseDetail extends StatelessWidget {
  const _ResponseDetail({required this.response});

  final SentResponse response;

  @override
  Widget build(BuildContext context) {
    final console = ConsoleScope.of(context);
    return ConsolePane(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
            child: _MetricStrip(response: response),
          ),
          SignalBuilder(
            builder: (BuildContext context) => SegmentBar<ResponseView>(
              values: ResponseView.values,
              selected: console.responseView.value,
              labelOf: (ResponseView view) => view.label,
              badgeOf: (ResponseView view) => switch (view) {
                ResponseView.headers => '${response.headers.length}',
                ResponseView.extras => response.extras.isEmpty
                    ? null
                    : '${response.extras.length}',
                _ => null,
              },
              onSelected: (ResponseView view) =>
                  console.responseView.value = view,
            ),
          ),
        ],
      ),
      child: SignalBuilder(
        builder: (BuildContext context) => switch (console.responseView.value) {
          ResponseView.pretty => _BodyView(
            response: response,
            pretty: true,
          ),
          ResponseView.raw => _BodyView(response: response, pretty: false),
          ResponseView.headers => _HeadersView(response: response),
          ResponseView.timings => _TimingsView(response: response),
          ResponseView.extras => _ExtrasView(response: response),
        },
      ),
    );
  }
}

/// The one-line summary every response gets.
///
/// One scrolling row rather than a `Wrap`, because this sits in a pane header
/// above an `Expanded` body: a header that reflows onto five lines at a large
/// text scale eats the body's height and overflows the pane. Scrolling sideways
/// keeps the header one line tall whatever the text size.
class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.response});

  final SentResponse response;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: Gap.lg,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
        StatusPill(
          statusCode: response.statusCode,
          reasonPhrase: response.reasonPhrase,
        ),
        MetricTile(
          label: 'Time',
          value: formatDuration(response.timings.total),
          hint: 'Wall time from send to the last byte',
        ),
        MetricTile(
          label: 'Size',
          value: formatBytes(response.byteCount),
          hint: response.contentType ?? 'No content type header',
        ),
        MetricTile(
          label: 'Protocol',
          value: response.httpVersion ?? '—',
          hint: response.httpVersion == null
              ? 'This client does not report the negotiated protocol'
              : null,
        ),
        if (response.redirectCount > 0)
          MetricTile(
            label: 'Redirects',
            value: '${response.redirectCount}',
            hint: response.finalUrl,
          ),
        if (response.fromCache)
          const MetricTile(
            label: 'Cache',
            value: 'hit',
            hint: 'Served from the client disk cache, not the network',
          ),
          LibraryChip(library: response.library, selected: true),
        ],
      ),
    );
  }
}

/// Pretty and Raw, which differ only in whether JSON gets re-indented.
class _BodyView extends StatelessWidget {
  const _BodyView({required this.response, required this.pretty});

  final SentResponse response;
  final bool pretty;

  @override
  Widget build(BuildContext context) {
    if (response.byteCount == 0) {
      return const EmptyHint(
        icon: Icons.check_circle_outline,
        title: 'Empty body',
        detail: 'Normal for HEAD, 204 and 304 responses.',
      );
    }
    if (!response.looksTextual) {
      return _BinaryBody(response: response);
    }
    final full = pretty ? response.prettyBody : response.bodyText;
    final clipped = full.length > _renderedBodyLimit;
    final shown = clipped ? full.substring(0, _renderedBodyLimit) : full;
    return _ScrollableText(
      text: shown,
      footer: clipped
          ? 'Showing the first ${formatBytes(_renderedBodyLimit)} of '
                '${formatBytes(response.byteCount)}. Copy takes the whole body.'
          : null,
      onCopy: () => _copy(context, full),
    );
  }
}

/// The affordance for a body that is not text.
///
/// A hex preview rather than a shrug: it is enough to recognise a PNG header or
/// a zeroed test payload, which is usually the whole question.
class _BinaryBody extends StatelessWidget {
  const _BinaryBody({required this.response});

  final SentResponse response;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _hexDump(response.bodyBytes, _hexPreviewLimit);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.data_object,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  'Binary body · ${formatBytes(response.byteCount)} · '
                  '${response.contentType ?? 'no content type'}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.md),
          Text(
            'Not rendered as text. The first '
            '${formatBytes(response.byteCount < _hexPreviewLimit ? response.byteCount : _hexPreviewLimit)} '
            'in hex:',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Gap.sm),
          CodeBlock(text: preview, maxHeight: 320),
        ],
      ),
    );
  }
}

class _HeadersView extends StatelessWidget {
  const _HeadersView({required this.response});

  final SentResponse response;

  @override
  Widget build(BuildContext context) {
    if (response.headers.isEmpty) {
      return const EmptyHint(
        icon: Icons.list_alt,
        title: 'No response headers',
        detail: 'Unusual — most clients synthesise at least a content length.',
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _copy(
                context,
                <String>[
                  for (final header in response.headers)
                    '${header.name}: ${header.value}',
                ].join('\n'),
              ),
              icon: const Icon(Icons.copy_all, size: 16),
              label: const Text('Copy all'),
            ),
          ),
          KeyValueTable(
            rows: <(String, String)>[
              for (final header in response.headers)
                (header.name, header.value),
            ],
          ),
        ],
      ),
    );
  }
}

/// The phase breakdown, and an honest note when there is not one.
class _TimingsView extends StatelessWidget {
  const _TimingsView({required this.response});

  final SentResponse response;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timings = response.timings;
    final phases = <(String, Duration?)>[
      ('DNS', timings.dns),
      ('Connect', timings.connect),
      ('TLS', timings.tls),
      ('First byte', timings.firstByte),
    ];
    final hasPhases = phases.any(((String, Duration?) row) => row.$2 != null);
    final capabilities = capabilitiesFor(response.library);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const EditorHeading('Phases'),
          if (hasPhases)
            _PhaseBars(phases: phases, total: timings.total)
          else
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      capabilities.noteFor('phaseTimings') ??
                          '${response.library.label} reports total elapsed time '
                              'only. Of the five clients here, nitro_http is the '
                              'one that reports DNS, connect, TLS and '
                              'time-to-first-byte separately.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: Gap.lg),
          const EditorHeading('Measured'),
          KeyValueTable(
            rows: <(String, String)>[
              for (final (label, value) in phases) (label, formatDuration(value)),
              ('Total', formatDuration(timings.total)),
            ],
          ),
        ],
      ),
    );
  }
}

/// A proportional bar per phase, because four numbers in a column hide which one
/// dominated and a bar does not.
class _PhaseBars extends StatelessWidget {
  const _PhaseBars({required this.phases, required this.total});

  final List<(String, Duration?)> phases;
  final Duration total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final micros = total.inMicroseconds == 0 ? 1 : total.inMicroseconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in phases)
          if (value != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(label, style: codeStyle(context, size: 11)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (value.inMicroseconds / micros).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  SizedBox(
                    width: 84,
                    child: Text(
                      formatDuration(value),
                      textAlign: TextAlign.right,
                      style: codeStyle(context, size: 11),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

class _ExtrasView extends StatelessWidget {
  const _ExtrasView({required this.response});

  final SentResponse response;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      if (response.finalUrl != null) ('final url', response.finalUrl!),
      ('redirects', '${response.redirectCount}'),
      ('from cache', response.fromCache ? 'yes' : 'no'),
      ('client', response.library.label),
      ('request', '${response.spec.method} ${response.spec.url}'),
      for (final entry in response.extras.entries) (entry.key, entry.value),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueTable(rows: rows),
          if (response.extras.isEmpty) ...[
            const SizedBox(height: Gap.lg),
            Text(
              'This client reported nothing beyond the shared fields. Anything a '
              'single library knows and the others do not shows up here.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A failed send, rendered as a result.
class _FailureDetail extends StatelessWidget {
  const _FailureDetail({required this.failure});

  final FailedSend failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paletteOf(context);
    final detail = failure.failure;
    final (background, foreground) = switch (detail.kind) {
      SendFailureKind.cancelled => (palette.neutral, palette.onNeutral),
      SendFailureKind.unsupported => (palette.clientError, palette.onClientError),
      SendFailureKind.timeout => (palette.clientError, palette.onClientError),
      SendFailureKind.connection ||
      SendFailureKind.certificate ||
      SendFailureKind.unknown => (palette.serverError, palette.onServerError),
    };
    return ConsolePane(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.md),
        // Same reason as the success strip: a pane header must not reflow into
        // the body's height when the text scale goes up.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: Gap.lg,
            children: [
              Pill(
                text: detail.kind.label,
                background: background,
                foreground: foreground,
                icon: Icons.error_outline,
              ),
              MetricTile(
                label: 'Failed after',
                value: formatDuration(detail.elapsed),
              ),
              LibraryChip(library: failure.library, selected: true),
            ],
          ),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'No response arrived',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              'The message below is the client\'s own, not a paraphrase — '
              'comparing the wording across clients is often the fastest way to '
              'work out what actually went wrong.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Gap.md),
            CodeBlock(text: detail.message, maxHeight: 260),
            const SizedBox(height: Gap.lg),
            const EditorHeading('Request'),
            KeyValueTable(
              rows: <(String, String)>[
                ('method', failure.spec.method),
                ('url', failure.spec.url),
                ('body', failure.spec.bodyKind.label),
                ('client', failure.library.label),
              ],
            ),
            if (failure.library.native &&
                detail.kind != SendFailureKind.cancelled) ...[
              const SizedBox(height: Gap.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.memory,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      '${failure.library.label} needs a native library in the '
                      'process. On a machine where that engine has not been '
                      'built, every send through it fails here rather than on '
                      'the network.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A monospace body view with a copy action and an optional truncation footer.
class _ScrollableText extends StatelessWidget {
  const _ScrollableText({required this.text, required this.onCopy, this.footer});

  final String text;
  final String? footer;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Gap.lg),
              child: SelectableText(text, style: codeStyle(context)),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.sm, Gap.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  footer ?? '',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

void _copy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text('Copied ${text.length} characters to the clipboard'),
      behavior: SnackBarBehavior.floating,
      width: 320,
    ),
  );
}

/// Classic `offset  hex  ascii` dump of the first [limit] bytes.
String _hexDump(Uint8List bytes, int limit) {
  final count = bytes.length < limit ? bytes.length : limit;
  final buffer = StringBuffer();
  for (var offset = 0; offset < count; offset += 16) {
    final end = offset + 16 < count ? offset + 16 : count;
    buffer.write(offset.toRadixString(16).padLeft(8, '0'));
    buffer.write('  ');
    for (var i = offset; i < offset + 16; i++) {
      buffer.write(
        i < end ? bytes[i].toRadixString(16).padLeft(2, '0') : '  ',
      );
      buffer.write(i == offset + 7 ? '  ' : ' ');
    }
    buffer.write(' ');
    for (var i = offset; i < end; i++) {
      final byte = bytes[i];
      buffer.writeCharCode(byte >= 0x20 && byte < 0x7f ? byte : 0x2e);
    }
    buffer.writeln();
  }
  return buffer.toString();
}
