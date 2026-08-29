// Where does a streamed upload's time go?
//
// Upload is the one benchmark row with no explanation: 106 ms against 104 ms for
// the pure-Dart clients on 8 MiB, consistently 4th of five, and the intervals do
// not overlap (105.1-106.8 against dio's 103.8-104.8) so it is a real gap rather
// than noise.
//
// The same trick that localised the download gap works here. A streamed upload
// goes Dart → `feedUploadChunk` → `BodyPipe` ring → curl's READFUNCTION, with a
// pause/resume protocol in between. An inline `HttpBody.bytes` upload of the same
// size skips all of it: the bytes are copied once when the request is built and
// curl reads them straight out.
//
// If streamed is much slower than inline, the pipe and its pause protocol are the
// cost and `BodyPipe` is worth rewriting — its `pull` compacts a `std::vector`
// with `erase(begin, begin + readPos_)`, which memmoves the tail every time the
// read cursor passes halfway, so a byte is copied ~2.5 times rather than twice.
// If they are equal, the pipe is innocent and the gap is elsewhere.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/upload_profile_test.dart

@Tags(['benchmark'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

const int _mib = int.fromEnvironment('UPLOAD_MIB', defaultValue: 8);
const int _runs = int.fromEnvironment('UPLOAD_RUNS', defaultValue: 7);

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

  testWidgets('streamed vs inline upload', (tester) async {
    final bytes = _mib * 1024 * 1024;
    final payload = Uint8List(bytes);

    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(client.dispose);

    await client.get('/bytes/1024'); // warm the connection

    final streamed = <int>[];
    final inline = <int>[];

    // Slices of the SAME pre-allocated buffer, not `deterministicByteStream`.
    // Generating the body lazily would put page generation on the streamed side
    // only, and that Dart-side cost has nothing to do with the pipe being
    // measured — a first attempt at this test did exactly that and made the pipe
    // look 38 % worse than it is.
    const sliceBytes = 64 * 1024;
    Stream<List<int>> slices() async* {
      for (var off = 0; off < bytes; off += sliceBytes) {
        yield Uint8List.sublistView(
          payload,
          off,
          off + sliceBytes > bytes ? bytes : off + sliceBytes,
        );
      }
    }

    for (var i = 0; i < _runs; i++) {
      final sw = Stopwatch()..start();
      await client.post(
        '/upload',
        body: HttpBody.stream(slices(), contentLength: bytes),
      );
      sw.stop();
      streamed.add(sw.elapsedMicroseconds);

      final sw2 = Stopwatch()..start();
      await client.post('/upload', body: HttpBody.bytes(payload));
      sw2.stop();
      inline.add(sw2.elapsedMicroseconds);
    }

    final s = _median(streamed);
    final b = _median(inline);

    // ignore: avoid_print
    print(
      'UPLOAD ${_mib}MiB us — streamed $s | inline $b | '
      'pipeOverhead ${s - b} us (${(100 * (s - b) / b).toStringAsFixed(1)}%) | '
      'streamed ${(bytes / (s / 1e6) / (1024 * 1024)).toStringAsFixed(1)} MiB/s | '
      'inline ${(bytes / (b / 1e6) / (1024 * 1024)).toStringAsFixed(1)} MiB/s',
    );

    expect(s, greaterThan(0));
  });
}
