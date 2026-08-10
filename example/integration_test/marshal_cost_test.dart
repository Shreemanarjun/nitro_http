// How much of the per-request deficit is marshalling?
//
// `latency_profile_test` puts a 1 KiB loopback GET at 163 us against
// `dart:io`'s 140 us, with `queue` at 2 us. `port_cost_test` accounts for ~4 us
// of the remaining ~23 us (a `ReceivePort` per call instead of one shared
// port). This measures the other candidate: turning a request into bytes and
// bytes back into a response.
//
// `dart:io` pays none of this — it never leaves the Dart heap. Every
// microsecond here is structural overhead this design has and that one does
// not, so it is worth knowing exactly how big it is before trying to shrink it.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/marshal_cost_test.dart

import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// The generated record extensions are a `part of` this library, so importing
// the spec brings `RawRequestRecordExt` / `RawResponseRecordExt` with it.
import 'package:nitro_http/src/nitro_http.native.dart';

/// Median nanoseconds for one call of [body].
///
/// A single encode is far under the 1 us that `elapsedMicroseconds` resolves,
/// so each sample times a batch of [batch] calls and divides. The median over
/// [samples] batches then discards the GC pause that would wreck a mean.
double _medianNanos(
  void Function() body, {
  int batch = 200,
  int samples = 200,
  int warmup = 20000,
}) {
  for (var i = 0; i < warmup; i++) {
    body();
  }
  final timings = <int>[];
  for (var s = 0; s < samples; s++) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < batch; i++) {
      body();
    }
    sw.stop();
    timings.add(sw.elapsedMicroseconds);
  }
  timings.sort();
  return timings[timings.length ~/ 2] * 1000 / batch;
}

/// A response shaped like what the local server actually returns: a handful of
/// headers and a 1 KiB body, matching `latency_profile_test`.
RawResponse _sampleResponse() => RawResponse(
  requestId: 1,
  errorKind: RawErrorKind.none,
  errorMessage: '',
  engineErrorCode: 0,
  statusCode: 200,
  reasonPhrase: 'OK',
  version: RawHttpVersion.http11,
  finalUrl: 'http://127.0.0.1:8080/bytes/1024',
  redirectCount: 0,
  headers: const [
    RawHeader(name: 'content-type', value: 'application/octet-stream'),
    RawHeader(name: 'content-length', value: '1024'),
    RawHeader(name: 'date', value: 'Fri, 08 Aug 2026 12:00:00 GMT'),
    RawHeader(name: 'server', value: 'shelf'),
    RawHeader(name: 'x-request-id', value: '0123456789abcdef'),
  ],
  body: Uint8List(1024),
  fromCache: false,
  revalidated: false,
  primaryIp: '127.0.0.1',
  primaryPort: 8080,
  timings: const RawTimings(
    queueMs: 0.002,
    dnsMs: 0,
    connectMs: 0,
    tlsMs: 0,
    firstByteMs: 0.12,
    redirectMs: 0,
    totalMs: 0.15,
  ),
);

RawRequest _sampleRequest() => const RawRequest(
  requestId: 1,
  method: RawMethod.get,
  customMethod: '',
  url: 'http://127.0.0.1:8080/bytes/1024',
  headers: [
    RawHeader(name: 'accept', value: '*/*'),
    RawHeader(name: 'accept-encoding', value: 'gzip, br, zstd'),
  ],
  bodyKind: RawBodyKind.none,
  bodyFilePath: '',
  options: RawRequestOptions(
    connectTimeoutMs: -1,
    requestTimeoutMs: -1,
    followRedirects: -1,
    maxRedirects: -1,
    cacheMode: RawCacheMode.normal,
    reportProgress: false,
    wantTimings: true,
    uploadContentLength: -1,
    pinnedSpkiOverride: '',
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('marshalling cost', (tester) async {
    final request = _sampleRequest();
    final response = _sampleResponse();

    // Encode a request the way the runner does: into an arena that is released
    // when the registering call returns.
    final encodeRequest = _medianNanos(() {
      final arena = Arena();
      RawRequestRecordExt(request).toNative(arena);
      arena.releaseAll();
    });

    // Decode a response from native memory. Encode once outside the loop so the
    // measurement is the read path only.
    final holder = Arena();
    final encoded = RawResponseRecordExt(response).toNative(holder);
    final decodeResponse = _medianNanos(() {
      RawResponseRecordExt.fromNative(encoded);
    });
    holder.releaseAll();

    // The floor: allocating and releasing the arena with nothing in it.
    final arenaOnly = _medianNanos(() {
      final a = Arena();
      a.releaseAll();
    });

    // ignore: avoid_print
    print(
      'MARSHAL ns — encodeRequest ${encodeRequest.toStringAsFixed(0)} | '
      'decodeResponse ${decodeResponse.toStringAsFixed(0)} | '
      'arenaOnly ${arenaOnly.toStringAsFixed(0)} | '
      'roundTrip us '
      '${((encodeRequest + decodeResponse) / 1000).toStringAsFixed(2)}',
    );

    expect(encodeRequest, greaterThan(0));
  });
}
