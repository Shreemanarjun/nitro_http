/// Streaming: the credit window, streamed uploads, and the memory bound that
/// makes the whole design worth having.
///
/// The headline test downloads 100 MB into a deliberately slow consumer and
/// asserts two things at once: the SHA-256 matches (so the credit window never
/// dropped or reordered a byte) and the peak RSS stays within a bound (so
/// nothing buffered the body while the consumer dawdled). Either assertion alone
/// is easy to satisfy the wrong way — buffer everything, or drop what does not
/// fit. Together they pin the behaviour.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

/// The download size the plan calls for.
const int hundredMegabytes = 100 * 1024 * 1024;

/// The streamed-upload size the plan calls for.
const int tenMegabytes = 10 * 1024 * 1024;

/// How much resident memory the 100 MB download may add.
///
/// Generous enough to absorb the Flutter engine's own churn during a test run,
/// and still an order of magnitude below the ~100 MB a full-body buffer would
/// cost. That gap is the assertion.
const int rssHeadroomBytes = 64 * 1024 * 1024;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;
  late NitroHttpClient client;

  setUp(() async {
    server = await LocalServer.start();
    client = NitroHttpClient(
      settings: ClientSettings(
        baseUrl: server.baseUrl,
        // Random bytes do not compress; asking for gzip would only burn CPU on
        // both ends and hide the throughput this test is about.
        enableCompression: false,
        idleTimeout: const Duration(seconds: 30),
      ),
    );
  });

  tearDown(() async {
    client.dispose();
    await server.stop();
  });

  testWidgets(
    '100 MB into a slow consumer: hash matches and RSS stays bounded',
    (_) async {
      final expected = await deterministicDigest(hundredMegabytes);

      // Settle first so the baseline is not measured mid-allocation.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final baselineRss = ProcessInfo.currentRss;
      var peakRss = baselineRss;

      final response = await client.requestStream(
        HttpMethod.get,
        '/bytes/$hundredMegabytes',
      );
      expect(response.statusCode, 200);
      expect(response.contentLength, hundredMegabytes);

      final digestSink = _HexDigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      var received = 0;
      var chunks = 0;

      // `await for` pauses the subscription between iterations, so every
      // suspension below really does withhold credits.
      await for (final chunk in response.body) {
        received += chunk.length;
        chunks++;
        hasher.add(chunk);

        final rss = ProcessInfo.currentRss;
        if (rss > peakRss) peakRss = rss;

        // A real event-loop turn per chunk: enough to keep the consumer behind
        // the loopback server, which can produce faster than anything can eat.
        await Future<void>.delayed(Duration.zero);
        // And three hard stalls, to slam the receive window shut rather than
        // merely throttle it.
        if (chunks == 16 || chunks == 128 || chunks == 512) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      hasher.close();

      expect(received, hundredMegabytes, reason: 'byte count');
      expect(digestSink.value, expected, reason: 'SHA-256 of the streamed body');
      expect(
        chunks,
        greaterThan(1),
        reason: 'a single chunk would mean the body was buffered whole',
      );
      expect(
        peakRss - baselineRss,
        lessThan(rssHeadroomBytes),
        reason:
            'peak RSS grew by ${peakRss - baselineRss} B while streaming '
            '$hundredMegabytes B — something buffered the body',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets('a chunked response reports an unknown content length', (_) async {
    final response = await client.requestStream(HttpMethod.get, '/drip/4/10');
    expect(response.contentLength, isNull);

    var received = 0;
    await for (final chunk in response.body) {
      received += chunk.length;
    }
    expect(received, 4 * defaultDripChunkBytes);
  });

  testWidgets('cancelling a streamed body mid-transfer fails the stream',
      (_) async {
    final token = CancelToken();
    final response = await client.requestStream(
      HttpMethod.get,
      '/drip/4096/5',
      cancelToken: token,
    );

    var received = 0;
    Object? failure;
    try {
      await for (final chunk in response.body) {
        received += chunk.length;
        if (received > defaultDripChunkBytes) token.cancel('enough');
      }
    } on Object catch (error) {
      failure = error;
    }

    expect(failure, isA<NitroHttpCancelException>());
    expect(
      received,
      lessThan(4096 * defaultDripChunkBytes),
      reason: 'the transfer must have been abandoned, not completed',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a 10 MB streamed upload arrives byte-for-byte', (_) async {
    final expected = await deterministicDigest(tenMegabytes);

    final response = await client.post(
      '/upload',
      body: HttpBody.stream(
        deterministicByteStream(tenMegabytes),
        contentLength: tenMegabytes,
        contentType: 'application/octet-stream',
      ),
    );

    final decoded = response.bodyToJson() as Map<String, Object?>;
    expect(decoded['bytes'], tenMegabytes);
    expect(
      decoded['sha256'],
      expected,
      reason: 'the server hashed something other than what we generated',
    );
    expect(server.lastUploadBytes, tenMegabytes);
    expect(server.lastUploadTruncated, isFalse);
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('an upload with no declared length goes out chunked', (_) async {
    const size = 512 * 1024;
    final expected = await deterministicDigest(size);

    final response = await client.post(
      '/upload',
      body: HttpBody.stream(deterministicByteStream(size)),
    );

    expect((response.bodyToJson() as Map<String, Object?>)['sha256'], expected);
    expect(server.lastUploadBytes, size);
  });

  testWidgets('a source that errors mid-upload fails the request', (_) async {
    const declared = tenMegabytes;
    const sentBeforeFailure = 4 * deterministicPageBytes;

    Stream<Uint8List> failing() async* {
      yield* deterministicByteStream(sentBeforeFailure);
      throw const FileSystemException('simulated read failure mid-upload');
    }

    await expectLater(
      client.post(
        '/upload',
        body: HttpBody.stream(failing(), contentLength: declared),
      ),
      throwsA(isA<NitroHttpException>()),
    );

    // The point of the test: the server must not have been handed a short body
    // and told it was complete.
    expect(
      server.lastUploadBytes,
      lessThan(declared),
      reason: 'a truncated upload was accepted as if it were whole',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a streamed request body is never replayed by a retry', (_) async {
    // `RetryInterceptor` would happily resend a buffered body; a stream has
    // already been consumed, so the client must surrender instead.
    final retrying = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl, throwOnStatusCode: false),
      interceptors: [RetryInterceptor(maxRetries: 3)],
    );
    addTearDown(retrying.dispose);

    final response = await retrying.post(
      '/status/503',
      body: HttpBody.stream(
        deterministicByteStream(4 * deterministicPageBytes),
        contentLength: 4 * deterministicPageBytes,
      ),
    );

    expect(response.statusCode, 503);
    expect(
      server.requestsFor('/status/503'),
      1,
      reason: 'the streamed body must not have been sent twice',
    );
  });
}

/// Collects the hex digest of a chunked `sha256` conversion.
final class _HexDigestSink implements Sink<Digest> {
  String value = '';

  @override
  void add(Digest data) => value = data.toString();

  @override
  void close() {}
}
