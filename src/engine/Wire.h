// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — record encode/decode helpers.
//
// Nitro generates a `fromReader` / `encodeInto` / `toNativeBuffer` trio on every
// record struct, so most of the wire work is already done. This header exists
// for the three things the generator does NOT hand us:
//
//   1. Deep copies. Record and `@zeroCopy` parameters point into an arena that
//      Nitro releases the moment the registering call returns. `sendBuffered`
//      and friends must copy synchronously. `decode*` returns owning values.
//
//   2. Indexed list returns. A `List<@HybridRecord>` RETURN uses a different
//      layout from a `List<@HybridRecord>` record FIELD: the return is
//      `[4B payloadLen][4B count][int64 offset × count][items]` with offsets
//      relative to the payload start, because Dart decodes it as a
//      `LazyRecordList` that seeks per element. Getting this wrong yields
//      plausible-looking garbage rather than a clean failure.
//
//   3. Sentinel resolution. Request options carry `-1 = inherit`; this is where
//      that collapses into concrete values.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Common.h"

namespace nitrohttp::wire {

// ── Decoding (always deep-copies out of the arena) ───────────────────────────

RawRequest decodeRequest(NitroCppBuffer buf);
RawClientConfig decodeClientConfig(NitroCppBuffer buf);
RawCacheConfig decodeCacheConfig(NitroCppBuffer buf);
RawCookie decodeCookie(NitroCppBuffer buf);
RawWsConfig decodeWsConfig(NitroCppBuffer buf);

// ── Encoding (returns malloc'd `[4B len][payload]`, ownership to the caller) ──

Blob encodeResponse(const RawResponse& v);

/// Bodies at least this large skip the record and reach Dart zero-copy. Below
/// it the copy is cheaper than the finalizer bookkeeping an external Dart
/// buffer costs, so small bodies stay inline exactly as before.
constexpr size_t kDetachBodyMinBytes = 16 * 1024;

/// A response body moved out of its record; see `RawResponse.bodyOwner`.
using DetachedBody = std::unique_ptr<std::vector<uint8_t>>;

/// Like the overload above, but when [detached] is non-null and the body is at
/// least `kDetachBodyMinBytes`, the body is MOVED into `*detached` and only its
/// address, length and owner are encoded. The caller keeps `*detached` alive
/// until the record is delivered, then releases it — Dart frees it through
/// `nitro_http_free_body` — or lets it die if delivery failed.
Blob encodeResponse(RawResponse& v, DetachedBody* detached);
Blob encodeResponseHead(const RawResponseHead& v);
Blob encodeEvent(const RawEvent& v);
Blob encodeWsHandshake(const RawWsHandshake& v);
Blob encodeCacheStats(const RawCacheStats& v);

/// Indexed layout for a `List<@HybridRecord>` RETURN — see the header comment.
Blob encodeCookieList(const std::vector<RawCookie>& v);

// ── Response construction ────────────────────────────────────────────────────

/// A response carrying nothing but the failure. Used on every path that must
/// still satisfy exactly-once completion: cancellation, engine shutdown,
/// malformed request, cache-only miss.
RawResponse errorResponse(int64_t requestId, const EngineError& err);
RawResponseHead errorResponseHead(int64_t requestId, const EngineError& err);

RawTimings zeroTimings();

// ── Sentinels ────────────────────────────────────────────────────────────────

/// Returns `requestValue` unless it is the inherit sentinel (`-1`), in which
/// case `clientValue`.
inline int64_t inherit(int64_t requestValue, int64_t clientValue) {
  return requestValue < 0 ? clientValue : requestValue;
}

/// Tri-state boolean option: `-1` inherit, `0` false, `1` true.
inline bool inheritBool(int64_t requestValue, bool clientValue) {
  return requestValue < 0 ? clientValue : requestValue != 0;
}

/// The HTTP method token curl should send. Handles `RawMethod::custom`.
std::string methodToken(const RawRequest& req);

/// True for methods that carry no request body by default.
bool methodIsBodyless(const RawRequest& req);

}  // namespace nitrohttp::wire
