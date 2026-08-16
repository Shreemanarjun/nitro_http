// A deliberately minimal nitro_http app: this package and nothing else.
//
// The main `example/` is a benchmark harness that also depends on dio, rhttp
// and package:http so it can race them. That makes it a poor instrument for
// "does nitro_http work on this platform?" — a red build there might belong to
// any of the four, and rhttp's Rust toolchain has broken it more than once for
// reasons unrelated to this package.
//
// Everything here runs against https://httpbin.io over a real network, so DNS,
// TLS, redirects and content negotiation are all exercised. The check matrix
// lives in checks.dart.
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';

import 'checks.dart';

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

enum Outcome { pending, running, pass, fail }

class CheckRow {
  CheckRow(this.check);
  final Check check;
  Outcome outcome = Outcome.pending;
  String detail = '';
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late final NitroHttpClient _client = NitroHttpClient(
    settings: const ClientSettings(
      baseUrl: httpbin,
      userAgent: 'nitro_http_minimal/1.0',
      timeout: Duration(seconds: 30),
      cookieSettings: CookieSettings(storeCookies: true),
      cacheSettings: CacheSettings(enabled: true),
      // A checking app wants to INSPECT a 404 or 401, not have it thrown. The
      // default (true) is the right default for an app; it is wrong here.
      throwOnStatusCode: false,
    ),
  );

  late final List<CheckRow> _rows = checks.map(CheckRow.new).toList();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Run on launch: this app exists to answer "does the engine work here?",
    // and making that require a tap means a terminal or CI run answers nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runAll());
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  Future<void> _runAll() async {
    setState(() {
      _busy = true;
      for (final r in _rows) {
        r
          ..outcome = Outcome.pending
          ..detail = '';
      }
    });
    for (final row in _rows) {
      setState(() => row.outcome = Outcome.running);
      try {
        final detail = await row.check.run(_client);
        row
          ..outcome = Outcome.pass
          ..detail = detail;
      } catch (e) {
        row
          ..outcome = Outcome.fail
          ..detail = '$e';
      }
      _emit(row);
      if (!mounted) return;
      setState(() {});
    }
    setState(() => _busy = false);
    _line('NITRO_CHECKS_DONE $_passed passed, $_failed failed');
  }

  void _emit(CheckRow row) {
    final mark = row.outcome == Outcome.pass ? 'PASS' : 'FAIL';
    _line('  $mark  ${row.check.group}/${row.check.name}  —  ${row.detail}');
  }

  // debugPrint keeps long lines intact; developer.log makes them visible in a
  // release run too, where print() is dropped on some platforms.
  void _line(String s) {
    debugPrint(s);
    developer.log(s, name: 'nitro_http');
  }

  int get _passed => _rows.where((r) => r.outcome == Outcome.pass).length;
  int get _failed => _rows.where((r) => r.outcome == Outcome.fail).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('nitro_http · checks'),
        actions: [
          if (_failed > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text('$_passed passed, $_failed failed',
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            )
          else if (_passed > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: Text('$_passed passed')),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _runAll,
        icon: _busy
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.play_arrow),
        label: Text(_busy ? 'Running…' : 'Run all'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: _rows.length,
        itemBuilder: (_, i) {
          final row = _rows[i];
          final first = i == 0 || _rows[i - 1].check.group != row.check.group;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (first)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
                  child: Text(row.check.group.toUpperCase(),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(letterSpacing: 1.4)),
                ),
              ListTile(
                dense: true,
                leading: switch (row.outcome) {
                  Outcome.pending => const Icon(Icons.remove, size: 18),
                  Outcome.running => const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  Outcome.pass =>
                    Icon(Icons.check, size: 18, color: Colors.green.shade600),
                  Outcome.fail =>
                    Icon(Icons.close, size: 18, color: theme.colorScheme.error),
                },
                title: Text(row.check.name,
                    style: const TextStyle(fontSize: 13.5)),
                subtitle: row.detail.isEmpty
                    ? null
                    : SelectableText(
                        row.detail,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: row.outcome == Outcome.fail
                              ? theme.colorScheme.error
                              : theme.textTheme.bodySmall?.color,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
