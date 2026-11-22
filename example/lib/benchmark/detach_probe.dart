// Copying a response body into Dart against adopting it with a finalizer, per
// size: the trade `kDetachBodyMinBytes` in src/engine/Wire.h decides.
//
// Run by `--dart-define=BENCH_PROBE=detach` in place of the benchmark, and by
// integration_test/detach_threshold_test.dart. `BENCH_PROBE=sizes` runs
// [runSizeProbe] instead: whole requests, for comparing builds that differ in
// that constant.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:nitro_http/nitro_http.dart';

const List<int> _sizesKiB = <int>[1, 2, 4, 8, 12, 16, 24, 32, 64, 128];

/// The engine's copy path makes two passes over a body: into the record,
/// which is posted to Dart as it is, and out of it into a `Uint8List`.
int _copyPath(Pointer<Uint8> body, int size) {
  final record = malloc<Uint8>(size);
  record.asTypedList(size).setRange(0, size, body.asTypedList(size));
  malloc.free(body);
  final bytes = Uint8List.fromList(record.asTypedList(size));
  malloc.free(record);
  return bytes[size - 1];
}

/// Read back by [_microsPer], or the compiler drops the store.
Uint8List? _held;

int _adoptPath(Pointer<Uint8> body, int size) {
  final bytes = body.asTypedList(size, finalizer: malloc.nativeFree);
  // A response holds its body. A list nothing holds can be collected while
  // its finalizer is being attached, and the read below then hits freed
  // memory: the compiler reads through the address, not the list.
  _held = bytes;
  return bytes[size - 1];
}

double _microsPer(int Function(Pointer<Uint8>, int) path, int size) {
  final iterations = (64 * 1024 * 1024 ~/ size).clamp(2000, 40000);
  var best = double.infinity;
  var sink = 0;
  for (var round = 0; round < 5; round++) {
    final watch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      final body = malloc<Uint8>(size);
      body[size - 1] = i;
      sink += path(body, size);
    }
    watch.stop();
    final micros = watch.elapsedMicroseconds / iterations;
    if (micros < best) best = micros;
  }
  return sink + (_held?.length ?? 0) < 0 ? 0 : best;
}

/// One line per size: microseconds per body for each path. Yields between
/// sizes so a driver's health check is answered.
Future<List<String>> runDetachProbe() async {
  final lines = <String>['DETACH_PROBE size | copy us | adopt us'];
  for (final kib in _sizesKiB) {
    await Future<void>.delayed(Duration.zero);
    lines.add('${kib.toString().padLeft(3)} KiB | '
        '${_microsPer(_copyPath, kib * 1024).toStringAsFixed(2)} | '
        '${_microsPer(_adoptPath, kib * 1024).toStringAsFixed(2)}');
  }
  return lines;
}

/// One line per size: median microseconds of a buffered GET against
/// [baseUrl], for each of three passes over all sizes.
Future<List<String>> runSizeProbe(String baseUrl) async {
  const sizesKiB = <int>[2, 4, 6, 8, 12, 16, 24, 32, 48];
  final client = NitroHttpClient(settings: ClientSettings(baseUrl: baseUrl));
  final medians = <int, List<int>>{for (final kib in sizesKiB) kib: <int>[]};
  final watch = Stopwatch();
  for (var pass = 0; pass < 3; pass++) {
    for (final kib in sizesKiB) {
      final micros = <int>[];
      for (var i = 0; i < 1300; i++) {
        watch
          ..reset()
          ..start();
        await client.requestBytes(HttpMethod.get, '/bytes/${kib * 1024}');
        watch.stop();
        if (i >= 100) micros.add(watch.elapsedMicroseconds);
      }
      micros.sort();
      medians[kib]!.add(micros[micros.length ~/ 2]);
    }
  }
  client.dispose();
  return <String>[
    'SIZE_PROBE size | p50 us per pass',
    for (final kib in sizesKiB)
      '${kib.toString().padLeft(3)} KiB | ${medians[kib]!.join(' ')}',
  ];
}
