// Burst A/B: HTTP/1.1 vs cleartext HTTP/2 (h2c), and the two engine knobs that
// only matter under a burst — PIPEWAIT and connections-per-host.
//
// The main suite's server is HTTP/1.1, so it can only ever measure nitro_http's
// burst as connection racing. This test adds the h2c server and drives the SAME
// client against both protocols, so the question "does multiplexing actually
// help the burst, and what pool/PIPEWAIT config is right per protocol" gets a
// real answer. Only nitro_http takes part: the pure-Dart clients have no HTTP/2
// client, and rhttp is measured separately.
//
// Run it in PROFILE mode (the native engine must be real, and debug timings are
// the wrong shape):
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/h2_burst_ab_test.dart
//
// The configs are measured INTERLEAVED round-robin, one burst each per round,
// so a machine transient biases every config together instead of landing on
// whichever block straddled it.

@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/h2_server.dart';
import 'package:nitro_http_example/server/local_server.dart';

const int _burst = int.fromEnvironment('BENCH_BURST', defaultValue: 64);
const int _repeats =
    int.fromEnvironment('BENCH_BURST_REPEATS', defaultValue: 30);
const int _warmupBursts =
    int.fromEnvironment('BENCH_WARMUP_BURSTS', defaultValue: 5);
const int _bodyBytes = int.fromEnvironment('BENCH_BODY', defaultValue: 256);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('burst A/B: h1 vs h2c, PIPEWAIT and connections-per-host',
      (tester) async {
    NitroHttp.reset();
    final h1 = await IsolatedServer.start();
    final h2 = await IsolatedH2Server.start();
    final path = '/bytes/$_bodyBytes';

    final configs = <_Ab>[
      _Ab('h1  auto        conn64  (PIPEWAIT on)',
          h1.baseUrl, HttpVersionPref.auto, 64),
      _Ab('h1  http11Only  conn64  (PIPEWAIT off)',
          h1.baseUrl, HttpVersionPref.http11Only, 64),
      _Ab('h1  auto        conn6',
          h1.baseUrl, HttpVersionPref.auto, 6),
      _Ab('h2c http2Only   conn64  (multiplex)',
          h2.baseUrl, HttpVersionPref.http2Only, 64),
      _Ab('h2c http2Only   conn1',
          h2.baseUrl, HttpVersionPref.http2Only, 1),
    ];

    for (final cfg in configs) {
      cfg.client = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: cfg.baseUrl,
          enableCompression: false,
          httpVersionPref: cfg.pref,
          poolSettings: PoolSettings(
            maxConnections: 64,
            maxConnectionsPerHost: cfg.connPerHost,
          ),
        ),
      );
    }

    // Warm each pool to burst width and record the negotiated protocol once.
    for (final cfg in configs) {
      for (var w = 0; w < _warmupBursts; w++) {
        await Future.wait(<Future<void>>[
          for (var i = 0; i < _burst; i++)
            cfg.client.requestBytes(HttpMethod.get, path),
        ]);
      }
      final probe = await cfg.client.requestBytes(HttpMethod.get, path);
      cfg.proto = probe.version;
    }

    // Interleaved: one burst per config per round.
    for (var r = 0; r < _repeats; r++) {
      for (final cfg in configs) {
        final sw = Stopwatch()..start();
        await Future.wait(<Future<void>>[
          for (var i = 0; i < _burst; i++)
            cfg.client.requestBytes(HttpMethod.get, path),
        ]);
        cfg.walls.add(sw.elapsedMicroseconds);
      }
    }

    // ignore: avoid_print
    print('H2AB burst=$_burst x $_repeats repeats, body=$_bodyBytes B, '
        'engine=${NitroHttp.engineVersion.replaceAll('\n', ' ')}');
    for (final cfg in configs) {
      cfg.walls.sort();
      final p50 = cfg.walls[cfg.walls.length ~/ 2] / 1000.0;
      final min = cfg.walls.first / 1000.0;
      final max = cfg.walls.last / 1000.0;
      // ignore: avoid_print
      print('H2AB ${cfg.label.padRight(42)} '
          'proto=${cfg.proto.label.padRight(9)} '
          'burst_p50=${p50.toStringAsFixed(3)}ms '
          '(min ${min.toStringAsFixed(3)} max ${max.toStringAsFixed(3)})');
    }
    // ignore: avoid_print
    print('H2AB_DONE');

    for (final cfg in configs) {
      cfg.client.dispose();
    }
    await h1.stop();
    await h2.stop();

    // The premise of the whole test: h2c prior-knowledge must actually speak
    // HTTP/2. If it silently fell back, the h2 rows would be meaningless.
    final h2Configs =
        configs.where((_Ab c) => c.pref == HttpVersionPref.http2Only);
    expect(
      h2Configs.every((_Ab c) => c.proto == HttpVersion.http2),
      isTrue,
      reason: 'h2c prior-knowledge must negotiate HTTP/2, got '
          '${h2Configs.map((_Ab c) => c.proto.label).toList()}',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}

final class _Ab {
  _Ab(this.label, this.baseUrl, this.pref, this.connPerHost);

  final String label;
  final String baseUrl;
  final HttpVersionPref pref;
  final int connPerHost;

  late final NitroHttpClient client;
  HttpVersion proto = HttpVersion.unknown;
  final List<int> walls = <int>[]; // microseconds per burst
}
