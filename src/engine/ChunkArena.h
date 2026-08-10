// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — zero-copy stream payload lifetime.
//
// THE PROBLEM. `RawChunk` is a `@HybridStruct(zeroCopy: ['bytes'])`. The
// generated release symbol `nitro_http_release_RawChunk` frees only the struct
// SHELL that the bridge malloc'd per emit; the payload buffer stays owned by
// native, and the generated Dart proxy reads it lazily:
//
//   Uint8List get bytes => _native.ref.bytes.asTypedList(_native.ref.bytesLength);
//
// So native gets no signal when Dart is done reading. Free too early and the
// proxy reads freed memory; never free and a 100 MB download leaks 100 MB.
//
// THE PROTOCOL. Every emitted payload is tagged with a monotonic sequence.
// `grantCredit(requestId, chunkCount, ackedChunks)` carries the cumulative
// count of chunks the Dart runner has already COPIED out of native memory, and
// this arena frees every payload with `seq < ackedChunks`.
//
// Why that is sound: the runner copies each chunk's bytes in its stream
// callback, before counting it toward the ack, and it only ever grants credit
// for chunks it has counted. So an acked sequence is a sequence Dart provably
// no longer reads. Payloads still un-acked at task teardown are freed
// unconditionally — by then the request is finished and the runner has closed
// its per-request controller.
//
// The same protocol serves `RawWsFrame` through `wsGrantCredit`.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <deque>
#include <mutex>
#include <utility>
#include <vector>

#include "Common.h"

namespace nitrohttp {

class ChunkArena {
 public:
  ChunkArena() = default;
  ~ChunkArena();

  ChunkArena(const ChunkArena&) = delete;
  ChunkArena& operator=(const ChunkArena&) = delete;

  /// Records `payload` as emitted with sequence `seq` and takes ownership.
  /// Sequences must be strictly increasing per arena.
  void track(int64_t seq, Blob payload);

  /// Frees every tracked payload with `seq < ackedSeq`. Idempotent and
  /// tolerant of out-of-order or repeated acks.
  void ack(int64_t ackedSeq);

  /// Frees everything unconditionally. Only safe once Dart provably cannot read
  /// any of these payloads again — from `resetAll()`, or from the deferred
  /// registry once a terminal ack has arrived.
  ///
  /// A task tearing down mid-stream MUST `drain()` into [DeferredPayloads]
  /// instead. `Dart_PostCObject_DL` returning true means the message was
  /// DELIVERED to the port, not PROCESSED by the isolate: chunks already posted
  /// may not have been copied yet, and freeing them here would be a
  /// use-after-free in the Dart proxy's `bytes` getter.
  void releaseAll();

  /// Hands ownership of every still-tracked payload to the caller, in emission
  /// order, and empties the arena.
  std::vector<std::pair<int64_t, Blob>> drain();

  size_t liveCount() const;
  size_t liveBytes() const;

 private:
  struct Entry {
    int64_t seq;
    Blob payload;
  };
  mutable std::mutex mtx_;
  std::deque<Entry> live_;
  size_t liveBytes_ = 0;
};

}  // namespace nitrohttp
