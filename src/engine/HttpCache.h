// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — disk cache, an RFC 9111 SUBSET.
//
// The goal is what a mobile app actually needs: skip the network for content
// that is still fresh, and warm the cache before the user asks. It is not a
// proxy-grade cache and does not pretend to be — no stale-while-revalidate, no
// shared-cache directives beyond `s-maxage`, no request-side `only-if-cached`
// hop-by-hop semantics.
//
// LAYOUT under `<dir>/nitro_http_cache/v1/`
//   index.bin           append log, compacted on open
//   e/<hex sha256>.m    per-entry metadata (status, headers, times, vary keys)
//   e/<hex sha256>.b    per-entry body
//
// KEY = method + canonical URL, extended with the stored request-header values
// named by the response's `Vary`. `Vary: *` makes a response uncacheable.
//
// POLICY  Store 200, 203, 301 and 308 for GET and HEAD. Freshness from
// `Cache-Control: max-age`/`s-maxage` then `Expires`, else the heuristic of
// 10 % of the `Last-Modified` age capped at 24 h. `no-store` and `private` are
// respected. Stale entries revalidate with `If-None-Match` /
// `If-Modified-Since`; a 304 merges headers and refreshes metadata without
// re-downloading.
//
// THREADING  One IO thread per cache owns the index and the body files.
// `lookup` takes a shared lock on the in-memory index and may be called from
// the engine loop thread; eviction and fsync batching happen on the IO thread.
// The cache never touches curl.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Common.h"

namespace nitrohttp {

/// What a lookup found, and therefore what the request should do next.
enum class CacheOutcome {
  Miss,        ///< nothing usable; go to the network
  Fresh,       ///< serve from disk, do not touch the network
  Stale,       ///< revalidate with the validators below
  Uncacheable, ///< request or method excludes caching entirely
};

struct CacheHit {
  CacheOutcome outcome = CacheOutcome::Miss;
  int64_t statusCode = 0;
  std::vector<RawHeader> headers;
  std::string etag;          ///< for `If-None-Match`
  std::string lastModified;  ///< for `If-Modified-Since`
  int64_t contentLength = -1;

  /// Populated for `Fresh` on the buffered path.
  std::vector<uint8_t> body;

  /// Absolute path to the body file. Populated for `Fresh` on the streamed
  /// path so chunks can be replayed from disk without loading it all.
  std::string bodyPath;
};

class HttpCache;

/// Tees the response body to disk while it streams to Dart. Writes to a temp
/// file and atomically renames on `commit`, so a cancelled or failed transfer
/// can never leave a truncated entry behind.
class CacheWriter {
 public:
  ~CacheWriter();
  CacheWriter(const CacheWriter&) = delete;
  CacheWriter& operator=(const CacheWriter&) = delete;

  /// Returns false once the entry has exceeded `maxEntryBytes`, after which the
  /// writer self-discards and the caller should stop teeing.
  bool write(const uint8_t* data, size_t n);

  void commit();
  void discard();
  bool active() const;

 private:
  friend class HttpCache;
  CacheWriter();
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

class HttpCache {
 public:
  /// Opens (or creates) the cache. Returns null when `cfg.enabled` is false or
  /// the directory is unusable — callers treat null as "no caching", never as
  /// an error, because a broken cache must not break HTTP.
  static std::shared_ptr<HttpCache> open(const RawCacheConfig& cfg);

  ~HttpCache();

  /// Cache key for a request. `requestHeaders` are needed because a previously
  /// stored `Vary` extends the key with their values.
  std::string keyFor(const std::string& method, const std::string& url,
                     const std::vector<RawHeader>& requestHeaders) const;

  /// `mode` is the per-request `RawCacheMode`. `onlyIfCached` never consults the
  /// network: a miss becomes `CacheOutcome::Miss` and the caller must answer
  /// `RawErrorKind::cacheMiss`, which is what makes offline UI possible.
  ///
  /// `afterRevalidation` marks the internal re-read that follows a 304. It does
  /// two things: it fills `body`/`bodyPath` for a `Stale` outcome (the stored
  /// body IS the answer, RFC 9111 §4.3.3 — the ordinary stale path only issues a
  /// conditional request and would throw the bytes away), and it leaves the
  /// hit/miss counters alone. One request must move them exactly once, on its
  /// first lookup; the revalidation is already recorded by `revalidationCount`.
  CacheHit lookup(const std::string& key, RawCacheMode mode,
                  const std::string& method,
                  const std::vector<RawHeader>& requestHeaders,
                  bool afterRevalidation = false);

  /// Starts a write-back for a response that policy says is storable. Returns
  /// null when it is not — an unstorable response is the common case and not
  /// worth an error.
  std::unique_ptr<CacheWriter> beginWrite(
      const std::string& key, int64_t statusCode,
      const std::vector<RawHeader>& responseHeaders,
      const std::vector<RawHeader>& requestHeaders, const std::string& method,
      const std::string& url);

  /// 304 path: merge the new headers into the stored metadata and reset the
  /// freshness clock without touching the body.
  void refreshMetadata(const std::string& key,
                       const std::vector<RawHeader>& responseHeaders);

  void clear();
  RawCacheStats stats() const;

  /// Prefetch de-duplication. `claimPrefetch` returns false when an identical
  /// prefetch is already in flight, so the caller can complete immediately
  /// instead of doubling the request.
  bool claimPrefetch(const std::string& key);
  void releasePrefetch(const std::string& key);

  // ── Policy, exposed for direct unit testing without a filesystem ───────────

  /// True when a response with this status/method/headers may be stored.
  static bool isStorable(int64_t statusCode, const std::string& method,
                         const std::vector<RawHeader>& responseHeaders);

  /// Freshness lifetime in milliseconds, or -1 when the response carries no
  /// usable freshness information at all.
  static int64_t freshnessLifetimeMs(
      const std::vector<RawHeader>& responseHeaders, int64_t responseTimeMs);

  /// Parses `Cache-Control` into the directives this cache honours.
  struct CacheControl {
    bool noStore = false;
    bool noCache = false;
    bool isPrivate = false;
    bool mustRevalidate = false;
    bool immutable = false;
    int64_t maxAgeMs = -1;
    int64_t sMaxAgeMs = -1;
  };
  static CacheControl parseCacheControl(const std::vector<RawHeader>& headers);

  /// Parses an HTTP-date (`Sun, 06 Nov 1994 08:49:37 GMT` and the two legacy
  /// forms) into wall-clock milliseconds. Returns -1 on failure.
  static int64_t parseHttpDate(const std::string& value);
  static std::string formatHttpDate(int64_t epochMs);

 private:
  HttpCache();
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace nitrohttp
