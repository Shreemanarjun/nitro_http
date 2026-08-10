/// The `nitro_http` demo app.
///
/// Six tabs, each a working screen rather than a placeholder, all pointed at an
/// in-process `shelf` server on `127.0.0.1`. That means the app is fully usable
/// with no network at all, and nothing you press here leaves the device.
library;

import 'package:flutter/material.dart';
import 'package:nitro_http/nitro_http.dart';

import 'benchmark/release_runner.dart';
import 'core/app_state.dart' as app_state;
import 'screens/benchmark/benchmark_screen.dart';
import 'screens/console/request_console_screen.dart';
import 'theme/app_theme.dart';
import 'server/local_server.dart';
import 'tabs/cache_tab.dart';
import 'tabs/cookies_tab.dart';
import 'tabs/streaming_tab.dart';
import 'tabs/websocket_tab.dart';
import 'widgets/panels.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Built with `--dart-define=NITRO_HTTP_BENCHMARK=1`: run the benchmark and
  // print it to the platform log instead of showing the UI. This exists because
  // `flutter drive` cannot run in release mode, and release is the only build
  // whose numbers are worth quoting. `kBenchmarkMode` is a const, so an ordinary
  // build tree-shakes all of this away.
  if (kBenchmarkMode) {
    // A frame still has to be pumped: the engine needs a live view to keep the
    // isolate scheduled, and on some targets the process exits without one.
    runApp(const _BenchmarkHost());
    return;
  }

  // Nothing here recovers from a hot restart: the library reconciles native
  // state itself on the first touch of a new isolate incarnation.
  //
  // This probe exists only to fail EARLY and legibly. Reading a capability is
  // the cheapest way to reach native, so a build with no engine library linked
  // says so on the first frame instead of throwing from somewhere inside the
  // first request — and an app that dies in `main` cannot explain why.
  Object? startupError;
  try {
    NitroHttp.engineVersion;
  } on Object catch (error) {
    startupError = error;
  }

  runApp(NitroHttpDemoApp(startupError: startupError));
}

/// Shows one line and runs the benchmark. Only ever built when
/// [kBenchmarkMode] is set; see `benchmark/release_runner.dart`.
class _BenchmarkHost extends StatefulWidget {
  const _BenchmarkHost();

  @override
  State<_BenchmarkHost> createState() => _BenchmarkHostState();
}

class _BenchmarkHostState extends State<_BenchmarkHost> {
  @override
  void initState() {
    super.initState();
    // After the first frame, so the run is never measuring startup contention
    // with the engine bringing up its first view.
    WidgetsBinding.instance.addPostFrameCallback((_) => runReleaseBenchmark());
  }

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Center(child: Text('Running benchmark — see the platform log.')),
    ),
  );
}

/// A snapshot of the native engine's identity and feature flags.
final class EngineInfo {
  const EngineInfo._({
    required this.version,
    required this.supportsHttp3,
    required this.supportsWebSockets,
    required this.supportsBrotli,
    required this.supportsZstd,
    required this.error,
  });

  /// Reads the engine's version and capabilities, capturing a native failure
  /// rather than propagating it.
  factory EngineInfo.probe() {
    try {
      return EngineInfo._(
        version: NitroHttp.engineVersion,
        supportsHttp3: NitroHttp.supportsHttp3,
        supportsWebSockets: NitroHttp.supportsWebSockets,
        supportsBrotli: NitroHttp.supportsBrotli,
        supportsZstd: NitroHttp.supportsZstd,
        error: null,
      );
    } on Object catch (error) {
      return EngineInfo._(
        version: 'unavailable',
        supportsHttp3: false,
        supportsWebSockets: false,
        supportsBrotli: false,
        supportsZstd: false,
        error: error,
      );
    }
  }

  /// The native stack string, e.g. `libcurl/8.21.0 OpenSSL/3.5.0`.
  final String version;

  /// Whether the linked libcurl has a QUIC backend.
  final bool supportsHttp3;

  /// Whether the engine can speak the WebSocket protocol.
  final bool supportsWebSockets;

  /// Whether brotli response bodies are decoded natively.
  final bool supportsBrotli;

  /// Whether zstd response bodies are decoded natively.
  final bool supportsZstd;

  /// The failure raised while probing, or `null` when the probe succeeded.
  final Object? error;

  /// Whether the engine answered at all.
  bool get isAvailable => error == null;
}

/// Root widget: owns the local server and the tab scaffold.
class NitroHttpDemoApp extends StatefulWidget {
  /// Creates the app. [startupError] is whatever `NitroHttp.reset()` threw.
  const NitroHttpDemoApp({this.startupError, super.key});

  /// The failure from the hot-restart reset in `main`, or `null`.
  final Object? startupError;

  @override
  State<NitroHttpDemoApp> createState() => _NitroHttpDemoAppState();
}

class _NitroHttpDemoAppState extends State<NitroHttpDemoApp> {
  LocalServer? _server;
  Object? _serverError;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      final server = await LocalServer.start();
      if (!mounted) {
        await server.stop();
        return;
      }
      app_state.baseUrl.value = server.baseUrl;
      setState(() {
        _server = server;
        _serverError = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _serverError = error);
    }
  }

  @override
  void dispose() {
    app_state.baseUrl.value = '';
    _server?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nitro_http',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: Builder(
        builder: (context) {
          final server = _server;
          final error = _serverError;
          if (error != null) {
            return Scaffold(
              appBar: AppBar(title: const Text('nitro_http')),
              body: EngineErrorCard(
                action: 'start the local test server',
                error: error,
                onRetry: () {
                  setState(() => _serverError = null);
                  _startServer();
                },
              ),
            );
          }
          if (server == null) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return _HomePage(
            server: server,
            startupError: widget.startupError,
          );
        },
      ),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage({required this.server, required this.startupError});

  final LocalServer server;
  final Object? startupError;

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  late EngineInfo _engine = EngineInfo.probe();

  static const List<Tab> _tabs = [
    Tab(text: 'Console', icon: Icon(Icons.terminal)),
    Tab(text: 'Streaming', icon: Icon(Icons.waves)),
    Tab(text: 'WebSocket', icon: Icon(Icons.cable)),
    Tab(text: 'Cache', icon: Icon(Icons.sd_storage)),
    Tab(text: 'Cookies', icon: Icon(Icons.cookie)),
    Tab(text: 'Benchmark', icon: Icon(Icons.speed)),
  ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 12,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('nitro_http'),
              Text(
                _engine.version,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                widget.server.baseUrl,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Re-probe the engine',
              onPressed: () => setState(() => _engine = EngineInfo.probe()),
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: _tabs),
        ),
        body: Column(
          children: [
            _CapabilityBar(engine: _engine),
            if (!_engine.isAvailable)
              EngineErrorCard(
                action: 'reach the native engine',
                error: widget.startupError ?? _engine.error!,
                onRetry: () => setState(() => _engine = EngineInfo.probe()),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  const RequestConsoleScreen(),
                  StreamingTab(server: widget.server),
                  WebSocketTab(server: widget.server),
                  CacheTab(server: widget.server),
                  CookiesTab(server: widget.server),
                  const BenchmarkScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityBar extends StatelessWidget {
  const _CapabilityBar({required this.engine});

  final EngineInfo engine;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          CapabilityChip(label: 'engine', enabled: engine.isAvailable),
          CapabilityChip(label: 'HTTP/3', enabled: engine.supportsHttp3),
          CapabilityChip(label: 'WebSocket', enabled: engine.supportsWebSockets),
          CapabilityChip(label: 'brotli', enabled: engine.supportsBrotli),
          CapabilityChip(label: 'zstd', enabled: engine.supportsZstd),
        ],
      ),
    );
  }
}
