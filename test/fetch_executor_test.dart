import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/executor_fetch.dart';
import 'package:nitro_http/src/internal/raw_mapping.dart';
import 'package:nitro_http/src/internal/request_runner.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

/// The web executor, driven on the VM against a fake `http.Client`.
///
/// `executor_web.dart` only picks `BrowserClient`; every decision — how a
/// request is shaped, how a response and its failures are mapped back, which
/// settings a page cannot honour — lives here, so it is testable without a
/// browser.
void main() {
  RawRequest request({
    String url = 'https://example.com/thing',
    RawMethod method = RawMethod.get,
    String customMethod = '',
    List<RawHeader> headers = const [],
    int followRedirects = 1,
    int requestTimeoutMs = -1,
    int connectTimeoutMs = -1,
    RawCacheMode cacheMode = RawCacheMode.normal,
    RawBodyKind bodyKind = RawBodyKind.none,
    int uploadContentLength = -1,
  }) => RawRequest(
    requestId: 1,
    method: method,
    customMethod: customMethod,
    url: url,
    headers: headers,
    bodyKind: bodyKind,
    bodyFilePath: '',
    options: RawRequestOptions(
      connectTimeoutMs: connectTimeoutMs,
      requestTimeoutMs: requestTimeoutMs,
      followRedirects: followRedirects,
      maxRedirects: -1,
      cacheMode: cacheMode,
      reportProgress: false,
      wantTimings: true,
      uploadContentLength: uploadContentLength,
      pinnedSpkiOverride: '',
      cancelTokenId: 0,
    ),
  );

  // Built from real `ClientSettings` through the real mapper, so the rejection
  // is checked against what a caller would actually produce.
  RawClientConfig config([ClientSettings settings = const ClientSettings()]) =>
      toRawClientConfig(settings);

  group('request mapping', () {
    test('method, url and headers reach the client', () async {
      late http.BaseRequest seen;
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          seen = r;
          return http.Response('ok', 200);
        }),
      );

      await executor.sendBuffered(
        request(
          method: RawMethod.post,
          headers: const [RawHeader(name: 'x-trace', value: 'abc')],
        ),
        Uint8List.fromList(utf8.encode('payload')),
      );

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://example.com/thing');
      expect(seen.headers['x-trace'], 'abc');
      expect((seen as http.Request).body, 'payload');
    });

    test('a custom verb is sent verbatim', () async {
      late http.BaseRequest seen;
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          seen = r;
          return http.Response('', 200);
        }),
      );

      await executor.sendBuffered(
        request(customMethod: 'REPORT'),
        Uint8List(0),
      );
      expect(seen.method, 'REPORT');
    });

    test('followRedirects 0 is honoured', () async {
      late http.BaseRequest seen;
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          seen = r;
          return http.Response('', 200);
        }),
      );

      await executor.sendBuffered(request(followRedirects: 0), Uint8List(0));
      expect(seen.followRedirects, isFalse);
    });
  });

  group('response mapping', () {
    test('status, headers and body come back', () async {
      final executor = FetchRequestExecutor(
        MockClient(
          (r) async => http.Response(
            'hello',
            201,
            headers: {'content-type': 'text/plain'},
            reasonPhrase: 'Created',
          ),
        ),
      );

      final response = await executor.sendBuffered(request(), Uint8List(0));

      expect(response.errorKind, RawErrorKind.none);
      expect(response.statusCode, 201);
      expect(utf8.decode(response.body), 'hello');
      expect(
        response.headers.any(
          (h) => h.name == 'content-type' && h.value == 'text/plain',
        ),
        isTrue,
      );
    });

    test('a transport failure becomes an io error, not an exception', () async {
      // `fetch` collapses DNS, refused and CORS into one opaque failure on
      // purpose, so the executor must not invent a more specific kind.
      final executor = FetchRequestExecutor(
        MockClient((r) async => throw http.ClientException('Failed to fetch')),
      );

      final response = await executor.sendBuffered(request(), Uint8List(0));

      expect(response.errorKind, RawErrorKind.io);
      expect(response.errorMessage, contains('Failed to fetch'));
      expect(response.statusCode, 0);
    });

    test('only the total timing is reported, never invented phases', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );

      final response = await executor.sendBuffered(request(), Uint8List(0));

      // A page cannot see DNS, connect or TLS separately.
      expect(response.timings.dnsMs, 0);
      expect(response.timings.connectMs, 0);
      expect(response.timings.tlsMs, 0);
      expect(response.timings.totalMs, greaterThanOrEqualTo(0));
    });
  });

  group('streaming', () {
    test('body chunks reach the demux and end with a done chunk', () async {
      final executor = FetchRequestExecutor(
        MockClient.streaming((r, body) async {
          return http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('one'),
              utf8.encode('two'),
            ]),
            200,
          );
        }),
      );

      final collected = <ChunkEvent>[];
      final done = Completer<void>();
      FetchStreamDemux.instance.chunks(1).listen((event) {
        collected.add(event);
        if (event.isDone) done.complete();
      });

      final head = await executor.startStreamed(request(), Uint8List(0));
      expect(head.statusCode, 200);
      await done.future.timeout(const Duration(seconds: 5));

      final data = collected.where((c) => c.isData).toList();
      expect(data, hasLength(2));
      expect(utf8.decode(data.first.bytes), 'one');
      expect(utf8.decode(data.last.bytes), 'two');
      expect(collected.last.isDone, isTrue);
      FetchStreamDemux.instance.release(1);
    });
  });

  group('what a browser cannot do', () {
    test('pinning, mTLS, proxies and DoH are refused, not ignored', () async {
      // Silently dropping a pin would be worse than failing: the caller would
      // believe a certificate was being checked when nothing was.
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );

      expect(
        () => executor.configureClient(
          config(
            const ClientSettings(
              tlsSettings: TlsSettings(pinnedSpkiSha256: ['sha256//abc']),
            ),
          ),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      expect(
        () => executor.configureClient(
          config(const ClientSettings(tlsSettings: TlsSettings.insecure())),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      expect(
        () => executor.configureClient(
          config(
            const ClientSettings(
              proxySettings: ProxySettings.http('http://proxy.local:8080'),
            ),
          ),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
    });

    test('a default configuration is accepted', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );
      expect(() => executor.configureClient(config()), returnsNormally);
    });

    test('feeding a request that is not streaming is inert', () async {
      // No sink exists for a buffered request, so a stray feed reports nothing
      // buffered rather than throwing at the runner.
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );
      expect(executor.feedUploadChunk(999, Uint8List(4)), 0);
    });
  });

  group('parity with the engine', () {
    test('a request that outlives its deadline times out', () async {
      // Nothing enforced a deadline on web before this: a hung request simply
      // never returned, where the same call on the engine would have failed.
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('late', 200);
        }),
      );

      final response = await executor.sendBuffered(
        request(requestTimeoutMs: 150),
        Uint8List(0),
      );

      expect(response.errorKind, RawErrorKind.timeoutRequest);
      expect(response.statusCode, 0);
    });

    test('the shortest of the deadlines wins', () async {
      // `fetch` cannot separate connecting from transferring, so both bound the
      // whole call. Stricter than the engine, never looser.
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('late', 200);
        }),
      );

      final response = await executor.sendBuffered(
        request(requestTimeoutMs: 4000, connectTimeoutMs: 150),
        Uint8List(0),
      );
      expect(response.errorKind, RawErrorKind.timeoutRequest);
    });

    test('a request with no deadline is left alone', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('ok', 200)),
      );
      final response = await executor.sendBuffered(request(), Uint8List(0));
      expect(response.errorKind, RawErrorKind.none);
    });

    test('download progress is reported as bytes arrive', () async {
      // `onReceiveProgress` was silent on web: the events stream existed but
      // nothing ever pushed to it.
      final executor = FetchRequestExecutor(
        MockClient.streaming(
          (r, body) async => http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('12345'),
              utf8.encode('67890'),
            ]),
            200,
            contentLength: 10,
          ),
        ),
      );

      final events = <RawEvent>[];
      FetchStreamDemux.instance.events(1).listen(events.add);
      await executor.startStreamed(request(), Uint8List(0));
      await pumpEventQueue();

      expect(events, isNotEmpty);
      expect(events.every((e) => e.kind == RawEventKind.downloadProgress), isTrue);
      expect(events.last.a, 10, reason: 'final event should carry every byte');
      expect(events.last.b, 10, reason: 'total should be the declared length');
      FetchStreamDemux.instance.release(1);
    });

    test('cookies follow the client setting rather than a web-only knob',
        () async {
      final seen = <bool>[];
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
        setCredentials: seen.add,
      );

      executor.configureClient(
        toRawClientConfig(
          const ClientSettings(cookieSettings: CookieSettings()),
        ),
      );
      executor.configureClient(
        toRawClientConfig(
          const ClientSettings(cookieSettings: CookieSettings(storeCookies: false)),
        ),
      );

      expect(seen, [true, false]);
    });
  });

  group('cache mode', () {
    test('every mode maps to the fetch mode that means the same thing', () {
      expect(fetchCacheModeOf(RawCacheMode.normal), 'default');
      expect(fetchCacheModeOf(RawCacheMode.noStore), 'no-store');
      // "Ignore what is stored and go to the network" is `reload`, not
      // `no-cache`, which would still revalidate against the entry.
      expect(fetchCacheModeOf(RawCacheMode.bypass), 'reload');
      expect(fetchCacheModeOf(RawCacheMode.onlyIfCached), 'only-if-cached');
      expect(fetchCacheModeOf(RawCacheMode.refresh), 'no-cache');
    });

    test('it rides on the request, not in the headers', () async {
      // It used to travel as `x-nitro-fetch-cache`, which meant the client had
      // to strip a header out of the caller's map — and would have eaten a
      // header of that name had a caller ever set one. Read through
      // `BaseClient.send`, which is the interface the real browser client
      // implements and where the tag has to survive.
      final client = _CapturingClient();
      final executor = FetchRequestExecutor(client);

      await executor.sendBuffered(
        request(cacheMode: RawCacheMode.noStore),
        Uint8List(0),
      );

      expect(fetchCacheMode[client.seen!], 'no-store');
      expect(
        client.seen!.headers.keys.any((k) => k.toLowerCase().contains('nitro')),
        isFalse,
        reason: 'no private header should reach the request',
      );
    });

    test('a caller header of the old name is left alone', () async {
      final client = _CapturingClient();
      final executor = FetchRequestExecutor(client);

      await executor.sendBuffered(
        request(
          headers: const [
            RawHeader(name: 'x-nitro-fetch-cache', value: 'mine'),
          ],
        ),
        Uint8List(0),
      );

      expect(client.seen!.headers['x-nitro-fetch-cache'], 'mine');
    });
  });

  group('resource timings', () {
    // The browser reports milestones; the engine reports time-from-start. These
    // pin the translation, so `HttpTimings` means one thing on every platform.
    test('every figure is measured from the start of the request', () {
      final timings = timingsFromMilestones(
        start: 100,
        domainLookupEnd: 110,
        connectEnd: 125,
        secureConnectionStart: 115,
        responseStart: 140,
        redirectEnd: 105,
        duration: 60,
      );

      expect(timings.dnsMs, 10);
      expect(timings.connectMs, 25);
      // TLS finishes with the connection, so it is measured to the same point.
      expect(timings.tlsMs, 25);
      expect(timings.firstByteMs, 40);
      expect(timings.redirectMs, 5);
      expect(timings.totalMs, 60);
    });

    test('a reused connection reports zero for DNS and connect', () {
      // Not missing data: the browser records those milestones as the start,
      // and the engine reports the same zero when curl reuses a connection.
      final timings = timingsFromMilestones(
        start: 200,
        domainLookupEnd: 200,
        connectEnd: 200,
        secureConnectionStart: 0,
        responseStart: 202,
        redirectEnd: 0,
        duration: 3,
      );

      expect(timings.dnsMs, 0);
      expect(timings.connectMs, 0);
      expect(timings.firstByteMs, 2);
      expect(timings.totalMs, 3);
    });

    test('plain http reports no TLS rather than the connect time', () {
      final timings = timingsFromMilestones(
        start: 0,
        domainLookupEnd: 5,
        connectEnd: 10,
        secureConnectionStart: 0,
        responseStart: 20,
        redirectEnd: 0,
        duration: 30,
      );
      expect(timings.tlsMs, 0);
      expect(timings.connectMs, 10);
    });

    test('a milestone before the start clamps to zero, never negative', () {
      // Cross-origin entries without Timing-Allow-Origin come back zeroed, so
      // the subtraction goes negative and must not surface as a negative time.
      final timings = timingsFromMilestones(
        start: 500,
        domainLookupEnd: 0,
        connectEnd: 0,
        secureConnectionStart: 0,
        responseStart: 0,
        redirectEnd: 0,
        duration: 12,
      );

      expect(timings.dnsMs, 0);
      expect(timings.connectMs, 0);
      expect(timings.firstByteMs, 0);
      expect(timings.totalMs, 12, reason: 'the total is still real');
    });

    test('a page has no queue time', () {
      final timings = timingsFromMilestones(
        start: 0,
        domainLookupEnd: 1,
        connectEnd: 2,
        secureConnectionStart: 0,
        responseStart: 3,
        redirectEnd: 0,
        duration: 4,
      );
      expect(timings.queueMs, 0);
    });

    test('the lookup is used when one is supplied', () async {
      // Proves the seam: a supplied lookup replaces the wall clock entirely.
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('ok', 200)),
        timings: (url) => const RawTimings(
          queueMs: 0,
          dnsMs: 1,
          connectMs: 2,
          tlsMs: 3,
          firstByteMs: 4,
          redirectMs: 0,
          totalMs: 5,
        ),
      );

      final response = await executor.sendBuffered(request(), Uint8List(0));
      expect(response.timings.dnsMs, 1);
      expect(response.timings.firstByteMs, 4);
      expect(response.timings.totalMs, 5);
    });

    test('without a lookup only the total is reported', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('ok', 200)),
      );
      final response = await executor.sendBuffered(request(), Uint8List(0));
      expect(response.timings.dnsMs, 0);
      expect(response.timings.totalMs, greaterThanOrEqualTo(0));
    });
  });

  group('streamed uploads', () {
    test('chunks fed after the call reach the request body', () async {
      // The body does not exist when `send` is called: the runner feeds it
      // afterwards. This used to throw outright on web.
      final client = _CapturingClient();
      final executor = FetchRequestExecutor(client);

      final sent = executor.startStreamed(
        request(bodyKind: RawBodyKind.streamed),
        Uint8List(0),
      );
      await pumpEventQueue();

      executor
        ..feedUploadChunk(1, Uint8List.fromList(utf8.encode('one')))
        ..feedUploadChunk(1, Uint8List.fromList(utf8.encode('two')))
        ..finishUpload(1);
      await sent;

      final body = await client.seen!.finalize().toBytes();
      expect(utf8.decode(body), 'onetwo');
      FetchStreamDemux.instance.release(1);
    });

    test('a declared length is passed through', () async {
      final client = _CapturingClient();
      final executor = FetchRequestExecutor(client);

      final sent = executor.startStreamed(
        request(bodyKind: RawBodyKind.streamed, uploadContentLength: 6),
        Uint8List(0),
      );
      await pumpEventQueue();
      executor
        ..feedUploadChunk(1, Uint8List.fromList(utf8.encode('abcdef')))
        ..finishUpload(1);
      await sent;

      expect(client.seen!.contentLength, 6);
      FetchStreamDemux.instance.release(1);
    });

    test('a failing source aborts rather than sending a short body', () async {
      // Truncating the upload would let the server accept half a document as if
      // it were whole.
      final client = _CapturingClient();
      final executor = FetchRequestExecutor(client);

      final sent = executor.startStreamed(
        request(bodyKind: RawBodyKind.streamed),
        Uint8List(0),
      );
      await pumpEventQueue();

      executor
        ..feedUploadChunk(1, Uint8List.fromList(utf8.encode('partial')))
        ..failUpload(1, 'source blew up');
      await sent;

      await expectLater(
        client.seen!.finalize().toBytes(),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      FetchStreamDemux.instance.release(1);
    });

    test('feeding after finish is dropped, not an error', () async {
      final client = _CapturingClient();
      final executor = FetchRequestExecutor(client);

      final sent = executor.startStreamed(
        request(bodyKind: RawBodyKind.streamed),
        Uint8List(0),
      );
      await pumpEventQueue();
      executor
        ..feedUploadChunk(1, Uint8List.fromList(utf8.encode('done')))
        ..finishUpload(1);
      await sent;

      expect(executor.feedUploadChunk(1, Uint8List(2)), 0);
      FetchStreamDemux.instance.release(1);
    });
  });

  group('lifecycle', () {
    test('a disposed executor refuses further work', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      )..dispose();

      await expectLater(
        executor.sendBuffered(request(), Uint8List(0)),
        throwsA(isA<NitroHttpDisposedException>()),
      );
    });

    test('cancel stops the body pump', () async {
      final controller = StreamController<List<int>>();
      final executor = FetchRequestExecutor(
        MockClient.streaming(
          (r, body) async => http.StreamedResponse(controller.stream, 200),
        ),
      );

      await executor.startStreamed(request(), Uint8List(0));
      executor.cancel(1);
      // The subscription is gone, so pushing more must not reach anyone.
      controller.add(utf8.encode('late'));
      await controller.close();
      expect(controller.hasListener, isFalse);
    });
  });
}

/// Captures the exact request object, the way the real browser client sees it.
///
/// `MockClient` hands its handler a rebuilt `Request`, so an [Expando] set on
/// the original would not be visible there — a fine harness for headers and
/// bodies, useless for anything attached to the instance.
class _CapturingClient extends http.BaseClient {
  http.BaseRequest? seen;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen = request;
    return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
  }
}
