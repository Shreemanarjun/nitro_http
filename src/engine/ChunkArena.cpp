// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — zero-copy stream payload lifetime.
//
// See ChunkArena.h for why the protocol is credit-based. This file is the easy
// half: a queue in emission order, freed from the front as acks arrive.
// ─────────────────────────────────────────────────────────────────────────────

#include "ChunkArena.h"

#include <utility>

namespace nitrohttp {

ChunkArena::~ChunkArena() { releaseAll(); }

void ChunkArena::track(int64_t seq, Blob payload) {
  if (payload.empty()) {
    // A zero-length emit owns nothing; tracking it would make `ack` free a
    // pointer it never allocated.
    payload.release();
    return;
  }
  std::lock_guard<std::mutex> lock(mtx_);
  liveBytes_ += payload.size;
  live_.push_back(Entry{seq, payload});
}

void ChunkArena::ack(int64_t ackedSeq) {
  // Sequences are pushed in increasing order, so everything releasable is at
  // the front. A repeated or stale ack simply frees nothing.
  std::lock_guard<std::mutex> lock(mtx_);
  while (!live_.empty() && live_.front().seq < ackedSeq) {
    Entry entry = live_.front();
    live_.pop_front();
    liveBytes_ -= entry.payload.size;
    entry.payload.release();
  }
}

void ChunkArena::releaseAll() {
  std::deque<Entry> doomed;
  {
    std::lock_guard<std::mutex> lock(mtx_);
    doomed.swap(live_);
    liveBytes_ = 0;
  }
  // Freeing outside the lock keeps a teardown of thousands of chunks from
  // blocking the loop thread's next `track`.
  for (Entry& entry : doomed) entry.payload.release();
}

std::vector<std::pair<int64_t, Blob>> ChunkArena::drain() {
  std::deque<Entry> taken;
  {
    std::lock_guard<std::mutex> lock(mtx_);
    taken.swap(live_);
    liveBytes_ = 0;
  }
  std::vector<std::pair<int64_t, Blob>> out;
  out.reserve(taken.size());
  for (Entry& entry : taken) out.emplace_back(entry.seq, entry.payload);
  return out;
}

size_t ChunkArena::liveCount() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return live_.size();
}

size_t ChunkArena::liveBytes() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return liveBytes_;
}

}  // namespace nitrohttp
