/// Disk-cache behaviour, asserted from both sides.
///
/// A cache hit is not "the second request was fast" — it is "the second request
/// never reached the server". Every test here checks the local server's own
/// request counter, which is the only unfalsifiable evidence available.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// `max-age=60`: a second request inside a test is a genuine fresh hit.
  const fresh = '/cache/60';

  /// `max-age=0`: every reuse has to be revalidated, which is how the
  /// revalidation counter and the `304` path get exercised.
  const stale = '/cache/0';

  late LocalServer server;
  late Directory cacheDir;
  late NitroHttpClient client;

  setUp(() async {
    server = await LocalServer.start();
    // A fresh directory per test re-opens the store, which also resets the
    // cumulative counters `CacheStats` reports.
    cacheDir = await Directory.systemTemp.createTemp('nitro_http_cache_test');
    NitroHttp.configureCache(
      HttpCacheConfig(
        directory: cacheDir.path,
        maxSizeBytes: 8 * 1024 * 1024,
        maxEntryBytes: 1024 * 1024,
      ),
    );
    NitroHttp.clearCache();
    client = NitroHttpClient(
      settings: ClientSettings(
        baseUrl: server.baseUrl,
        cacheSettings: const CacheSettings(enabled: true),
      ),
    );
  });

  tearDown(() async {
    client.dispose();
    await server.stop();
    try {
      await cacheDir.delete(recursive: true);
    } on FileSystemException {
      // The engine may still hold a handle; a leftover temp directory is not
      // worth failing a test over.
    }
  });

  testWidgets('a fresh entry is served without reaching the server', (_) async {
    final first = await client.get(fresh);
    expect(first.fromCache, isFalse);
    expect(server.requestsFor(fresh), 1);

    final second = await client.get(fresh);
    expect(second.fromCache, isTrue);
    expect(second.revalidated, isFalse);
    expect(
      server.requestsFor(fresh),
      1,
      reason: 'a fresh hit must not produce a request',
    );
    expect(
      second.body,
      first.body,
      reason: 'the same stored body, serial included',
    );
  });

  testWidgets('a stale entry revalidates and a 304 sets revalidated', (_) async {
    final first = await client.get(stale);
    expect(first.fromCache, isFalse);
    expect(server.requestsFor(stale), 1);

    final second = await client.get(stale);
    expect(server.requestsFor(stale), 2, reason: 'a round trip must happen');
    expect(
      server.receivedHeaderNames,
      contains('if-none-match'),
      reason: 'revalidation means a conditional request',
    );
    expect(second.revalidated, isTrue);
    expect(second.statusCode, 200, reason: 'a 304 is resolved to the stored 200');
    expect(
      second.body,
      first.body,
      reason: 'the server bumps its serial only on a 200, so a 304 reuse '
          'must return the original body',
    );
  });

  testWidgets('onlyIfCached on a cold key throws NitroHttpCacheMissException',
      (_) async {
    const cold = '/cache/123';
    await expectLater(
      client.get(cold, options: const RequestOptions(cacheMode: CacheMode.onlyIfCached)),
      throwsA(isA<NitroHttpCacheMissException>()),
    );
    expect(
      server.requestsFor(cold),
      0,
      reason: 'onlyIfCached must never touch the network',
    );
  });

  testWidgets('onlyIfCached on a warm key is served from disk', (_) async {
    await client.get(fresh);
    expect(server.requestsFor(fresh), 1);

    final cached = await client.get(
      fresh,
      options: const RequestOptions(cacheMode: CacheMode.onlyIfCached),
    );
    expect(cached.fromCache, isTrue);
    expect(server.requestsFor(fresh), 1);
  });

  testWidgets('bypass skips the stored entry but still stores the result',
      (_) async {
    await client.get(fresh);
    expect(server.requestsFor(fresh), 1);

    final bypassed = await client.get(
      fresh,
      options: const RequestOptions(cacheMode: CacheMode.bypass),
    );
    expect(bypassed.fromCache, isFalse);
    expect(server.requestsFor(fresh), 2);

    final afterwards = await client.get(fresh);
    expect(afterwards.fromCache, isTrue);
    expect(server.requestsFor(fresh), 2, reason: 'bypass must have re-stored');
    expect(
      afterwards.body,
      bypassed.body,
      reason: 'the stored copy should be the one bypass just fetched',
    );
  });

  testWidgets('refresh revalidates a still-fresh entry', (_) async {
    await client.get(fresh);
    expect(server.requestsFor(fresh), 1);

    final refreshed = await client.get(
      fresh,
      options: const RequestOptions(cacheMode: CacheMode.refresh),
    );
    expect(
      server.requestsFor(fresh),
      2,
      reason: 'refresh forces the round trip a fresh entry would have skipped',
    );
    expect(server.receivedHeaderNames, contains('if-none-match'));
    expect(refreshed.revalidated, isTrue);
    expect(refreshed.statusCode, 200);
  });

  testWidgets('noStore leaves nothing behind', (_) async {
    await client.get(
      fresh,
      options: const RequestOptions(cacheMode: CacheMode.noStore),
    );
    expect(server.requestsFor(fresh), 1);

    await expectLater(
      client.get(fresh, options: const RequestOptions(cacheMode: CacheMode.onlyIfCached)),
      throwsA(isA<NitroHttpCacheMissException>()),
    );
  });

  testWidgets('prefetch warms the cache so the next request is a hit', (_) async {
    await NitroHttp.prefetchDetailed('${server.baseUrl}$fresh');
    expect(server.requestsFor(fresh), 1, reason: 'prefetch fetches exactly once');

    final response = await client.get(fresh);
    expect(response.fromCache, isTrue);
    expect(
      server.requestsFor(fresh),
      1,
      reason: 'the prefetched entry should have satisfied the request',
    );
  });

  testWidgets('CacheStats counters move with hits, misses and revalidations',
      (_) async {
    final start = NitroHttp.cacheStats();

    await client.get(fresh); // miss + store
    await client.get(fresh); // hit
    await client.get(stale); // miss + store
    await client.get(stale); // revalidation

    final end = NitroHttp.cacheStats();

    expect(end.missCount - start.missCount, 2);
    expect(end.hitCount - start.hitCount, 1);
    expect(end.revalidationCount - start.revalidationCount, 1);
    expect(end.entryCount, greaterThanOrEqualTo(2));
    expect(end.sizeBytes, greaterThan(0));
    // `hitRate` must agree with the counters it is derived from, and must
    // exclude revalidations from both sides of the ratio. Asserted against the
    // absolute counters rather than a literal, because the store's counters are
    // cumulative since it was opened and nothing here may assume a zero start.
    expect(
      end.hitRate,
      closeTo(end.hitCount / (end.hitCount + end.missCount), 1e-9),
    );
    expect(end.hitRate, inClosedOpenRange(0, 1));
  });

  testWidgets('a client that did not opt in never reads the cache', (_) async {
    await client.get(fresh);
    expect(server.requestsFor(fresh), 1);

    final uncached = NitroHttpClient(
      settings: ClientSettings(baseUrl: server.baseUrl),
    );
    addTearDown(uncached.dispose);

    final response = await uncached.get(fresh);
    expect(response.fromCache, isFalse);
    expect(
      server.requestsFor(fresh),
      2,
      reason: 'CacheSettings.enabled defaults to false',
    );
  });

  testWidgets('clearCache drops every entry', (_) async {
    await client.get(fresh);
    expect((await client.get(fresh)).fromCache, isTrue);

    NitroHttp.clearCache();
    expect(NitroHttp.cacheStats().entryCount, 0);

    final afterClear = await client.get(fresh);
    expect(afterClear.fromCache, isFalse);
    expect(server.requestsFor(fresh), 2);
  });
}
