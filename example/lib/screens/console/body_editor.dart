/// The Body tab: one editor per [RequestBodyKind], and the content-type override
/// that applies to all of them.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import '../../core/http_sender.dart';
import '../../core/request_spec.dart';
import '../../theme/app_theme.dart';
import '../../widgets/http_bits.dart';
import 'console_bits.dart';
import 'key_value_editor.dart';

/// The payload editor.
class BodyEditor extends StatelessWidget {
  /// Creates the editor for the client described by [capabilities].
  const BodyEditor({required this.capabilities, super.key});

  /// What the selected client can carry.
  final SenderCapabilities capabilities;

  /// The default content type each kind implies, shown as the override's
  /// placeholder so it is obvious what you are replacing.
  static String? _impliedContentType(RequestBodyKind kind) => switch (kind) {
    RequestBodyKind.none => null,
    RequestBodyKind.text => 'text/plain; charset=utf-8',
    RequestBodyKind.json => 'application/json',
    RequestBodyKind.form => 'application/x-www-form-urlencoded',
    RequestBodyKind.multipart => 'multipart/form-data',
    RequestBodyKind.file => 'application/octet-stream',
    RequestBodyKind.generatedBytes => 'application/octet-stream',
  };

  bool _supports(RequestBodyKind kind) =>
      kind != RequestBodyKind.multipart || capabilities.multipart;

  @override
  Widget build(BuildContext context) {
    final draft = requestDraft;
    return SignalBuilder(
      builder: (BuildContext context) {
        final kind = draft.bodyKind.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const EditorHeading('Body kind'),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final option in RequestBodyKind.values)
                  ChoiceChip(
                    label: Text(option.label),
                    selected: option == kind,
                    onSelected: _supports(option)
                        ? (bool _) => draft.bodyKind.value = option
                        : null,
                    tooltip: _supports(option)
                        ? null
                        : capabilities.noteFor('multipart'),
                  ),
              ],
            ),
            const SizedBox(height: Gap.lg),
            switch (kind) {
              RequestBodyKind.none => const _NoBody(),
              RequestBodyKind.text => const _TextBody(json: false),
              RequestBodyKind.json => const _TextBody(json: true),
              RequestBodyKind.form => const _FormBody(),
              RequestBodyKind.multipart => const _MultipartBody(),
              RequestBodyKind.file => _FileBody(capabilities: capabilities),
              RequestBodyKind.generatedBytes => const _GeneratedBody(),
            },
            if (kind.hasPayload) ...[
              const SizedBox(height: Gap.xl),
              // Multipart is the one kind whose content type is not ours to
              // set: the header carries the boundary the client generated, so
              // overriding it produces a body no server can parse.
              EditorHeading(
                'Content type',
                trailing: kind == RequestBodyKind.multipart
                    ? UnsupportedBadge(
                        note: capabilities.noteFor('contentTypeOverride'),
                      )
                    : null,
              ),
              SignalBuilder(
                builder: (BuildContext context) => SignalTextField(
                  read: () => draft.contentTypeOverride.value ?? '',
                  write: (String value) => draft.contentTypeOverride.value =
                      value.trim().isEmpty ? null : value,
                  enabled: kind != RequestBodyKind.multipart,
                  labelText: 'Override',
                  hintText: _impliedContentType(kind),
                  helperText: kind == RequestBodyKind.multipart
                      ? capabilities.noteFor('contentTypeOverride') ??
                            'A multipart content type carries the generated '
                                'boundary, so it cannot be overridden.'
                      : 'Leave empty to send the type this body kind implies.',
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _NoBody extends StatelessWidget {
  const _NoBody();

  @override
  Widget build(BuildContext context) => const EmptyHint(
    icon: Icons.horizontal_rule,
    title: 'No request body',
    detail:
        'What GET, HEAD and most DELETEs want. Pick another kind above to '
        'attach a payload.',
  );
}

/// The text and JSON editors.
///
/// One widget for both because the only difference is validation, and a JSON
/// editor that silently accepts broken JSON is the failure mode worth avoiding.
class _TextBody extends StatelessWidget {
  const _TextBody({required this.json});

  final bool json;

  /// The parse error, or null when the text is valid or empty.
  static String? _jsonProblem(String text) {
    if (text.trim().isEmpty) return null;
    try {
      jsonDecode(text);
      return null;
    } on FormatException catch (error) {
      final at = error.offset;
      return at == null ? error.message : '${error.message} (at offset $at)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = requestDraft;
    final theme = Theme.of(context);
    return SignalBuilder(
      builder: (BuildContext context) {
        final text = draft.bodyText.value;
        final problem = json ? _jsonProblem(text) : null;
        final valid = json && problem == null && text.trim().isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EditorHeading(
              json ? 'JSON' : 'Text',
              trailing: json
                  ? TextButton.icon(
                      onPressed: valid
                          ? () => draft.bodyText.value = const JsonEncoder
                                .withIndent('  ').convert(jsonDecode(text))
                          : null,
                      icon: const Icon(Icons.format_align_left, size: 18),
                      label: const Text('Format'),
                    )
                  : null,
            ),
            SignalTextField(
              read: () => draft.bodyText.value,
              write: (String value) => draft.bodyText.value = value,
              hintText: json ? '{\n  "key": "value"\n}' : 'Anything at all.',
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
            ),
            if (json) ...[
              const SizedBox(height: Gap.sm),
              Row(
                children: [
                  Icon(
                    problem == null
                        ? (valid ? Icons.check_circle_outline : Icons.circle_outlined)
                        : Icons.error_outline,
                    size: 16,
                    color: problem == null
                        ? paletteOf(context).success
                        : theme.colorScheme.error,
                  ),
                  const SizedBox(width: Gap.xs + 2),
                  Expanded(
                    child: Text(
                      problem ??
                          (valid
                              ? 'Valid JSON · ${text.length} characters'
                              : 'Empty — nothing will be sent as the body.'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: problem == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _FormBody extends StatelessWidget {
  const _FormBody();

  @override
  Widget build(BuildContext context) => KeyValueEditor(
    rows: requestDraft.formFields,
    title: 'Form fields',
    nameHint: 'field',
    emptyTitle: 'No form fields',
    emptyDetail:
        'Rows here are URL-encoded into the body, the way an HTML form posts.',
  );
}

class _MultipartBody extends StatelessWidget {
  const _MultipartBody();

  @override
  Widget build(BuildContext context) {
    final parts = requestDraft.parts;
    return SignalBuilder(
      builder: (BuildContext context) {
        final current = parts.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EditorHeading(
              'Parts',
              trailing: TextButton.icon(
                onPressed: () =>
                    parts.add(MultipartPart(field: 'field${current.length + 1}')),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add part'),
              ),
            ),
            if (current.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.lg),
                child: EmptyHint(
                  icon: Icons.attachment,
                  title: 'No parts yet',
                  detail:
                      'A multipart body is a list of named parts, each either a '
                      'value or a file. Add one to get started.',
                ),
              )
            else
              for (var index = 0; index < current.length; index++)
                _PartTile(parts: parts, index: index),
          ],
        );
      },
    );
  }
}

class _PartTile extends StatelessWidget {
  const _PartTile({required this.parts, required this.index});

  final ListSignal<MultipartPart> parts;
  final int index;

  MultipartPart? get _part {
    final current = parts.value;
    return index < current.length ? current[index] : null;
  }

  void _update(MultipartPart Function(MultipartPart part) change) {
    final part = _part;
    if (part == null) return;
    parts[index] = change(part);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SignalBuilder(
      builder: (BuildContext context) {
        final part = _part;
        if (part == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: Gap.md),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: part.enabled,
                    onChanged: (bool? next) => _update(
                      (MultipartPart p) => p.copyWith(enabled: next ?? false),
                    ),
                  ),
                  Expanded(
                    child: SignalTextField(
                      read: () => _part?.field ?? '',
                      write: (String value) => _update(
                        (MultipartPart p) => p.copyWith(field: value),
                      ),
                      hintText: 'part name',
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove this part',
                    onPressed: () => parts.removeAt(index),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: Gap.sm),
              SegmentedButton<bool>(
                segments: const <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    label: Text('Value'),
                    icon: Icon(Icons.text_fields, size: 16),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text('File'),
                    icon: Icon(Icons.insert_drive_file_outlined, size: 16),
                  ),
                ],
                selected: <bool>{part.isFile},
                showSelectedIcon: false,
                onSelectionChanged: (Set<bool> selection) => _update(
                  // `copyWith` cannot clear a nullable field, so switching back to
                  // a value part rebuilds the record rather than copying it.
                  (MultipartPart p) => selection.first
                      ? p.copyWith(filePath: '')
                      : MultipartPart(
                          field: p.field,
                          value: p.value,
                          contentType: p.contentType,
                          enabled: p.enabled,
                        ),
                ),
              ),
              const SizedBox(height: Gap.sm),
              if (part.filePath != null)
                SignalTextField(
                  read: () => _part?.filePath ?? '',
                  write: (String value) => _update(
                    (MultipartPart p) => p.copyWith(filePath: value),
                  ),
                  labelText: 'File path',
                  hintText: '/tmp/payload.bin',
                )
              else
                SignalTextField(
                  read: () => _part?.value ?? '',
                  write: (String value) =>
                      _update((MultipartPart p) => p.copyWith(value: value)),
                  labelText: 'Value',
                  minLines: 1,
                  maxLines: 4,
                ),
              const SizedBox(height: Gap.sm),
              SignalTextField(
                read: () => _part?.contentType ?? '',
                write: (String value) => _update(
                  (MultipartPart p) => value.trim().isEmpty
                      ? MultipartPart(
                          field: p.field,
                          value: p.value,
                          filePath: p.filePath,
                          enabled: p.enabled,
                        )
                      : p.copyWith(contentType: value),
                ),
                labelText: 'Part content type',
                hintText: 'left to the client',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The file-body editor.
///
/// There is no file picker plugin in this app, so the path is typed — and
/// because a typed path is useless on a phone, the editor can also write a
/// throwaway file of a chosen size into the OS temp directory and point at that.
/// That is what makes "stream a 64 MiB upload from disk" testable on a device.
class _FileBody extends StatefulWidget {
  const _FileBody({required this.capabilities});

  final SenderCapabilities capabilities;

  @override
  State<_FileBody> createState() => _FileBodyState();
}

class _FileBodyState extends State<_FileBody> {
  final _status = signal<String?>(
    null,
    options: const SignalOptions<String?>(name: 'console.tempFileStatus'),
  );
  final _busy = signal<bool>(
    false,
    options: const SignalOptions<bool>(name: 'console.tempFileBusy'),
  );

  @override
  void dispose() {
    _status.dispose();
    _busy.dispose();
    super.dispose();
  }

  Future<void> _makeTempFile(int bytes) async {
    if (_busy.value) return;
    batch(() {
      _busy.value = true;
      _status.value = null;
    });
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/console-body-$bytes.bin');
      await file.writeAsBytes(Uint8List(bytes), flush: true);
      batch(() {
        requestDraft.filePath.value = file.path;
        _status.value = 'Wrote ${formatBytes(bytes)} to ${file.path}';
      });
    } on Object catch (error) {
      _status.value = 'Could not write the file: $error';
    } finally {
      _busy.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final streams = widget.capabilities.fileBodyWithoutHeap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const EditorHeading('File'),
        SignalTextField(
          read: () => requestDraft.filePath.value ?? '',
          write: (String value) => requestDraft.filePath.value =
              value.trim().isEmpty ? null : value,
          labelText: 'Path on disk',
          hintText: '/tmp/payload.bin',
          prefixIcon: const Icon(Icons.folder_open, size: 18),
        ),
        const SizedBox(height: Gap.md),
        SignalBuilder(
          builder: (BuildContext context) => Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'No file picker in this demo — make one:',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              for (final size in const <int>[
                64 * 1024,
                1024 * 1024,
                16 * 1024 * 1024,
              ])
                ActionChip(
                  label: Text(formatBytes(size)),
                  onPressed: _busy.value ? null : () => _makeTempFile(size),
                ),
              if (_busy.value)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        SignalBuilder(
          builder: (BuildContext context) {
            final status = _status.value;
            if (status == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(status, style: codeStyle(context, size: 11)),
            );
          },
        ),
        const SizedBox(height: Gap.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              streams ? Icons.bolt : Icons.info_outline,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                streams
                    ? 'This client streams the file straight off disk; the '
                          'bytes never enter the Dart heap.'
                    : widget.capabilities.noteFor('fileBodyWithoutHeap') ??
                          'This client reads the whole file into the Dart heap '
                              'before sending it, so a large file costs memory.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _GeneratedBody extends StatelessWidget {
  const _GeneratedBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = requestDraft.generatedByteCount;
    return SignalBuilder(
      builder: (BuildContext context) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const EditorHeading('Generated bytes'),
            SignalTextField(
              read: () => '${size.value}',
              write: (String value) {
                final parsed = parseByteSize(value);
                if (parsed != null) size.value = parsed;
              },
              labelText: 'Size',
              hintText: '1 MiB, 512k, or 1048576',
              helperText:
                  'Currently ${formatBytes(size.value)}. Units are binary: '
                  '1k is 1024 bytes. Capped at 1 GiB.',
            ),
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final preset in const <int>[
                  16 * 1024,
                  256 * 1024,
                  1024 * 1024,
                  8 * 1024 * 1024,
                  64 * 1024 * 1024,
                ])
                  ChoiceChip(
                    label: Text(formatBytes(preset)),
                    selected: size.value == preset,
                    onSelected: (bool _) => size.value = preset,
                  ),
              ],
            ),
            const SizedBox(height: Gap.md),
            Text(
              'Synthesised in memory rather than read from disk, so an upload '
              'measurement times the transfer instead of the filesystem.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}
