// nitro_worker_pool.h — a small fixed thread pool the generated C++ bridge
// uses to run `@nitroAsync` implementations off the Dart isolate. The sync
// implementation is unchanged; the bridge copies the arguments, runs it on a
// worker and posts the result (see <lib>_<method>_dispatch in the bridge).
#ifndef NITRO_WORKER_POOL_H_
#define NITRO_WORKER_POOL_H_

#ifdef __cplusplus
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

class NitroWorkerPool {
 public:
  // Threads start on first use; the process exit tears them down.
  void enqueue(std::function<void()> job) {
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
  bool enqueueBounded(std::function<void()> job, size_t maxQueued, int dropOldest) {
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
      std::function<void()> job;
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
  std::deque<std::function<void()>> queue_;
  std::vector<std::thread> threads_;
};
#endif  // __cplusplus
#endif  // NITRO_WORKER_POOL_H_
