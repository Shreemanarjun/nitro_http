// Standalone runner for the benchmark's `shelf` test server, so NATIVE clients
// (Swift/URLSession, Kotlin/OkHttp) can hit the exact same server — same routes,
// same deterministic `/bytes/<n>` generator, same `/upload` hashing — that the
// in-app Flutter harness uses. That identity is what makes the native-vs-nitro
// numbers a fair comparison rather than two different servers.
//
//   cd example && dart run tool/bench_serve.dart
//
// Prints `BENCH_SERVER_PORT <n>` on the first line, then serves until SIGINT.
// Android: the driver runs `adb reverse tcp:<n> tcp:<n>` so the device reaches
// it at 127.0.0.1:<n>; macOS/simulator reach 127.0.0.1:<n> directly.
library;

import 'dart:async';
import 'dart:io';

import 'package:nitro_http_example/server/local_server.dart';

Future<void> main() async {
  final server = await LocalServer.start();
  final port = Uri.parse(server.baseUrl).port;

  // First line, flushed, so a driver can capture the port deterministically.
  stdout.writeln('BENCH_SERVER_PORT $port');
  stdout.writeln('BENCH_SERVER_URL ${server.baseUrl}');
  await stdout.flush();

  // Serve until killed. Both signals so `kill` and Ctrl-C both shut down cleanly.
  final done = Completer<void>();
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  }
  await done.future;
  await server.stop();
}
