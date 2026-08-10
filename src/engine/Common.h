// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — shared vocabulary.
//
// Everything in `namespace nitrohttp` is free of any dependency on Nitro's
// generated bridge *class*: the engine talks to Dart through the two seams
// declared here (`StreamSink` and `DartPost`), both of which the test suite
// replaces with in-process fakes. That is the whole reason the engine is
// testable without a Dart VM.
//
// The generated record STRUCTS (RawRequest, RawResponse, …) are fair game —
// they are plain aggregates with a hand-auditable binary codec.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// Spelled relative rather than as a bare `"nitro_http.native.g.h"`: the CMake
// builds put `lib/src/generated/cpp` on the include path, but the SwiftPM target
// cannot — a header search path may not escape the package root — and CocoaPods
// would need the entry duplicated in every podspec. A relative include resolves
// against this file on every one of the five platforms with no configuration.
#include "../../lib/src/generated/cpp/nitro_http.native.g.h"

namespace nitrohttp {

// ── Time ─────────────────────────────────────────────────────────────────────

/// Monotonic milliseconds since an arbitrary epoch. Used for queue timing and
/// cache freshness arithmetic; never for wall-clock values on the wire.
double monotonicMs();

/// Wall-clock milliseconds since the Unix epoch. Cache expiry and cookie
/// expiry are wall-clock by definition.
int64_t wallClockMs();

// ── Byte buffers ─────────────────────────────────────────────────────────────

/// A malloc'd block whose ownership is about to transfer across the FFI
/// boundary. Deliberately *not* RAII: the whole point is to hand the pointer
/// to code that will `free()` it later. Use `Owned` when you want the opposite.
struct Blob {
  uint8_t* data = nullptr;
  size_t size = 0;

  bool empty() const { return data == nullptr || size == 0; }

  /// Wraps in the generated buffer type the bridge expects.
  NitroCppBuffer toBuffer() const { return NitroCppBuffer{data, size}; }

  /// Copies `n` bytes from `src` into a fresh malloc'd block.
  static Blob copy(const void* src, size_t n);

  void release();  // free() and null out
};

// ── Errors ───────────────────────────────────────────────────────────────────

/// The error envelope every response record opens with. Errors ride *inside*
/// the result rather than as bridge exceptions, because `@NitroResult` cannot
/// combine with native-async (validator E015) and the bare native-async
/// failure path can only post `kNull`.
struct EngineError {
  RawErrorKind kind = RawErrorKind::RAWERRORKIND_NONE;
  std::string message;
  int64_t code = 0;  ///< raw CURLcode, diagnostics only

  bool ok() const { return kind == RawErrorKind::RAWERRORKIND_NONE; }

  static EngineError none() { return {}; }
  static EngineError make(RawErrorKind k, std::string msg, int64_t c = 0) {
    return EngineError{k, std::move(msg), c};
  }
};

/// Total CURLcode → RawErrorKind mapping. `curlCode` is a `CURLcode` widened to
/// int so this header does not have to include curl.h. `httpProxyInUse`
/// disambiguates the several codes curl reuses for proxy failures.
RawErrorKind mapCurlError(int curlCode, bool proxyInUse);

/// Human-readable description that keeps the curl text but prefixes the
/// classification, so a log line is useful without a CURLcode table to hand.
std::string describeCurlError(int curlCode, const char* curlMessage);

// ── Stream sink ──────────────────────────────────────────────────────────────
//
// The generated `emit_*` helpers are member functions of the bridge class and
// fan out to a file-level static port registry keyed by stream NAME — the
// instance id is accepted and discarded. Streams are therefore module-global
// by construction, which is exactly why every item carries a `requestId` or
// `socketId` and why the Dart runner keeps exactly one subscription per stream
// and demultiplexes. Routing per instance is not possible; do not try.

struct StreamSink {
  /// Emits a body chunk. `item.bytes` stays NATIVE-OWNED — see ChunkArena for
  /// the release protocol. Must be safe to call from the engine loop thread.
  std::function<void(RawChunk)> chunk;

  /// Emits a progress/drain/notice event. Takes ownership of the buffer.
  std::function<void(NitroCppBuffer)> event;

  /// Emits a WebSocket frame. `item.payload` stays native-owned, released via
  /// the `wsGrantCredit` ack.
  std::function<void(RawWsFrame)> wsFrame;

  bool valid() const { return chunk && event && wsFrame; }
};

/// Process-global sink, installed once by `HybridNitroHttp.cpp` (or by a test
/// harness). Module-global because the streams themselves are.
StreamSink& streamSink();
void installStreamSink(StreamSink sink);

// ── Small helpers ────────────────────────────────────────────────────────────

/// ASCII case-insensitive compare — HTTP header names are ASCII by RFC, and
/// `strcasecmp` is locale-sensitive on some platforms.
bool asciiEqualIgnoreCase(const std::string& a, const std::string& b);
std::string asciiLower(std::string s);
std::string trimAsciiSpace(const std::string& s);

/// Finds the first header whose name case-insensitively equals `name`.
/// Returns nullptr when absent — duplicates are preserved in the vector, so
/// callers that care (Set-Cookie) must iterate.
const RawHeader* findHeader(const std::vector<RawHeader>& headers,
                            const std::string& name);

/// Splits `"HTTP/1.1 200 OK"`-style status lines. Returns false when the line
/// is not a status line at all (which is how header accumulation detects the
/// start of a new block across redirects).
///
/// `reasonPhrase` receives the text after the code with surrounding whitespace
/// and the trailing CRLF stripped, and is set to empty when the server sent
/// none — HTTP/2 and HTTP/3 have no reason phrase, so curl synthesises a status
/// line without one.
bool parseStatusLine(const std::string& line, int* statusCode,
                     std::string* reasonPhrase = nullptr);

/// Splits `"Name: value"`. Trailing CRLF and surrounding whitespace are
/// stripped. Returns false for continuation lines and garbage.
bool parseHeaderLine(const std::string& line, std::string* name,
                     std::string* value);

/// Lowercased scheme+host+port+path+sorted-query, for cache keys. Not a
/// general-purpose URL normaliser: it exists to make two spellings of the same
/// resource hash the same.
std::string canonicalizeUrl(const std::string& url);

std::string hexSha256(const void* data, size_t len);

std::string base64Encode(const void* data, size_t len);
bool base64Decode(const std::string& in, std::vector<uint8_t>* out);

// ── Debug thread guard ───────────────────────────────────────────────────────
//
// Once `curl_multi_add_handle` has been called, ONLY the loop thread may touch
// that handle. `curl_easy_pause` from another thread is undefined behaviour
// that manifests as rare, unreproducible crashes, so every curl-touching
// method asserts its thread in debug builds.

class ThreadGuard {
 public:
  void bind();                 ///< call from the owning thread
  bool onOwningThread() const; ///< always true before bind()
 private:
  std::atomic<uint64_t> owner_{0};
};

#ifdef NDEBUG
#define NITRO_HTTP_ASSERT_THREAD(guard) ((void)0)
#else
#define NITRO_HTTP_ASSERT_THREAD(guard) nitrohttp::assertThread((guard), __FILE__, __LINE__)
void assertThread(const ThreadGuard& guard, const char* file, int line);
#endif

// ── Capability queries ───────────────────────────────────────────────────────

/// `libcurl/8.21.0 OpenSSL/3.5.0 nghttp2/1.70.0 …` — whatever curl reports,
/// verbatim, so a bug report identifies the exact stack.
std::string engineVersionString();
bool hasHttp3();
bool hasWebSockets();  ///< always true: RFC 6455 framing is ours, not curl's

/// What the ENGINE can decode, not what curl can. Content decoding moved into
/// `ContentDecoder` precisely so the answer stops depending on how the local
/// libcurl happened to be built, and these two are what `NitroHttp.supportsBrotli`
/// / `supportsZstd` hand users — they have to describe the codings that actually
/// work end to end.
bool hasBrotli();
bool hasZstd();

/// The exact `Accept-Encoding` value the engine advertises: the comma-separated
/// list of codings `ContentDecoder` can inflate in this build. Built once.
///
/// Advertising anything wider would invite a server to send a coding we would
/// then have to pass through as opaque bytes, which is a correct-but-useless
/// response. Advertising anything narrower would give up compression we can
/// handle.
const std::string& acceptEncodingHeader();

/// Runs `curl_global_init` under `std::call_once`. Never paired with
/// `curl_global_cleanup`: that is unsafe with concurrent reload and would save
/// a few KB at library unload, which is not a trade worth a crash.
void ensureCurlGlobalInit();

}  // namespace nitrohttp
