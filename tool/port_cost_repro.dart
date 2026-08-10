// ignore_for_file: avoid_print
//
// Standalone reproduction: the cost of a ReceivePort per call.
//
//   dart compile exe main.dart -o repro && ./repro
//
// AOT-compiled on purpose. `dart run` is JIT and flatters the allocation path.

import 'dart:async';
import 'dart:isolate';

Future<double> _medianMicros(
  Future<void> Function() body, {
  int batch = 200,
  int samples = 200,
  int warmup = 20000,
}) async {
  for (var i = 0; i < warmup; i++) {
    await body();
  }
  final timings = <int>[];
  for (var s = 0; s < samples; s++) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < batch; i++) {
      await body();
    }
    sw.stop();
    timings.add(sw.elapsedMicroseconds);
  }
  timings.sort();
  return timings[timings.length ~/ 2] / batch;
}

Future<void> main() async {
  // What `openNativeAsync` does today: a fresh port per call, closed on settle.
  final perCall = await _medianMicros(() async {
    final port = ReceivePort();
    final done = Completer<Object?>();
    port.listen((message) {
      done.complete(message);
      port.close();
    });
    port.sendPort.send(1);
    await done.future;
  });

  // What `IsolatePool` already does: one port for the lifetime, callId demux.
  final shared = ReceivePort();
  final pending = <int, Completer<Object?>>{};
  shared.listen((message) {
    final envelope = message as List<Object?>;
    pending.remove(envelope[0]! as int)?.complete(envelope[1]);
  });
  var nextId = 0;
  final sharedPort = await _medianMicros(() async {
    final id = nextId++;
    final done = Completer<Object?>();
    pending[id] = done;
    shared.sendPort.send([id, 1]);
    await done.future;
  });
  shared.close();

  print('per-call ReceivePort : ${perCall.toStringAsFixed(2)} us');
  print('shared port + callId : ${sharedPort.toStringAsFixed(2)} us');
  print('saving               : ${(perCall - sharedPort).toStringAsFixed(2)} us'
      ' (${(100 * (perCall - sharedPort) / perCall).toStringAsFixed(0)}%)');
}
