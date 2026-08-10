#include "DeferredPayloads.h"

#include <deque>
#include <map>
#include <mutex>
#include <utility>
#include <vector>

namespace nitrohttp {

struct DeferredPayloads::Impl {
  struct Bucket {
    // Insertion order within a bucket is emission order, so an ack releases a
    // prefix exactly as ChunkArena does.
    std::deque<std::pair<int64_t, Blob>> entries;
    size_t bytes = 0;
    uint64_t generation = 0;  ///< adoption order, for oldest-first eviction
  };

  std::mutex mtx;
  // Keyed by (owner, id). `std::map` rather than a hash map: bucket counts are in
  // the low hundreds and an ordered container makes the eviction scan trivial.
  std::map<std::pair<int, int64_t>, Bucket> buckets;
  size_t totalBytes = 0;
  uint64_t nextGeneration = 1;

  static std::pair<int, int64_t> key(PayloadOwner owner, int64_t id) {
    return {static_cast<int>(owner), id};
  }

  /// Enforces the caps. Callers hold `mtx`; freeing happens after it is released,
  /// so the doomed entries are moved out rather than freed in place.
  void collectEvictions(std::vector<std::pair<int64_t, Blob>>* doomed) {
    while (totalBytes > kMaxBytes || buckets.size() > kMaxBuckets) {
      auto oldest = buckets.end();
      uint64_t oldestGeneration = UINT64_MAX;
      for (auto it = buckets.begin(); it != buckets.end(); ++it) {
        if (it->second.generation < oldestGeneration) {
          oldestGeneration = it->second.generation;
          oldest = it;
        }
      }
      if (oldest == buckets.end()) return;
      totalBytes -= oldest->second.bytes;
      for (auto& entry : oldest->second.entries) doomed->push_back(entry);
      buckets.erase(oldest);
    }
  }
};

DeferredPayloads& DeferredPayloads::instance() {
  static DeferredPayloads singleton;
  return singleton;
}

DeferredPayloads::Impl& DeferredPayloads::impl() const {
  // Function-local static: the unity build concatenates every engine source into
  // one translation unit, where namespace-scope static init order is a hazard
  // worth simply not having.
  static Impl state;
  return state;
}

void DeferredPayloads::adopt(PayloadOwner owner, int64_t id, ChunkArena& arena) {
  auto taken = arena.drain();
  if (taken.empty()) return;

  std::vector<std::pair<int64_t, Blob>> doomed;
  {
    Impl& state = impl();
    std::lock_guard<std::mutex> lock(state.mtx);
    Impl::Bucket& bucket = state.buckets[Impl::key(owner, id)];
    if (bucket.generation == 0) bucket.generation = state.nextGeneration++;
    for (auto& entry : taken) {
      bucket.bytes += entry.second.size;
      state.totalBytes += entry.second.size;
      bucket.entries.push_back(entry);
    }
    state.collectEvictions(&doomed);
  }
  for (auto& entry : doomed) entry.second.release();
}

void DeferredPayloads::ack(PayloadOwner owner, int64_t id, int64_t ackedSeq) {
  std::vector<std::pair<int64_t, Blob>> doomed;
  {
    Impl& state = impl();
    std::lock_guard<std::mutex> lock(state.mtx);
    auto it = state.buckets.find(Impl::key(owner, id));
    if (it == state.buckets.end()) return;
    Impl::Bucket& bucket = it->second;
    while (!bucket.entries.empty() && bucket.entries.front().first < ackedSeq) {
      auto entry = bucket.entries.front();
      bucket.entries.pop_front();
      bucket.bytes -= entry.second.size;
      state.totalBytes -= entry.second.size;
      doomed.push_back(entry);
    }
    if (bucket.entries.empty()) state.buckets.erase(it);
  }
  for (auto& entry : doomed) entry.second.release();
}

void DeferredPayloads::releaseAll(PayloadOwner owner, int64_t id) {
  std::deque<std::pair<int64_t, Blob>> doomed;
  {
    Impl& state = impl();
    std::lock_guard<std::mutex> lock(state.mtx);
    auto it = state.buckets.find(Impl::key(owner, id));
    if (it == state.buckets.end()) return;
    state.totalBytes -= it->second.bytes;
    doomed.swap(it->second.entries);
    state.buckets.erase(it);
  }
  for (auto& entry : doomed) entry.second.release();
}

void DeferredPayloads::dropEverything() {
  std::vector<std::pair<int64_t, Blob>> doomed;
  {
    Impl& state = impl();
    std::lock_guard<std::mutex> lock(state.mtx);
    for (auto& kv : state.buckets) {
      for (auto& entry : kv.second.entries) doomed.push_back(entry);
    }
    state.buckets.clear();
    state.totalBytes = 0;
  }
  for (auto& entry : doomed) entry.second.release();
}

size_t DeferredPayloads::bucketCount() const {
  Impl& state = impl();
  std::lock_guard<std::mutex> lock(state.mtx);
  return state.buckets.size();
}

size_t DeferredPayloads::liveBytes() const {
  Impl& state = impl();
  std::lock_guard<std::mutex> lock(state.mtx);
  return state.totalBytes;
}

}  // namespace nitrohttp
