// HTTP/2 against HTTP/1.1 over TLS, to a server on the Mac. See
// lib/benchmark/remote_tls_probe.dart.
//
//   PORT=$(tool/bench_native/h2tls/server.sh start)
//   cd example
//   flutter drive --profile -d macos \
//     --dart-define=BENCH_REMOTE_URL=https://127.0.0.1:$PORT/bytes/1024 \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/remote_tls_test.dart
//   ../tool/bench_native/h2tls/server.sh stop
//
// From an Android emulator the Mac is https://10.0.2.2:<port>.

@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http_example/benchmark/remote_tls_probe.dart';

const String _url = String.fromEnvironment('BENCH_REMOTE_URL');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('parallel requests to one TLS host', (tester) async {
    // ignore: avoid_print
    (await runRemoteTlsProbe(_url)).forEach(print);
  }, skip: _url.isEmpty);
}
