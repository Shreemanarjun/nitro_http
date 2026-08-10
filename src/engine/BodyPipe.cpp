// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — bounded upload ring with a pause/resume protocol.
//
// A `std::vector` plus a read cursor rather than a real ring: uploads are
// strictly FIFO with one producer and one consumer, so the only thing a
// wrap-around buffer would buy is avoiding the compaction memmove — and
// compaction happens at most once per half-buffer of throughput, which is
// cheaper than the modular arithmetic on every copy.
// ─────────────────────────────────────────────────────────────────────────────

#include "BodyPipe.h"

#include <algorithm>
#include <cstring>
#include <utility>

namespace nitrohttp {

BodyPipe::BodyPipe(size_t softCapacityBytes)
    : softCapacity_(softCapacityBytes) {}

size_t BodyPipe::push(const uint8_t* data, size_t n) {
  std::lock_guard<std::mutex> lock(mtx_);
  const size_t depthBefore = buf_.size() - readPos_;

  // Bytes offered after a clean end of stream or an abort would silently
  // corrupt the body, so they are dropped rather than appended. The runner
  // stops feeding on both paths; this is belt and braces.
  if (finished_ || failed_) return depthBefore;

  if (data != nullptr && n > 0) buf_.insert(buf_.end(), data, data + n);

  const size_t depth = buf_.size() - readPos_;
  // Half the soft capacity is the drain watermark: crossing it upward arms the
  // signal that `pull` fires on the way back down.
  const size_t watermark = softCapacity_ / 2 > 0 ? softCapacity_ / 2 : 1;
  if (depth >= watermark) wasAboveWatermark_ = true;
  return depth;
}

size_t BodyPipe::pull(uint8_t* dst, size_t n) {
  std::lock_guard<std::mutex> lock(mtx_);
  // A failed upload must not hand curl the bytes it already buffered: sending
  // a truncated body is worse than aborting the transfer.
  if (failed_) return 0;
  if (dst == nullptr || n == 0) return 0;

  const size_t available = buf_.size() - readPos_;
  const size_t take = std::min(n, available);
  if (take == 0) return 0;

  std::memcpy(dst, buf_.data() + readPos_, take);
  readPos_ += take;

  // Drop the consumed prefix once it is the larger half, so a multi-gigabyte
  // upload holds a bounded buffer instead of growing for its whole lifetime.
  if (readPos_ > buf_.size() / 2) {
    buf_.erase(buf_.begin(), buf_.begin() + static_cast<std::ptrdiff_t>(readPos_));
    readPos_ = 0;
  }

  const size_t depth = buf_.size() - readPos_;
  const size_t watermark = softCapacity_ / 2 > 0 ? softCapacity_ / 2 : 1;
  if (wasAboveWatermark_ && depth < watermark) {
    wasAboveWatermark_ = false;
    drainPending_ = true;  // exactly one uploadDrain event per crossing
  }
  return take;
}

void BodyPipe::finish() {
  std::lock_guard<std::mutex> lock(mtx_);
  finished_ = true;
}

void BodyPipe::fail(std::string message) {
  std::lock_guard<std::mutex> lock(mtx_);
  failed_ = true;
  failure_ = std::move(message);
  // Nothing will ever be read again; release the memory now rather than at
  // task teardown.
  buf_.clear();
  buf_.shrink_to_fit();
  readPos_ = 0;
}

bool BodyPipe::finished() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return finished_;
}

bool BodyPipe::failed() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return failed_;
}

std::string BodyPipe::failureMessage() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return failure_;
}

bool BodyPipe::atEof() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return finished_ && buf_.size() == readPos_;
}

size_t BodyPipe::buffered() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return buf_.size() - readPos_;
}

bool BodyPipe::consumeDrainSignal() {
  std::lock_guard<std::mutex> lock(mtx_);
  const bool pending = drainPending_;
  drainPending_ = false;
  return pending;
}

}  // namespace nitrohttp
