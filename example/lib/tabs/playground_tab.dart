/// A request playground: compose any request against the local server and see
/// exactly what came back, including the negotiated protocol and the per-phase
/// timings the engine reports.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:path_provider/path_provider.dart';

import '../server/local_server.dart';
import '../widgets/panels.dart';

/// Which payload shape the playground sends.
enum PlaygroundBodyKind {
  /// No request body at all.
  none('none'),

  /// A UTF-8 `text/plain` body.
  text('text'),

  /// The editor content parsed as JSON and re-encoded.
  json('json'),

  /// `key=value` lines encoded as `application/x-www-form-urlencoded`.
  form('form'),

  /// A `multipart/form-data` body with a text part and a bytes part.
  multipart('multipart'),

  /// A temporary file streamed off disk by the native engine.
  file('file');

  const PlaygroundBodyKind(this.label);

  /// Label shown in the selector.
  final String label;
}

/// The playground screen.
class PlaygroundTab extends StatefulWidget {
  /// Creates the playground against [server].
  const PlaygroundTab({required this.server, super.key});

  /// The local server every default points at.
  final LocalServer server;

  @override
  State<PlaygroundTab> createState() => _PlaygroundTabState();
}

class _PlaygroundTabState extends State<PlaygroundTab> {
  late final TextEditingController _url = TextEditingController(
    text: '${widget.server.baseUrl}/echo?greeting=hello',
  );
  final TextEditingController _customMethod = TextEditingController(text: 'PURGE');
  final TextEditingController _headers = TextEditingController(
    text: 'X-Demo: playground\nAccept: application/json',
  );
  final TextEditingController _body = TextEditingController(
    text: '{"hello":"world","n":42}',
  );

  HttpMethod _method = HttpMethod.get;
  PlaygroundBodyKind _bodyKind = PlaygroundBodyKind.none;
  bool _wantTimings = true;
  bool _throwOnStatusCode = false;

  NitroHttpClient? _client;
  Object? _clientError;

  bool _busy = false;
  HttpResponse? _response;
  Uint8List _responseBytes = Uint8List(0);
  Object? _requestError;

  @override
  void dispose() {
    _client?.dispose();
    _url.dispose();
    _customMethod.dispose();
    _headers.dispose();
    _body.dispose();
    super.dispose();
  }

  /// Creates the client on first use, remembering a native failure so the screen
  /// renders an explanation instead of throwing on every rebuild.
  NitroHttpClient? _ensureClient() {
    final existing = _client;
    if (existing != null) {
      existing.reconfigure(_settings());
      return existing;
    }
    if (_clientError != null) return null;
    try {
      return _client = NitroHttpClient(settings: _settings());
    } on Object catch (error) {
      _clientError = error;
      return null;
    }
  }

  ClientSettings _settings() => ClientSettings(
    timeout: const Duration(seconds: 20),
    connectTimeout: const Duration(seconds: 5),
    throwOnStatusCode: _throwOnStatusCode,
    userAgent: 'nitro_http-playground',
  );

  HttpHeaders _parseHeaders() {
    final headers = HttpHeaders();
    for (final line in const LineSplitter().convert(_headers.text)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers.add(line.substring(0, colon).trim(), line.substring(colon + 1).trim());
    }
    return headers;
  }

  Future<HttpBody?> _buildBody() async {
    switch (_bodyKind) {
      case PlaygroundBodyKind.none:
        return null;
      case PlaygroundBodyKind.text:
        return HttpBody.text(_body.text);
      case PlaygroundBodyKind.json:
        // A malformed editor buffer is a user error, not an engine error, so it
        // surfaces as a FormatException in the result card.
        return HttpBody.json(jsonDecode(_body.text));
      case PlaygroundBodyKind.form:
        final fields = <String, String>{};
        for (final line in const LineSplitter().convert(_body.text)) {
          final eq = line.indexOf('=');
          if (eq <= 0) continue;
          fields[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
        }
        return HttpBody.form(fields);
      case PlaygroundBodyKind.multipart:
        return HttpBody.multipart([
          MultipartItem.text('note', _body.text),
          MultipartItem.bytes(
            'blob',
            deterministicBytes(256),
            filename: 'blob.bin',
            contentType: 'application/octet-stream',
          ),
        ]);
      case PlaygroundBodyKind.file:
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/playground_upload.txt');
        await file.writeAsString(_body.text);
        return HttpBody.file(file.path, contentType: 'text/plain; charset=utf-8');
    }
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _response = null;
      _responseBytes = Uint8List(0);
      _requestError = null;
    });

    try {
      final client = _ensureClient();
      if (client == null) return;

      final body = await _buildBody();
      final request = HttpRequest(
        method: _method,
        customMethod: _method == HttpMethod.custom ? _customMethod.text : null,
        url: Uri.parse(_url.text),
        headers: _parseHeaders(),
        body: body,
        expectedBody: HttpExpectedBody.bytes,
        options: RequestOptions(wantTimings: _wantTimings),
      );
      final response = await client.request(request);
      if (!mounted) return;
      setState(() {
        _response = response;
        _responseBytes = switch (response) {
          HttpBytesResponse(:final bodyBytes) => bodyBytes,
          HttpTextResponse(:final bodyBytes) => bodyBytes,
          HttpStreamResponse() => Uint8List(0),
        };
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _requestError = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SectionCard(
          title: 'Request',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  DropdownButton<HttpMethod>(
                    value: _method,
                    onChanged: (value) =>
                        setState(() => _method = value ?? _method),
                    items: [
                      for (final method in HttpMethod.values)
                        DropdownMenuItem(
                          value: method,
                          child: Text(
                            method == HttpMethod.custom
                                ? 'CUSTOM'
                                : method.name.toUpperCase(),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _url,
                      decoration: const InputDecoration(
                        labelText: 'URL',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              if (_method == HttpMethod.custom) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _customMethod,
                  decoration: const InputDecoration(
                    labelText: 'Custom method token',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _headers,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Headers, one "Name: value" per line',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final kind in PlaygroundBodyKind.values)
                    ChoiceChip(
                      label: Text(kind.label),
                      selected: _bodyKind == kind,
                      onSelected: (_) => setState(() => _bodyKind = kind),
                    ),
                ],
              ),
              if (_bodyKind != PlaygroundBodyKind.none) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _body,
                  minLines: 3,
                  maxLines: 8,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    labelText: switch (_bodyKind) {
                      PlaygroundBodyKind.form =>
                        'Body — one "key=value" per line',
                      PlaygroundBodyKind.json => 'Body — JSON',
                      PlaygroundBodyKind.multipart => 'Body — the "note" part',
                      PlaygroundBodyKind.none ||
                      PlaygroundBodyKind.text ||
                      PlaygroundBodyKind.file => 'Body',
                    },
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Collect phase timings'),
                value: _wantTimings,
                onChanged: (value) => setState(() => _wantTimings = value),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Throw on non-2xx status'),
                value: _throwOnStatusCode,
                onChanged: (value) =>
                    setState(() => _throwOnStatusCode = value),
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: _busy ? null : _send,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: Text(_busy ? 'Sending…' : 'Send'),
              ),
            ],
          ),
        ),
        if (_clientError != null)
          EngineErrorCard(
            action: 'create a NitroHttpClient',
            error: _clientError!,
            onRetry: () => setState(() => _clientError = null),
          ),
        if (_requestError != null)
          SectionCard(
            title: 'Failed',
            child: CodeBlock(text: '$_requestError'),
          ),
        if (_response case final HttpResponse response) ...[
          SectionCard(
            title: 'Response',
            child: KeyValueTable(
              rows: [
                ('status', '${response.statusCode}'),
                ('version', response.version.label),
                ('final url', '${response.finalUrl}'),
                ('redirects', '${response.redirectCount}'),
                ('peer', '${response.primaryIp}:${response.primaryPort}'),
                ('from cache', '${response.fromCache}'),
                ('revalidated', '${response.revalidated}'),
                ('body bytes', '${_responseBytes.length}'),
              ],
            ),
          ),
          SectionCard(
            title: 'Timings',
            child: KeyValueTable(rows: _timingRows(response.timings)),
          ),
          SectionCard(
            title: 'Response headers',
            child: KeyValueTable(
              rows: [
                for (final (name, value) in response.headers.entries)
                  (name, value),
              ],
            ),
          ),
          SectionCard(
            title: 'Response body',
            child: CodeBlock(text: _renderBody(response)),
          ),
        ],
      ],
    );
  }

  static List<(String, String)> _timingRows(HttpTimings timings) {
    if (timings.isEmpty) {
      return const [('timings', 'not collected for this request')];
    }
    String ms(Duration d) => '${(d.inMicroseconds / 1000).toStringAsFixed(2)} ms';
    return [
      ('queue', ms(timings.queue)),
      ('dns', ms(timings.dns)),
      ('connect', ms(timings.connect)),
      ('tls', ms(timings.tls)),
      ('firstByte', ms(timings.firstByte)),
      ('redirect', ms(timings.redirect)),
      ('total', ms(timings.total)),
    ];
  }

  String _renderBody(HttpResponse response) {
    if (_responseBytes.isEmpty) return '';
    final text = utf8.decode(_responseBytes, allowMalformed: true);
    final contentType = response.headers.contentType ?? '';
    if (!contentType.contains('json')) return text;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } on FormatException {
      // Server said JSON and sent something else; showing the raw text is more
      // useful than an error.
      return text;
    }
  }
}
