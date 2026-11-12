// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — bounded upload ring with a pause/resume protocol.
//
// A flat buffer plus a read cursor rather than a real ring: uploads are
// strictly FIFO with one producer and one consumer, so the only thing a
// wrap-around buffer would buy is avoiding the compaction memmove — and
// compaction happens only when the tail runs out of room, which is cheaper than
// the modular arithmetic on every copy. A flat buffer is also what lets a
// reservation be one contiguous region the producer can write in a single pass.
// ─────────────────────────────────────────────────────────────────────────────

#include "BodyPipe.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <new>
#include <utility>

namespace nitrohttp {
namespace {

// One buffer kept between uploads. A pipe's working buffer is megabytes, and a
// fresh allocation is page-faulted in, a page at a time, on the Dart isolate's
// thread. Handing the last pipe's buffer to the next one keeps the pages
// mapped, which is what makes a deep pipe affordable (see
// `uploadPipeCapacityFor`).
//
// One slot, capped at the deepest pipe plus slack for the reservation beyond
// it. `releaseIdleUploadSpare` drops it once no upload has used it for a few
// seconds.
constexpr size_t kSpareMaxBytes = kUploadPipeMaxCapBytes + 1024 * 1024;
constexpr auto kSpareIdle = std::chrono::seconds(5);
std::mutex g_spareMtx;
std::unique_ptr<uint8_t[]> g_spare;
size_t g_spareCapacity = 0;
std::chrono::steady_clock::time_point g_spareParkedAt;

std::unique_ptr<uint8_t[]> takeSpare(size_t want, size_t* capacity) {
  std::lock_guard<std::mutex> lock(g_spareMtx);
  if (!g_spare || g_spareCapacity < want) return nullptr;
  *capacity = g_spareCapacity;
  g_spareCapacity = 0;
  return std::move(g_spare);
}

void giveSpare(std::unique_ptr<uint8_t[]> buffer, size_t capacity) {
  if (!buffer || capacity > kSpareMaxBytes) return;
  std::lock_guard<std::mutex> lock(g_spareMtx);
  if (capacity <= g_spareCapacity) return;  // keep the larger one
  g_spare = std::move(buffer);
  g_spareCapacity = capacity;
  g_spareParkedAt = std::chrono::steady_clock::now();
}

}  // namespace

void releaseIdleUploadSpare(bool force) {
  std::unique_ptr<uint8_t[]> idle;
  {
    std::lock_guard<std::mutex> lock(g_spareMtx);
    if (!g_spare) return;
    if (!force &&
        std::chrono::steady_clock::now() - g_spareParkedAt < kSpareIdle) {
      return;
    }
    idle = std::move(g_spare);
    g_spareCapacity = 0;
  }
  // Freed outside the lock.
}

size_t uploadSpareBytes() {
  std::lock_guard<std::mutex> lock(g_spareMtx);
  return g_spareCapacity;
}

BodyPipe::BodyPipe(size_t softCapacityBytes)
    : softCapacity_(softCapacityBytes) {}

BodyPipe::~BodyPipe() {
  giveSpare(std::move(retired_), retiredCapacity_);
  giveSpare(std::move(data_), capacity_);
}

void BodyPipe::releaseBufferLocked() {
  if (reading_ && !retired_) {
    // A read in flight is copying out of it. Park it; `pull` lets go when done.
    retired_ = std::move(data_);
    retiredCapacity_ = capacity_;
  } else {
    giveSpare(std::move(data_), capacity_);
  }
  data_.reset();
  capacity_ = 0;
}

bool BodyPipe::makeRoomLocked(size_t n) {
  if (capacity_ - size_ >= n) return true;
  const size_t live = size_ - readPos_;

  // Reclaim what curl has already taken before asking for more memory: one
  // memmove of the unread remainder, and usually that remainder is empty. Not
  // while a read is in flight, though — those are the bytes it is copying.
  if (!reading_ && readPos_ > 0) {
    if (live > 0) std::memmove(data_.get(), data_.get() + readPos_, live);
    size_ = live;
    readPos_ = 0;
    if (capacity_ - size_ >= n) return true;
  }

  // A different buffer, then: because this one is too small, or because it
  // cannot be rearranged under the reader. Sized straight to the working depth
  // rather than doubling up to it — a pipe that will hold `softCapacity_`
  // bytes should allocate once, not copy itself five times on the way there.
  size_t want = std::max(live + n, softCapacity_ + n);
  if (want <= capacity_) {
    want = capacity_;  // same size: this is a relocation, not growth
  } else if (live > softCapacity_ * 2 && want < capacity_ * 2) {
    // Far past the depth it was asked to stop at: this producer is not
    // pausing, so grow geometrically rather than re-copying on every chunk.
    // A producer that does pause overshoots by one chunk at most and gets
    // exactly the room it asked for, which keeps the buffer recyclable.
    want = capacity_ * 2;
  }
  std::unique_ptr<uint8_t[]> next = takeSpare(want, &want);
  if (!next) next.reset(new (std::nothrow) uint8_t[want]);
  if (!next) return false;
  if (live > 0) std::memcpy(next.get(), data_.get() + readPos_, live);

  // `pull` advances `readPos_` by what it copied once it re-takes the lock.
  // With the unread bytes now starting at 0 that lands in the right place:
  // what it was copying is exactly the head of what was moved.
  releaseBufferLocked();
  data_ = std::move(next);
  capacity_ = want;
  size_ = live;
  readPos_ = 0;
  return true;
}

size_t BodyPipe::noteDepthLocked() {
  const size_t depth = size_ - readPos_;
  // Half the soft capacity is the drain watermark: crossing it upward arms the
  // signal that `pull` fires on the way back down.
  const size_t watermark = softCapacity_ / 2 > 0 ? softCapacity_ / 2 : 1;
  if (depth > watermark) wasAboveWatermark_ = true;
  return depth;
}

void BodyPipe::failLocked(std::string message) {
  failed_ = true;
  failure_ = std::move(message);
  // Nothing will ever be read again, so the memory can go now rather than at
  // teardown — unless the producer is mid-write into it.
  if (reserved_ == 0) releaseBufferLocked();
  size_ = 0;
  readPos_ = 0;
}

size_t BodyPipe::push(const uint8_t* data, size_t n) {
  std::lock_guard<std::mutex> lock(mtx_);
  // Bytes offered after a clean end of stream or an abort would silently
  // corrupt the body, so they are dropped rather than appended. The runner
  // stops feeding on both paths; this is belt and braces.
  if (finished_ || failed_) return size_ - readPos_;

  if (data != nullptr && n > 0) {
    reserved_ = 0;  // a push supersedes any reservation the producer left open
    if (!makeRoomLocked(n)) {
      failLocked("out of memory buffering the request body");
      return 0;
    }
    std::memcpy(data_.get() + size_, data, n);
    size_ += n;
  }
  return noteDepthLocked();
}

uint8_t* BodyPipe::reserveLocked(size_t n) {
  if (finished_ || failed_ || producerClosed_) return nullptr;
  reserved_ = 0;
  if (!makeRoomLocked(n)) {
    failLocked("out of memory buffering the request body");
    return nullptr;
  }
  reserved_ = n;
  return data_.get() + size_;
}

size_t BodyPipe::commitLocked(size_t n) {
  // Never publish more than was lent: bytes past the reservation were not
  // written by anyone.
  if (n > reserved_) n = reserved_;
  reserved_ = 0;
  if (finished_ || failed_) return size_ - readPos_;
  size_ += n;
  return noteDepthLocked();
}

uint8_t* BodyPipe::reserve(size_t n) {
  std::lock_guard<std::mutex> lock(mtx_);
  return reserveLocked(n);
}

size_t BodyPipe::commit(size_t n) {
  std::lock_guard<std::mutex> lock(mtx_);
  return commitLocked(n);
}

BodyPipe::Exchange BodyPipe::exchange(size_t commitBytes, size_t reserveBytes) {
  std::lock_guard<std::mutex> lock(mtx_);
  Exchange out;
  out.buffered = commitLocked(commitBytes);
  out.region = reserveLocked(reserveBytes);
  out.softCapacity = softCapacity_;
  out.readerStarved = readerStarved_;
  readerStarved_ = false;
  return out;
}

void BodyPipe::closeProducer() {
  std::lock_guard<std::mutex> lock(mtx_);
  producerClosed_ = true;
}

size_t BodyPipe::pull(uint8_t* dst, size_t n) {
  if (dst == nullptr || n == 0) return 0;

  size_t copied = 0;
  while (copied < n) {
    const uint8_t* src = nullptr;
    size_t take = 0;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      // A failed upload must not hand curl the bytes it already buffered:
      // sending a truncated body is worse than aborting the transfer.
      if (failed_) return 0;
      take = std::min(n - copied, size_ - readPos_);
      if (take == 0) {
        // Came up empty with the stream still open: the caller is about to
        // pause the transfer, and the producer's next step has to wake it.
        if (copied == 0 && !finished_) readerStarved_ = true;
        break;
      }
      src = data_.get() + readPos_;
      reading_ = true;  // from here the producer may not move these bytes
    }

    // The copy itself, with the lock released. The producer is free to commit
    // more behind it; if it has to make room it leaves this buffer alone.
    std::memcpy(dst + copied, src, take);

    std::lock_guard<std::mutex> lock(mtx_);
    reading_ = false;
    if (retired_) {
      giveSpare(std::move(retired_), retiredCapacity_);
      retired_.reset();
      retiredCapacity_ = 0;
    }
    if (failed_) return 0;  // aborted while we were copying
    readPos_ += take;
    copied += take;

    // An emptied buffer rewinds for free — but not under an open reservation,
    // which points at the current tail. The producer reclaims the prefix itself
    // the next time it needs room. This side never moves the buffer.
    if (readPos_ == size_ && reserved_ == 0) {
      readPos_ = 0;
      size_ = 0;
    }

    const size_t depth = size_ - readPos_;
    const size_t watermark = softCapacity_ / 2 > 0 ? softCapacity_ / 2 : 1;
    if (wasAboveWatermark_ && depth <= watermark) {
      wasAboveWatermark_ = false;
      drainPending_ = true;  // exactly one uploadDrain event per crossing
    }
  }
  return copied;
}

void BodyPipe::finish() {
  std::lock_guard<std::mutex> lock(mtx_);
  finished_ = true;
}

void BodyPipe::fail(std::string message) {
  std::lock_guard<std::mutex> lock(mtx_);
  failLocked(std::move(message));
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
  return finished_ && size_ == readPos_;
}

size_t BodyPipe::buffered() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return size_ - readPos_;
}

size_t BodyPipe::softCapacity() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return softCapacity_;
}

void BodyPipe::setSoftCapacity(size_t bytes) {
  std::lock_guard<std::mutex> lock(mtx_);
  softCapacity_ = bytes;
  noteDepthLocked();
}

bool BodyPipe::consumeDrainSignal() {
  std::lock_guard<std::mutex> lock(mtx_);
  const bool pending = drainPending_;
  drainPending_ = false;
  return pending;
}

}  // namespace nitrohttp
