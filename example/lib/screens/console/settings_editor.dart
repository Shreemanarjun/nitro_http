/// The Settings tab: everything about the transport rather than the message.
///
/// Every control here is paired with the selected client's declared capability.
/// When a client cannot honour a setting the control is genuinely disabled — not
/// hidden, not silently ignored — and carries the client's own explanation. A
/// hidden control teaches nothing; a dead one that looks alive is a bug report
/// waiting to happen.
library;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import '../../core/http_library.dart';
import '../../core/http_sender.dart';
import '../../core/request_spec.dart';
import '../../widgets/panels.dart';
import 'console_bits.dart';

/// The transport settings editor.
class SettingsEditor extends StatelessWidget {
  /// Creates the editor for [library], described by [capabilities].
  const SettingsEditor({
    required this.library,
    required this.capabilities,
    super.key,
  });

  /// The selected client.
  final HttpLibrary library;

  /// What it can honour.
  final SenderCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final draft = requestDraft;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const EditorHeading('Response'),
        SignalBuilder(
          builder: (BuildContext context) => SettingRow(
            label: 'Response mode',
            description: capabilities.streamedResponses
                ? 'Streaming reports progress as bytes arrive instead of '
                      'handing over one finished buffer.'
                : 'Only buffered responses are available here.',
            supported: capabilities.streamedResponses,
            note: capabilities.noteFor('streamedResponses'),
            control: SegmentedButton<ResponseMode>(
              segments: const <ButtonSegment<ResponseMode>>[
                ButtonSegment<ResponseMode>(
                  value: ResponseMode.buffered,
                  label: Text('Buffered'),
                ),
                ButtonSegment<ResponseMode>(
                  value: ResponseMode.streamed,
                  label: Text('Streamed'),
                ),
              ],
              selected: <ResponseMode>{draft.responseMode.value},
              showSelectedIcon: false,
              onSelectionChanged: capabilities.streamedResponses
                  ? (Set<ResponseMode> selection) =>
                        draft.responseMode.value = selection.first
                  : null,
            ),
          ),
        ),
        const Divider(height: Gap.xl),
        const EditorHeading('Redirects'),
        SignalBuilder(
          builder: (BuildContext context) {
            final follows = draft.followRedirects.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingRow(
                  label: 'Follow redirects',
                  description:
                      'Off means a 3xx is returned to you as the response.',
                  supported: capabilities.redirectPolicy,
                  note: capabilities.noteFor('redirectPolicy'),
                  control: Switch(
                    value: follows,
                    onChanged: capabilities.redirectPolicy
                        ? (bool next) => draft.followRedirects.value = next
                        : null,
                  ),
                ),
                SettingRow(
                  label: 'Redirect limit',
                  description: 'How many hops before the client gives up.',
                  supported: capabilities.redirectPolicy,
                  note: capabilities.noteFor('redirectPolicy'),
                  control: SizedBox(
                    width: 120,
                    child: SignalTextField(
                      read: () => '${draft.maxRedirects.value}',
                      write: (String value) {
                        final parsed = int.tryParse(value);
                        if (parsed != null) draft.maxRedirects.value = parsed;
                      },
                      enabled: capabilities.redirectPolicy && follows,
                      keyboardType: TextInputType.number,
                      inputFormatters: digitsOnly,
                      suffixText: 'hops',
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const Divider(height: Gap.xl),
        const EditorHeading('Timeouts'),
        SignalBuilder(
          builder: (BuildContext context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingRow(
                label: 'Connect timeout',
                description:
                    'Applies to name resolution, the TCP connect and the TLS '
                    'handshake. Empty means the client default.',
                supported: capabilities.perRequestConnectTimeout,
                note: capabilities.noteFor('perRequestConnectTimeout'),
                control: SizedBox(
                  width: 140,
                  child: SignalTextField(
                    read: () =>
                        draft.connectTimeout.value?.inMilliseconds.toString() ??
                        '',
                    write: (String value) => draft.connectTimeout.value =
                        _millis(value),
                    enabled: capabilities.perRequestConnectTimeout,
                    keyboardType: TextInputType.number,
                    inputFormatters: digitsOnly,
                    hintText: 'default',
                    suffixText: 'ms',
                  ),
                ),
              ),
              SettingRow(
                label: 'Total timeout',
                description:
                    'The whole request, body included. /slow/1500 is the route '
                    'to test it against.',
                supported: capabilities.perRequestTotalTimeout,
                note: capabilities.noteFor('perRequestTotalTimeout'),
                control: SizedBox(
                  width: 140,
                  child: SignalTextField(
                    read: () =>
                        draft.totalTimeout.value?.inMilliseconds.toString() ??
                        '',
                    write: (String value) => draft.totalTimeout.value =
                        _millis(value),
                    enabled: capabilities.perRequestTotalTimeout,
                    keyboardType: TextInputType.number,
                    inputFormatters: digitsOnly,
                    hintText: 'default',
                    suffixText: 'ms',
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: Gap.xl),
        const EditorHeading('Negotiation'),
        SignalBuilder(
          builder: (BuildContext context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingRow(
                label: 'Send cookies',
                description:
                    'Uses the client\'s jar: /setcookie then /readcookie shows '
                    'whether it kept them.',
                supported: capabilities.cookieJar,
                note: capabilities.noteFor('cookieJar'),
                control: Switch(
                  value: draft.sendCookies.value,
                  onChanged: capabilities.cookieJar
                      ? (bool next) => draft.sendCookies.value = next
                      : null,
                ),
              ),
              SettingRow(
                label: 'Accept compressed responses',
                description:
                    'Advertises Accept-Encoding and decodes what comes back. '
                    'Turn it off to see /gzip arrive compressed.',
                // Not a disabled control: three of the five clients send
                // `Accept-Encoding: identity` as asked and then decode the
                // response anyway. The switch does something, just not
                // everything, and saying so beats both silence and a grey-out.
                caveat: capabilities.noteFor('acceptEncoding'),
                control: Switch(
                  value: draft.acceptEncoding.value,
                  onChanged: (bool next) => draft.acceptEncoding.value = next,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: Gap.xl),
        EditorHeading('${library.label} capabilities'),
        Wrap(
          runSpacing: Gap.sm,
          children: [
            CapabilityChip(
              label: 'Custom verbs',
              enabled: capabilities.customMethods,
            ),
            CapabilityChip(
              label: 'Streaming',
              enabled: capabilities.streamedResponses,
            ),
            CapabilityChip(label: 'Multipart', enabled: capabilities.multipart),
            CapabilityChip(
              label: 'Zero-copy file body',
              enabled: capabilities.fileBodyWithoutHeap,
            ),
            CapabilityChip(
              label: 'Connect timeout',
              enabled: capabilities.perRequestConnectTimeout,
            ),
            CapabilityChip(
              label: 'Total timeout',
              enabled: capabilities.perRequestTotalTimeout,
            ),
            CapabilityChip(
              label: 'Redirect policy',
              enabled: capabilities.redirectPolicy,
            ),
            CapabilityChip(label: 'Cookie jar', enabled: capabilities.cookieJar),
            CapabilityChip(
              label: 'Phase timings',
              enabled: capabilities.phaseTimings,
            ),
            CapabilityChip(label: 'Disk cache', enabled: capabilities.diskCache),
          ],
        ),
        const SizedBox(height: Gap.sm),
        Text(
          'These are declared by each client, not probed. A greyed-out control '
          'above is greyed out because of one of these.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Parses a millisecond field, treating empty as "use the client default".
  static Duration? _millis(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed <= 0) return null;
    return Duration(milliseconds: parsed);
  }
}
