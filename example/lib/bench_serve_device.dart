// Device-local benchmark server entrypoint. Built as its own APK target so a
// standalone native client (OkHttp via `app_process`) can hit the SAME `shelf`
// server the in-app nitro_http harness uses — on the device's own loopback,
// with no `adb reverse` USB tunnel. That tunnel otherwise caps device
// throughput at ~USB speed and adds a round-trip to every request, which
// dominates the comparison and makes the numbers meaningless (measured: it
// turned a device-local 1.2 ms small GET into 4.6 ms, and 113 MiB/s into 29).
//
//   flutter build apk --release --target lib/bench_serve_device.dart \
//       --target-platform android-arm64
//
// Once the server is up it logs `BENCH_SERVE_URL=http://127.0.0.1:<port>` (grep
// it from `adb logcat -s flutter:I`), then stays alive until the app is
// force-stopped. The on-screen text is only so a human can see it is serving.
library;

import 'package:flutter/material.dart';

import 'server/local_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final server = await LocalServer.start();
  // Release builds keep `debugPrint`, and it reaches logcat — this is how the
  // driver discovers the ephemeral port without parsing /proc/net/tcp.
  debugPrint('BENCH_SERVE_URL=${server.baseUrl}');
  runApp(_ServeApp(url: server.baseUrl));
}

class _ServeApp extends StatelessWidget {
  const _ServeApp({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Text('benchmark server\n$url', textAlign: TextAlign.center),
          ),
        ),
      );
}
