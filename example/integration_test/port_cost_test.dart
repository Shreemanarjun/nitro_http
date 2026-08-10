// What does the completion path itself cost, with no HTTP involved?
//
// `latency_profile_test` says a 1 KiB loopback GET costs 163 us against
// `dart:io`'s 140 us, and that `queue` — the gap between the Dart call and the
// loop thread picking the request up — is only 2 us. So the remaining ~23 us
// deficit is not the engine waking up. It is the machinery on either side of
// the transfer.
//
// The prime suspect is `NitroRuntime.openNativeAsync`, which allocates a fresh
// `ReceivePort` per call and closes it when the call settles. That is a VM port
// allocation and teardown on every single request — the exact cost Nitro's
// IsolatePool already eliminated for `@nitroAsync` by keeping one persistent
// reply port and demultiplexing on a call id.
//
// This measures the pieces in isolation so the optimisation targets a number
// rather than a hunch:
//
//   1. `ReceivePort` create + close, nothing sent.
//   2. Create + close with one message round-tripped through it, which is what
//      a request actually does.
//   3. The same round trip over a single persistent port with an id demux —
//      the shape a fix would take.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/port_cost_test.dart

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Runs [body] [iterations] times and returns the median microseconds per call.
///
/// The median rather than the mean: one GC pause during a 20 000-iteration run
/// would otherwise dominate an average that is only a few microseconds wide.
Future<double> _median(
  int iterations,
  Future<void> Function() body, {
  int warmup = 2000,
}) async {
  for (var i = 0; i < warmup; i++) {
    await body();
  }
  final samples = <int>[];
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2].toDouble();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('completion-path cost', (tester) async {
    const iterations = 20000;

    // 1. Allocation and teardown alone.
    final openClose = await _median(iterations, () async {
      ReceivePort().close();
    });

    // 2. What a request pays today: a port per call, one message through it.
    //    `sendPort.send` from the same isolate still goes through the VM's
    //    message queue and an event-loop turn, which is the part that matters.
    final perCallPort = await _median(iterations, () async {
      final port = ReceivePort();
      final done = Completer<Object?>();
      port.listen((message) {
        done.complete(message);
        port.close();
      });
      port.sendPort.send(1);
      await done.future;
    });

    // 3. One persistent port shared by every call, demultiplexed on an id.
    //    Same event-loop turn, no allocation.
    final shared = ReceivePort();
    final pending = <int, Completer<Object?>>{};
    shared.listen((message) {
      final id = (message as List<Object?>)[0]! as int;
      pending.remove(id)?.complete(message[1]);
    });
    var nextId = 0;
    final sharedPort = await _median(iterations, () async {
      final id = nextId++;
      final done = Completer<Object?>();
      pending[id] = done;
      shared.sendPort.send([id, 1]);
      await done.future;
    });
    shared.close();

    // ignore: avoid_print
    print(
      'PORT COST us — openClose ${openClose.toStringAsFixed(2)} | '
      'perCallPort ${perCallPort.toStringAsFixed(2)} | '
      'sharedPort ${sharedPort.toStringAsFixed(2)} | '
      'saving ${(perCallPort - sharedPort).toStringAsFixed(2)}',
    );

    expect(openClose, greaterThanOrEqualTo(0));
  });
}
