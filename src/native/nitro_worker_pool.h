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
      job();
    }
  }

  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<std::function<void()>> queue_;
  std::vector<std::thread> threads_;
};
#endif  // __cplusplus
#endif  // NITRO_WORKER_POOL_H_
