import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  group('HttpCacheConfig', () {
    test('defaults are 64 MiB total and 8 MiB per entry, enabled', () {
      const config = HttpCacheConfig(directory: '/tmp/cache');

      expect(config.directory, '/tmp/cache');
      expect(config.enabled, isTrue);
      expect(config.maxSizeBytes, 64 * 1024 * 1024);
      expect(config.maxEntryBytes, 8 * 1024 * 1024);
    });

    group('copyWith', () {
      const base = HttpCacheConfig(
        directory: '/a',
        enabled: false,
        maxSizeBytes: 10,
        maxEntryBytes: 5,
      );

      test('keeps every field when nothing is passed', () {
        expect(base.copyWith(), base);
      });

      test('replaces each field independently', () {
        expect(base.copyWith(directory: '/b').directory, '/b');
        expect(base.copyWith(enabled: true).enabled, isTrue);
        expect(base.copyWith(maxSizeBytes: 99).maxSizeBytes, 99);
        expect(base.copyWith(maxEntryBytes: 42).maxEntryBytes, 42);
      });

      test('leaves the untouched fields alone', () {
        final copy = base.copyWith(maxSizeBytes: 99);

        expect(copy.directory, '/a');
        expect(copy.enabled, isFalse);
        expect(copy.maxEntryBytes, 5);
      });

      test('replaces every field at once', () {
        final copy = base.copyWith(
          directory: '/b',
          enabled: true,
          maxSizeBytes: 1,
          maxEntryBytes: 2,
        );

        expect(copy, const HttpCacheConfig(
          directory: '/b',
          maxSizeBytes: 1,
          maxEntryBytes: 2,
        ));
      });
    });

    test('equal configs compare equal and hash alike', () {
      const a = HttpCacheConfig(directory: '/a');
      const b = HttpCacheConfig(directory: '/a');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, same(a));
    });

    test('each differing field breaks equality', () {
      const base = HttpCacheConfig(directory: '/a');

      expect(base, isNot(const HttpCacheConfig(directory: '/b')));
      expect(
        base,
        isNot(const HttpCacheConfig(directory: '/a', enabled: false)),
      );
      expect(
        base,
        isNot(const HttpCacheConfig(directory: '/a', maxSizeBytes: 1)),
      );
      expect(
        base,
        isNot(const HttpCacheConfig(directory: '/a', maxEntryBytes: 1)),
      );
      expect(base, isNot(Object()));
    });

    test('toString names every field', () {
      const config = HttpCacheConfig(
        directory: '/tmp/c',
        enabled: false,
        maxSizeBytes: 10,
        maxEntryBytes: 5,
      );

      expect(
        config.toString(),
        'HttpCacheConfig(enabled: false, directory: /tmp/c, '
        'maxSizeBytes: 10, maxEntryBytes: 5)',
      );
    });
  });

  group('CacheStats', () {
    test('every counter defaults to zero', () {
      const stats = CacheStats();

      expect(stats.entryCount, 0);
      expect(stats.sizeBytes, 0);
      expect(stats.hitCount, 0);
      expect(stats.missCount, 0);
      expect(stats.revalidationCount, 0);
      expect(stats.evictionCount, 0);
    });

    group('hitRate', () {
      test('is zero before any lookup, not NaN', () {
        // 0/0 would be NaN and would render as "NaN%" in the stats line.
        expect(const CacheStats().hitRate, 0.0);
      });

      test('is the hit share of all lookups', () {
        expect(
          const CacheStats(hitCount: 3, missCount: 1).hitRate,
          0.75,
        );
        expect(const CacheStats(hitCount: 1).hitRate, 1.0);
        expect(const CacheStats(missCount: 1).hitRate, 0.0);
      });

      test('excludes revalidations from both sides of the ratio', () {
        const stats = CacheStats(
          hitCount: 1,
          missCount: 1,
          revalidationCount: 98,
        );

        expect(stats.hitRate, 0.5);
      });
    });

    group('copyWith', () {
      const base = CacheStats(
        entryCount: 1,
        sizeBytes: 2,
        hitCount: 3,
        missCount: 4,
        revalidationCount: 5,
        evictionCount: 6,
      );

      test('keeps every field when nothing is passed', () {
        expect(base.copyWith(), base);
      });

      test('replaces each field independently', () {
        expect(base.copyWith(entryCount: 9).entryCount, 9);
        expect(base.copyWith(sizeBytes: 9).sizeBytes, 9);
        expect(base.copyWith(hitCount: 9).hitCount, 9);
        expect(base.copyWith(missCount: 9).missCount, 9);
        expect(base.copyWith(revalidationCount: 9).revalidationCount, 9);
        expect(base.copyWith(evictionCount: 9).evictionCount, 9);
      });

      test('leaves the untouched fields alone', () {
        final copy = base.copyWith(hitCount: 9);

        expect(copy.entryCount, 1);
        expect(copy.sizeBytes, 2);
        expect(copy.missCount, 4);
        expect(copy.revalidationCount, 5);
        expect(copy.evictionCount, 6);
      });
    });

    test('equal snapshots compare equal and hash alike', () {
      const a = CacheStats(entryCount: 1, hitCount: 2);
      const b = CacheStats(entryCount: 1, hitCount: 2);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, same(a));
    });

    test('each differing counter breaks equality', () {
      const base = CacheStats();

      expect(base, isNot(const CacheStats(entryCount: 1)));
      expect(base, isNot(const CacheStats(sizeBytes: 1)));
      expect(base, isNot(const CacheStats(hitCount: 1)));
      expect(base, isNot(const CacheStats(missCount: 1)));
      expect(base, isNot(const CacheStats(revalidationCount: 1)));
      expect(base, isNot(const CacheStats(evictionCount: 1)));
      expect(base, isNot(Object()));
    });

    test('toString reports the counters and the hit rate as a percentage', () {
      const stats = CacheStats(
        entryCount: 2,
        sizeBytes: 1024,
        hitCount: 3,
        missCount: 1,
        revalidationCount: 4,
        evictionCount: 5,
      );

      expect(
        stats.toString(),
        'CacheStats(entries: 2, size: 1024 B, hits: 3, misses: 1, '
        'revalidations: 4, evictions: 5, hitRate: 75.0%)',
      );
    });

    test('toString renders 0.0% before any lookup', () {
      expect(const CacheStats().toString(), contains('hitRate: 0.0%'));
    });
  });
}
