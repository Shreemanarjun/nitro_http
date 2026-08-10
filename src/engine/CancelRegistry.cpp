#include "CancelRegistry.h"

#include <utility>

namespace nitrohttp {

void CancelState::cancel(std::string reason) {
  {
    std::lock_guard<std::mutex> lock(mtx_);
    // First reason wins, so a second cancel cannot rewrite the diagnosis a
    // caller is already reporting. Guard on the string rather than the atomic:
    // the atomic is stored last, and testing it here would let two racing
    // cancels both find it false and both write.
    if (reason_.empty()) reason_ = std::move(reason);
  }
  // Released after the reason is in place, so any thread that observes the flag
  // with acquire ordering also observes the string it is paired with.
  cancelled_.store(true, std::memory_order_release);
}

std::string CancelState::reason() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return reason_;
}

CancelRegistry& CancelRegistry::instance() {
  static CancelRegistry registry;
  return registry;
}

std::shared_ptr<CancelState> CancelRegistry::obtain(int64_t tokenId) {
  if (tokenId == 0) return nullptr;
  std::lock_guard<std::mutex> lock(mtx_);
  std::shared_ptr<CancelState>& slot = states_[tokenId];
  if (!slot) slot = std::make_shared<CancelState>();
  return slot;
}

std::shared_ptr<CancelState> CancelRegistry::lookup(int64_t tokenId) const {
  if (tokenId == 0) return nullptr;
  std::lock_guard<std::mutex> lock(mtx_);
  const auto it = states_.find(tokenId);
  return it == states_.end() ? nullptr : it->second;
}

void CancelRegistry::cancel(int64_t tokenId, std::string reason) {
  if (tokenId == 0) return;
  // `obtain` rather than `lookup`: cancelling a token no request has used yet is
  // the pre-emptive case, and it has to be remembered so the request that
  // arrives later is refused.
  const std::shared_ptr<CancelState> state = obtain(tokenId);
  // Outside the registry lock — a task reading the flag in a curl callback must
  // never contend with an unrelated token being created.
  if (state) state->cancel(std::move(reason));
}

void CancelRegistry::release(int64_t tokenId) {
  if (tokenId == 0) return;
  std::lock_guard<std::mutex> lock(mtx_);
  states_.erase(tokenId);
}

void CancelRegistry::clear() {
  std::lock_guard<std::mutex> lock(mtx_);
  states_.clear();
}

size_t CancelRegistry::size() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return states_.size();
}

}  // namespace nitrohttp
