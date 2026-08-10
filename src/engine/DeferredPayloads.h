// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — payload lifetime AFTER a transfer is gone.
//
// THE HAZARD. `Dart_PostCObject_DL` returning true means the message reached the
// port, not that the Dart isolate processed it. A streamed transfer therefore
// finishes like this:
//
//   loop thread                            Dart isolate
//   ───────────                            ────────────
//   emit chunk 0..N-1  ──────────────────►  (queued, not yet processed)
//   emit terminal chunk ─────────────────►  (queued)
//   destroy RequestTask
//     └─ ChunkArena frees payloads 0..N-1
//                                           processes chunk 0
//                                           reads proxy.bytes  ← FREED MEMORY
//
// The window is widest on the streamed cache-hit path, where a task is created,
// replays an entire body, and is destroyed inside a single loop-thread turn.
//
// THE FIX. A task tearing down hands its still-unacked payloads to this
// process-global registry instead of freeing them. The registry frees a bucket
// when the runner sends its terminal `grantCredit(id, 0, acked)` — which it does
// only after it has cancelled its subscription, meaning every posted chunk has
// been processed and copied. Ordinary acks for a retired id also release
// prefixes, so a long tail does not sit around waiting for the terminal call.
//
// THE BACKSTOP. A caller that takes an `HttpStreamResponse` and never listens to
// its body produces no terminal ack, so buckets are capped by both count and
// bytes and the oldest are dropped when the cap is hit. That is a genuine
// use-after-free risk *only* for a stream nobody is reading, which is a caller
// bug that already leaks the transfer; bounding the memory is the better trade
// than growing without limit. `resetAll()` (hot restart) drops everything,
// because by then the isolate that held those views is gone.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstddef>
#include <cstdint>

#include "ChunkArena.h"

namespace nitrohttp {

/// Which id space a bucket belongs to. Request ids and socket ids are allocated
/// by independent Dart counters and would otherwise collide.
enum class PayloadOwner { Request, Socket };

class DeferredPayloads {
 public:
  static DeferredPayloads& instance();

  /// Takes ownership of everything still tracked in `arena`, tagged with `id`.
  /// Cheap and safe to call when the arena is already empty, which is the common
  /// case: a transfer whose consumer kept up has nothing outstanding.
  void adopt(PayloadOwner owner, int64_t id, ChunkArena& arena);

  /// Releases deferred payloads for `id` with `seq < ackedSeq`.
  void ack(PayloadOwner owner, int64_t id, int64_t ackedSeq);

  /// Releases the whole bucket for `id`. Sent by the runner as
  /// `grantCredit(id, 0, acked)` once it has stopped reading the stream.
  void releaseAll(PayloadOwner owner, int64_t id);

  /// Drops every bucket. Only correct when no Dart view can survive — i.e. from
  /// `EngineRegistry::resetAll()` after a hot restart.
  void dropEverything();

  size_t bucketCount() const;
  size_t liveBytes() const;

  /// Caps, exposed for the tests that prove eviction happens.
  static constexpr size_t kMaxBytes = 32u * 1024u * 1024u;
  static constexpr size_t kMaxBuckets = 256;

 private:
  DeferredPayloads() = default;
  struct Impl;
  Impl& impl() const;
};

}  // namespace nitrohttp
