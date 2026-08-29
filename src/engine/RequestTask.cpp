// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — RequestTask implementation.
//
// The whole file exists to protect one invariant: EXACTLY ONE completion per
// accepted request. Every early return either completes the task or leaves it
// attached to curl, and `completed_` makes both completion entry points
// idempotent. The destructor completes anything that somehow slipped through
// with `engineError`, because a request that never posts hangs a Dart `Future`
// forever and there is no recovery from that.
//
// Feature guards use `LIBCURL_VERSION_NUM`, never `#ifdef`: every `CURLOPT_*` and
// `CURLINFO_*` name is an enum constant built by a macro curl.h `#undef`s, so
// `#ifdef` is always false and would silently disable the feature.
// ─────────────────────────────────────────────────────────────────────────────

#include "RequestTask.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "CertStore.h"
#include "ClientConfig.h"
#include "CookieBridge.h"
#include "CurlEngine.h"
#include "DartPost.h"
#include "DeferredPayloads.h"
#include "Wire.h"

namespace nitrohttp {
namespace {

/// Cached bodies are replayed in blocks this size so a 40 MB entry does not
/// become one 40 MB `RawChunk`.
constexpr size_t kReplayChunkBytes = 64 * 1024;

/// Soft high-water mark for streamed request bodies. The Dart runner throttles
/// its source above this depth and resumes on the `uploadDrain` event.
constexpr size_t kUploadPipeSoftCapBytes = 1024 * 1024;

/// One progress event per this many milliseconds, at most.
constexpr double kProgressIntervalMs = 100.0;

/// Smallest declared body that opts into coalescing by default.
///
/// Below this the batching cannot pay for itself (a 1 MiB body is only ~64 write
/// callbacks), and the responses that stream without a length at all — server-
/// sent events, long polls — must keep their bytes moving immediately.
constexpr int64_t kDefaultCoalesceMinContentLength = 1 << 20;

/// Longest a partly-filled chunk may be held by default.
///
/// The ladder below assumes a large body also arrives quickly. That holds on a
/// fast link and fails on a slow one, where a 512 KiB target would sit half-full
/// for seconds. Flushing on age bounds the damage, so batching can never turn a
/// throughput win into a latency regression.
constexpr double kDefaultCoalesceMaxHoldMs = 25.0;

/// Chunk size for a body of any size, when the client asked for `auto`.
///
/// FLAT, NOT A LADDER, AND THE FLATNESS IS MEASURED. This was first written as a
/// ladder — 64 KiB, 256 KiB above 16 MiB, 512 KiB above 128 MiB — on the
/// reasoning that a bigger body has more chunks and so deserves a coarser
/// target. `example/integration_test/chunk_ladder_test.dart` sweeps chunk size
/// against body size and says otherwise. Throughput in MiB/s on an M1 Pro over
/// loopback:
///
///   body    none    16K     64K     128K    256K    512K    1M
///   8 MiB   218.0   221.7   235.7   240.5   215.1   218.2   222.6
///   32 MiB  222.5   224.9   237.2   246.9   226.3   229.4   236.5
///   64 MiB  225.6   228.5   241.2   247.6   222.5   230.9   234.4
///   128 MiB 225.1   224.6   240.7   242.3   221.8   227.3   232.9
///   256 MiB 225.1   225.6   240.7   242.4   220.7   227.7   234.8
///
/// 128 KiB wins at every size, and the curve is not monotonic: 256 KiB is the
/// worst batching size tested and at four of the five body sizes it is slower
/// than not batching at all. The ladder was therefore selecting close to the
/// worst option above 16 MiB — which is why a 32 MiB download measured 143 ms
/// through the ladder and 129.6 ms at a flat 128 KiB.
///
/// The parameter is kept so the signature still expresses "the engine may choose
/// per response", and because a future backend may want the freedom. Anyone
/// reintroducing a size dependence should re-run that sweep first.
size_t adaptiveCoalesceBytes(int64_t /*contentLength*/) { return 128 * 1024; }

/// `CURLINFO_PROXY_ERROR` — 7.73.0.
#define NITRO_HTTP_HAS_PROXY_ERROR (LIBCURL_VERSION_NUM >= 0x074900)

/// Copies a payload that is about to cross the FFI boundary, guaranteeing a
/// non-null pointer even for an empty payload: the generated Dart proxy calls
/// `Pointer.asTypedList`, which cannot accept `nullptr`. The arena owns the
/// allocation; the length on the wire is the real (possibly zero) length.
Blob copyPayload(const void* data, size_t len) {
  if (len == 0) return Blob::copy("", 1);
  return Blob::copy(data, len);
}

RawHttpVersion mapCurlHttpVersion(long v) {
  switch (v) {
    case CURL_HTTP_VERSION_1_0:
      return RawHttpVersion::RAWHTTPVERSION_HTTP10;
    case CURL_HTTP_VERSION_1_1:
      return RawHttpVersion::RAWHTTPVERSION_HTTP11;
    case CURL_HTTP_VERSION_2_0:
      return RawHttpVersion::RAWHTTPVERSION_HTTP2;
#if LIBCURL_VERSION_NUM >= 0x074200
    case CURL_HTTP_VERSION_3:
      return RawHttpVersion::RAWHTTPVERSION_HTTP3;
#endif
    default:
      return RawHttpVersion::RAWHTTPVERSION_UNKNOWN;
  }
}

/// A 3xx carrying `Location` is followed by curl when redirects are enabled, so
/// its header block is not the response the caller asked for. Treating it as
/// non-final regardless of the redirect policy is safe: when redirects are
/// disabled the head is published from the first body byte (or from completion),
/// which costs a little latency and never publishes the wrong status.
bool statusBlockIsFinal(int64_t status, const std::vector<RawHeader>& headers) {
  if (status < 200) return false;  // 1xx is informational
  if (status < 300 || status >= 400) return true;
  return findHeader(headers, "Location") == nullptr;
}

/// The body length a streamed consumer can rely on, taken from the headers
/// rather than from curl.
///
/// `CURLINFO_CONTENT_LENGTH_DOWNLOAD_T` is still -1 while the header callback
/// runs — curl only publishes it after the header phase — and the streamed head
/// is posted from exactly there, so the info API cannot serve this.
///
/// There is deliberately no `Content-Encoding` special case here any more. When
/// the engine decoded the body, `beginContentDecoding` has already removed both
/// headers, so this returns -1 on its own. When it passed the body through, the
/// header describes precisely the bytes Dart receives and is the right answer.
int64_t contentLengthFromHeaders(const std::vector<RawHeader>& headers) {
  const RawHeader* header = findHeader(headers, "Content-Length");
  if (header == nullptr) return -1;

  const std::string value = trimAsciiSpace(header->value);
  if (value.empty()) return -1;
  int64_t length = 0;
  for (const char c : value) {
    if (c < '0' || c > '9') return -1;
    length = length * 10 + (c - '0');
    if (length > (int64_t{1} << 53)) return -1;  // absurd, and unrepresentable in Dart
  }
  return length;
}

/// Drops every header with this name. Duplicates are possible and all of them
/// have to go, or the survivor still lies about the body.
void eraseHeaders(std::vector<RawHeader>* headers, const std::string& name) {
  headers->erase(std::remove_if(headers->begin(), headers->end(),
                                [&name](const RawHeader& h) {
                                  return asciiEqualIgnoreCase(h.name, name);
                                }),
                 headers->end());
}

/// `curl_easy_setopt` copies string options, so a temporary line is fine here.
void appendHeaderLine(struct curl_slist** list, const std::string& line) {
  struct curl_slist* grown = curl_slist_append(*list, line.c_str());
  if (grown != nullptr) *list = grown;
}

/// The header name a rendered `Name: value` / `Name;` line carries.
std::string headerLineName(const std::string& line) {
  const size_t cut = line.find_first_of(":;");
  return cut == std::string::npos ? line : line.substr(0, cut);
}

/// Which of the three deadlines actually fired.
///
/// curl collapses all of them into `CURLE_OPERATION_TIMEDOUT`, so `mapCurlError`
/// can only answer with the generic `timeoutRequest`. Telling them apart matters:
/// a connect timeout means "this host is unreachable, back off", an idle timeout
/// means "the peer went quiet mid-body, retry is cheap", and a request timeout
/// means "the caller's own budget ran out". `effectiveRequestTimeoutMs` is the
/// resolved per-transfer budget, 0 when the caller set none.
RawErrorKind classifyTimeout(CURL* easy, int64_t effectiveRequestTimeoutMs,
                             int64_t effectiveConnectTimeoutMs) {
  if (easy == nullptr) return RawErrorKind::RAWERRORKIND_TIMEOUT_REQUEST;

  const auto micros = [easy](CURLINFO info) -> curl_off_t {
    curl_off_t value = 0;
    if (curl_easy_getinfo(easy, info, &value) != CURLE_OK) return 0;
    return value;
  };

  // The caller's own budget outranks everything: if it has run out, that is the
  // deadline that fired no matter which phase the transfer was in. curl checks
  // it at millisecond granularity, hence the two-millisecond slack.
  const int64_t elapsedMs =
      static_cast<int64_t>(micros(CURLINFO_TOTAL_TIME_T) / 1000);
  // WHICH DEADLINE curl STOPPED AT is the reliable signal, not which phase
  // stamps are still zero.
  //
  // The phase stamps used to carry this: `PRETRANSFER_TIME_T` stayed 0 until the
  // whole connect phase finished, so 0 meant "never connected". curl 8.21 stamps
  // it — and `STARTTRANSFER_TIME_T` — with the elapsed time even when the
  // connect never completed, so both reads are non-zero on a connect timeout and
  // the old test fell through to `timeoutIdle`. Measured against a black-holed
  // TEST-NET-1 address with a 400 ms connect budget:
  //
  //   total=400ms connect=0 appconnect=0 pretransfer=400056 starttransfer=400056
  //
  // Comparing the elapsed time against the budget that was actually configured
  // does not depend on any of that, and reads the same on every curl version.
  // The connect budget is checked first because it is the inner deadline: if it
  // has run out, connect is what failed regardless of how much request budget
  // was left. curl checks deadlines at millisecond granularity, hence the slack.
  if (effectiveConnectTimeoutMs > 0 &&
      elapsedMs + 2 >= effectiveConnectTimeoutMs) {
    return RawErrorKind::RAWERRORKIND_TIMEOUT_CONNECT;
  }
  if (effectiveRequestTimeoutMs > 0 &&
      elapsedMs + 2 >= effectiveRequestTimeoutMs) {
    return RawErrorKind::RAWERRORKIND_TIMEOUT_REQUEST;
  }

  // Neither budget explains it, which means the caller set no connect budget and
  // curl's own default (300 s) fired, or a deadline moved underneath us. Fall
  // back to the phase stamps, now read for what they still say reliably: TCP
  // completion and TLS completion. `CONNECT_TIME` is stamped when TCP is up, and
  // `APPCONNECT_TIME` when TLS is, so a zero in either is a connect phase that
  // never finished.
  if (micros(CURLINFO_CONNECT_TIME_T) == 0) {
    return RawErrorKind::RAWERRORKIND_TIMEOUT_CONNECT;
  }
  return RawErrorKind::RAWERRORKIND_TIMEOUT_REQUEST;
}

/// How the request body is handed to curl. The three strategies imply three
/// different HTTP verbs, which is why `CURLOPT_CUSTOMREQUEST` is only set when
/// the implied verb differs from the one the caller asked for — setting it
/// unconditionally breaks curl's own method rewriting across redirects.
enum class BodyStrategy { NoBody, Fields, Upload };

BodyStrategy chooseBodyStrategy(const RawRequest& req) {
  if (req.method == RawMethod::RAWMETHOD_HEAD) return BodyStrategy::NoBody;
  switch (req.bodyKind) {
    case RawBodyKind::RAWBODYKIND_FILE_PATH:
    case RawBodyKind::RAWBODYKIND_STREAMED:
      return BodyStrategy::Upload;
    case RawBodyKind::RAWBODYKIND_BYTES:
      // A `PUT` with an inline body streams through READFUNCTION so curl frames
      // it as a real upload rather than a form post.
      return req.method == RawMethod::RAWMETHOD_PUT ? BodyStrategy::Upload
                                                   : BodyStrategy::Fields;
    case RawBodyKind::RAWBODYKIND_NONE:
      break;
  }
  // A body-carrying verb with no body still needs `Content-Length: 0`; servers
  // reject a bodyless POST or PATCH that omits it.
  return wire::methodIsBodyless(req) ? BodyStrategy::NoBody
                                     : BodyStrategy::Fields;
}

const char* impliedVerb(BodyStrategy strategy, const RawRequest& req) {
  switch (strategy) {
    case BodyStrategy::Fields:
      return "POST";
    case BodyStrategy::Upload:
      return "PUT";
    case BodyStrategy::NoBody:
      break;
  }
  return req.method == RawMethod::RAWMETHOD_HEAD ? "HEAD" : "GET";
}

/// Portable 64-bit file size. `fseeko`/`ftello` are POSIX; MSVC spells them with
/// an underscore and no `off_t`.
bool fileSize(FILE* file, curl_off_t* out) {
#if defined(_WIN32)
  if (_fseeki64(file, 0, SEEK_END) != 0) return false;
  const long long size = _ftelli64(file);
  if (size < 0 || _fseeki64(file, 0, SEEK_SET) != 0) return false;
#else
  if (fseeko(file, 0, SEEK_END) != 0) return false;
  const off_t size = ftello(file);
  if (size < 0 || fseeko(file, 0, SEEK_SET) != 0) return false;
#endif
  *out = static_cast<curl_off_t>(size);
  return true;
}

}  // namespace

RequestTask::RequestTask(CurlEngine& engine, PendingRequest pending)
    : engine_(engine), pending_(std::move(pending)) {
  // Resolved in the constructor, before `prepare` and before the handle is
  // added to the multi, so `startTask` can refuse an already-cancelled token
  // without ever opening a socket. `obtain` creates the state when this request
  // is the first mention of the token, which is the ordinary case.
  token_ = CancelRegistry::instance().obtain(pending_.req.options.cancelTokenId);
}

RequestTask::~RequestTask() {
  // Last line of defence for exactly-once completion. Reaching here uncompleted
  // is an engine bug, but a hung Dart Future is worse than a wrong error kind.
  if (!completed_) {
    completeWithError(EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
                                        "request destroyed before completion"));
  }

  if (pending_.mode == RespMode::Prefetch && cache_ && !cacheKey_.empty()) {
    cache_->releasePrefetch(cacheKey_);
  }

  if (headerList_ != nullptr) {
    curl_slist_free_all(headerList_);
    headerList_ = nullptr;
  }
  if (uploadFile_ != nullptr) {
    fclose(uploadFile_);
    uploadFile_ = nullptr;
  }
  if (easy_ != nullptr) {
    curl_easy_cleanup(easy_);
    easy_ = nullptr;
  }

  // Never `arena_.releaseAll()`: chunks already posted may not have been copied
  // by the isolate yet. The registry frees them on the runner's terminal ack.
  DeferredPayloads::instance().adopt(PayloadOwner::Request, id(), arena_);
}

// ── Setup ────────────────────────────────────────────────────────────────────

EngineError RequestTask::prepare(const ClientConfig& config,
                                 CookieBridge* cookies,
                                 const std::shared_ptr<HttpCache>& cache) {
  const RawRequest& req = pending_.req;
  const RawRequestOptions& options = req.options;

  if (req.url.empty()) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_BAD_REQUEST,
                             "request URL is empty");
  }
  const std::string token = wire::methodToken(req);
  if (token.empty()) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_BAD_REQUEST,
                             "custom method requested without a method token");
  }
  if (req.bodyKind == RawBodyKind::RAWBODYKIND_FILE_PATH &&
      req.bodyFilePath.empty()) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_BAD_REQUEST,
                             "file body requested without a path");
  }

  // Recycled when the engine has a spare: `curl_easy_reset` left it with default
  // options but kept the connection, DNS and TLS-session caches, so everything
  // below still applies to a blank handle.
  easy_ = engine_.acquireEasy();
  if (easy_ == nullptr) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
                             "curl_easy_init failed");
  }

  EngineError err = config.applyTo(easy_);
  if (!err.ok()) return err;

  // Per-request overrides. `-1` means "inherit", which is why these go through
  // `wire::inherit` rather than a plain comparison against zero.
  const int64_t connectMs =
      wire::inherit(options.connectTimeoutMs, config.raw().connectTimeoutMs);
  curl_easy_setopt(easy_, CURLOPT_CONNECTTIMEOUT_MS,
                   static_cast<long>(connectMs > 0 ? connectMs : 0));
  // Sentinel collapsed in place, exactly as the request budget is below:
  // `classifyTimeout` needs the *effective* connect budget to tell a connect
  // timeout from a request one, and by then the client config is gone.
  pending_.req.options.connectTimeoutMs = connectMs > 0 ? connectMs : 0;
  const int64_t totalMs =
      wire::inherit(options.requestTimeoutMs, config.raw().requestTimeoutMs);
  curl_easy_setopt(easy_, CURLOPT_TIMEOUT_MS,
                   static_cast<long>(totalMs > 0 ? totalMs : 0));
  // Sentinel collapsed in place: `finish` needs the *effective* budget to tell a
  // request timeout from an idle one, and by then the client config is gone.
  pending_.req.options.requestTimeoutMs = totalMs > 0 ? totalMs : 0;
  // No per-request override exists for this one, so the client budget is the
  // whole story. The engine loop polices it; see `idleBudgetRemainingMs`.
  idleTimeoutMs_ = config.raw().idleTimeoutMs > 0 ? config.raw().idleTimeoutMs : 0;
  const bool follow =
      wire::inheritBool(options.followRedirects, config.raw().followRedirects);
  curl_easy_setopt(easy_, CURLOPT_FOLLOWLOCATION, follow ? 1L : 0L);
  const int64_t maxRedirects =
      wire::inherit(options.maxRedirects, config.raw().maxRedirects);
  curl_easy_setopt(easy_, CURLOPT_MAXREDIRS,
                   static_cast<long>(maxRedirects >= 0 ? maxRedirects : -1));

  curl_easy_setopt(easy_, CURLOPT_URL, req.url.c_str());

  const BodyStrategy strategy = chooseBodyStrategy(req);
  if (token != impliedVerb(strategy, req)) {
    curl_easy_setopt(easy_, CURLOPT_CUSTOMREQUEST, token.c_str());
  }
  if (req.method == RawMethod::RAWMETHOD_HEAD) {
    curl_easy_setopt(easy_, CURLOPT_NOBODY, 1L);
  }

  switch (strategy) {
    case BodyStrategy::NoBody:
      break;
    case BodyStrategy::Fields:
      // `CURLOPT_POSTFIELDS` does not copy. `pending_.body` was deep-copied out
      // of Nitro's arena and lives exactly as long as this task, so pointing
      // curl at it directly is safe and avoids a second copy of every payload.
      curl_easy_setopt(easy_, CURLOPT_POSTFIELDSIZE_LARGE,
                       static_cast<curl_off_t>(pending_.body.size()));
      curl_easy_setopt(
          easy_, CURLOPT_POSTFIELDS,
          pending_.body.empty()
              ? ""
              : reinterpret_cast<const char*>(pending_.body.data()));
      break;
    case BodyStrategy::Upload: {
      curl_easy_setopt(easy_, CURLOPT_UPLOAD, 1L);
      if (req.bodyKind == RawBodyKind::RAWBODYKIND_FILE_PATH) {
        uploadFile_ = fopen(req.bodyFilePath.c_str(), "rb");
        if (uploadFile_ == nullptr) {
          return EngineError::make(
              RawErrorKind::RAWERRORKIND_IO,
              "cannot open request body file: " + req.bodyFilePath);
        }
        curl_off_t size = 0;
        if (fileSize(uploadFile_, &size)) {
          curl_easy_setopt(easy_, CURLOPT_INFILESIZE_LARGE, size);
        }
      } else if (req.bodyKind == RawBodyKind::RAWBODYKIND_STREAMED) {
        pipe_.reset(new BodyPipe(kUploadPipeSoftCapBytes));
        // Dart may start pumping before the submit op reaches the loop thread;
        // `CurlEngine::feedUpload` parks those early bytes here.
        if (!pending_.body.empty()) {
          pipe_->push(pending_.body.data(), pending_.body.size());
        }
        if (options.uploadContentLength >= 0) {
          curl_easy_setopt(
              easy_, CURLOPT_INFILESIZE_LARGE,
              static_cast<curl_off_t>(options.uploadContentLength));
        }
      } else {
        curl_easy_setopt(easy_, CURLOPT_INFILESIZE_LARGE,
                         static_cast<curl_off_t>(pending_.body.size()));
      }
      break;
    }
  }

  // Client defaults first, then request headers, which win by name.
  for (const std::string& line : config.defaultHeaderLines()) {
    if (findHeader(req.headers, headerLineName(line)) != nullptr) continue;
    appendHeaderLine(&headerList_, line);
  }
  for (const RawHeader& header : req.headers) {
    if (header.name.empty()) continue;
    appendHeaderLine(&headerList_, header.value.empty()
                                       ? header.name + ";"
                                       : header.name + ": " + header.value);
  }
  if (req.bodyKind == RawBodyKind::RAWBODYKIND_STREAMED &&
      options.uploadContentLength < 0 &&
      findHeader(req.headers, "Transfer-Encoding") == nullptr &&
      findHeader(req.headers, "Content-Length") == nullptr) {
    // An upload of unknown length has to be framed somehow, and curl requires
    // the application to ask for chunked explicitly. HTTP/2 and later frame
    // bodies themselves, where curl drops this header again.
    appendHeaderLine(&headerList_, "Transfer-Encoding: chunked");
  }
  if (req.bodyKind != RawBodyKind::RAWBODYKIND_NONE &&
      findHeader(req.headers, "Expect") == nullptr) {
    // Suppress curl's automatic `Expect: 100-continue`, which it adds by itself
    // once a body is large (observed: not at 128 KiB, yes at 8 MiB). Against a
    // server that simply ignores the header — which includes `dart:io`'s own
    // `HttpServer`, and therefore `shelf` — curl waits out
    // `CURLOPT_EXPECT_100_TIMEOUT_MS` (1 s by default) before sending the body at
    // all. Measured on an 8 MiB POST: 1134 ms with the header, 120 ms without,
    // for every body shape (in-memory, file and streamed). `dart:io`,
    // `package:http`, `dio` and `rhttp` all take ~120 ms; none of them send it.
    //
    // A caller who genuinely wants the handshake sets `Expect: 100-continue`
    // themselves; the loop above has already emitted it and this block then
    // leaves it alone. An empty value after the colon is curl's documented way
    // to drop a header it would otherwise add itself.
    appendHeaderLine(&headerList_, "Expect:");
  }
  if (headerList_ != nullptr) {
    curl_easy_setopt(easy_, CURLOPT_HTTPHEADER, headerList_);
  }

  curl_easy_setopt(easy_, CURLOPT_HEADERFUNCTION, &RequestTask::onHeader);
  curl_easy_setopt(easy_, CURLOPT_HEADERDATA, this);
  curl_easy_setopt(easy_, CURLOPT_WRITEFUNCTION, &RequestTask::onWrite);
  curl_easy_setopt(easy_, CURLOPT_WRITEDATA, this);
  curl_easy_setopt(easy_, CURLOPT_READFUNCTION, &RequestTask::onRead);
  curl_easy_setopt(easy_, CURLOPT_READDATA, this);
  curl_easy_setopt(easy_, CURLOPT_XFERINFOFUNCTION, &RequestTask::onProgress);
  curl_easy_setopt(easy_, CURLOPT_XFERINFODATA, this);
  // Always on: the progress callback is also the cancellation check, so a
  // transfer that reports no progress at all must still be interruptible.
  curl_easy_setopt(easy_, CURLOPT_NOPROGRESS, 0L);
  curl_easy_setopt(easy_, CURLOPT_PRIVATE, this);

  // Bind to the engine's `curl_share`. Without this the share is inert for real
  // traffic: every transfer gets a PRIVATE cookie jar that dies with the handle
  // (so a `Set-Cookie` is never replayed and `getCookies` reads an empty jar),
  // and resolved addresses and TLS session tickets are never reused across
  // requests on this client.
  if (CURLSH* share = engine_.share()) {
    curl_easy_setopt(easy_, CURLOPT_SHARE, share);
  }

  err = CertStore::apply(easy_, config.raw().tls, options.pinnedSpkiOverride);
  if (!err.ok()) return err;

  if (cookies != nullptr) cookies->attach(easy_);

  cache_ = cache;
  if (cache_ && config.cacheEnabled() &&
      options.cacheMode != RawCacheMode::RAWCACHEMODE_NO_STORE) {
    cacheKey_ = cache_->keyFor(token, req.url, req.headers);
  }

  startedAtMs_ = monotonicMs();
  return EngineError::none();
}

void RequestTask::markAttached() { attached_ = true; }

// ── Cache ────────────────────────────────────────────────────────────────────

bool RequestTask::tryServeFromCache(const std::shared_ptr<HttpCache>& cache,
                                    bool afterRevalidation) {
  const RawCacheMode mode = pending_.req.options.cacheMode;
  const bool onlyIfCached = mode == RawCacheMode::RAWCACHEMODE_ONLY_IF_CACHED;

  // `onlyIfCached` must never reach the network, so anything short of a fresh
  // hit is a hard miss the caller has to see.
  const auto answerMiss = [this, onlyIfCached]() -> bool {
    if (!onlyIfCached) return false;
    completeWithError(EngineError::make(
        RawErrorKind::RAWERRORKIND_CACHE_MISS,
        "no usable cached response and cacheMode is onlyIfCached"));
    return true;
  };

  if (!cache || cacheKey_.empty() ||
      (!afterRevalidation && (mode == RawCacheMode::RAWCACHEMODE_NO_STORE ||
                              mode == RawCacheMode::RAWCACHEMODE_BYPASS))) {
    return answerMiss();
  }

  const std::string method = wire::methodToken(pending_.req);
  // After a 304 the stored body is what the caller gets, so ask the cache to
  // load it even though the freshness check will still call the entry stale —
  // and to leave its hit/miss counters where the first lookup left them.
  CacheHit hit = cache->lookup(cacheKey_, mode, method, pending_.req.headers,
                               /*afterRevalidation=*/afterRevalidation);
  if (!afterRevalidation && mode == RawCacheMode::RAWCACHEMODE_REFRESH &&
      hit.outcome == CacheOutcome::Fresh) {
    // `refresh` means "ask the origin", so a fresh entry is demoted to a
    // conditional request rather than served.
    hit.outcome = CacheOutcome::Stale;
  }

  // A 304 IS the freshness proof, so a stored entry is servable here even when
  // its own lifetime is zero — which is exactly what
  // `Cache-Control: max-age=0` + `ETag` produces.
  const bool servable = afterRevalidation
                            ? (hit.outcome == CacheOutcome::Fresh ||
                               hit.outcome == CacheOutcome::Stale)
                            : hit.outcome == CacheOutcome::Fresh;

  if (!servable) {
    if (onlyIfCached) return answerMiss();

    if (pending_.mode == RespMode::Prefetch &&
        !cache->claimPrefetch(cacheKey_)) {
      // An identical prefetch is already running; doubling it would only cost
      // bandwidth. Clearing the key records that we hold no claim to release.
      // An ok `EngineError` completes with an empty success record — nothing
      // failed, and nothing was fetched.
      cacheKey_.clear();
      completeWithError(EngineError::none());
      return true;
    }

    if (hit.outcome == CacheOutcome::Stale &&
        (!hit.etag.empty() || !hit.lastModified.empty())) {
      revalidating_ = true;
      if (!hit.etag.empty()) {
        appendHeaderLine(&headerList_, "If-None-Match: " + hit.etag);
      }
      if (!hit.lastModified.empty()) {
        appendHeaderLine(&headerList_,
                         "If-Modified-Since: " + hit.lastModified);
      }
      curl_easy_setopt(easy_, CURLOPT_HTTPHEADER, headerList_);
    }
    return false;
  }

  // ── Servable: the body comes off disk ──────────────────────────────────────
  servedFromCache_ = true;
  statusCode_ = hit.statusCode;
  headers_ = std::move(hit.headers);
  contentLength_ = hit.contentLength;
  version_ = RawHttpVersion::RAWHTTPVERSION_UNKNOWN;
  redirectCount_ = 0;
  if (afterRevalidation) {
    // A revalidation DID touch the network, so the DNS/connect/TTFB numbers
    // already collected are real and worth reporting; only the body was reused.
    finalUrl_ = finalUrl_.empty() ? pending_.req.url : finalUrl_;
  } else {
    finalUrl_ = pending_.req.url;
    timings_ = wire::zeroTimings();
    timings_.queueMs = monotonicMs() - pending_.submittedAtMs;
  }
  completed_ = true;

  if (pending_.mode == RespMode::Streamed) {
    headSent_ = true;
    RawResponseHead head{};
    head.requestId = id();
    head.errorKind = RawErrorKind::RAWERRORKIND_NONE;
    head.engineErrorCode = 0;
    head.statusCode = statusCode_;
  head.reasonPhrase = reasonPhrase_;
    head.version = version_;
    head.finalUrl = finalUrl_;
    head.redirectCount = 0;
    head.headers = headers_;
    head.fromCache = true;
    head.contentLength = contentLength_;
    head.primaryPort = 0;
    head.timings = timings_;

    if (postRecord(pending_.dartPort, wire::encodeResponseHead(head))) {
      // Credits are debited for the accounting the runner's acks rely on, but
      // the replay never stalls on them: this task owns no attached handle to
      // pause and resume. A cached entry is bounded by the cache's own
      // `maxEntryBytes`, so the burst cannot grow without limit, and the
      // deferred registry keeps the payloads alive until the runner acks.
      if (!hit.body.empty()) {
        size_t offset = 0;
        while (offset < hit.body.size()) {
          const size_t left = hit.body.size() - offset;
          const size_t n = left < kReplayChunkBytes ? left : kReplayChunkBytes;
          emitChunk(hit.body.data() + offset, n);
          --credits_;
          offset += n;
        }
      } else if (!hit.bodyPath.empty()) {
        FILE* body = fopen(hit.bodyPath.c_str(), "rb");
        if (body != nullptr) {
          std::vector<uint8_t> block(kReplayChunkBytes);
          for (;;) {
            const size_t n = fread(block.data(), 1, block.size(), body);
            if (n == 0) break;
            emitChunk(block.data(), n);
            --credits_;
          }
          fclose(body);
        }
      }
      emitTerminalChunk(EngineError::none());
    }
  } else {
    RawResponse response{};
    response.requestId = id();
    response.errorKind = RawErrorKind::RAWERRORKIND_NONE;
    response.engineErrorCode = 0;
    response.statusCode = statusCode_;
    response.reasonPhrase = reasonPhrase_;
    response.version = version_;
    response.finalUrl = finalUrl_;
    response.redirectCount = 0;
    response.headers = headers_;
    // A prefetch only warms the cache; shipping the bytes to Dart as well would
    // defeat the point of prefetching.
    if (pending_.mode != RespMode::Prefetch) response.body = std::move(hit.body);
    response.fromCache = true;
    response.revalidated = revalidating_;
    response.primaryPort = 0;
    response.timings = timings_;
    deliverBuffered(wire::encodeResponse(response));
  }

  if (pending_.mode == RespMode::Prefetch) cacheKey_.clear();
  return true;
}

// ── curl callback trampolines ────────────────────────────────────────────────

size_t RequestTask::onHeader(char* buf, size_t size, size_t n, void* self) {
  return static_cast<RequestTask*>(self)->handleHeader(buf, size * n);
}

size_t RequestTask::onWrite(char* buf, size_t size, size_t n, void* self) {
  return static_cast<RequestTask*>(self)->handleWrite(buf, size * n);
}

size_t RequestTask::onRead(char* buf, size_t size, size_t n, void* self) {
  return static_cast<RequestTask*>(self)->handleRead(buf, size * n);
}

int RequestTask::onProgress(void* self, curl_off_t dlTotal, curl_off_t dlNow,
                            curl_off_t ulTotal, curl_off_t ulNow) {
  auto* task = static_cast<RequestTask*>(self);

  // The one place a cancellation can interrupt a connect or a stalled read: any
  // non-zero return aborts the transfer with CURLE_ABORTED_BY_CALLBACK.
  if (task->cancelRequested()) return 1;
  if (!task->pending_.req.options.reportProgress) return 0;

  const double now = monotonicMs();
  if (now - task->lastProgressMs_ < kProgressIntervalMs) return 0;

  // The stamp moves only when an event actually went out. curl calls this back
  // during connect with both counters at zero; stamping there would swallow the
  // first real byte movement for a further `kProgressIntervalMs`, which on a
  // loopback transfer is the whole transfer.
  if (dlNow != task->lastDlNow_) {
    task->lastDlNow_ = dlNow;
    task->lastProgressMs_ = now;
    task->emitProgress(RawEventKind::RAWEVENTKIND_DOWNLOAD_PROGRESS,
                       static_cast<int64_t>(dlNow),
                       dlTotal > 0 ? static_cast<int64_t>(dlTotal) : -1);
  }
  if (ulNow != task->lastUlNow_) {
    task->lastUlNow_ = ulNow;
    task->lastProgressMs_ = now;
    task->emitProgress(RawEventKind::RAWEVENTKIND_UPLOAD_PROGRESS,
                       static_cast<int64_t>(ulNow),
                       ulTotal > 0 ? static_cast<int64_t>(ulTotal) : -1);
  }
  return 0;
}

// ── Header accumulation ──────────────────────────────────────────────────────

size_t RequestTask::handleHeader(const char* data, size_t len) {
  // The first response byte arms the idle clock. Everything before it belongs
  // to the connect budget.
  lastActivityMs_ = monotonicMs();

  const std::string line(data, len);

  int status = 0;
  std::string reason;
  if (parseStatusLine(line, &status, &reason)) {
    // A redirect chain re-sends a whole header block; only the last one counts.
    // The decoder is built from that block, so it has to go with it — a 302 that
    // was itself gzipped must not leave a half-fed inflate stream behind.
    headers_.clear();
    decoder_.reset();
    decodedBody_ = false;
    statusCode_ = status;
    reasonPhrase_ = std::move(reason);
    return len;
  }

  std::string name;
  std::string value;
  if (parseHeaderLine(line, &name, &value)) {
    headers_.push_back(RawHeader{std::move(name), std::move(value)});
    return len;
  }

  if (trimAsciiSpace(line).empty() &&
      statusBlockIsFinal(statusCode_, headers_) &&
      !(revalidating_ && statusCode_ == 304)) {
    emitHeadIfNeeded();
  }
  return len;
}

void RequestTask::beginContentDecoding() {
  const RawHeader* encoding = findHeader(headers_, "Content-Encoding");
  if (encoding == nullptr) return;

  decoder_ = ContentDecoder::forHeader(encoding->value);
  if (!decoder_) {
    // An unrecognised or `identity` coding. The body passes through byte for
    // byte and both headers stay, because they describe exactly what Dart gets.
    return;
  }
  decodedBody_ = true;

  // Both headers describe the ENCODED bytes, which nobody above this line will
  // ever see. Leaving them makes `contentLength` a lie and invites a caller to
  // inflate an already-inflated body. dart:io strips them for the same reason.
  //
  // It also keeps the cache honest: `beginWrite` below snapshots this vector,
  // and the entry stores decoded bytes.
  eraseHeaders(&headers_, "Content-Encoding");
  eraseHeaders(&headers_, "Content-Length");
}

void RequestTask::failContentDecoding() {
  completeWithError(EngineError::make(
      RawErrorKind::RAWERRORKIND_DECOMPRESSION_FAILURE,
      decoder_ ? decoder_->failure() : std::string("content decoding failed")));
}

void RequestTask::emitHeadIfNeeded() {
  if (headSent_) return;
  headSent_ = true;

  // Strictly first: the cache write-back and the published head both read
  // `headers_` after this, and `handleWrite` needs the decoder to exist before
  // it touches the first body byte.
  beginContentDecoding();

  // Opening the cache write-back here — before the first body byte — is what
  // lets the tee in `handleWrite` see the whole body.
  if (cache_ && !cacheKey_.empty() && !cacheWriter_ && statusCode_ > 0 &&
      !(revalidating_ && statusCode_ == 304) &&
      pending_.req.options.cacheMode != RawCacheMode::RAWCACHEMODE_NO_STORE) {
    cacheWriter_ = cache_->beginWrite(cacheKey_, statusCode_, headers_,
                                      pending_.req.headers,
                                      wire::methodToken(pending_.req),
                                      pending_.req.url);
  }

  if (pending_.mode != RespMode::Streamed) {
    // Reserve from the declared length so accumulation does not repeatedly
    // reallocate and copy. Measured effect on a 32 MiB buffered download: none
    // (437 ms either way) — the buffered path is dominated by the record codec's
    // own passes over the body, not by this vector's growth. Kept because it is
    // free and removes the reallocation regardless, not because it showed a win.
    // Capped so a hostile or mistaken `Content-Length` cannot be turned into an
    // arbitrary allocation — beyond the cap the vector simply grows as before.
    constexpr int64_t kMaxReserveBytes = 64LL * 1024 * 1024;
    const int64_t declared = decodedBody_ ? -1 : contentLengthFromHeaders(headers_);
    if (declared > 0 && declared <= kMaxReserveBytes) {
      bodyBuf_.reserve(static_cast<size_t>(declared));
    }
    return;
  }

  collectTransferInfo();
  collectTimings(&timings_);
  // A decoded body's length is only known once the last byte inflates, and both
  // the header and `CURLINFO_CONTENT_LENGTH_DOWNLOAD_T` count encoded bytes.
  if (decodedBody_) {
    contentLength_ = -1;
  } else if (contentLength_ < 0) {
    contentLength_ = contentLengthFromHeaders(headers_);
  }

  // Decided once, here, because it needs the final headers and must not change
  // mid-body. A decoded body reports `-1` above and so never coalesces, which is
  // the conservative answer: its inflated size is unknown until the last byte.
  const RawClientConfig& cfg = engine_.config().raw();
  const int64_t requested = cfg.streamChunkBytes;
  if (requested < 0) {
    coalesceTarget_ = 0;  // explicitly disabled by the caller
  } else {
    // `>= 0`, not `> 0`: zero is a real setting — "batch every response
    // whatever its size" — and Dart always sends an explicit value, so only a
    // negative can mean "unset".
    const int64_t minLength = cfg.streamChunkMinContentLength >= 0
                                  ? cfg.streamChunkMinContentLength
                                  : kDefaultCoalesceMinContentLength;
    if (contentLength_ >= minLength) {
      coalesceTarget_ = requested > 0
                            ? static_cast<size_t>(requested)
                            : adaptiveCoalesceBytes(contentLength_);
    }
  }
  coalesceMaxHoldMs_ = cfg.streamChunkMaxHoldMs >= 0
                           ? static_cast<double>(cfg.streamChunkMaxHoldMs)
                           : kDefaultCoalesceMaxHoldMs;
  if (coalesceTarget_ > 0) coalesceBuf_.reserve(coalesceTarget_);

  RawResponseHead head{};
  head.requestId = id();
  head.errorKind = RawErrorKind::RAWERRORKIND_NONE;
  head.engineErrorCode = 0;
  head.statusCode = statusCode_;
  head.reasonPhrase = reasonPhrase_;
  head.version = version_;
  head.finalUrl = finalUrl_.empty() ? pending_.req.url : finalUrl_;
  head.redirectCount = redirectCount_;
  head.headers = headers_;
  head.fromCache = false;
  head.contentLength = contentLength_;
  head.primaryIp = primaryIp_;
  head.primaryPort = primaryPort_;
  head.timings = timings_;

  if (!postRecord(pending_.dartPort, wire::encodeResponseHead(head))) {
    // Dead port — a hot restart tore the isolate down. Nothing will ever read
    // the body, so stop the transfer instead of downloading into a void.
    requestCancel();
  }
}

// ── Response body ────────────────────────────────────────────────────────────

size_t RequestTask::handleWrite(const char* data, size_t len) {
  if (len == 0) return 0;

  // The earliest abort point on a download. `XFERINFOFUNCTION` also aborts, but
  // it is throttled and only fires between transfers of progress, so on a fast
  // body this callback runs many times per progress tick — checking here is what
  // makes a cancelled 100 MB download stop at the next 16 KiB block instead of
  // at the next progress callback. Returning a short count is curl's documented
  // abort signal (CURLE_WRITE_ERROR); `finish` sees `cancelRequested()` and
  // reports it as cancelled rather than as a write failure.
  if (cancelRequested()) return 0;

  lastActivityMs_ = monotonicMs();

  // A 304 body (there should not be one) belongs to the revalidation handshake,
  // never to the caller.
  if (revalidating_ && statusCode_ == 304) return len;

  emitHeadIfNeeded();

  if (pending_.mode == RespMode::Streamed && credits_ <= 0) {
    // No credit: stop reading the socket entirely. The TCP window closes and the
    // peer stops sending, which is real backpressure rather than unbounded
    // native buffering.
    //
    // This check comes BEFORE the cache tee on purpose. curl buffers a paused
    // block and hands the very same bytes to this callback again after the
    // unpause, so teeing first would write every paused block to the cache
    // entry twice and corrupt it.
    writePaused_ = true;
    return CURL_WRITEFUNC_PAUSE;
  }

  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data);
  size_t count = len;
  if (decoder_) {
    // Decoded FIRST, so the cache tee, the buffered accumulator and the streamed
    // chunks all see the same bytes. Anything else would give a cached replay a
    // different body from the live response.
    decodeBuf_.clear();
    if (!decoder_->write(bytes, len, &decodeBuf_)) {
      failContentDecoding();
      // Any short return aborts the transfer with CURLE_WRITE_ERROR. `finish`
      // then sees `completed_` and leaves our error in place.
      return 0;
    }
    bytes = decodeBuf_.data();
    count = decodeBuf_.size();
  }

  if (cacheWriter_ && count > 0) {
    if (!cacheWriter_->write(bytes, count)) {
      cacheWriter_.reset();  // entry outgrew the cache; stop teeing
    }
  }

  switch (pending_.mode) {
    case RespMode::Streamed:
      // An encoded block can decode to nothing at all — a gzip header split
      // across two socket reads. Emitting an empty chunk would spend a credit
      // and look to the runner like a body byte.
      if (count > 0) {
        if (coalesceTarget_ > 0) {
          // Batched into one larger chunk; see `coalesceTarget_`.
          if (coalesceBuf_.empty()) coalesceStartedMs_ = lastActivityMs_;
          coalesceBuf_.insert(coalesceBuf_.end(), bytes, bytes + count);
          // Age as well as size, so a body that arrives slowly is not held back
          // waiting for a threshold this link will not reach soon.
          if (coalesceBuf_.size() >= coalesceTarget_ ||
              lastActivityMs_ - coalesceStartedMs_ >= coalesceMaxHoldMs_) {
            flushCoalesced();
          }
        } else {
          emitChunk(bytes, count);
          --credits_;
        }
      }
      return len;

    case RespMode::Buffered:
      bodyBuf_.insert(bodyBuf_.end(), bytes, bytes + count);
      return len;

    case RespMode::Prefetch:
      // Warming the cache only; buffering megabytes we are about to discard
      // would be pure waste.
      return len;
  }
  return len;
}

void RequestTask::emitChunk(const uint8_t* data, size_t len) {
  Blob payload = copyPayload(data, len);

  RawChunk chunk{};
  chunk.bytes = payload.data;
  chunk.bytesLength = static_cast<int64_t>(len);
  chunk.requestId = id();
  chunk.kind = RAWCHUNKKIND_DATA;
  chunk.aux = 0;

  // The arena owns `payload` until Dart acknowledges having copied it; the
  // generated release symbol frees only the per-emit struct shell.
  arena_.track(emittedSeq_, payload);
  ++emittedSeq_;

  if (streamSink().chunk) streamSink().chunk(chunk);
}

double RequestTask::coalesceHoldRemainingMs(double now) const {
  // Nothing held, or nothing allowed to cross: either way there is no deadline
  // for the loop to wake up for.
  if (coalesceBuf_.empty() || credits_ <= 0) return -1.0;
  const double left = coalesceMaxHoldMs_ - (now - coalesceStartedMs_);
  return left > 0.0 ? left : 0.0;
}

void RequestTask::flushAgedCoalesce(double now) {
  if (coalesceHoldRemainingMs(now) == 0.0) flushCoalesced();
}

void RequestTask::flushCoalesced() {
  if (coalesceBuf_.empty()) return;
  emitChunk(coalesceBuf_.data(), coalesceBuf_.size());
  --credits_;
  // `clear` keeps the capacity, so a 32 MiB body allocates this buffer once.
  coalesceBuf_.clear();
}

void RequestTask::emitTerminalChunk(const EngineError& err) {
  // The body's tail is still held back when the transfer ends on a threshold
  // that never filled, which is the common case — 32 MiB is not a whole number
  // of 64 KiB chunks once headers and framing are accounted for.
  flushCoalesced();

  const size_t len = err.ok() ? 0 : err.message.size();
  Blob payload = copyPayload(err.message.data(), len);

  RawChunk chunk{};
  chunk.bytes = payload.data;
  chunk.bytesLength = static_cast<int64_t>(len);
  chunk.requestId = id();
  chunk.kind = err.ok() ? RAWCHUNKKIND_DONE : RAWCHUNKKIND_ERROR;
  chunk.aux = err.ok() ? 0 : static_cast<int64_t>(err.kind);

  arena_.track(emittedSeq_, payload);
  ++emittedSeq_;

  if (streamSink().chunk) streamSink().chunk(chunk);
}

void RequestTask::emitProgress(RawEventKind kind, int64_t now, int64_t total) {
  RawEvent event{};
  event.requestId = id();
  event.kind = kind;
  event.a = now;
  event.b = total;

  Blob blob = wire::encodeEvent(event);
  if (streamSink().event) {
    streamSink().event(blob.toBuffer());  // ownership transfers to the sink
  } else {
    blob.release();
  }
}

// ── Request body ─────────────────────────────────────────────────────────────

size_t RequestTask::handleRead(char* dst, size_t capacity) {
  if (cancelRequested()) return CURL_READFUNC_ABORT;
  if (capacity == 0) return 0;
  // Bytes still going OUT count as activity too. A server that answers before
  // it has read the whole request body (a 100-continue, or an early 413) arms
  // the idle clock while the upload is still running, and a long body must not
  // then be aborted for the peer's silence.
  lastActivityMs_ = monotonicMs();

  switch (pending_.req.bodyKind) {
    case RawBodyKind::RAWBODYKIND_FILE_PATH:
      if (uploadFile_ == nullptr) return CURL_READFUNC_ABORT;
      return fread(dst, 1, capacity, uploadFile_);

    case RawBodyKind::RAWBODYKIND_BYTES: {
      const size_t remaining = pending_.body.size() - readOffset_;
      const size_t n = remaining < capacity ? remaining : capacity;
      if (n > 0) {
        std::memcpy(dst, pending_.body.data() + readOffset_, n);
        readOffset_ += n;
      }
      return n;
    }

    case RawBodyKind::RAWBODYKIND_STREAMED: {
      if (!pipe_) return 0;
      const size_t n = pipe_->pull(reinterpret_cast<uint8_t*>(dst), capacity);
      if (pipe_->consumeDrainSignal()) {
        emitProgress(RawEventKind::RAWEVENTKIND_UPLOAD_DRAIN,
                     static_cast<int64_t>(pipe_->buffered()),
                     static_cast<int64_t>(pipe_->softCapacity()));
      }
      if (n == 0) {
        if (pipe_->failed()) return CURL_READFUNC_ABORT;
        if (!pipe_->atEof()) {
          // Nothing buffered and the stream is still open: go quiet rather than
          // spin. `CurlEngine` unpauses when Dart feeds more.
          readPaused_ = true;
          return CURL_READFUNC_PAUSE;
        }
      }
      return n;
    }

    case RawBodyKind::RAWBODYKIND_NONE:
      break;
  }
  return 0;
}

int64_t RequestTask::feedUpload(const uint8_t* data, size_t n) {
  if (!pipe_) return 0;
  return static_cast<int64_t>(pipe_->push(data, n));
}

void RequestTask::finishUpload() {
  if (pipe_) pipe_->finish();
}

void RequestTask::failUpload(const std::string& message) {
  if (pipe_) pipe_->fail(message);
}

// ── Flow control ─────────────────────────────────────────────────────────────

bool RequestTask::grantCredit(int64_t chunkCount, int64_t ackedChunks) {
  // Enforced in every build, not just debug: a grant applied off the loop thread
  // would race the write callback's own reads of `credits_` and `writePaused_`,
  // and the caller would then unpause a handle it does not own. Failing closed
  // costs one atomic load and only stalls a stream the engine mis-routed.
  if (!engine_.loopGuard().onOwningThread()) return false;
  if (chunkCount > 0) credits_ += chunkCount;
  arena_.ack(ackedChunks);
  return writePaused_ && credits_ > 0;
}

void RequestTask::requestCancel() {
  cancelled_.store(true, std::memory_order_release);
}

double RequestTask::idleBudgetRemainingMs(double now) const {
  if (idleTimeoutMs_ <= 0 || completed_ || !attached_) return -1.0;
  // Unarmed until the first byte lands, and suspended while flow control holds
  // one direction shut: neither is the peer going quiet.
  if (lastActivityMs_ <= 0.0 || writePaused_ || readPaused_) return -1.0;
  const double deadline =
      lastActivityMs_ + static_cast<double>(idleTimeoutMs_);
  const double left = deadline - now;
  return left > 0.0 ? left : 0.0;
}

void RequestTask::completeWithIdleTimeout() {
  // `CURLE_OPERATION_TIMEDOUT` rather than 0: the engine code a caller reads is
  // the CURLcode curl would have reported had it been able to see the stall.
  completeWithError(EngineError::make(
      RawErrorKind::RAWERRORKIND_TIMEOUT_IDLE,
      "no data received for " + std::to_string(idleTimeoutMs_) + " ms",
      CURLE_OPERATION_TIMEDOUT));
}

// ── Transfer info ────────────────────────────────────────────────────────────

void RequestTask::collectTransferInfo() {
  if (easy_ == nullptr) return;

  // Every `CURLINFO_*` string is owned by the handle and dies with it, so each
  // one is copied into a member here rather than read after cleanup.
  char* text = nullptr;
  if (curl_easy_getinfo(easy_, CURLINFO_EFFECTIVE_URL, &text) == CURLE_OK &&
      text != nullptr) {
    finalUrl_.assign(text);
  }
  text = nullptr;
  if (curl_easy_getinfo(easy_, CURLINFO_PRIMARY_IP, &text) == CURLE_OK &&
      text != nullptr) {
    primaryIp_.assign(text);
  }

  long value = 0;
  if (curl_easy_getinfo(easy_, CURLINFO_PRIMARY_PORT, &value) == CURLE_OK) {
    primaryPort_ = value;
  }
  value = 0;
  if (curl_easy_getinfo(easy_, CURLINFO_REDIRECT_COUNT, &value) == CURLE_OK) {
    redirectCount_ = value;
  }
  value = 0;
  if (curl_easy_getinfo(easy_, CURLINFO_RESPONSE_CODE, &value) == CURLE_OK &&
      value > 0) {
    statusCode_ = value;
  }
  value = 0;
  if (curl_easy_getinfo(easy_, CURLINFO_HTTP_VERSION, &value) == CURLE_OK) {
    version_ = mapCurlHttpVersion(value);
  }

  curl_off_t length = 0;
  if (curl_easy_getinfo(easy_, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &length) ==
      CURLE_OK) {
    contentLength_ = length >= 0 ? static_cast<int64_t>(length) : -1;
  }
}

void RequestTask::collectTimings(RawTimings* out) {
  *out = wire::zeroTimings();
  // Queue time is ours: how long the request sat between the Dart call and the
  // loop thread picking it up. curl cannot know it.
  out->queueMs = startedAtMs_ > 0 ? startedAtMs_ - pending_.submittedAtMs : 0.0;

  if (easy_ == nullptr || !pending_.req.options.wantTimings) return;

  const auto millis = [this](CURLINFO info) -> double {
    curl_off_t micros = 0;
    if (curl_easy_getinfo(easy_, info, &micros) != CURLE_OK) return 0.0;
    return static_cast<double>(micros) / 1000.0;
  };
  out->dnsMs = millis(CURLINFO_NAMELOOKUP_TIME_T);
  out->connectMs = millis(CURLINFO_CONNECT_TIME_T);
  out->tlsMs = millis(CURLINFO_APPCONNECT_TIME_T);
  out->firstByteMs = millis(CURLINFO_STARTTRANSFER_TIME_T);
  out->redirectMs = millis(CURLINFO_REDIRECT_TIME_T);
  out->totalMs = millis(CURLINFO_TOTAL_TIME_T);
}

// ── Completion ───────────────────────────────────────────────────────────────

void RequestTask::finish(int curlCode) {
  NITRO_HTTP_ASSERT_THREAD(engine_.loopGuard());
  if (completed_) return;

  collectTransferInfo();
  collectTimings(&timings_);

  if (cancelRequested()) {
    completeWithError(EngineError::make(RawErrorKind::RAWERRORKIND_CANCELLED,
                                        cancelledMessage(cancelReason()),
                                        curlCode));
    return;
  }

  // An aborted read function reports itself as a generic callback abort; the
  // upload's own failure message is far more useful than that.
  if (pipe_ && pipe_->failed()) {
    completeWithError(EngineError::make(RawErrorKind::RAWERRORKIND_SEND_FAILURE,
                                        pipe_->failureMessage(), curlCode));
    return;
  }

  if (curlCode != CURLE_OK) {
    bool proxyInUse = false;
#if NITRO_HTTP_HAS_PROXY_ERROR
    long proxyCode = 0;
    if (curl_easy_getinfo(easy_, CURLINFO_PROXY_ERROR, &proxyCode) == CURLE_OK) {
      proxyInUse = proxyCode != static_cast<long>(CURLPX_OK);
    }
#endif
    RawErrorKind kind = mapCurlError(curlCode, proxyInUse);
    if (curlCode == CURLE_OPERATION_TIMEDOUT) {
      // `mapCurlError` cannot see which deadline fired; only the handle can.
      kind = classifyTimeout(easy_, pending_.req.options.requestTimeoutMs,
                             pending_.req.options.connectTimeoutMs);
    }
    const char* text = curl_easy_strerror(static_cast<CURLcode>(curlCode));
    completeWithError(
        EngineError::make(kind, describeCurlError(curlCode, text), curlCode));
    return;
  }

  if (revalidating_ && statusCode_ == 304 && cache_ && !cacheKey_.empty()) {
    cache_->refreshMetadata(cacheKey_, headers_);
    if (cacheWriter_) {
      cacheWriter_->discard();
      cacheWriter_.reset();
    }
    // `normal` rather than the caller's original mode: the conditional request
    // already happened, so the re-read must not trigger another one.
    pending_.req.options.cacheMode = RawCacheMode::RAWCACHEMODE_NORMAL;
    if (tryServeFromCache(cache_, /*afterRevalidation=*/true)) return;
    // Only reachable when the entry genuinely vanished between the conditional
    // request and now — eviction, or a concurrent clear(). Falling through hands
    // the caller the bare 304, which is at least truthful.
  }

  emitHeadIfNeeded();

  if (decoder_) {
    decodeBuf_.clear();
    if (!decoder_->finish(&decodeBuf_)) {
      failContentDecoding();
      return;
    }
    // Empty in practice — every stage drains its own output inside `write`, so
    // `finish` mostly just proves the stream ended on a member boundary. Handled
    // anyway, because losing a tail byte would be silent corruption.
    if (!decodeBuf_.empty()) {
      if (cacheWriter_ && !cacheWriter_->write(decodeBuf_.data(),
                                               decodeBuf_.size())) {
        cacheWriter_.reset();
      }
      if (pending_.mode == RespMode::Streamed) {
        emitChunk(decodeBuf_.data(), decodeBuf_.size());
      } else if (pending_.mode == RespMode::Buffered) {
        bodyBuf_.insert(bodyBuf_.end(), decodeBuf_.begin(), decodeBuf_.end());
      }
    }
  }

  if (cacheWriter_) {
    cacheWriter_->commit();
    cacheWriter_.reset();
  }

  if (pending_.req.options.reportProgress) {
    // The throttle can swallow the last tick, and a progress bar that stops at
    // 98 % looks like a bug. Synthesise the terminal events.
    //
    // The upload side needs this even more than the download side: a body that
    // fits in the socket buffer is handed to the kernel inside a single curl
    // turn, so `XFERINFOFUNCTION` never observes a non-zero `ulNow` at all and
    // a caller with an `onSendProgress` would otherwise see NOTHING.
    curl_off_t sent = 0;
    curl_easy_getinfo(easy_, CURLINFO_SIZE_UPLOAD_T, &sent);
    if (sent > 0) {
      emitProgress(RawEventKind::RAWEVENTKIND_UPLOAD_PROGRESS,
                   static_cast<int64_t>(sent), static_cast<int64_t>(sent));
    }

    curl_off_t received = 0;
    curl_easy_getinfo(easy_, CURLINFO_SIZE_DOWNLOAD_T, &received);
    emitProgress(RawEventKind::RAWEVENTKIND_DOWNLOAD_PROGRESS,
                 static_cast<int64_t>(received),
                 static_cast<int64_t>(received));
  }

  completed_ = true;

  if (pending_.mode == RespMode::Streamed) {
    emitTerminalChunk(EngineError::none());
    return;
  }

  RawResponse response{};
  response.requestId = id();
  response.errorKind = RawErrorKind::RAWERRORKIND_NONE;
  response.engineErrorCode = 0;
  response.statusCode = statusCode_;
  response.reasonPhrase = std::move(reasonPhrase_);
  response.version = version_;
  response.finalUrl = finalUrl_.empty() ? pending_.req.url : std::move(finalUrl_);
  response.redirectCount = redirectCount_;
  // Moved, not copied: `completed_` is already set above, so nothing reads these
  // again — the task is retired as soon as this returns. A copy here duplicates
  // every header name and value only to destroy the originals immediately.
  //
  // Below the measurement floor of this project's harness, so it is not claimed
  // as a speed-up; it is removing work that has no reason to exist.
  response.headers = std::move(headers_);
  // Prefetch never accumulates a body, so this move is empty by construction.
  response.body = std::move(bodyBuf_);
  response.fromCache = servedFromCache_;
  response.revalidated = false;
  response.primaryIp = primaryIp_;
  response.primaryPort = primaryPort_;
  response.timings = timings_;
  deliverBuffered(wire::encodeResponse(response));
}

void RequestTask::deliverBuffered(Blob blob) {
  if (!pending_.coalesced()) {
    postRecord(pending_.dartPort, blob);
    return;
  }
  // The address IS the value on this path — the same pointer `postRecord` would
  // have posted as an int64, just carried in a batch. Ownership moves to Dart,
  // so nothing here frees it; `postCoalescedBatch` frees the whole batch if the
  // port turns out to be dead.
  const auto address =
      static_cast<int64_t>(reinterpret_cast<intptr_t>(blob.data));
  engine_.enqueueCompletion(pending_.coalescePort, pending_.coalesceCallId,
                            address);
}

void RequestTask::completeWithError(const EngineError& err) {
  if (completed_) return;
  completed_ = true;

  if (cacheWriter_) {
    // A partial body must never become a cache entry.
    cacheWriter_->discard();
    cacheWriter_.reset();
  }

  if (pending_.mode == RespMode::Streamed) {
    if (!headSent_) {
      headSent_ = true;
      postRecord(pending_.dartPort,
                 wire::encodeResponseHead(wire::errorResponseHead(id(), err)));
    }
    // The head may already have resolved the caller's Future with a 200, so the
    // failure has to travel down the chunk stream instead.
    emitTerminalChunk(err);
  } else {
    RawResponse response = wire::errorResponse(id(), err);
    // The hop count is real information the caller acts on — "too many
    // redirects" is only actionable if you know how many. It is zero in the
    // envelope by construction, so fill it in from what the task counted.
    response.redirectCount = redirectCount_;
    deliverBuffered(wire::encodeResponse(response));
  }
}

}  // namespace nitrohttp
