/// Process-wide HTTP disk-cache configuration and statistics.
///
/// The cache lives in the native engine and is shared by every client in the
/// process — a per-client cache would duplicate entries and fight over the same
/// eviction budget. Individual clients opt in through `CacheSettings.enabled`;
/// this file configures the store itself.
library;

/// Configuration for the shared on-disk response cache.
///
/// Apply it once, early in `main`, before the first request. Reconfiguring with
/// a different [directory] later re-opens the store; in-flight requests keep
/// using the old one until they complete.
final class HttpCacheConfig {
  /// Creates a cache configuration rooted at [directory].
  ///
  /// [directory] is required and has no default on purpose: a plugin cannot
  /// know which of an app's several writable locations is the right one, and
  /// guessing (say, the documents directory) would put purgeable bytes in a
  /// backed-up, user-visible place. Pass a path from `path_provider` —
  /// typically `getApplicationCacheDirectory()`.
  const HttpCacheConfig({
    required this.directory,
    this.enabled = true,
    this.maxSizeBytes = 64 * 1024 * 1024,
    this.maxEntryBytes = 8 * 1024 * 1024,
  });

  /// Whether the store is active.
  ///
  /// `false` makes every lookup miss and every store a no-op without deleting
  /// the existing on-disk entries, so caching can be toggled at runtime without
  /// losing a warm cache.
  final bool enabled;

  /// Absolute path of the directory the engine owns for cache files.
  ///
  /// The engine creates it if missing and treats every file beneath it as its
  /// own; do not share the directory with other data.
  final String directory;

  /// Total on-disk budget in bytes. Defaults to 64 MiB.
  ///
  /// Exceeding it evicts least-recently-used entries until the store fits.
  final int maxSizeBytes;

  /// Largest single response that may be stored, in bytes. Defaults to 8 MiB.
  ///
  /// A response above this size is streamed to the caller and never written, so
  /// one large download cannot evict the whole working set.
  final int maxEntryBytes;

  /// Returns a copy with the given fields replaced.
  HttpCacheConfig copyWith({
    bool? enabled,
    String? directory,
    int? maxSizeBytes,
    int? maxEntryBytes,
  }) => HttpCacheConfig(
    directory: directory ?? this.directory,
    enabled: enabled ?? this.enabled,
    maxSizeBytes: maxSizeBytes ?? this.maxSizeBytes,
    maxEntryBytes: maxEntryBytes ?? this.maxEntryBytes,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HttpCacheConfig &&
          other.enabled == enabled &&
          other.directory == directory &&
          other.maxSizeBytes == maxSizeBytes &&
          other.maxEntryBytes == maxEntryBytes;

  @override
  int get hashCode =>
      Object.hash(enabled, directory, maxSizeBytes, maxEntryBytes);

  @override
  String toString() =>
      'HttpCacheConfig(enabled: $enabled, directory: $directory, '
      'maxSizeBytes: $maxSizeBytes, maxEntryBytes: $maxEntryBytes)';
}

/// A snapshot of the shared cache's counters.
///
/// Counters are cumulative since the store was opened, not since process start,
/// and are read atomically so the ratios are self-consistent.
final class CacheStats {
  /// Creates a statistics snapshot. All counters default to zero.
  const CacheStats({
    this.entryCount = 0,
    this.sizeBytes = 0,
    this.hitCount = 0,
    this.missCount = 0,
    this.revalidationCount = 0,
    this.evictionCount = 0,
  });

  /// Number of stored responses.
  final int entryCount;

  /// Bytes currently occupied on disk, counted against
  /// [HttpCacheConfig.maxSizeBytes].
  final int sizeBytes;

  /// Lookups served entirely from disk without contacting the origin.
  final int hitCount;

  /// Lookups with no usable stored entry, which went to the network.
  final int missCount;

  /// Conditional requests (`If-None-Match` / `If-Modified-Since`) the origin
  /// answered with `304`, refreshing a stale entry.
  ///
  /// These count as neither [hitCount] nor [missCount]: a round trip happened,
  /// but no body was transferred.
  final int revalidationCount;

  /// Entries removed to stay within the size budget.
  final int evictionCount;

  /// Fraction of hits over hits plus misses, in `0.0..1.0`.
  ///
  /// Returns `0.0` before any lookup. Revalidations are excluded from both
  /// sides of the ratio.
  double get hitRate {
    final lookups = hitCount + missCount;
    return lookups == 0 ? 0.0 : hitCount / lookups;
  }

  /// Returns a copy with the given fields replaced.
  CacheStats copyWith({
    int? entryCount,
    int? sizeBytes,
    int? hitCount,
    int? missCount,
    int? revalidationCount,
    int? evictionCount,
  }) => CacheStats(
    entryCount: entryCount ?? this.entryCount,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    hitCount: hitCount ?? this.hitCount,
    missCount: missCount ?? this.missCount,
    revalidationCount: revalidationCount ?? this.revalidationCount,
    evictionCount: evictionCount ?? this.evictionCount,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheStats &&
          other.entryCount == entryCount &&
          other.sizeBytes == sizeBytes &&
          other.hitCount == hitCount &&
          other.missCount == missCount &&
          other.revalidationCount == revalidationCount &&
          other.evictionCount == evictionCount;

  @override
  int get hashCode => Object.hash(
    entryCount,
    sizeBytes,
    hitCount,
    missCount,
    revalidationCount,
    evictionCount,
  );

  @override
  String toString() =>
      'CacheStats(entries: $entryCount, size: $sizeBytes B, '
      'hits: $hitCount, misses: $missCount, '
      'revalidations: $revalidationCount, evictions: $evictionCount, '
      'hitRate: ${(hitRate * 100).toStringAsFixed(1)}%)';
}
