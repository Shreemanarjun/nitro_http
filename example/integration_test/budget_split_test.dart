// Splits a small GET's wall time into the layers that can be optimised.
//
// So far: the whole request is 163 us against `dart:io`'s 140 us; `queue` is
// 2 us; marshalling both directions is 0.93 us; and a per-call `ReceivePort`
// costs ~4 us more than a shared one. That leaves ~18 us unaccounted for.
//
// `HttpTimings.total` is curl's own `CURLINFO_TOTAL_TIME` — the transfer as
// libcurl sees it, from the moment it starts work to the moment it finishes.
// Subtracting it (and `queue`) from the wall time isolates everything this
// plugin does around the transfer: `curl_easy_init`, ~30 `curl_easy_setopt`
// calls, `curl_multi_add_handle`, building the response blob, the port post,
// and `curl_easy_cleanup`.
//
// If that remainder is large, handle pooling is the fix. If it is small, the
// cost is inside libcurl and the fix is elsewhere.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/budget_split_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

int _median(List<int> xs) {
  xs.sort();
  return xs[xs.length ~/ 2];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUpAll(() async {
    NitroHttp.reset();
    server = await LocalServer.start();
  });

  tearDownAll(() async => server.stop());

  testWidgets('where the microseconds go', (tester) async {
    const iterations = 2000;
    const warmup = 300;

    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(client.dispose);

    for (var i = 0; i < warmup; i++) {
      await client.get('/bytes/1024');
    }

    final wall = <int>[];
    final queue = <int>[];
    final curlTotal = <int>[];
    final firstByte = <int>[];

    for (var i = 0; i < iterations; i++) {
      final sw = Stopwatch()..start();
      final res = await client.get('/bytes/1024');
      sw.stop();
      expect(res.statusCode, 200);
      wall.add(sw.elapsedMicroseconds);
      queue.add(res.timings.queue.inMicroseconds);
      curlTotal.add(res.timings.total.inMicroseconds);
      firstByte.add(res.timings.firstByte.inMicroseconds);
    }

    // The same request through `dart:io`, as the target to beat.
    final io = HttpClient();
    addTearDown(() => io.close(force: true));
    final ioWall = <int>[];
    for (var i = 0; i < warmup; i++) {
      final r = await io.getUrl(Uri.parse('${server.baseUrl}/bytes/1024'));
      await (await r.close()).drain<void>();
    }
    for (var i = 0; i < iterations; i++) {
      final sw = Stopwatch()..start();
      final r = await io.getUrl(Uri.parse('${server.baseUrl}/bytes/1024'));
      await (await r.close()).drain<void>();
      sw.stop();
      ioWall.add(sw.elapsedMicroseconds);
    }

    final w = _median(wall);
    final q = _median(queue);
    final c = _median(curlTotal);
    final glue = w - q - c;

    // ignore: avoid_print
    print(
      'BUDGET us — wall $w | queue $q | curlTotal $c | '
      'firstByte ${_median(firstByte)} | glue $glue | '
      'dart:io ${_median(ioWall)} | deficit ${w - _median(ioWall)}',
    );

    expect(w, greaterThan(0));
  });
}
