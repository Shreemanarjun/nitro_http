// Where does a 32 MiB download's time go?
//
// nitro_http is last of five on this scenario on both macOS (157.7 ms vs
// rhttp's 141.9) and Android (341.8 vs 298.1), and unlike small-request latency
// it is not bridge-bound: a 32 MiB transfer amortises the ~36 us round trip to
// nothing. So the cost is somewhere in the engine, and two candidates are
// already ruled out by measurements recorded in the source — `CURLOPT_BUFFERSIZE`
// (tried at 16/64/256 KiB, bigger loses every time) and the credit window
// (ramping 64 → 256 moved the median 1.1 %).
//
// This isolates the streaming machinery instead of theorising about it. The same
// 32 MiB body is fetched two ways:
//
//   streamed — credits, one `RawChunk` emit per curl write callback, a
//              zero-copy struct proxy per chunk, and a `controller.add` per
//              chunk.
//   buffered — none of that. The engine accumulates natively and posts one
//              response. No credits, no per-chunk crossing.
//
// If buffered is much faster, the per-chunk streaming path is the cost and that
// is where to optimise. If the two are equal, the streaming machinery is
// innocent and the time is inside curl or the socket, which would mean the
// deficit against rhttp is not something the credit loop can fix.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/download_profile_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

const int _mib = int.fromEnvironment('PROFILE_MIB', defaultValue: 32);
const int _runs = int.fromEnvironment('PROFILE_RUNS', defaultValue: 5);

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

  testWidgets('streamed vs buffered download', (tester) async {
    final bytes = _mib * 1024 * 1024;
    final path = '/bytes/$bytes';

    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(client.dispose);

    // Warm the connection so neither mode pays setup.
    await client.get('/bytes/1024');

    final streamed = <int>[];
    final buffered = <int>[];
    final chunkCounts = <int>[];
    final streamedCurl = <int>[];
    final bufferedCurl = <int>[];

    for (var i = 0; i < _runs; i++) {
      final sw = Stopwatch()..start();
      final res = await client.requestStream(HttpMethod.get, path);
      var total = 0;
      var chunks = 0;
      await for (final chunk in res.body) {
        total += chunk.length;
        chunks++;
      }
      sw.stop();
      expect(total, bytes);
      streamed.add(sw.elapsedMicroseconds);
      chunkCounts.add(chunks);
      streamedCurl.add(res.timings.total.inMicroseconds);

      final sw2 = Stopwatch()..start();
      final res2 = await client.requestBytes(HttpMethod.get, path);
      sw2.stop();
      expect(res2.bodyBytes.length, bytes);
      buffered.add(sw2.elapsedMicroseconds);
      bufferedCurl.add(res2.timings.total.inMicroseconds);
    }

    final s = _median(streamed);
    final b = _median(buffered);
    final chunks = _median(chunkCounts);

    // ignore: avoid_print
    print(
      'DOWNLOAD ${_mib}MiB us — '
      'streamed $s (curl ${_median(streamedCurl)}) | '
      'buffered $b (curl ${_median(bufferedCurl)}) | '
      'chunks $chunks avg ${bytes ~/ chunks}B | '
      'streamingOverhead ${s - b} us '
      '(${(100 * (s - b) / b).toStringAsFixed(1)}%) | '
      'perChunk ${((s - b) / chunks).toStringAsFixed(2)} us',
    );

    expect(s, greaterThan(0));
  });
}
