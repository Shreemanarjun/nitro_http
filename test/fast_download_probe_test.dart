// A large download from the native source, streamed and buffered. The Dart
// test servers send more slowly than the engine receives, so only this shows
// what the engine's own path costs.
//
//   URL=$(tool/bench_native/source/source.sh start macos)
//   DOWNLOAD_SOURCE=$URL flutter test --run-skipped test/fast_download_probe_test.dart
//   tool/bench_native/source/source.sh stop macos
@Tags(['benchmark'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';
import 'package:nitro_http/nitro_http.dart';

const int _mib = 256;
const int _bytes = _mib * 1024 * 1024;

double _p50(List<int> micros) {
  micros.sort();
  return micros[micros.length ~/ 2] / 1000;
}

void main() {
  final lib = File('build/lib/libnitro_http.dylib');
  final source = Platform.environment['DOWNLOAD_SOURCE'];

  test('a large download from a fast source', () async {
    DynamicLibrary.open(lib.absolute.path);
    final client = NitroHttpClient();
    final url = '$source/bytes/$_bytes';

    Future<int> streamed() async {
      final watch = Stopwatch()..start();
      final response = await client.requestStream(HttpMethod.get, url);
      var total = 0;
      await for (final chunk in response.body) {
        total += chunk.length;
      }
      watch.stop();
      expect(total, _bytes);
      return watch.elapsedMicroseconds;
    }

    Future<int> buffered() async {
      final watch = Stopwatch()..start();
      final response = await client.requestBytes(HttpMethod.get, url);
      watch.stop();
      expect(response.bodyBytes.length, _bytes);
      return watch.elapsedMicroseconds;
    }

    await streamed();
    await buffered();
    final stream = <int>[], whole = <int>[];
    for (var round = 0; round < 10; round++) {
      stream.add(await streamed());
      whole.add(await buffered());
    }
    client.dispose();
    final s = _p50(stream), b = _p50(whole);
    // ignore: avoid_print
    print('FAST_DOWNLOAD $_mib MiB  streamed ${s.toStringAsFixed(1)} ms '
        '(${(_mib * 1000 / s).toStringAsFixed(0)} MiB/s)   '
        'buffered ${b.toStringAsFixed(1)} ms '
        '(${(_mib * 1000 / b).toStringAsFixed(0)} MiB/s)');
  }, skip: !lib.existsSync()
      ? 'build/lib/libnitro_http.dylib missing'
      : source == null
          ? 'set DOWNLOAD_SOURCE to the native source URL'
          : null);
}
