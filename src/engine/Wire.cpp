// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — record encode/decode helpers.
//
// The generated codecs do the field work. What lives here is the handful of
// things they do not cover: the ownership boundary (a decoded record must own
// every byte it references once the parameter arena dies), the indexed list
// layout a `List<@HybridRecord>` RETURN uses, and the response envelope every
// failure path shares.
// ─────────────────────────────────────────────────────────────────────────────

#include "Wire.h"

namespace nitrohttp::wire {
namespace {

/// The bridge hands parameter buffers to us already advanced past the 4-byte
/// length prefix, so `fromNative` reads from offset 0. Every field lands in a
/// `std::string` / `std::vector` member, which means the returned record owns
/// its bytes and survives the arena — the decode functions need nothing beyond
/// returning by value.
///
/// Underflow throws `std::runtime_error`, which the generated bridge catches and
/// turns into a `kNull` post; exactly-once completion holds either way.
template <typename T>
inline T decodeRecord(NitroCppBuffer buf) {
  return T::fromNative(buf);
}

/// Adopts a `toNativeBuffer()` result — a malloc'd `[4B len][payload]` block.
inline Blob adopt(NitroCppBuffer owned) {
  if (owned.data == nullptr) return Blob{};
  return Blob{const_cast<uint8_t*>(owned.data), owned.size};
}

}  // namespace

// ── Decoding ─────────────────────────────────────────────────────────────────

RawRequest decodeRequest(NitroCppBuffer buf) {
  return decodeRecord<RawRequest>(buf);
}

RawClientConfig decodeClientConfig(NitroCppBuffer buf) {
  return decodeRecord<RawClientConfig>(buf);
}

RawCacheConfig decodeCacheConfig(NitroCppBuffer buf) {
  return decodeRecord<RawCacheConfig>(buf);
}

RawCookie decodeCookie(NitroCppBuffer buf) {
  return decodeRecord<RawCookie>(buf);
}

RawWsConfig decodeWsConfig(NitroCppBuffer buf) {
  return decodeRecord<RawWsConfig>(buf);
}

// ── Encoding ─────────────────────────────────────────────────────────────────

Blob encodeResponse(const RawResponse& v) { return adopt(v.toNativeBuffer()); }

Blob encodeResponseHead(const RawResponseHead& v) {
  return adopt(v.toNativeBuffer());
}

Blob encodeEvent(const RawEvent& v) { return adopt(v.toNativeBuffer()); }

Blob encodeWsHandshake(const RawWsHandshake& v) {
  return adopt(v.toNativeBuffer());
}

Blob encodeCacheStats(const RawCacheStats& v) {
  return adopt(v.toNativeBuffer());
}

Blob encodeCookieList(const std::vector<RawCookie>& v) {
  // `LazyRecordList.decode` seeks per element, so a RETURNED list carries an
  // offset table. This is NOT the layout of a `List<@HybridRecord>` record
  // FIELD, which the generated codec writes sequentially as `[4B count][items]`.
  //
  //   [4B payloadLen][4B count][int64 offset × count][item payloads…]
  //                  ^ payload starts here; offsets are measured from it,
  //                    so the first item sits at 4 + 8 * count.
  std::vector<std::vector<uint8_t>> items;
  items.reserve(v.size());
  for (const RawCookie& cookie : v) {
    NitroRecordWriter item;
    cookie.encodeInto(item);
    const NitroCppBuffer payload = item.toBuffer();  // non-owning; copy now
    items.emplace_back(payload.data, payload.data + payload.size);
  }

  NitroRecordWriter out;
  out.writeInt32(static_cast<int32_t>(items.size()));
  int64_t offset = 4 + 8 * static_cast<int64_t>(items.size());
  for (const std::vector<uint8_t>& item : items) {
    out.writeInt(offset);
    offset += static_cast<int64_t>(item.size());
  }
  for (const std::vector<uint8_t>& item : items) {
    out.writeBytes(item.data(), item.size());
  }
  return adopt(out.toNativeBuffer());
}

// ── Response construction ────────────────────────────────────────────────────

RawTimings zeroTimings() {
  RawTimings t{};
  t.queueMs = 0.0;
  t.dnsMs = 0.0;
  t.connectMs = 0.0;
  t.tlsMs = 0.0;
  t.firstByteMs = 0.0;
  t.redirectMs = 0.0;
  t.totalMs = 0.0;
  return t;
}

RawResponse errorResponse(int64_t requestId, const EngineError& err) {
  RawResponse r{};
  r.requestId = requestId;
  r.errorKind = err.kind;
  r.errorMessage = err.message;
  r.engineErrorCode = err.code;
  r.statusCode = 0;
  r.version = RawHttpVersion::RAWHTTPVERSION_UNKNOWN;
  r.finalUrl.clear();
  r.redirectCount = 0;
  r.headers.clear();
  r.body.clear();
  r.fromCache = false;
  r.revalidated = false;
  r.primaryIp.clear();
  r.primaryPort = 0;
  r.timings = zeroTimings();
  return r;
}

RawResponseHead errorResponseHead(int64_t requestId, const EngineError& err) {
  RawResponseHead r{};
  r.requestId = requestId;
  r.errorKind = err.kind;
  r.errorMessage = err.message;
  r.engineErrorCode = err.code;
  r.statusCode = 0;
  r.version = RawHttpVersion::RAWHTTPVERSION_UNKNOWN;
  r.finalUrl.clear();
  r.redirectCount = 0;
  r.headers.clear();
  r.fromCache = false;
  // -1, not 0: the spec defines -1 as "the server declared no length", and a
  // failed transfer never got a declaration at all.
  r.contentLength = -1;
  r.primaryIp.clear();
  r.primaryPort = 0;
  r.timings = zeroTimings();
  return r;
}

// ── Methods ──────────────────────────────────────────────────────────────────

std::string methodToken(const RawRequest& req) {
  switch (req.method) {
    case RawMethod::RAWMETHOD_GET: return "GET";
    case RawMethod::RAWMETHOD_HEAD: return "HEAD";
    case RawMethod::RAWMETHOD_POST: return "POST";
    case RawMethod::RAWMETHOD_PUT: return "PUT";
    case RawMethod::RAWMETHOD_DELETE: return "DELETE";
    case RawMethod::RAWMETHOD_PATCH: return "PATCH";
    case RawMethod::RAWMETHOD_OPTIONS: return "OPTIONS";
    case RawMethod::RAWMETHOD_TRACE: return "TRACE";
    case RawMethod::RAWMETHOD_CUSTOM:
      // Custom method tokens are case-sensitive per RFC 9110 §9.1, so this is
      // the one method that is never upper-cased. An empty token means the
      // caller set `custom` without a name — a `badRequest`, which the task
      // rejects rather than papering over with a default verb.
      return trimAsciiSpace(req.customMethod);
  }
  return "GET";
}

bool methodIsBodyless(const RawRequest& req) {
  const std::string token = methodToken(req);
  return asciiEqualIgnoreCase(token, "GET") ||
         asciiEqualIgnoreCase(token, "HEAD") ||
         asciiEqualIgnoreCase(token, "OPTIONS") ||
         asciiEqualIgnoreCase(token, "TRACE") ||
         asciiEqualIgnoreCase(token, "DELETE");
}

}  // namespace nitrohttp::wire
