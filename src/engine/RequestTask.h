// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — one HTTP transfer.
//
// Owns an easy handle from setup through `CURLMSG_DONE`, and is the only place
// that knows the difference between the buffered and streamed response paths.
//
// EXACTLY-ONCE COMPLETION is the invariant that matters most: every task that
// was accepted posts precisely one message to its Dart port. Cancellation posts
// `cancelled`; engine shutdown posts `engineError`; a malformed request posts
// `badRequest`. A task that never posts would hang a Dart `Future` forever, so
// `complete()` is idempotent and asserts it fired.
//
// THREADING  Everything after `attach()` runs on the engine loop thread. The
// only exceptions are `feedUpload` / `finishUpload` / `failUpload`, which touch
// the `BodyPipe`'s own mutex from the Dart thread, and `requestCancel`, which
// only sets an atomic flag — the actual `curl_multi_remove_handle` happens on
// the loop thread via the engine inbox.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <curl/curl.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "BodyPipe.h"
#include "ChunkArena.h"
#include "Common.h"
#include "ContentDecoder.h"
#include "HttpCache.h"

namespace nitrohttp {

class ClientConfig;
class CookieBridge;
class CurlEngine;

/// How the response is delivered to Dart.
enum class RespMode {
  Buffered,  ///< accumulate, post one RawResponse
  Streamed,  ///< post RawResponseHead, then emit RawChunk items
  Prefetch,  ///< populate the cache, post a RawResponse with an empty body
};

/// A request whose every byte has been copied out of Nitro's parameter arena.
/// Constructed synchronously inside `sendBuffered` / `startStreamed` /
/// `prefetch`, because that arena is released the instant the call returns.
struct PendingRequest {
  RawRequest req;               ///< owns its strings and header vector
  std::vector<uint8_t> body;    ///< inline body, already copied
  RespMode mode = RespMode::Buffered;
  int64_t dartPort = 0;
  double submittedAtMs = 0;     ///< for RawTimings::queueMs

  /// Set by `sendBufferedCoalesced`. When `coalescePort` is non-zero the
  /// completion does NOT get its own post: the encoded blob's address is buffered
  /// as `(coalesceCallId, address)` and the whole drained batch goes out as one
  /// `kArray` on `coalescePort`, so a burst shares one isolate wake.
  ///
  /// `dartPort` stays 0 in that case — the two are mutually exclusive, and
  /// posting both would complete the same call twice.
  int64_t coalescePort = 0;
  int64_t coalesceCallId = -1;

  bool coalesced() const { return coalescePort != 0; }
};

class RequestTask {
 public:
  RequestTask(CurlEngine& engine, PendingRequest pending);
  ~RequestTask();

  RequestTask(const RequestTask&) = delete;
  RequestTask& operator=(const RequestTask&) = delete;

  int64_t id() const { return pending_.req.requestId; }
  RespMode mode() const { return pending_.mode; }
  CURL* easy() const { return easy_; }
  int64_t dartPort() const { return pending_.dartPort; }

  /// Hands the easy handle back to the caller, leaving this task without one.
  ///
  /// The engine calls this after `curl_multi_remove_handle` so it can recycle the
  /// handle instead of paying `curl_easy_cleanup` + `curl_easy_init` per request
  /// (see `CurlEngine::recycleEasy`). The destructor still cleans up whatever it
  /// is left holding, so forgetting to call this leaks nothing.
  ///
  /// PRECONDITION: the handle is not attached to a multi.
  [[nodiscard]] CURL* detachEasy() {
    CURL* easy = easy_;
    easy_ = nullptr;
    return easy;
  }

  /// Builds the easy handle and applies client + request options. Returns
  /// non-ok when the request cannot be attempted at all; the caller then
  /// completes with that error instead of adding the handle.
  EngineError prepare(const ClientConfig& config, CookieBridge* cookies,
                      const std::shared_ptr<HttpCache>& cache);

  /// Serves a fresh cache hit without touching the network. Returns true when it
  /// completed the task.
  ///
  /// After a 304 the caller passes `afterRevalidation = true`, which serves the
  /// stored entry whether the freshness check now calls it fresh or stale. RFC
  /// 9111 §4.3.3: a 304 updates the stored response and the request is answered
  /// with THAT. Re-running the freshness test would hand the caller a bare 304
  /// for the common `Cache-Control: max-age=0` + `ETag` pattern, where the
  /// entry's own lifetime is zero by design and the revalidation is the whole
  /// mechanism that establishes freshness.
  bool tryServeFromCache(const std::shared_ptr<HttpCache>& cache,
                         bool afterRevalidation = false);

  /// Called once from the loop thread after `curl_multi_add_handle` succeeded.
  void markAttached();
  bool attached() const { return attached_; }

  /// `CURLMSG_DONE`. Collects `CURLINFO_*`, finalises the cache write, and
  /// completes exactly once. `curlCode` is the raw `CURLcode`.
  void finish(int curlCode);

  /// Completes with an explicit error without consulting curl. Used for
  /// cancellation before attach, shutdown, and preparation failures.
  void completeWithError(const EngineError& err);

  bool completed() const { return completed_; }

  // ── Cancellation ───────────────────────────────────────────────────────────

  /// Any thread. Sets the flag that `XFERINFOFUNCTION` observes, so a transfer
  /// already inside a curl callback aborts with `CURLE_ABORTED_BY_CALLBACK`.
  void requestCancel();
  bool cancelRequested() const { return cancelled_.load(std::memory_order_acquire); }

  // ── Idle deadline ──────────────────────────────────────────────────────────

  /// Loop thread. Milliseconds left before this transfer must be aborted for
  /// going quiet, or a negative value when no deadline is armed.
  ///
  /// curl cannot police this for us: `CURLOPT_LOW_SPEED_*` compares an AVERAGE
  /// rate over a rolling window, so a body that delivers a 16 KiB chunk and
  /// then stalls for five seconds still averages kilobytes per second and is
  /// never aborted. "No byte for N ms" needs its own clock.
  ///
  /// Unarmed before the first response header — the connect budget owns that
  /// window — and while either direction is paused for flow control, because a
  /// consumer that stopped granting credit is not a peer that went quiet.
  double idleBudgetRemainingMs(double now) const;

  /// Loop thread. Completes the task with `timeoutIdle`; the caller retires it.
  void completeWithIdleTimeout();

  // ── Download flow control (streamed mode) ─────────────────────────────────

  /// Loop thread. Adds credit and releases acked payloads. Returns true when
  /// the transfer was paused and should now be unpaused.
  bool grantCredit(int64_t chunkCount, int64_t ackedChunks);
  bool writePaused() const { return writePaused_; }
  void clearWritePause() { writePaused_ = false; }

  // ── Upload flow control (streamed request bodies) ─────────────────────────

  /// Dart thread. Returns bytes currently buffered.
  int64_t feedUpload(const uint8_t* data, size_t n);
  void finishUpload();
  void failUpload(const std::string& message);
  bool readPaused() const { return readPaused_; }
  void clearReadPause() { readPaused_ = false; }
  bool hasUploadPipe() const { return pipe_ != nullptr; }

 private:
  // curl callback trampolines
  static size_t onHeader(char* buf, size_t size, size_t n, void* self);
  static size_t onWrite(char* buf, size_t size, size_t n, void* self);
  static size_t onRead(char* buf, size_t size, size_t n, void* self);
  static int onProgress(void* self, curl_off_t dlTotal, curl_off_t dlNow,
                        curl_off_t ulTotal, curl_off_t ulNow);

  size_t handleHeader(const char* data, size_t len);
  size_t handleWrite(const char* data, size_t len);
  size_t handleRead(char* dst, size_t capacity);

  /// First thing `emitHeadIfNeeded` does, because both the cache write-back and
  /// the published head read `headers_` after it has run.
  void beginContentDecoding();
  /// Completes the task with `decompressionFailure` and the decoder's message.
  void failContentDecoding();

  void emitHeadIfNeeded();
  void emitChunk(const uint8_t* data, size_t len);

  /// Emits whatever `coalesceBuf_` is holding, if anything, and spends a credit.
  ///
  /// Must run before anything that ends or suspends the flow of body bytes —
  /// the terminal chunk, a pause, a failure — or the tail of the body would be
  /// delivered late or not at all.
  void flushCoalesced();
  /// Delivers a finished BUFFERED response. Ordinary requests get their own
  /// post; `sendBufferedCoalesced` requests join the engine's batch instead, so
  /// a burst finishing together costs one isolate wake rather than one each.
  ///
  /// Takes ownership of `blob` on both paths. A zero address is the batch wire's
  /// "could not encode" signal — the coalescer carries plain int64s and has no
  /// null — which the Dart runner turns into a StateError, mirroring what
  /// `postNull` does for the non-coalesced path.
  void deliverBuffered(Blob blob);

  void emitTerminalChunk(const EngineError& err);
  void emitProgress(RawEventKind kind, int64_t now, int64_t total);
  void collectTimings(RawTimings* out);
  void collectTransferInfo();

  CurlEngine& engine_;
  PendingRequest pending_;
  CURL* easy_ = nullptr;
  struct curl_slist* headerList_ = nullptr;
  FILE* uploadFile_ = nullptr;

  bool attached_ = false;
  // Header accumulation. A redirect chain restarts the block, so the vectors
  // are cleared whenever a new status line arrives.
  std::vector<RawHeader> headers_;
  int64_t statusCode_ = 0;
  std::string reasonPhrase_;
  bool headSent_ = false;

  std::vector<uint8_t> bodyBuf_;   // buffered + prefetch modes
  size_t readOffset_ = 0;          // inline-body upload cursor

  // Content decoding. Null means "pass the body through untouched", which is
  // what an absent, `identity` or unrecognised `Content-Encoding` gets.
  std::unique_ptr<ContentDecoder> decoder_;
  bool decodedBody_ = false;
  std::vector<uint8_t> decodeBuf_;  // reused per write, so a streamed body does
                                    // not allocate once per socket read

  // Streamed download bookkeeping.
  ChunkArena arena_;
  int64_t emittedSeq_ = 0;
  int64_t credits_ = 0;
  bool writePaused_ = false;

  /// Bytes held back to be emitted as one larger chunk. See `coalesceTarget_`.
  std::vector<uint8_t> coalesceBuf_;

  /// Chunk size this transfer batches up to, or 0 to emit as bytes arrive.
  ///
  /// Decided once from `Content-Length` and the client's `streamChunkBytes`, in
  /// `emitHeadIfNeeded`, because it needs the final headers and must not change
  /// mid-body. A 32 MiB body arrives as ~2050 calls to the write callback since
  /// curl's buffer is 16 KiB, and each emit costs a chunk struct, a zero-copy
  /// proxy with a finalizer, a credit, and a `controller.add` on the Dart side —
  /// measured at 4.81 us per chunk, 9.9 ms over the transfer, 7.4 % on top of a
  /// download whose buffered equivalent takes 134 ms.
  ///
  /// Zero for anything short, of unknown length, or content-decoded, so a
  /// trickling response — server-sent events, a long poll — never has a byte
  /// held waiting for more that may be seconds away.
  ///
  /// Raising `CURLOPT_BUFFERSIZE` instead was tried and lost (see
  /// `ClientConfig.cpp`): it enlarges curl's socket reads and forces the credit
  /// window down to keep in-flight memory constant. Coalescing here changes
  /// neither — curl still reads 16 KiB at a time, and credits still bound how
  /// much is outstanding.
  size_t coalesceTarget_ = 0;

  /// Longest `coalesceBuf_` may be held before it is emitted part-full.
  double coalesceMaxHoldMs_ = 0.0;

  /// When the current batch took its first byte, for the age check.
  double coalesceStartedMs_ = 0.0;

  // Streamed upload bookkeeping.
  std::unique_ptr<BodyPipe> pipe_;
  bool readPaused_ = false;

  // Progress throttling — one event per 100 ms at most, plus a synthesized
  // terminal event from the completion path so callers always see 100 %.
  double lastProgressMs_ = 0;
  int64_t lastDlNow_ = 0;
  int64_t lastUlNow_ = 0;

  // Idle deadline. `lastActivityMs_` is 0 while the clock is unarmed.
  int64_t idleTimeoutMs_ = 0;
  double lastActivityMs_ = 0;

  // Cache.
  std::string cacheKey_;
  std::unique_ptr<CacheWriter> cacheWriter_;
  std::shared_ptr<HttpCache> cache_;
  bool revalidating_ = false;
  bool servedFromCache_ = false;

  // Completion.
  std::atomic<bool> cancelled_{false};
  bool completed_ = false;
  double startedAtMs_ = 0;

  // Transfer info copied out of curl BEFORE `curl_easy_cleanup`, because
  // `CURLINFO_*` strings are owned by the handle.
  std::string finalUrl_;
  std::string primaryIp_;
  int64_t primaryPort_ = 0;
  int64_t redirectCount_ = 0;
  RawHttpVersion version_ = RawHttpVersion::RAWHTTPVERSION_UNKNOWN;
  int64_t contentLength_ = -1;
  RawTimings timings_{};
};

}  // namespace nitrohttp
