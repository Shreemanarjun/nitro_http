// Small kept-alive GETs over plain HTTP on the loopback, with and without
// libcurl timings.
//
//   flutter test --run-skipped test/small_request_probe_test.dart
@Tags(['benchmark'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';
import 'package:nitro_http/nitro_http.dart';

const int _requests = 2000;

void main() {
  final lib = File('build/lib/libnitro_http.dylib');

  test('small kept-alive requests', () async {
    DynamicLibrary.open(lib.absolute.path);
    final body = List<int>.filled(1024, 0x61);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..headers.contentType = ContentType.binary
        ..add(body);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/';
    final client = NitroHttpClient();

    Future<double> p50({required bool timings}) async {
      final options = RequestOptions(wantTimings: timings);
      final micros = <int>[];
      final watch = Stopwatch();
      for (var i = 0; i < _requests + 200; i++) {
        watch
          ..reset()
          ..start();
        await client.requestBytes(HttpMethod.get, url, options: options);
        watch.stop();
        if (i >= 200) micros.add(watch.elapsedMicroseconds);
      }
      micros.sort();
      return micros[micros.length ~/ 2].toDouble();
    }

    // ignore: avoid_print
    print('SMALL_REQUEST_PROBE');
    for (var round = 0; round < 4; round++) {
      final on = await p50(timings: true);
      final off = await p50(timings: false);
      // ignore: avoid_print
      print('round $round  timings on: ${on.toStringAsFixed(0)} us   '
          'timings off: ${off.toStringAsFixed(0)} us');
    }

    client.dispose();
    await server.close(force: true);
  }, skip: lib.existsSync() ? null : 'build/lib/libnitro_http.dylib missing');
}
