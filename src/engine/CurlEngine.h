// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — one client, one event loop.
//
// A `CurlEngine` is what a `NitroHttpClient` maps to: an owned `curl_multi`, an
// owned thread driving it, a `curl_share` carrying cookies / DNS / TLS session
// tickets, and an inbox.
//
// THE RULE THAT MATTERS. Once `curl_multi_add_handle` has been called, ONLY the
// loop thread may touch that handle. `curl_easy_pause` from another thread is
// undefined behaviour that shows up as rare, unreproducible crashes. Every
// cross-thread request — submit, cancel, credit grant, unpause, cookie op,
// shutdown — is pushed onto a mutex-guarded deque and woken with
// `curl_multi_wakeup`, then executed on the loop thread. A lock-free queue
// would be pointless at HTTP submission rates and would complicate shutdown.
//
// The public methods below are the ones Dart calls directly, so they are all
// sub-microsecond: validate, copy, enqueue, wake, return.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <curl/curl.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "ClientConfig.h"
#include "Common.h"
#include "CookieBridge.h"
#include "HttpCache.h"
#include "RequestTask.h"

namespace nitrohttp {

class CurlEngine {
 public:
  explicit CurlEngine(int64_t clientId);
  ~CurlEngine();

  CurlEngine(const CurlEngine&) = delete;
  CurlEngine& operator=(const CurlEngine&) = delete;

  int64_t clientId() const { return clientId_; }

  // ── Dart-thread API ────────────────────────────────────────────────────────

  /// Replaces this client's configuration. Applies to transfers submitted
  /// afterwards; in-flight transfers keep the options they were built with.
  void configure(const RawClientConfig& cfg);

  /// Accepts a request whose bytes are already copied out of Nitro's arena.
  /// Always results in exactly one post to `pending.dartPort`.
  void submit(PendingRequest pending);

  void cancel(int64_t requestId);
  void cancelAll();

  /// Completes every transfer on this client bound to `tokenId`.
  ///
  /// The caller is expected to have raised the token's flag already, so a
  /// transfer running curl callbacks has usually aborted itself before this op
  /// is drained. This exists for the transfers that are NOT running callbacks —
  /// paused on a credit window, waiting on a connect, queued behind an inbox
  /// backlog — which would otherwise sit until their own timeout.
  void cancelToken(int64_t tokenId);

  void grantCredit(int64_t requestId, int64_t chunkCount, int64_t ackedChunks);

  /// Returns bytes buffered in the upload ring, or 0 when the request is gone.
  int64_t feedUpload(int64_t requestId, const uint8_t* data, size_t n);
  void finishUpload(int64_t requestId);
  void failUpload(int64_t requestId, const std::string& message);

  /// Cookie operations. Each blocks briefly on the loop thread executing the op,
  /// because the parked handle may only be touched there. Sub-millisecond for a
  /// jar of any realistic size.
  std::vector<RawCookie> cookies();
  void setCookie(const RawCookie& cookie);
  void clearCookies();
  void flushCookies();

  void setCache(std::shared_ptr<HttpCache> cache);

  /// Aborts every in-flight transfer with `engineError`, joins the loop thread
  /// and flushes the cookie jar. Idempotent; safe to call from any thread and
  /// from the destructor.
  void shutdown();

  // ── Loop-thread internals, used by RequestTask ─────────────────────────────
  const ClientConfig& config() const { return config_; }
  const std::shared_ptr<HttpCache>& cache() const { return cache_; }

  /// The `curl_share` carrying `CURL_LOCK_DATA_COOKIE`, `_DNS` and
  /// `_SSL_SESSION`. EVERY transfer handle must be bound to it, not just the
  /// parked cookie handle: without it each transfer gets a private cookie jar
  /// that dies with the handle, and DNS results and TLS session tickets are
  /// never reused across requests on this client.
  CURLSH* share() const { return share_; }

  /// Unpauses a transfer's read or write side. Loop thread only.
  void unpauseTransfer(RequestTask* task, bool write, bool read);

  /// Removes a completed task's handle and destroys it. Loop thread only.
  void retire(RequestTask* task);

  /// Buffers one coalesced completion. `blobAddress` is the encoded record's
  /// malloc'd pointer widened to int64; ownership passes to Dart, which decodes
  /// it and calls `nitro_http_nitro_free`. Nothing here frees it.
  ///
  /// Nothing is posted until `flushCompletionBatch()`, which the loop runs once
  /// its completion drain finishes — that is what turns N wakes into one.
  ///
  /// Unrelated to `RequestTask::flushCoalesced`, which batches body CHUNKS on a
  /// streamed transfer. This batches whole COMPLETIONS across transfers.
  ///
  /// LOOP THREAD ONLY.
  void enqueueCompletion(int64_t port, int64_t callId, int64_t blobAddress);

  const ThreadGuard& loopGuard() const { return loopGuard_; }

 private:
  enum class OpKind {
    Submit,
    Cancel,
    CancelAll,
    CancelToken,
    GrantCredit,
    UploadFinished,
    UploadFailed,
    UploadFed,
    CookieRead,
    CookieWrite,
    CookieClear,
    CookieFlush,
    SetCache,
    Shutdown,
  };

  struct Op {
    OpKind kind;
    int64_t requestId = 0;
    int64_t a = 0;
    int64_t b = 0;
    std::string text;
    std::unique_ptr<PendingRequest> pending;
    RawCookie cookie{};
    std::shared_ptr<HttpCache> cache;

    // Reply channel for the synchronous cookie reads.
    std::shared_ptr<std::promise<std::vector<RawCookie>>> cookieReply;
    std::shared_ptr<std::promise<void>> ack;
  };

  void loop();
  /// Loop thread. Shortens the poll when a transfer's idle deadline is nearer
  /// than the default tick.
  int nextPollTimeoutMs();
  /// Loop thread. Completes and retires every transfer whose peer went quiet
  /// for longer than the client's `idleTimeout`.
  void enforceIdleDeadlines();

  /// Emits stream chunks whose `maxHold` has elapsed while the link was quiet.
  void flushAgedCoalesceBuffers();
  /// Executes every queued op. Returns whether any op was executed, which is
  /// what tells the loop it did real work and may keep spinning.
  bool drainInbox();
  void push(Op op);
  void pushAndWait(Op op);
  void startTask(std::unique_ptr<PendingRequest> pending);
  void completeAllWith(const EngineError& err);
  RequestTask* find(int64_t requestId);

 public:
  /// Hands out an easy handle for one transfer, recycled when one is spare.
  ///
  /// `curl_easy_init` allocates and zeroes a `Curl_easy`, which is tens of
  /// kilobytes of substructures, and `curl_easy_cleanup` tears it all down again
  /// — per request. Measured on a 1 KiB loopback GET, the engine spent ~42 us
  /// outside the transfer itself while the Dart side accounted for only ~2.4 us
  /// and record marshalling 0.9 us; this pair was the bulk of the remainder, and
  /// it is paid 64 times over in a burst.
  ///
  /// Returns nullptr when curl cannot allocate, which the caller reports as an
  /// engine error.
  ///
  /// LOOP THREAD ONLY.
  CURL* acquireEasy();

  /// Takes a detached handle back, resetting it for the next transfer.
  ///
  /// `curl_easy_reset` returns every option to its default but deliberately
  /// keeps the live connections, the DNS and TLS-session caches, the cookies, the
  /// share and the alt-svc cache — which is exactly the state worth keeping and
  /// why pooling does not change behaviour. It also clears `CURLOPT_PRIVATE`, so
  /// a pooled handle cannot carry a dangling `RequestTask*`.
  ///
  /// PRECONDITION: `easy` has been removed from the multi. Resetting an attached
  /// handle is undefined.
  ///
  /// LOOP THREAD ONLY.
  void recycleEasy(CURL* easy);

#ifdef NITRO_HTTP_TESTING
  /// Spare handles currently held. Test-only: the pool is an optimisation, so
  /// nothing in the engine's behaviour may depend on this, but a test has to be
  /// able to prove handles are actually being reused rather than reallocated.
  ///
  /// Racy by construction if called while the loop thread is working; call it
  /// between requests.
  size_t pooledEasyHandlesForTesting() const { return easyPool_.size(); }
#endif

 private:
  /// Frees every pooled handle. Must run after the loop thread has joined and
  /// before the share is cleaned up, because a pooled handle still references it.
  void drainEasyPool();

  int64_t clientId_;
  CURLM* multi_ = nullptr;
  CURLSH* share_ = nullptr;
  ClientConfig config_;
  std::unique_ptr<CookieBridge> cookies_;
  std::shared_ptr<HttpCache> cache_;

  std::thread thread_;
  ThreadGuard loopGuard_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> shutdownDone_{false};

  std::mutex inboxMtx_;
  std::deque<Op> inbox_;

  /// Owned by the loop thread after startup.
  std::unordered_map<int64_t, std::unique_ptr<RequestTask>> tasks_;

  /// Posts every buffered coalesced completion as ONE `kArray` of int64 pairs,
  /// `[callId0, addr0, callId1, addr1, …]`, matching `NitroCoalescer`'s wire.
  /// No-op when the buffer is empty, so the loop can call it unconditionally.
  ///
  /// LOOP THREAD ONLY.
  void flushCompletionBatch();

  /// Completions waiting for the next flush, as `(callId, blobAddress)`.
  /// Loop-thread owned; never touched from the Dart thread.
  std::vector<std::pair<int64_t, int64_t>> completionBatch_;

  /// The port the buffered batch goes to. All coalesced requests on one client
  /// share a coalescer, so this is uniform in practice; a change flushes the
  /// batch already buffered rather than misdelivering it to the new port.
  int64_t completionBatchPort_ = 0;

  /// Spare easy handles, loop-thread owned. See `acquireEasy`.
  ///
  /// Bounded so a burst cannot leave a permanent high-water mark: a handle is
  /// tens of kilobytes, and an app that once ran 500 requests at a time should
  /// not hold 500 handles for the rest of the process. Beyond the cap a returned
  /// handle is simply freed.
  std::vector<CURL*> easyPool_;

  /// Cancellation requested for an id that has not been submitted yet — a real
  /// race when Dart cancels during the same microtask that started the request.
  std::vector<int64_t> preCancelled_;

  std::mutex startMtx_;
  std::condition_variable startCv_;
  bool started_ = false;
};

}  // namespace nitrohttp
