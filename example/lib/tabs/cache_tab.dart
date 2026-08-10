/// The disk-cache screen.
///
/// The cache is process-wide and its directory is never guessed by the plugin,
/// so the first thing this screen does is hand `path_provider`'s cache directory
/// to [NitroHttp.configureCache]. Every button then fires the *same* request and
/// shows how the counters move, which is the only way to tell a hit from a
/// revalidation from a miss.
library;

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:path_provider/path_provider.dart';

import '../server/local_server.dart';
import '../widgets/panels.dart';

/// The outcome of one cache-mode request, as the screen shows it.
final class CacheProbe {
  /// Creates a successful probe result.
  CacheProbe.success({
    required this.mode,
    required this.statusCode,
    required this.fromCache,
    required this.revalidated,
    required this.body,
    required this.serverRequests,
  }) : error = null;

  /// Creates a failed probe result, e.g. a cache miss under
  /// [CacheMode.onlyIfCached].
  CacheProbe.failure({
    required this.mode,
    required this.error,
    required this.serverRequests,
  }) : statusCode = 0,
       fromCache = false,
       revalidated = false,
       body = '';

  /// The mode the request ran under.
  final CacheMode mode;

  /// The response status, or `0` when the request failed.
  final int statusCode;

  /// Whether the body came off disk without contacting the origin.
  final bool fromCache;

  /// Whether a stored entry was refreshed by a `304`.
  final bool revalidated;

  /// The response body, trimmed for display.
  final String body;

  /// How many requests the local server had seen when this probe finished.
  ///
  /// A hit is only proven by this number *not* moving.
  final int serverRequests;

  /// The failure, or `null`.
  final Object? error;
}

/// The cache screen.
class CacheTab extends StatefulWidget {
  /// Creates the screen against [server].
  const CacheTab({required this.server, super.key});

  /// The local server serving `/cache/<maxAge>`.
  final LocalServer server;

  @override
  State<CacheTab> createState() => _CacheTabState();
}

class _CacheTabState extends State<CacheTab> {
  /// `max-age=60` is long enough that a second request inside a demo session is
  /// a genuine fresh hit rather than a revalidation.
  static const String _freshPath = '/cache/60';

  /// `max-age=0` forces the conditional round trip, so the revalidation counter
  /// is reachable from the UI.
  static const String _stalePath = '/cache/0';

  NitroHttpClient? _client;
  Object? _error;
  String _cacheDirectory = '';
  bool _configured = false;
  bool _busy = false;
  CacheStats _stats = const CacheStats();
  final List<CacheProbe> _probes = [];

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }

  Future<void> _configure() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dir = await getApplicationCacheDirectory();
      final path = '${dir.path}/nitro_http_demo_cache';
      NitroHttp.configureCache(
        HttpCacheConfig(
          directory: path,
          maxSizeBytes: 8 * 1024 * 1024,
          maxEntryBytes: 1024 * 1024,
        ),
      );
      _client?.dispose();
      final client = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: widget.server.baseUrl,
          throwOnStatusCode: false,
          cacheSettings: const CacheSettings(enabled: true),
        ),
      );
      if (!mounted) {
        client.dispose();
        return;
      }
      setState(() {
        _cacheDirectory = path;
        _client = client;
        _configured = true;
        _stats = NitroHttp.cacheStats();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _configured = false;
        _error = error;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probe(CacheMode mode, {bool stale = false}) async {
    final client = _client;
    if (client == null) return;
    setState(() => _busy = true);
    final path = stale ? _stalePath : _freshPath;
    try {
      final response = await client.get(
        path,
        options: RequestOptions(cacheMode: mode),
      );
      if (!mounted) return;
      setState(() {
        _probes.insert(
          0,
          CacheProbe.success(
            mode: mode,
            statusCode: response.statusCode,
            fromCache: response.fromCache,
            revalidated: response.revalidated,
            body: response.body,
            serverRequests: widget.server.requestsFor(path),
          ),
        );
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _probes.insert(
          0,
          CacheProbe.failure(
            mode: mode,
            error: error,
            serverRequests: widget.server.requestsFor(path),
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stats = _readStats();
        });
      }
    }
  }

  Future<void> _prefetch() async {
    setState(() => _busy = true);
    try {
      await NitroHttp.prefetchDetailed('${widget.server.baseUrl}$_freshPath');
      if (!mounted) return;
      setState(() {
        _probes.insert(
          0,
          CacheProbe.success(
            mode: CacheMode.normal,
            statusCode: 200,
            fromCache: false,
            revalidated: false,
            body: 'prefetched $_freshPath (body discarded)',
            serverRequests: widget.server.requestsFor(_freshPath),
          ),
        );
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stats = _readStats();
        });
      }
    }
  }

  void _clear() {
    try {
      NitroHttp.clearCache();
      setState(() {
        _probes.clear();
        _stats = _readStats();
      });
    } on Object catch (error) {
      setState(() => _error = error);
    }
  }

  CacheStats _readStats() {
    try {
      return NitroHttp.cacheStats();
    } on Object {
      // Stats are diagnostics: a failure here must not replace the result the
      // user just produced with an error card.
      return _stats;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SectionCard(
          title: 'Store',
          trailing: TextButton(
            onPressed: _busy ? null : _configure,
            child: const Text('Reconfigure'),
          ),
          child: KeyValueTable(
            rows: [
              ('directory', _cacheDirectory.isEmpty ? '—' : _cacheDirectory),
              ('configured', '$_configured'),
              ('fresh key', '$_freshPath (max-age=60)'),
              ('stale key', '$_stalePath (max-age=0, must revalidate)'),
              (
                'server hits on fresh key',
                '${widget.server.requestsFor(_freshPath)}',
              ),
            ],
          ),
        ),
        if (_error != null)
          EngineErrorCard(
            action: 'configure the shared disk cache',
            error: _error!,
            onRetry: () => setState(() => _error = null),
          ),
        SectionCard(
          title: 'Statistics',
          trailing: TextButton(
            onPressed: () => setState(() => _stats = _readStats()),
            child: const Text('Refresh'),
          ),
          child: KeyValueTable(
            rows: [
              ('entries', '${_stats.entryCount}'),
              ('size', '${_stats.sizeBytes} B'),
              ('hits', '${_stats.hitCount}'),
              ('misses', '${_stats.missCount}'),
              ('revalidations', '${_stats.revalidationCount}'),
              ('evictions', '${_stats.evictionCount}'),
              ('hit rate', '${(_stats.hitRate * 100).toStringAsFixed(1)} %'),
            ],
          ),
        ),
        SectionCard(
          title: 'Fire a request',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in CacheMode.values)
                    FilledButton.tonal(
                      onPressed: _busy || !_configured
                          ? null
                          : () => _probe(mode),
                      child: Text(mode.name),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy || !_configured
                        ? null
                        : () => _probe(CacheMode.normal, stale: true),
                    child: const Text('normal on max-age=0 (revalidate)'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || !_configured ? null : _prefetch,
                    child: const Text('prefetch'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _clear,
                    child: const Text('clear cache'),
                  ),
                ],
              ),
            ],
          ),
        ),
        for (final probe in _probes)
          SectionCard(
            title: 'CacheMode.${probe.mode.name}',
            child: probe.error != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      KeyValueTable(
                        rows: [
                          ('server hits', '${probe.serverRequests}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      CodeBlock(text: '${probe.error}', maxHeight: 120),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      KeyValueTable(
                        rows: [
                          ('status', '${probe.statusCode}'),
                          ('fromCache', '${probe.fromCache}'),
                          ('revalidated', '${probe.revalidated}'),
                          ('server hits', '${probe.serverRequests}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      CodeBlock(text: probe.body, maxHeight: 120),
                    ],
                  ),
          ),
      ],
    );
  }
}
