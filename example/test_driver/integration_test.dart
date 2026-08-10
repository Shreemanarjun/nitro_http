// Driver for `flutter drive`, which is the only way to run an integration test
// in profile or release mode. `flutter test -d <device>` always builds debug, and
// debug-mode timings are not worth quoting: the Dart layer of every client pays
// JIT warm-up and assertion overhead.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/benchmark_test.dart
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
