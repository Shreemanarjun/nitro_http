// Where does a small GET's wall time actually go?
//
// The benchmark says nitro_http is ~30 us slower than `dart:io` per small
// request. That is a per-request overhead question, not a throughput one, and
// the engine already measures the one piece nobody else can see: `queue`, the
// gap between the Dart call and the loop thread picking the request up. This
// splits the budget so the optimisation targets a measured layer.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/latency_profile_test.dart

@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('small GET budget', (tester) async {
    const iterations = 2000;

    Future<List<int>> run({required bool wantTimings}) async {
      final client = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.baseUrl),
      );
      addTearDown(client.dispose);
      // Warm the pool: the first request pays connect and TLS-less setup that
      // nothing else in the loop does.
      for (var i = 0; i < 200; i++) {
        await client.get('/bytes/1024');
      }
      final micros = <int>[];
      final queue = <int>[];
      for (var i = 0; i < iterations; i++) {
        final sw = Stopwatch()..start();
        final res = await client.get(
          '/bytes/1024',
          options: RequestOptions(wantTimings: wantTimings),
        );
        sw.stop();
        expect(res.statusCode, 200);
        micros.add(sw.elapsedMicroseconds);
        queue.add(res.timings.queue.inMicroseconds);
      }
      micros.sort();
      queue.sort();
      return <int>[micros[micros.length ~/ 2], queue[queue.length ~/ 2]];
    }

    final withTimings = await run(wantTimings: true);
    final withoutTimings = await run(wantTimings: false);

    // A `dart:io` control in the same process, so the comparison is not against
    // a number measured on a different day under a different load.
    final dartIo = HttpClient();
    addTearDown(dartIo.close);
    for (var i = 0; i < 200; i++) {
      final req = await dartIo.getUrl(Uri.parse('${server.baseUrl}/bytes/1024'));
      await (await req.close()).drain<void>();
    }
    final baseline = <int>[];
    for (var i = 0; i < iterations; i++) {
      final sw = Stopwatch()..start();
      final req = await dartIo.getUrl(Uri.parse('${server.baseUrl}/bytes/1024'));
      await (await req.close()).drain<void>();
      sw.stop();
      baseline.add(sw.elapsedMicroseconds);
    }
    baseline.sort();

    // ignore: avoid_print
    print(
      'LATENCY p50 us — nitro(timings on) ${withTimings[0]} '
      '(queue ${withTimings[1]}) | nitro(timings off) ${withoutTimings[0]} '
      '(queue ${withoutTimings[1]}) | dart:io ${baseline[baseline.length ~/ 2]}',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
