// An in-memory body posted to the native upload sink.
//
//   URL=$(tool/bench_native/sink/sink.sh start macos)
//   UPLOAD_SINK=$URL flutter test --run-skipped test/inline_upload_probe_test.dart
//   tool/bench_native/sink/sink.sh stop macos
@Tags(['benchmark'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:nitro_http/nitro_http.dart';

double _p50(List<int> micros) {
  micros.sort();
  return micros[micros.length ~/ 2] / 1000;
}

void main() {
  final lib = File('build/lib/libnitro_http.dylib');
  final sink = Platform.environment['UPLOAD_SINK'];

  test('in-memory uploads', () async {
    DynamicLibrary.open(lib.absolute.path);
    final client = NitroHttpClient();
    // ignore: avoid_print
    print('INLINE_UPLOAD_PROBE');
    for (final mib in [1, 8, 32]) {
      final bytes = Uint8List(mib * 1024 * 1024)..fillRange(0, mib * 1024 * 1024, 0x61);

      final post = <int>[];
      final watch = Stopwatch();
      for (var i = 0; i < 24; i++) {
        watch
          ..reset()
          ..start();
        final response = await client.requestBytes(
          HttpMethod.post,
          '$sink/upload',
          body: HttpBody.bytes(bytes),
        );
        watch.stop();
        expect(response.statusCode, 200);
        if (i >= 4) post.add(watch.elapsedMicroseconds);
      }
      // ignore: avoid_print
      print('$mib MiB  post: ${_p50(post).toStringAsFixed(2)} ms');
    }
    client.dispose();
  }, skip: !lib.existsSync()
      ? 'build/lib/libnitro_http.dylib missing'
      : sink == null
          ? 'set UPLOAD_SINK to the native sink URL'
          : null);
}
