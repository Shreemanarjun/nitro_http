// ─────────────────────────────────────────────────────────────────────────────
// nitro_http — native cancellation tokens.
//
// A token is one `CancelState` behind an integer id Dart allocates. Two
// properties are the whole point, and neither is reachable from a Dart-side
// token that fans out one `cancel(requestId)` per request:
//
//   • A transfer submitted AFTER its token was cancelled never opens a socket.
//     `startTask` reads the flag before `curl_multi_add_handle`, so there is no
//     window to lose and no bounded "cancelled before I saw the submit" list to
//     overflow.
//
//   • Cancelling N bound transfers is one flag store. Every bound task shares
//     the same `CancelState` by `shared_ptr`, so the store is immediately
//     visible to all of them, on every client, without the loop thread having
//     been scheduled at all.
//
// The registry is process-global rather than per `CurlEngine` on purpose: one
// token may be handed to requests on several clients, and cancellation must not
// depend on which engine happens to notice first.
//
// LIFETIME  Tasks hold `shared_ptr<CancelState>`, so `release()` during a live
// transfer drops only the registry's own reference. A token can therefore never
// be released out from under a transfer, and a released id that comes back is
// simply a fresh state.
//
// THREADING  `cancelled()` is a lock-free atomic read, because it runs in
// curl's write/read/progress callbacks on the loop thread and must stay cheap.
// The reason string is guarded separately and read only when a transfer is
// actually being failed.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace nitrohttp {

/// The shared flag behind one token id.
class CancelState {
 public:
  /// Any thread. Lock-free by design — see the header note.
  bool cancelled() const { return cancelled_.load(std::memory_order_acquire); }

  /// Any thread. Idempotent; the FIRST reason is the one kept, matching the
  /// Dart `CancelToken` contract where the first `cancel()` wins.
  void cancel(std::string reason);

  /// Any thread. Empty when the token carries no reason.
  std::string reason() const;

 private:
  std::atomic<bool> cancelled_{false};
  mutable std::mutex mtx_;
  std::string reason_;
};

class CancelRegistry {
 public:
  static CancelRegistry& instance();

  /// Returns the state for `tokenId`, creating it if absent. `0` means "no
  /// token" and yields nullptr, which is the common case and allocates nothing.
  std::shared_ptr<CancelState> obtain(int64_t tokenId);

  /// Returns the state only if it already exists. Never creates.
  std::shared_ptr<CancelState> lookup(int64_t tokenId) const;

  /// Cancels `tokenId`, creating the state when the cancel arrives before any
  /// request bound to it — that is what makes a pre-emptive cancel work.
  void cancel(int64_t tokenId, std::string reason);

  /// Drops the registry's reference. In-flight transfers keep theirs.
  void release(int64_t tokenId);

  /// Hot-restart recovery: `resetNative()` tears the Dart side down, so every
  /// id it allocated is meaningless afterwards.
  void clear();

  size_t size() const;

 private:
  CancelRegistry() = default;

  mutable std::mutex mtx_;
  std::unordered_map<int64_t, std::shared_ptr<CancelState>> states_;
};

}  // namespace nitrohttp
