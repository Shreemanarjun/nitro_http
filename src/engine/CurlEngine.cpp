// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — CurlEngine implementation.
//
// TWO RULES GOVERN THIS FILE.
//
//   1. After `curl_multi_add_handle`, only the loop thread touches that handle.
//      Every cross-thread request becomes an inbox op. The single exceptions are
//      `feedUpload` / `finishUpload` / `failUpload`, which touch nothing but the
//      `BodyPipe`'s own mutex and must answer synchronously — they still push an
//      unpause op, because curl may be parked in `CURL_READFUNC_PAUSE`.
//
//   2. Every accepted request posts exactly once. That is why `push` answers
//      inline once shutdown has begun, why the loop drains leftover ops after
//      exiting, and why `completeAllWith` runs before the thread returns.
//
// `inboxMtx_` is the engine's general mutex: it guards the inbox, `tasks_`,
// `config_` and `cookies_`. The Dart thread only ever holds it for a map lookup
// or a ring-buffer append, so contention with the loop thread is negligible.
// ─────────────────────────────────────────────────────────────────────────────

#include "CurlEngine.h"

#include <algorithm>
#include <chrono>
#include <utility>

#include "DartPost.h"
#include "DeferredPayloads.h"

namespace nitrohttp {
namespace {

/// Wake at least this often even with no socket activity, so a stopping engine
/// and curl's own timers make progress without a wakeup.
constexpr int kPollTimeoutMs = 1000;

/// Floor on a shortened poll, so an idle deadline that has just passed cannot
/// spin the loop thread.
constexpr int kMinPollTimeoutMs = 5;

/// Ceiling on spare easy handles kept for reuse. See `CurlEngine::acquireEasy`.
///
/// Sized to cover the concurrency an app actually sustains rather than the peak
/// it once hit: 64 is the burst width the benchmark uses and comfortably more
/// than `maxConnections` defaults to, so a steady workload never allocates a
/// handle after warm-up. At tens of kilobytes each this caps the pool at a couple
/// of megabytes.
constexpr size_t kMaxPooledEasyHandles = 64;

/// How long the loop keeps polling without sleeping after it last did work.
///
/// Blocking in `curl_multi_poll` costs a wakeup on the next submit: the Dart
/// thread writes to curl's wakeup socket, the kernel schedules this thread, and
/// poll returns. Measured on an idle M1 that round trip is ~18 us, which is
/// exactly half of this client's whole per-request deficit against `dart:io`
/// (181 us against 145 us for a 1 KiB loopback GET). None of it is compute — the
/// engine is asleep for all of it.
///
/// So after doing work the loop stays awake briefly and polls with a zero
/// timeout, which turns the next submit's wakeup into a poll that has already
/// returned. The window is deliberately short: it is long enough to cover the
/// gap between two back-to-back requests, and short enough that an app which
/// stops making requests stops burning CPU within a millisecond. An engine with
/// nothing to do sleeps exactly as before.
constexpr auto kSpinWindow = std::chrono::microseconds(750);

/// Ceiling on how long a Dart-thread cookie call waits for the loop thread. The
/// operation itself is sub-millisecond; this only exists so a wedged loop thread
/// degrades into an empty answer instead of freezing the isolate.
constexpr auto kOpReplyTimeout = std::chrono::seconds(2);

/// Cancellations for ids that were never submitted are remembered so a cancel
/// racing its own submit still wins. Bounded, because a caller that cancels ids
/// it never submits would otherwise grow this forever.
constexpr size_t kMaxPreCancelled = 1024;

/// A `curl_share` without lock callbacks is not thread-safe, and the engine's
/// transfers plus its parked cookie handle genuinely run concurrently with other
/// engines. One mutex per lock-data kind is enough: these critical sections are
/// cookie-jar and DNS-cache updates measured in microseconds, so sharing them
/// across engines costs nothing measurable and avoids per-share bookkeeping.
///
/// DELIBERATELY LEAKED. These outlive every other static in the process on
/// purpose. `EngineRegistry`'s own function-local `State` is constructed BEFORE
/// this array (the first `curl_share_setopt` happens inside the first
/// `CurlEngine`, which is built while `State` is being populated), so at exit
/// `State` is destroyed LAST — after a plain `static std::mutex[]` would already
/// have run `pthread_mutex_destroy`. Tearing an engine down from `State`'s
/// destructor then calls `curl_easy_cleanup`, which takes the cookie lock,
/// which makes `std::mutex::lock()` throw `std::system_error` out of
/// `~CookieBridge` — a noexcept destructor — and the process aborts. Immortal
/// storage is the only fix that does not depend on static ordering.
std::mutex& shareMutex(curl_lock_data data) {
  static std::mutex* const mutexes = new std::mutex[CURL_LOCK_DATA_LAST];
  const int index = static_cast<int>(data);
  return mutexes[index > 0 && index < CURL_LOCK_DATA_LAST ? index : 0];
}

void shareLock(CURL*, curl_lock_data data, curl_lock_access, void*) {
  shareMutex(data).lock();
}

void shareUnlock(CURL*, curl_lock_data data, void*) {
  shareMutex(data).unlock();
}

EngineError cancelledError() {
  return EngineError::make(RawErrorKind::RAWERRORKIND_CANCELLED,
                           "request cancelled");
}

EngineError shutdownError() {
  return EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
                           "engine shut down before the request completed");
}

/// Finds the queued `Submit` op for `requestId`, newest first. `Op` is private to
/// `CurlEngine`, so this is a template: deduction happens at the call site, which
/// is inside a member and therefore allowed to name the type.
template <typename OpT>
OpT* findPendingSubmit(std::deque<OpT>& inbox, int64_t requestId) {
  for (auto it = inbox.rbegin(); it != inbox.rend(); ++it) {
    if (it->pending && it->pending->req.requestId == requestId) return &*it;
  }
  return nullptr;
}

/// Value-initialises an op. Aggregate initialisation would leave the trailing
/// members unmentioned, and `Op` is private, so this is a template for the same
/// reason as `findPendingSubmit`.
template <typename OpT, typename KindT>
OpT makeOp(KindT kind, int64_t requestId = 0) {
  OpT op{};
  op.kind = kind;
  op.requestId = requestId;
  return op;
}

}  // namespace

// ── Lifecycle ────────────────────────────────────────────────────────────────

CurlEngine::CurlEngine(int64_t clientId) : clientId_(clientId) {
  ensureCurlGlobalInit();

  multi_ = curl_multi_init();
  share_ = curl_share_init();

  if (share_ != nullptr) {
    curl_share_setopt(share_, CURLSHOPT_LOCKFUNC, shareLock);
    curl_share_setopt(share_, CURLSHOPT_UNLOCKFUNC, shareUnlock);
    curl_share_setopt(share_, CURLSHOPT_USERDATA, this);
    // Cookies, resolved addresses and TLS session tickets are reused across
    // every transfer on this client — the difference between a 3-RTT and a
    // 0-RTT second request.
    curl_share_setopt(share_, CURLSHOPT_SHARE, CURL_LOCK_DATA_COOKIE);
    curl_share_setopt(share_, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
    curl_share_setopt(share_, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
  }

  cookies_.reset(new CookieBridge(share_, std::string()));
  config_.applyToMulti(multi_);

  if (multi_ == nullptr) {
    // Without a multi handle there is nothing to drive. Refusing to start the
    // loop makes `push` answer every op inline, so callers still complete.
    stopping_.store(true, std::memory_order_release);
    return;
  }

  thread_ = std::thread([this] { loop(); });

  // The loop thread must have bound its ThreadGuard before any op can arrive,
  // otherwise the debug thread assertions would latch the wrong owner.
  std::unique_lock<std::mutex> lock(startMtx_);
  startCv_.wait(lock, [this] { return started_; });
}

CurlEngine::~CurlEngine() { shutdown(); }

void CurlEngine::shutdown() {
  bool expected = false;
  if (!shutdownDone_.compare_exchange_strong(expected, true)) return;

  {
    // Appended directly rather than through `push`, which now refuses ops: this
    // must be the last thing the loop thread sees.
    std::lock_guard<std::mutex> lock(inboxMtx_);
    inbox_.push_back(makeOp<Op>(OpKind::Shutdown));
  }
  if (multi_ != nullptr) curl_multi_wakeup(multi_);
  if (thread_.joinable()) thread_.join();

  // Ordered: the parked cookie handle must go before the share it borrows, and
  // the share before nothing at all. `curl_easy_cleanup` inside the bridge is
  // what writes the jar to disk.
  cookies_.reset();
  // Same rule as the cookie handle: a pooled easy handle still references the
  // share, so it has to be freed before `curl_share_cleanup`. Safe to touch
  // without the loop thread's guard because that thread has been joined.
  drainEasyPool();
  if (multi_ != nullptr) {
    curl_multi_cleanup(multi_);
    multi_ = nullptr;
  }
  if (share_ != nullptr) {
    curl_share_cleanup(share_);
    share_ = nullptr;
  }
}

// ── Loop thread ──────────────────────────────────────────────────────────────

void CurlEngine::loop() {
  loopGuard_.bind();
  {
    std::lock_guard<std::mutex> lock(startMtx_);
    started_ = true;
  }
  startCv_.notify_all();

  // Reopened by any real work; see `kSpinWindow`.
  auto spinUntil = std::chrono::steady_clock::time_point{};

  while (!stopping_.load(std::memory_order_acquire)) {
    int numfds = 0;
    // Zero timeout while the spin window is open — see `kSpinWindow`. Outside it
    // this is the same blocking poll as before, so an idle engine still sleeps.
    const bool spinning = std::chrono::steady_clock::now() < spinUntil;
    curl_multi_poll(multi_, nullptr, 0, spinning ? 0 : nextPollTimeoutMs(),
                    &numfds);
    (void)numfds;

    const bool hadOps = drainInbox();

    int running = 0;
    curl_multi_perform(multi_, &running);
    (void)running;

    // The window reopens on real work only: an op arriving, a transfer running,
    // or a socket that was ready. A poll that timed out with nothing to do lets
    // it lapse, which is what stops an idle engine from spinning forever.
    if (hadOps || running > 0 || numfds > 0) {
      spinUntil = std::chrono::steady_clock::now() + kSpinWindow;
    }

    for (;;) {
      int left = 0;
      CURLMsg* msg = curl_multi_info_read(multi_, &left);
      if (msg == nullptr) break;
      if (msg->msg != CURLMSG_DONE) continue;

      // `msg` is invalidated by the next `info_read` and by `remove_handle`, so
      // everything needed is copied out first.
      CURL* easy = msg->easy_handle;
      const CURLcode result = msg->data.result;

      char* priv = nullptr;
      curl_easy_getinfo(easy, CURLINFO_PRIVATE, &priv);
      auto* task = reinterpret_cast<RequestTask*>(priv);
      if (task == nullptr) {
        curl_multi_remove_handle(multi_, easy);
        continue;
      }
      task->finish(static_cast<int>(result));
      retire(task);
    }

    // Every completion this turn produced is now buffered, so one post carries
    // the whole burst. Draining first and posting once is the entire mechanism:
    // flushing inside the loop above would be one wake per completion again.
    flushCompletionBatch();

    enforceIdleDeadlines();
  }

  completeAllWith(shutdownError());
  // Shutdown completions are coalesced too — otherwise aborting a 64-request
  // burst would post 64 times on the way down.
  flushCompletionBatch();

  // Ops queued behind the shutdown op still own promises and pending requests.
  // Dropping them would hang a Dart Future or a cookie call forever.
  std::deque<Op> leftover;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    leftover.swap(inbox_);
  }
  for (Op& op : leftover) {
    if (op.pending) {
      RequestTask orphan(*this, std::move(*op.pending));
      orphan.completeWithError(shutdownError());
    }
    if (op.cookieReply) op.cookieReply->set_value({});
    if (op.ack) op.ack->set_value();
  }

  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    if (cookies_) cookies_->flush();
  }
}

void CurlEngine::enqueueCompletion(int64_t port, int64_t callId,
                                  int64_t blobAddress) {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);

  // A port change would misdeliver everything already buffered, so flush first.
  // In practice one client's coalesced requests all share one coalescer and this
  // never fires; it exists so that "never fires" is a property, not a hope.
  if (completionBatchPort_ != 0 && completionBatchPort_ != port) flushCompletionBatch();
  completionBatchPort_ = port;
  completionBatch_.emplace_back(callId, blobAddress);
}

void CurlEngine::flushCompletionBatch() {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);
  if (completionBatch_.empty()) return;

  // Ownership of every blob leaves here: `postCoalescedBatch` either transfers
  // the batch to Dart or frees it. Clearing before the call would strand the
  // addresses, and clearing after a throw is not a concern because it does not
  // throw — but the buffer is still swapped out first so that a re-entrant call
  // could never see a half-posted batch.
  std::vector<std::pair<int64_t, int64_t>> batch;
  batch.swap(completionBatch_);
  postCoalescedBatch(completionBatchPort_, batch);
}

/// How long the next `curl_multi_poll` may sleep.
///
/// Normally `kPollTimeoutMs`, but an armed idle deadline shortens it: nothing
/// else will wake this thread when a peer simply stops sending, and a deadline
/// that is only checked once a second is not a 400 ms deadline.
int CurlEngine::nextPollTimeoutMs() {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);

  const double now = monotonicMs();
  double soonest = static_cast<double>(kPollTimeoutMs);
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);

    // Never block while work is already queued.
    //
    // `push` appends under this mutex and only then calls `curl_multi_wakeup`,
    // so an op is always visible here before its wakeup is even attempted. That
    // ordering is what makes this check sufficient, and it is why the loop no
    // longer depends on the wakeup arriving at all: `curl_multi_wakeup` writes a
    // byte to an internal socketpair and reports failure if that write does not
    // land (a full pipe, or EINTR), and neither call site can do anything useful
    // with the error. A dropped byte used to mean the op sat here for the whole
    // of `kPollTimeoutMs` — one second — while the loop slept on a poll nothing
    // would wake. That is the shape of the 1003 ms outlier seen once in 500
    // requests on a physical Android device, against a p99 of 3.59 ms.
    //
    // Costs nothing: this lock is already taken for the deadline scan below, and
    // the check can only ever shorten a poll that would otherwise have blocked
    // with work pending.
    if (!inbox_.empty()) return 0;

    for (const auto& entry : tasks_) {
      const double left = entry.second->idleBudgetRemainingMs(now);
      if (left >= 0.0 && left < soonest) soonest = left;
    }
  }
  // Floored rather than allowed to reach zero: a zero timeout turns the loop
  // into a spin for as long as the deadline is in the past, and the very next
  // `enforceIdleDeadlines` is what clears it anyway.
  if (soonest < kMinPollTimeoutMs) return kMinPollTimeoutMs;
  return static_cast<int>(soonest) + 1;
}

void CurlEngine::enforceIdleDeadlines() {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);

  const double now = monotonicMs();

  std::vector<int64_t> expired;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    for (const auto& entry : tasks_) {
      if (entry.second->idleBudgetRemainingMs(now) == 0.0) {
        expired.push_back(entry.first);
      }
    }
  }
  // Completed outside the lock, exactly as the cancel path does: `retire`
  // takes `inboxMtx_` itself, and `completeWithError` posts to a Dart port.
  for (const int64_t id : expired) {
    RequestTask* task = find(id);
    if (task == nullptr) continue;
    // The flag stops the transfer's own callbacks from doing more work while
    // `curl_multi_remove_handle` unwinds it.
    task->requestCancel();
    task->completeWithIdleTimeout();
    retire(task);
  }
}

bool CurlEngine::drainInbox() {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);

  bool didWork = false;
  for (;;) {
    Op op{};
    bool have = false;
    bool submitted = false;
    int64_t submitId = 0;
    bool uploadFinished = false;
    bool uploadFailed = false;

    {
      std::unique_lock<std::mutex> lock(inboxMtx_);
      if (!inbox_.empty()) {
        op = std::move(inbox_.front());
        inbox_.pop_front();
        have = true;

        if (op.kind == OpKind::Submit && op.pending) {
          submitId = op.pending->req.requestId;
          uploadFinished = op.a != 0;
          uploadFailed = op.b != 0;
          submitted = true;
          // THE LOCK IS DELIBERATELY STILL HELD. `feedUpload` looks for a queued
          // submit and then for a live task; if the op left the inbox before its
          // task was registered, an upload chunk landing in between would find
          // neither and be dropped silently. One critical section covering both
          // makes that state unobservable.
          try {
            startTask(std::move(op.pending));
          } catch (...) {
            // A throwing submit must not strand the loop thread with the lock.
          }
        }
      }
    }
    if (!have) break;
    didWork = true;

    try {
      if (submitted) {
        if (uploadFinished || uploadFailed) {
          // Upload lifecycle signals that arrived while the submit was still
          // queued: `prepare` seeded the pipe with the early bytes, and these
          // close it out.
          if (RequestTask* task = find(submitId)) {
            if (uploadFailed) {
              task->failUpload(op.text);
            } else {
              task->finishUpload();
            }
            unpauseTransfer(task, false, true);
          }
        }
        if (op.cookieReply) op.cookieReply->set_value({});
        if (op.ack) op.ack->set_value();
        continue;
      }

      switch (op.kind) {
        case OpKind::Submit:
          break;  // a submit with no payload: nothing to start

        case OpKind::Cancel: {
          RequestTask* task = find(op.requestId);
          if (task == nullptr) {
            // The cancel overtook its own submit — a real race when Dart cancels
            // in the same microtask that started the request.
            if (preCancelled_.size() >= kMaxPreCancelled) {
              preCancelled_.erase(preCancelled_.begin());
            }
            preCancelled_.push_back(op.requestId);
            break;
          }
          task->requestCancel();
          task->completeWithError(cancelledError());
          retire(task);
          break;
        }

        case OpKind::CancelAll: {
          std::vector<int64_t> ids;
          {
            std::lock_guard<std::mutex> lock(inboxMtx_);
            ids.reserve(tasks_.size());
            for (const auto& entry : tasks_) ids.push_back(entry.first);
          }
          for (const int64_t id : ids) {
            RequestTask* task = find(id);
            if (task == nullptr) continue;
            task->requestCancel();
            task->completeWithError(cancelledError());
            retire(task);
          }
          break;
        }

        case OpKind::GrantCredit: {
          RequestTask* task = find(op.requestId);
          if (task == nullptr) {
            // The transfer is retired but Dart may still hold typed-data views
            // into its payloads, which the deferred registry now owns. A grant
            // for an unknown id is routine, not an error.
            if (op.a == 0) {
              DeferredPayloads::instance().releaseAll(PayloadOwner::Request,
                                                      op.requestId);
            } else {
              DeferredPayloads::instance().ack(PayloadOwner::Request,
                                               op.requestId, op.b);
            }
            break;
          }
          if (task->grantCredit(op.a, op.b)) unpauseTransfer(task, true, false);
          break;
        }

        case OpKind::UploadFed:
        case OpKind::UploadFinished:
        case OpKind::UploadFailed: {
          // The pipe was already updated on the Dart thread; all that is left is
          // resuming a transfer parked in CURL_READFUNC_PAUSE.
          if (RequestTask* task = find(op.requestId)) {
            unpauseTransfer(task, false, true);
          }
          break;
        }

        case OpKind::CookieRead: {
          std::vector<RawCookie> jar;
          {
            std::lock_guard<std::mutex> lock(inboxMtx_);
            if (cookies_) jar = cookies_->all();
          }
          // Moved out so the fallback below cannot answer a second time.
          auto reply = std::move(op.cookieReply);
          if (reply) reply->set_value(std::move(jar));
          break;
        }

        case OpKind::CookieWrite: {
          std::lock_guard<std::mutex> lock(inboxMtx_);
          if (cookies_) cookies_->set(op.cookie);
          break;
        }

        case OpKind::CookieClear: {
          std::lock_guard<std::mutex> lock(inboxMtx_);
          if (cookies_) cookies_->clearAll();
          break;
        }

        case OpKind::CookieFlush: {
          std::lock_guard<std::mutex> lock(inboxMtx_);
          if (cookies_) cookies_->flush();
          break;
        }

        case OpKind::SetCache:
          // Loop-thread owned from here on, so `startTask` needs no lock for it.
          cache_ = std::move(op.cache);
          break;

        case OpKind::Shutdown:
          stopping_.store(true, std::memory_order_release);
          break;
      }
    } catch (...) {
      // One malformed op must never take the loop thread down with it; the
      // promises below still release whoever is waiting.
    }

    if (op.cookieReply) op.cookieReply->set_value({});
    if (op.ack) op.ack->set_value();
  }
  return didWork;
}

/// PRECONDITION: the caller holds `inboxMtx_`. `drainInbox` keeps it across the
/// inbox pop and this whole call so that `feedUpload`, which consults the inbox
/// and then `tasks_`, can never observe a submitted request that belongs to
/// neither. Nothing here reaches back for the mutex.
void CurlEngine::startTask(std::unique_ptr<PendingRequest> pending) {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);
  if (!pending) return;

  const int64_t requestId = pending->req.requestId;
  std::unique_ptr<RequestTask> task(new RequestTask(*this, std::move(*pending)));

  const auto cancelled =
      std::find(preCancelled_.begin(), preCancelled_.end(), requestId);
  if (cancelled != preCancelled_.end()) {
    preCancelled_.erase(cancelled);
    task->requestCancel();
    task->completeWithError(cancelledError());
    return;
  }

  if (tasks_.count(requestId) != 0) {
    task->completeWithError(
        EngineError::make(RawErrorKind::RAWERRORKIND_BAD_REQUEST,
                          "a request with this id is already in flight"));
    return;
  }

  // Pool limits live on the multi handle, which only this thread may touch, so a
  // reconfigure takes effect here rather than on the Dart thread.
  config_.applyToMulti(multi_);
  const EngineError err = task->prepare(
      config_, config_.cookiesEnabled() ? cookies_.get() : nullptr, cache_);
  if (!err.ok()) {
    task->completeWithError(err);
    // `prepare` may have acquired a handle before failing, and a half-configured
    // handle is still reusable once reset.
    recycleEasy(task->detachEasy());
    return;
  }

  if (task->tryServeFromCache(cache_)) {
    // A fresh cache hit never reached the network, so its handle is untouched.
    // Recycling matters here: on a cache-heavy workload this is the hot path, and
    // leaving it to the destructor would pay a full init/cleanup pair per hit.
    recycleEasy(task->detachEasy());
    return;
  }

  const CURLMcode added = curl_multi_add_handle(multi_, task->easy());
  if (added != CURLM_OK) {
    task->completeWithError(EngineError::make(
        RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
        std::string("curl_multi_add_handle: ") + curl_multi_strerror(added),
        added));
    return;
  }
  task->markAttached();
  tasks_.emplace(requestId, std::move(task));
}

void CurlEngine::unpauseTransfer(RequestTask* task, bool write, bool read) {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);
  if (task == nullptr || !task->attached() || task->easy() == nullptr) return;

  // Nothing to resume is the COMMON case, not an edge case, and it must stay
  // free. Every `feedUpload` pushes an unpause op and every credit grant asks
  // for one, but a producer or consumer that is keeping up leaves the transfer
  // running the whole time. `curl_easy_pause` is not free even when it changes
  // nothing: it re-arms the socket and drives a round of transfer processing, so
  // calling it per 64 KiB chunk cost ~245 us of `curl_multi_perform` work each.
  // Measured on a 4 x 8 MiB streamed upload: 125.7 ms of loop-thread `perform`
  // time before this guard, 11 ms after — the same as the paths that never touch
  // the pipe at all.
  const bool resumingWrite = write && task->writePaused();
  const bool resumingRead = read && task->readPaused();
  if (!resumingWrite && !resumingRead) return;

  if (resumingWrite) task->clearWritePause();
  if (resumingRead) task->clearReadPause();

  // `curl_easy_pause` takes the full desired state, not a delta, so the mask is
  // rebuilt from whatever is still paused. Passing 0 (CURLPAUSE_CONT) would
  // resume a side the caller never asked to resume.
  int mask = 0;
  if (task->writePaused()) mask |= CURLPAUSE_RECV;
  if (task->readPaused()) mask |= CURLPAUSE_SEND;
  curl_easy_pause(task->easy(), mask);
}

CURL* CurlEngine::acquireEasy() {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);

  if (!easyPool_.empty()) {
    CURL* easy = easyPool_.back();
    easyPool_.pop_back();
    return easy;
  }
  return curl_easy_init();
}

void CurlEngine::recycleEasy(CURL* easy) {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);
  if (easy == nullptr) return;

  if (easyPool_.size() >= kMaxPooledEasyHandles) {
    curl_easy_cleanup(easy);
    return;
  }
  // Reset on the way in, not on the way out: a pooled handle then holds no
  // request state at all — no `CURLOPT_PRIVATE` pointing at a destroyed task, no
  // callback pointing into a freed arena — so a leak of the pool cannot become a
  // use-after-free.
  curl_easy_reset(easy);
  easyPool_.push_back(easy);
}

void CurlEngine::drainEasyPool() {
  for (CURL* easy : easyPool_) curl_easy_cleanup(easy);
  easyPool_.clear();
}

void CurlEngine::retire(RequestTask* task) {
  NITRO_HTTP_ASSERT_THREAD(loopGuard_);
  if (task == nullptr) return;

  if (task->attached() && task->easy() != nullptr) {
    curl_multi_remove_handle(multi_, task->easy());
  }
  // Detached while the task is still alive, so the handle is reusable for the
  // next request rather than freed by the destructor below.
  recycleEasy(task->detachEasy());

  std::unique_ptr<RequestTask> owned;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    const auto it = tasks_.find(task->id());
    if (it != tasks_.end()) {
      owned = std::move(it->second);
      tasks_.erase(it);
    }
  }
  // Destroyed outside the lock: `curl_easy_cleanup` can take a moment, and the
  // Dart thread only needs the map entry gone to stop finding the task.
}

void CurlEngine::completeAllWith(const EngineError& err) {
  std::vector<std::unique_ptr<RequestTask>> doomed;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    doomed.reserve(tasks_.size());
    for (auto& entry : tasks_) doomed.push_back(std::move(entry.second));
    tasks_.clear();
  }
  for (auto& task : doomed) {
    if (task->attached() && task->easy() != nullptr) {
      curl_multi_remove_handle(multi_, task->easy());
    }
    task->completeWithError(err);
    // Recycled even on the shutdown path: `drainEasyPool` frees the pool a moment
    // later, and routing every handle through one place keeps the "detached
    // handles are reset" invariant true without a second cleanup call site.
    recycleEasy(task->detachEasy());
  }
}

RequestTask* CurlEngine::find(int64_t requestId) {
  std::lock_guard<std::mutex> lock(inboxMtx_);
  const auto it = tasks_.find(requestId);
  return it == tasks_.end() ? nullptr : it->second.get();
}

// ── Inbox plumbing ───────────────────────────────────────────────────────────

void CurlEngine::push(Op op) {
  bool accepted = false;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    if (!shutdownDone_.load(std::memory_order_acquire) &&
        !stopping_.load(std::memory_order_acquire)) {
      inbox_.push_back(std::move(op));
      accepted = true;
    }
  }
  if (accepted) {
    if (multi_ != nullptr) curl_multi_wakeup(multi_);
    return;
  }

  // Shutdown has begun, so nothing will ever execute this op. Answering inline
  // is what keeps exactly-once completion true across a disposal race.
  if (op.pending) {
    RequestTask orphan(*this, std::move(*op.pending));
    orphan.completeWithError(shutdownError());
  }
  if (op.kind == OpKind::GrantCredit) {
    // The engine is gone, but the payloads its tasks handed to the deferred
    // registry are not — and a runner routinely sends its terminal ack after
    // disposing the client. The registry is process-global and internally
    // locked, so releasing from this thread is safe.
    if (op.a == 0) {
      DeferredPayloads::instance().releaseAll(PayloadOwner::Request,
                                              op.requestId);
    } else {
      DeferredPayloads::instance().ack(PayloadOwner::Request, op.requestId,
                                       op.b);
    }
  }
  if (op.cookieReply) op.cookieReply->set_value({});
  if (op.ack) op.ack->set_value();
}

void CurlEngine::pushAndWait(Op op) {
  auto ack = std::make_shared<std::promise<void>>();
  auto done = ack->get_future();
  op.ack = ack;
  push(std::move(op));
  done.wait_for(kOpReplyTimeout);
}

// ── Dart-thread API ──────────────────────────────────────────────────────────

void CurlEngine::configure(const RawClientConfig& cfg) {
  std::lock_guard<std::mutex> lock(inboxMtx_);

  const bool hadCookies = config_.cookiesEnabled();
  const std::string previousJar = config_.cookieJarPath();
  config_.set(cfg);

  if (config_.cookiesEnabled() != hadCookies ||
      config_.cookieJarPath() != previousJar) {
    // The parked handle carries COOKIEFILE/COOKIEJAR, so a jar change means a
    // new bridge. Destroying the old one persists it: curl writes the jar out
    // during `curl_easy_cleanup`.
    cookies_.reset(new CookieBridge(
        share_, config_.cookiesEnabled() ? config_.cookieJarPath()
                                        : std::string()));
  }
}

void CurlEngine::submit(PendingRequest pending) {
  auto op = makeOp<Op>(OpKind::Submit, pending.req.requestId);
  op.pending.reset(new PendingRequest(std::move(pending)));
  push(std::move(op));
}

void CurlEngine::cancel(int64_t requestId) {
  {
    // Flipping the flag here rather than on the loop thread is what lets a
    // transfer already inside a curl callback abort on its next progress tick.
    std::lock_guard<std::mutex> lock(inboxMtx_);
    const auto it = tasks_.find(requestId);
    if (it != tasks_.end()) it->second->requestCancel();
  }
  push(makeOp<Op>(OpKind::Cancel, requestId));
}

void CurlEngine::cancelAll() {
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    for (auto& entry : tasks_) entry.second->requestCancel();
  }
  push(makeOp<Op>(OpKind::CancelAll));
}

void CurlEngine::grantCredit(int64_t requestId, int64_t chunkCount,
                             int64_t ackedChunks) {
  auto op = makeOp<Op>(OpKind::GrantCredit, requestId);
  op.a = chunkCount;
  op.b = ackedChunks;
  push(std::move(op));
}

int64_t CurlEngine::feedUpload(int64_t requestId, const uint8_t* data,
                               size_t n) {
  int64_t buffered = 0;
  bool live = false;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    const auto it = tasks_.find(requestId);
    if (it != tasks_.end()) {
      // `BodyPipe` is internally locked and touches no curl state, which is why
      // this one path may run off the loop thread and answer synchronously.
      buffered = it->second->feedUpload(data, n);
      live = true;
    } else if (Op* queued = findPendingSubmit(inbox_, requestId)) {
      // The submit has not reached the loop thread yet, so there is no pipe.
      // Parking the bytes on the pending request keeps them in order; `prepare`
      // seeds the pipe with them. Without this, a runner that starts pumping in
      // the same microtask as `startStreamed` would silently lose its first
      // chunks.
      if (data != nullptr && n > 0) {
        queued->pending->body.insert(queued->pending->body.end(), data,
                                     data + n);
      }
      buffered = static_cast<int64_t>(queued->pending->body.size());
    }
  }
  if (live) push(makeOp<Op>(OpKind::UploadFed, requestId));
  return buffered;
}

void CurlEngine::finishUpload(int64_t requestId) {
  bool live = false;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    const auto it = tasks_.find(requestId);
    if (it != tasks_.end()) {
      it->second->finishUpload();
      live = true;
    } else if (Op* queued = findPendingSubmit(inbox_, requestId)) {
      queued->a = 1;  // applied once the task exists
    }
  }
  if (live) push(makeOp<Op>(OpKind::UploadFinished, requestId));
}

void CurlEngine::failUpload(int64_t requestId, const std::string& message) {
  bool live = false;
  {
    std::lock_guard<std::mutex> lock(inboxMtx_);
    const auto it = tasks_.find(requestId);
    if (it != tasks_.end()) {
      it->second->failUpload(message);
      live = true;
    } else if (Op* queued = findPendingSubmit(inbox_, requestId)) {
      queued->b = 1;
      queued->text = message;
    }
  }
  if (live) {
    auto op = makeOp<Op>(OpKind::UploadFailed, requestId);
    op.text = message;
    push(std::move(op));
  }
}

std::vector<RawCookie> CurlEngine::cookies() {
  auto reply = std::make_shared<std::promise<std::vector<RawCookie>>>();
  auto jar = reply->get_future();

  auto op = makeOp<Op>(OpKind::CookieRead);
  op.cookieReply = reply;
  push(std::move(op));

  if (jar.wait_for(kOpReplyTimeout) != std::future_status::ready) return {};
  try {
    return jar.get();
  } catch (...) {
    return {};
  }
}

void CurlEngine::setCookie(const RawCookie& cookie) {
  auto op = makeOp<Op>(OpKind::CookieWrite);
  op.cookie = cookie;
  pushAndWait(std::move(op));
}

void CurlEngine::clearCookies() { pushAndWait(makeOp<Op>(OpKind::CookieClear)); }

void CurlEngine::flushCookies() { pushAndWait(makeOp<Op>(OpKind::CookieFlush)); }

void CurlEngine::setCache(std::shared_ptr<HttpCache> cache) {
  auto op = makeOp<Op>(OpKind::SetCache);
  op.cache = std::move(cache);
  push(std::move(op));
}

}  // namespace nitrohttp
