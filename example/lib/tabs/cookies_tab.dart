/// The cookie-jar screen.
///
/// The jar lives in the native engine, so the round trip proven here is the real
/// one: `/setcookie` writes into libcurl's jar, and `/readcookie` echoes back the
/// `Cookie:` header the engine chose to send.
library;

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';

import '../server/local_server.dart';
import '../widgets/panels.dart';

/// The cookies screen.
class CookiesTab extends StatefulWidget {
  /// Creates the screen against [server].
  const CookiesTab({required this.server, super.key});

  /// The local server serving `/setcookie` and `/readcookie`.
  final LocalServer server;

  @override
  State<CookiesTab> createState() => _CookiesTabState();
}

class _CookiesTabState extends State<CookiesTab> {
  final TextEditingController _name = TextEditingController(text: 'manual');
  final TextEditingController _value = TextEditingController(text: 'set-from-dart');

  NitroHttpClient? _client;
  Object? _error;
  bool _busy = false;
  List<Cookie> _jar = const [];
  String _lastRead = '';
  String _serverSaw = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _client?.dispose();
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  NitroHttpClient? _ensureClient() {
    final existing = _client;
    if (existing != null) return existing;
    try {
      return _client = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: widget.server.baseUrl,
          throwOnStatusCode: false,
        ),
      );
    } on Object catch (error) {
      _error = error;
      return null;
    }
  }

  void _refresh() {
    final client = _ensureClient();
    if (client == null) {
      setState(() {});
      return;
    }
    try {
      setState(() {
        _jar = client.allCookies();
        _error = null;
      });
    } on Object catch (error) {
      setState(() => _error = error);
    }
  }

  Future<void> _run(String label, Future<void> Function(NitroHttpClient) body) async {
    final client = _ensureClient();
    if (client == null) {
      setState(() {});
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body(client);
      if (!mounted) return;
      setState(() => _jar = client.allCookies());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = StateError('$label failed: $error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hitSetCookie() => _run('GET /setcookie', (client) async {
    final response = await client.get('/setcookie');
    if (!mounted) return;
    setState(
      () => _lastRead =
          'Set-Cookie lines:\n${response.headers.setCookie.join('\n')}',
    );
  });

  Future<void> _hitReadCookie() => _run('GET /readcookie', (client) async {
    final response = await client.get('/readcookie');
    if (!mounted) return;
    setState(() {
      _lastRead = response.body;
      _serverSaw = widget.server.lastCookieHeader ?? '(no Cookie header)';
    });
  });

  Future<void> _addCookie() => _run('setCookie', (client) async {
    client.setCookie(
      Cookie(
        name: _name.text,
        value: _value.text,
        domain: '127.0.0.1',
        path: '/',
        expires: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
    );
  });

  Future<void> _deleteCookie(Cookie cookie) => _run('delete cookie', (client) async {
    // There is no "remove" on the jar: the wire-level way to delete a cookie is
    // to store it again with an expiry in the past, which is exactly what a
    // server does with `Max-Age=0`.
    client.setCookie(
      Cookie(
        name: cookie.name,
        value: '',
        domain: cookie.domain,
        path: cookie.path,
        expires: DateTime.utc(1970),
        secure: cookie.secure,
        httpOnly: cookie.httpOnly,
      ),
    );
  });

  Future<void> _clearAll() => _run('clearCookies', (client) async {
    client.clearCookies();
    if (!mounted) return;
    setState(() {
      _lastRead = '';
      _serverSaw = '';
    });
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SectionCard(
          title: 'Round trip',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : _hitSetCookie,
                child: const Text('GET /setcookie'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _hitReadCookie,
                child: const Text('GET /readcookie'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _clearAll,
                child: const Text('clearCookies()'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _refresh,
                child: const Text('Reload jar'),
              ),
            ],
          ),
        ),
        if (_error != null)
          EngineErrorCard(
            action: 'talk to the native cookie jar',
            error: _error!,
            onRetry: () {
              setState(() => _error = null);
              _refresh();
            },
          ),
        SectionCard(
          title: 'Add a cookie by hand',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _value,
                      decoration: const InputDecoration(
                        labelText: 'Value',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _addCookie,
                icon: const Icon(Icons.add),
                label: const Text('setCookie'),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Jar (${_jar.length})',
          child: _jar.isEmpty
              ? Text('empty', style: Theme.of(context).textTheme.bodySmall)
              : Column(
                  children: [
                    for (final cookie in _jar)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${cookie.name}=${cookie.value}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        subtitle: Text(
                          'domain ${cookie.domain.isEmpty ? '(unscoped)' : cookie.domain} '
                          '· path ${cookie.path} '
                          '· ${cookie.expires == null ? 'session' : 'expires ${cookie.expires!.toIso8601String()}'}'
                          '${cookie.secure ? ' · secure' : ''}'
                          '${cookie.httpOnly ? ' · httpOnly' : ''}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: IconButton(
                          tooltip: 'Expire this cookie',
                          onPressed: _busy ? null : () => _deleteCookie(cookie),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Last response',
          child: CodeBlock(text: _lastRead),
        ),
        SectionCard(
          title: 'Cookie header the server actually received',
          child: CodeBlock(text: _serverSaw, maxHeight: 100),
        ),
      ],
    );
  }
}
