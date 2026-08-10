// Is the burst gap the CLIENT's loop thread, or the test server?
//
// `burst_scaling_test` showed per-request p50 growing linearly with burst width
// at a slope implying ~109 us of serialised work per request — far more than the
// 13 us of engine work `handoff_cost_test` accounts for, and more than a whole
// serial request (170 us, of which curl owns 111 us). Something upstream of the
// engine is serialising.
//
// The prime suspect is the harness, not the client. `LocalServer` is
// `HttpServer.bind` on the SAME Dart isolate the test runs in, so it is
// single-threaded: 64 simultaneous requests are accepted, routed and answered
// one after another by one event loop. If that is the constraint, then EVERY
// client sees the same slope, and the burst row is largely a measurement of the
// server.
//
// So sweep width for two clients that could not be more different — the C++
// engine on its own OS thread, and `dart:io` on the same isolate as the server:
//
//   • Slopes equal            -> server-bound. The burst row cannot separate
//                                clients at this width and the 430 us gap is not
//                                attributable to the engine.
//   • nitro_http slope worse  -> genuinely client-bound; the per-request
//                                loop-thread work is the thing to optimise.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/burst_attribution_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

const List<int> _widths = <int>[8, 16, 32, 64, 128];
const int _rounds = 25;

Duration _median(List<Duration> xs) {
  xs.sort();
  return xs[xs.length ~/ 2];
}

/// Least-squares slope of p50 (us) against burst width.
double _slope(Map<int, Duration> pts) {
  final xs = pts.keys.toList();
  final n = xs.length;
  final meanX = xs.reduce((int a, int b) => a + b) / n;
  final meanY =
      xs.map((int w) => pts[w]!.inMicroseconds).reduce((a, b) => a + b) / n;
  var num = 0.0;
  var den = 0.0;
  for (final w in xs) {
    num += (w - meanX) * (pts[w]!.inMicroseconds - meanY);
    den += (w - meanX) * (w - meanX);
  }
  return num / den;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('burst slope, engine vs dart:io', (tester) async {
    const path = '/bytes/1024';
    final widest = _widths.reduce((int a, int b) => a > b ? a : b);

    final nitro = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(nitro.dispose);

    // maxConnectionsPerHost must clear the widest burst or dart:io queues
    // internally and would be measured as slow for a reason that is not its own.
    final dartIo = HttpClient()..maxConnectionsPerHost = widest + 8;
    addTearDown(() => dartIo.close(force: true));
    final base = Uri.parse(server.baseUrl);

    Future<void> nitroGet() => nitro.get(path);
    Future<void> dartIoGet() async {
      final req = await dartIo.getUrl(base.replace(path: path));
      final res = await req.close();
      await res.drain<void>();
    }

    final subjects = <String, Future<void> Function()>{
      'nitro_http': nitroGet,
      'dart:io': dartIoGet,
    };

    final slopes = <String, double>{};
    for (final entry in subjects.entries) {
      // Prime to the widest burst so no step pays connection setup.
      for (var i = 0; i < 3; i++) {
        await Future.wait(<Future<void>>[
          for (var j = 0; j < widest; j++) entry.value(),
        ]);
      }

      final pts = <int, Duration>{};
      for (final width in _widths) {
        final samples = <Duration>[];
        for (var round = 0; round < _rounds; round++) {
          samples.addAll(
            await Future.wait(<Future<Duration>>[
              for (var i = 0; i < width; i++)
                () async {
                  final one = Stopwatch()..start();
                  await entry.value();
                  return one.elapsed;
                }(),
            ]),
          );
        }
        pts[width] = _median(samples);
      }
      slopes[entry.key] = _slope(pts);

      // ignore: avoid_print
      print(
        'BURST_ATTR ${entry.key} '
        '${jsonEncode({
          for (final e in pts.entries) e.key.toString(): e.value.inMicroseconds,
        })} slope=${_slope(pts).toStringAsFixed(2)}',
      );
    }

    final a = slopes['nitro_http']!;
    final b = slopes['dart:io']!;
    // ignore: avoid_print
    print(
      'BURST_ATTR slopes us/width — nitro_http ${a.toStringAsFixed(2)}, '
      'dart:io ${b.toStringAsFixed(2)}, ratio ${(a / b).toStringAsFixed(2)}x',
    );
  }, timeout: const Timeout(Duration(minutes: 45)));
}
