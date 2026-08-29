// How much of the 49 us of glue is Dart, and how much is native?
//
// `budget_split_test` puts a 1 KiB loopback GET at 164 us: 2 us of queue,
// 113 us inside libcurl, and 49 us of everything this plugin does around the
// transfer. `dart:io` does the same request in 137 us, so ~21 us of that glue
// is the deficit.
//
// This drives a real `NitroHttpClient` against a fake executor that completes
// instantly with a canned response. No native library, no socket — what is left
// is exactly the Dart-side cost: building the request, resolving the URL,
// running the interceptor chain, mapping to and from the `Raw*` records, and
// constructing the response and its header map.
//
// Whatever this does not account for is native glue, and that is where handle
// pooling would pay off.
//
//   cd example
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/dart_glue_cost_test.dart

@Tags(['benchmark'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/request_runner.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

/// Completes every send with the same canned response, synchronously.
///
/// `Future.value` rather than a `Completer` so the measurement is the runner's
/// own work plus one microtask, not scheduler latency.
class _InstantExecutor implements RequestExecutor {
  _InstantExecutor(this._response);

  final RawResponse _response;

  @override
  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body) =>
      Future.value(_response);

  @override
  Future<RawResponseHead> startStreamed(RawRequest request, Uint8List body) =>
      throw UnimplementedError();

  @override
  void configureClient(RawClientConfig config) {}
  @override
  void cancel(int requestId) {}
  @override
  void cancelAll() {}
  @override
  void cancelToken(int tokenId, String reason) {}
  @override
  void releaseCancelToken(int tokenId) {}
  @override
  void grantCredit(int requestId, int chunkCount, int ackedChunks) {}
  @override
  int feedUploadChunk(int requestId, Uint8List chunk) => 0;
  @override
  void finishUpload(int requestId) {}
  @override
  void failUpload(int requestId, String message) {}
  @override
  List<RawCookie> getCookies(String url) => const [];
  @override
  void setCookie(RawCookie cookie) {}
  @override
  void clearCookies() {}
  @override
  void flushCookies() {}
  @override
  void dispose() {}
}

/// The same response shape `budget_split_test` measures against: five headers
/// and a 1 KiB body.
RawResponse _cannedResponse() => RawResponse(
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
    queueMs: 0,
    dnsMs: 0,
    connectMs: 0,
    tlsMs: 0,
    firstByteMs: 0,
    redirectMs: 0,
    totalMs: 0,
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Dart-side glue', (tester) async {
    const iterations = 20000;
    const warmup = 5000;

    final client = NitroHttpClient(
      settings: const ClientSettings(baseUrl: 'http://127.0.0.1:8080'),
      executor: _InstantExecutor(_cannedResponse()),
    );

    for (var i = 0; i < warmup; i++) {
      await client.get('/bytes/1024');
    }

    final samples = <int>[];
    // Batched: one round trip is a fraction of the 1 us `elapsedMicroseconds`
    // can resolve.
    const batch = 100;
    for (var i = 0; i < iterations ~/ batch; i++) {
      final sw = Stopwatch()..start();
      for (var j = 0; j < batch; j++) {
        await client.get('/bytes/1024');
      }
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    samples.sort();
    final perCall = samples[samples.length ~/ 2] / batch;

    // The floor an empty async round trip costs, so the number above can be
    // read as "runner work plus one await".
    final awaitSamples = <int>[];
    for (var i = 0; i < iterations ~/ batch; i++) {
      final sw = Stopwatch()..start();
      for (var j = 0; j < batch; j++) {
        await Future.value(0);
      }
      sw.stop();
      awaitSamples.add(sw.elapsedMicroseconds);
    }
    awaitSamples.sort();
    final awaitFloor = awaitSamples[awaitSamples.length ~/ 2] / batch;

    // ignore: avoid_print
    print(
      'DART GLUE us — perCall ${perCall.toStringAsFixed(2)} | '
      'awaitFloor ${awaitFloor.toStringAsFixed(2)} | '
      'runnerWork ${(perCall - awaitFloor).toStringAsFixed(2)}',
    );

    expect(perCall, greaterThan(0));
  });
}
