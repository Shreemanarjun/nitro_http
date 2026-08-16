// A deliberately minimal nitro_http app.
//
// The main `example/` is a benchmark harness: it also depends on dio, rhttp and
// package:http so it can race them. That makes it a poor place to answer "does
// nitro_http work on this platform?", because a failure might belong to any of
// them — a missing Rust toolchain for rhttp has broken its build more than once.
//
// This app depends on nitro_http and nothing else, so anything that goes wrong
// here is ours. It is the app to reach for when checking a fresh platform
// setup, a new Flutter version, or an SDK bump.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';

void main() => runApp(const MinimalApp());

class MinimalApp extends StatelessWidget {
  const MinimalApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'nitro_http minimal',
    theme: ThemeData(colorSchemeSeed: const Color(0xFF2A78D6)),
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _client = NitroHttpClient(
    settings: const ClientSettings(
      baseUrl: 'https://httpbin.org',
      userAgent: 'nitro_http_minimal/1.0',
      timeout: Duration(seconds: 20),
    ),
  );

  final _log = <String>[];

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  void _say(String line) {
    if (mounted) setState(() => _log.insert(0, line));
  }

  /// What the linked engine can actually do. Reported by the binary at runtime
  /// rather than assumed, so a build that silently fell back to a system
  /// libcurl shows up here as `http3 false` instead of failing much later.
  void _capabilities() {
    _say('engine    ${NitroHttp.engineVersion}');
    _say('http3 ${NitroHttp.supportsHttp3}  ws ${NitroHttp.supportsWebSockets}  '
        'brotli ${NitroHttp.supportsBrotli}  zstd ${NitroHttp.supportsZstd}');
  }

  Future<void> _get() async {
    try {
      final res = await _client.get('/json');
      final keys = (res.bodyToJson()! as Map).keys.join(', ');
      _say('GET /json -> ${res.statusCode} ${res.version.label} '
          '${res.bodyBytes.length}B  keys: $keys');
      _say('  dns ${res.timings.dns}  tls ${res.timings.tls}  '
          'ttfb ${res.timings.firstByte}');
    } on NitroHttpException catch (e) {
      _say('GET failed: ${e.runtimeType} — ${e.message}');
    }
  }

  /// Streaming with backpressure: chunks arrive as the socket delivers them and
  /// nothing buffers the whole body in the Dart heap.
  Future<void> _stream() async {
    try {
      final res = await _client.requestStream(HttpMethod.get, '/bytes/1048576');
      var seen = 0;
      await for (final chunk in res.body) {
        seen += chunk.length;
      }
      _say('streamed 1 MiB -> $seen bytes, status ${res.statusCode}');
    } on NitroHttpException catch (e) {
      _say('stream failed: ${e.message}');
    }
  }

  /// Cancellation is enforced inside the engine, so this aborts the transfer
  /// rather than merely dropping the Dart future.
  Future<void> _cancel() async {
    final token = CancelToken();
    Timer(const Duration(milliseconds: 300), () => token.cancel('user tapped cancel'));
    try {
      await _client.get('/delay/5', cancelToken: token);
      _say('cancel: request finished before the timer (unexpected)');
    } on NitroHttpCancelException catch (e) {
      _say('cancelled as expected: ${e.reason}');
    } on NitroHttpException catch (e) {
      _say('cancel test failed: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('nitro_http · minimal')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: _capabilities, child: const Text('Capabilities')),
              FilledButton(onPressed: _get, child: const Text('GET json')),
              FilledButton(onPressed: _stream, child: const Text('Stream 1 MiB')),
              FilledButton(onPressed: _cancel, child: const Text('Cancel')),
              OutlinedButton(
                onPressed: () => setState(_log.clear),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _log.isEmpty
              ? const Center(child: Text('Tap a button — results appear here.'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: SelectableText(
                      _log[i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
        ),
      ],
    ),
  );
}
