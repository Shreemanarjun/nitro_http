// Where adopting a response body starts to beat copying it. See
// lib/benchmark/detach_probe.dart.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/detach_threshold_test.dart

@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http_example/benchmark/detach_probe.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('copy vs adopt by body size', (tester) async {
    // ignore: avoid_print
    (await runDetachProbe()).forEach(print);
  });
}
