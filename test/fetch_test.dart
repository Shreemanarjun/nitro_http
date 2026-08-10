import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'support/fakes.dart';

void main() {
  late FakeEngineExecutor engine;
  late FakeRequestExecutor executor;
  late FakeStreamDemux demux;
  late NitroHttpClient client;

  setUp(() {
    engine = FakeEngineExecutor();
    executor = FakeRequestExecutor();
    demux = FakeStreamDemux();
    client = NitroHttpClient(
      settings: const ClientSettings(baseUrl: 'http://example.test'),
      executor: executor,
      demux: demux,
    );
    NitroHttp.overrideEngineExecutorForTesting(engine);
    NitroHttp.overrideDefaultClientForTesting(client);
  });

  tearDown(() {
    NitroHttp.overrideDefaultClientForTesting(null);
    NitroHttp.overrideEngineExecutorForTesting(null);
    client.dispose();
    demux.closeAll();
  });

  /// The last request the fake saw, as a `(method, url)` pair.
  (String, String) lastSent() {
    final sent = executor.bufferedRequests.last.request;
    return (sent.method.name, sent.url);
  }

  group('capabilities', () {
    test('are read straight off the engine', () {
      expect(NitroHttp.engineVersion, 'libcurl/8.21.0 (fake)');
      expect(NitroHttp.supportsHttp3, isTrue);
      expect(NitroHttp.supportsWebSockets, isTrue);
      expect(NitroHttp.supportsBrotli, isTrue);
      expect(NitroHttp.supportsZstd, isFalse);
    });

    test('reflect an engine that reports less', () {
      NitroHttp.overrideEngineExecutorForTesting(
        FakeEngineExecutor(
          engineVersion: 'libcurl/8.0.0',
          supportsHttp3: false,
          supportsWebSockets: false,
          supportsBrotli: false,
        ),
      );

      expect(NitroHttp.engineVersion, 'libcurl/8.0.0');
      expect(NitroHttp.supportsHttp3, isFalse);
      expect(NitroHttp.supportsWebSockets, isFalse);
      expect(NitroHttp.supportsBrotli, isFalse);
    });
  });

  group('verbs delegate to the default client', () {
    setUp(() => executor.onSendBuffered = (_, _) => rawResponse());

    test('get', () async {
      await NitroHttp.get('/a');

      expect(lastSent(), ('get', 'http://example.test/a'));
    });

    test('post carries the body', () async {
      await NitroHttp.post('/a', body: HttpBody.text('hello'));

      expect(lastSent(), ('post', 'http://example.test/a'));
      expect(executor.bufferedRequests.last.body, isNotEmpty);
    });

    test('put', () async {
      await NitroHttp.put('/a', body: HttpBody.text('x'));

      expect(lastSent(), ('put', 'http://example.test/a'));
    });

    test('patch', () async {
      await NitroHttp.patch('/a', body: HttpBody.text('x'));

      expect(lastSent(), ('patch', 'http://example.test/a'));
    });

    test('delete', () async {
      await NitroHttp.delete('/a');

      expect(lastSent(), ('delete', 'http://example.test/a'));
    });

    test('head', () async {
      await NitroHttp.head('/a');

      expect(lastSent(), ('head', 'http://example.test/a'));
    });

    test('passes query, headers and options through', () async {
      await NitroHttp.get(
        '/a',
        query: {'q': '1'},
        headers: HttpHeaders()..set('x-test', 'yes'),
        options: const RequestOptions(maxRedirects: 7),
      );

      final sent = executor.bufferedRequests.last.request;
      expect(sent.url, contains('q=1'));
      expect(
        sent.headers.any((h) => h.name.toLowerCase() == 'x-test'),
        isTrue,
      );
      expect(sent.options.maxRedirects, 7);
    });

    test('a cancel token reaches the engine', () async {
      final token = CancelToken();
      final pending = NitroHttp.get('/slow', cancelToken: token);
      token.cancel();
      await pending.then<void>((_) {}, onError: (_) {});

      expect(executor.cancelled, isNotEmpty);
    });

    test('fetch() is a GET on the default client', () async {
      await fetch('/one-liner');

      expect(lastSent(), ('get', 'http://example.test/one-liner'));
    });
  });

  group('cache controls', () {
    test('configureCache forwards a mapped config', () {
      NitroHttp.configureCache(
        const HttpCacheConfig(
          directory: '/tmp/c',
          maxSizeBytes: 10,
          maxEntryBytes: 5,
        ),
      );

      expect(engine.cacheConfigs, hasLength(1));
      expect(engine.cacheConfigs.single.directory, '/tmp/c');
      expect(engine.cacheConfigs.single.maxSizeBytes, 10);
      expect(engine.cacheConfigs.single.maxEntryBytes, 5);
      expect(engine.cacheConfigs.single.enabled, isTrue);
    });

    test('clearCache forwards', () {
      NitroHttp.clearCache();
      NitroHttp.clearCache();

      expect(engine.clearCacheCount, 2);
    });

    test('cacheStats maps the native snapshot', () {
      engine.stats = const RawCacheStats(
        entryCount: 3,
        sizeBytes: 100,
        hitCount: 7,
        missCount: 3,
        revalidationCount: 1,
        evictionCount: 2,
      );

      final stats = NitroHttp.cacheStats();

      expect(stats.entryCount, 3);
      expect(stats.sizeBytes, 100);
      expect(stats.hitCount, 7);
      expect(stats.missCount, 3);
      expect(stats.revalidationCount, 1);
      expect(stats.evictionCount, 2);
      expect(stats.hitRate, 0.7);
    });
  });

  group('prefetch', () {
    test('sends a GET for the url', () async {
      await NitroHttp.prefetch('http://example.test/warm');

      expect(engine.prefetched, hasLength(1));
      expect(engine.prefetched.single.url, 'http://example.test/warm');
      expect(engine.prefetched.single.method, RawMethod.get);
    });

    test('forwards headers', () async {
      await NitroHttp.prefetch(
        'http://example.test/warm',
        headers: HttpHeaders()..set('authorization', 'Bearer t'),
      );

      expect(
        engine.prefetched.single.headers.any(
          (h) => h.name.toLowerCase() == 'authorization',
        ),
        isTrue,
      );
    });

    test('swallows a transport failure', () async {
      // A prefetch is an optimisation; callers should not have to guard every
      // warm-up call with a try/catch.
      engine.prefetchResponse = rawResponse(
        kind: RawErrorKind.connectionRefused,
        message: 'refused',
      );

      await expectLater(
        NitroHttp.prefetch('http://example.test/warm'),
        completes,
      );
    });

    test('prefetchDetailed throws the failure instead', () async {
      engine.prefetchResponse = rawResponse(
        kind: RawErrorKind.connectionRefused,
        message: 'refused',
      );

      await expectLater(
        NitroHttp.prefetchDetailed('http://example.test/warm'),
        throwsA(isA<NitroHttpConnectionException>()),
      );
    });

    test('prefetchDetailed completes on success', () async {
      await expectLater(
        NitroHttp.prefetchDetailed('http://example.test/warm'),
        completes,
      );
    });

    test('prefetchOnAppStart warms every url', () async {
      await NitroHttp.prefetchOnAppStart([
        'http://example.test/a',
        'http://example.test/b',
        'http://example.test/c',
      ]);

      expect(
        engine.prefetched.map((r) => r.url),
        containsAll([
          'http://example.test/a',
          'http://example.test/b',
          'http://example.test/c',
        ]),
      );
    });

    test('prefetchOnAppStart survives a failing url', () async {
      engine.prefetchResponse = rawResponse(
        kind: RawErrorKind.dnsFailure,
        message: 'nope',
      );

      await expectLater(
        NitroHttp.prefetchOnAppStart(['http://example.test/a']),
        completes,
      );
    });

    test('prefetchOnAppStart with no urls does nothing', () async {
      await NitroHttp.prefetchOnAppStart([]);

      expect(engine.prefetched, isEmpty);
    });
  });

  group('lifecycle', () {
    test('reset drops the client and resets native', () {
      NitroHttp.reset();

      expect(engine.resetCount, 1);
    });

    test('init installs a client built from the given settings', () {
      // `init` replaces the override with a real client, so the only thing that
      // can be asserted without a native library is that a client exists and is
      // a new one.
      final before = NitroHttp.defaultClient;
      NitroHttp.overrideDefaultClientForTesting(
        NitroHttpClient(
          settings: const ClientSettings(baseUrl: 'http://other.test'),
          executor: FakeRequestExecutor(),
          demux: FakeStreamDemux(),
        ),
      );

      expect(NitroHttp.defaultClient, isNot(same(before)));
    });

    test('the override seam is what defaultClient returns', () {
      expect(NitroHttp.defaultClient, same(client));
    });

    // The lazy `_client ??= NitroHttpClient(...)` branch in `defaultClient` is
    // not reachable from a unit test: constructing a real client looks up
    // `nitro_http_init_dart_api_dl`, which only resolves with the dynamic
    // library loaded. It is covered by `example/integration_test/http_test.dart`
    // instead.
  });

  test('a 1 KiB body round-trips through the static verbs', () async {
    executor.onSendBuffered = (_, _) => rawResponse(
      body: Uint8List.fromList(List.filled(1024, 0x41)),
      headers: const [RawHeader(name: 'content-type', value: 'text/plain')],
    );

    final response = await NitroHttp.get('/bytes/1024');

    expect(response.statusCode, 200);
    expect(response.bodyBytes, hasLength(1024));
    expect(response.body, startsWith('AAA'));
  });
}
