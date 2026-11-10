// nitro_worker_pool.h — a small fixed thread pool the generated C++ bridge
// uses to run `@nitroAsync` implementations off the Dart isolate. The sync
// implementation is unchanged; the bridge copies the arguments, runs it on a
// worker and posts the result (see <lib>_<method>_dispatch in the bridge).
#ifndef NITRO_WORKER_POOL_H_
#define NITRO_WORKER_POOL_H_

#ifdef __cplusplus
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <mutex>
#include <new>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

// Move-only type-erased `void()` job with a 64-byte inline buffer and a heap
// fallback. Replaces std::function for pool jobs: a generated async-dispatch
// closure captures the instance id, the args and the port (~40B here), which
// does NOT fit std::function's small-buffer (16B libstdc++ / 24B libc++), so
// every enqueue used to heap-allocate it. 64B inline holds the common closure,
// so enqueue no longer allocates; a larger closure still falls back to the heap
// exactly as before. Jobs are only moved, never copied — move-only drops
// std::function's copy machinery and lets a move-only capture through too.
// kInline is the one knob: bump it if a hot async method's closure spills.
class NitroJob {
 public:
  NitroJob() noexcept = default;

  template <class F, class = std::enable_if_t<
                         !std::is_same<std::decay_t<F>, NitroJob>::value>>
  NitroJob(F&& f) {
    using D = std::decay_t<F>;
    if (sizeof(D) <= kInline && alignof(D) <= alignof(std::max_align_t)) {
      ::new (static_cast<void*>(&storage_.buf)) D(std::forward<F>(f));
      heap_ = false;
      // Inline: object lives in `buf`, so destruct only — never free `buf`.
      destroy_ = [](void* p) { static_cast<D*>(p)->~D(); };
    } else {
      storage_.ptr = new D(std::forward<F>(f));
      heap_ = true;
      // Heap: allocated with `new`, so `delete` to destruct AND free. A bare
      // `->~D()` here destructs but leaks the allocation (LSan caught this).
      destroy_ = [](void* p) { delete static_cast<D*>(p); };
    }
    call_ = [](void* p) { (*static_cast<D*>(p))(); };
    move_ = [](void* d, void* s) {
      ::new (d) D(std::move(*static_cast<D*>(s)));
      static_cast<D*>(s)->~D();
    };
  }

  NitroJob(NitroJob&& o) noexcept { moveFrom(o); }
  NitroJob& operator=(NitroJob&& o) noexcept {
    if (this != &o) {
      reset();
      moveFrom(o);
    }
    return *this;
  }
  NitroJob(const NitroJob&) = delete;
  NitroJob& operator=(const NitroJob&) = delete;
  ~NitroJob() { reset(); }

  void operator()() { call_(target()); }

 private:
  static constexpr std::size_t kInline = 64;
  union Storage {
    void* ptr;
    alignas(std::max_align_t) char buf[kInline];
  } storage_{};
  void (*call_)(void*) = nullptr;
  void (*destroy_)(void*) = nullptr;
  void (*move_)(void*, void*) = nullptr;  // inline move-construct + destroy src
  bool heap_ = false;

  void* target() noexcept {
    return heap_ ? storage_.ptr : static_cast<void*>(&storage_.buf);
  }
  void reset() noexcept {
    if (call_) {
      destroy_(target());
      call_ = nullptr;
    }
  }
  void moveFrom(NitroJob& o) noexcept {
    call_ = o.call_;
    destroy_ = o.destroy_;
    move_ = o.move_;
    heap_ = o.heap_;
    if (!o.call_) return;
    if (heap_) {
      storage_.ptr = o.storage_.ptr;  // steal the pointer
    } else {
      move_(&storage_.buf, &o.storage_.buf);  // move-construct, then destroy src
    }
    o.call_ = nullptr;  // source emptied; its ~NitroJob/reset() becomes a no-op
  }
};

class NitroWorkerPool {
 public:
  // Threads start on first use; the process exit tears them down.
  void enqueue(NitroJob job) {
    {
      std::lock_guard<std::mutex> lk(mu_);
      if (threads_.empty()) start();
      queue_.push_back(std::move(job));
    }
    cv_.notify_one();
  }

  // Fire-and-forget bounded enqueue (issue #58; a void @nitroNativeAsync). Caps the
  // backlog at [maxQueued]; when full it either blocks the caller until a worker
  // drains one ([dropOldest]==0) or drops the oldest queued job ([dropOldest]!=0)
  // so the newest wins. [maxQueued]==0 is unbounded. Returns false iff a job was
  // dropped. Unlike enqueue(), the caller does not wait for the work's result —
  // only (optionally) for queue space — so many calls dispatch concurrently.
  bool enqueueBounded(NitroJob job, size_t maxQueued, int dropOldest) {
    bool dropped = false;
    {
      std::unique_lock<std::mutex> lk(mu_);
      if (threads_.empty()) start();
      if (maxQueued > 0 && queue_.size() >= maxQueued) {
        if (dropOldest) {
          queue_.pop_front();
          dropped = true;
        } else {
          space_.wait(lk, [&] { return queue_.size() < maxQueued; });
        }
      }
      queue_.push_back(std::move(job));
    }
    cv_.notify_one();
    return !dropped;
  }

 private:
  void start() {
    unsigned n = std::thread::hardware_concurrency();
    n = n == 0 ? 2 : (n > 4 ? 4 : n);
    for (unsigned i = 0; i < n; i++) {
      threads_.emplace_back([this] { loop(); });
      threads_.back().detach();
    }
  }

  void loop() {
    for (;;) {
      NitroJob job;
      {
        std::unique_lock<std::mutex> lk(mu_);
        cv_.wait(lk, [this] { return !queue_.empty(); });
        job = std::move(queue_.front());
        queue_.pop_front();
      }
      space_.notify_one();  // a bounded (fire-and-forget) producer may be waiting for room
      job();
    }
  }

  std::mutex mu_;
  std::condition_variable cv_;
  std::condition_variable space_;  // signals queue space for enqueueBounded(block)
  std::deque<NitroJob> queue_;
  std::vector<std::thread> threads_;
};
#endif  // __cplusplus
#endif  // NITRO_WORKER_POOL_H_
