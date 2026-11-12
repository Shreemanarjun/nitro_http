/// Where an 8 MiB upload's time goes: streamed at several chunk sizes, the
/// buffered path, and `dart:io` as the reference. Debug-mode numbers against an
/// in-isolate server — read the ratios between rows, never the absolutes.
///
///   flutter test -d macos --run-skipped integration_test/upload_probe_test.dart
@Tags(['benchmark'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

Stream<Uint8List> chunks(int total, int chunk) async* {
  final block = Uint8List(chunk);
  for (var i = 0; i < chunk; i++) {
    block[i] = i & 0xff;
  }
  var left = total;
  while (left > 0) {
    final n = left < chunk ? left : chunk;
    yield n == chunk ? block : Uint8List.sublistView(block, 0, n);
    left -= n;
  }
}

Future<double> p50(int runs, Future<void> Function() body) async {
  final t = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await body();
    t.add(sw.elapsedMicroseconds / 1000);
  }
  t.sort();
  return t[t.length ~/ 2];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('upload probe', (_) async {
    final server = await LocalServer.start();
    final client = NitroHttpClient(
      settings: ClientSettings(
        baseUrl: server.baseUrl,
        enableCompression: false,
      ),
    );
    const total = 8 << 20;
    const runs = 7;
    Future<void> nitroStream(int c) => client.post(
      '/upload',
      body: HttpBody.stream(chunks(total, c), contentLength: total),
    );
    await nitroStream(64 << 10); // warm-up
    final out = StringBuffer();
    for (final c in [16 << 10, 64 << 10, 256 << 10, 1 << 20]) {
      final ms = await p50(runs, () => nitroStream(c));
      out.writeln('nitro stream ${c >> 10} KiB chunks: ${ms.toStringAsFixed(1)} ms');
    }
    final bytes = Uint8List(total);
    final msBytes = await p50(
      runs,
      () => client.post('/upload', body: HttpBody.bytes(bytes)),
    );
    out.writeln('nitro bytes (buffered): ${msBytes.toStringAsFixed(1)} ms');
    final io = HttpClient();
    Future<void> ioStream(int c) async {
      final r = await io.postUrl(Uri.parse('${server.baseUrl}/upload'));
      r.contentLength = total;
      await r.addStream(chunks(total, c));
      final resp = await r.close();
      await resp.drain<void>();
    }
    await ioStream(64 << 10);
    for (final c in [64 << 10, 1 << 20]) {
      final ms = await p50(runs, () => ioStream(c));
      out.writeln('dart:io stream ${c >> 10} KiB chunks: ${ms.toStringAsFixed(1)} ms');
    }
    // ignore: avoid_print
    print('UPLOAD_PROBE\n$out');
    client.dispose();
    io.close(force: true);
    await server.stop();
  });
}
