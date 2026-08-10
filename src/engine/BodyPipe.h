// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — bounded upload ring with a pause/resume protocol.
//
// Streamed request bodies flow Dart → native through `feedUploadChunk`, which
// runs on the Dart isolate thread, while curl's `READFUNCTION` drains on the
// engine loop thread. The ring is the only synchronisation point between them.
//
// Backpressure is two-sided and honest:
//   • Dart side: `push` returns the currently buffered byte count, and the
//     runner pauses its source stream above a high-water mark, resuming on the
//     `uploadDrain` event.
//   • curl side: `pull` returning 0 while neither EOF nor failure is set makes
//     `READFUNCTION` answer `CURL_READFUNC_PAUSE`, so curl stops asking and the
//     socket goes quiet instead of spinning.
//
// REFUTED — do not "fix" the compaction. The obvious objection to the single
// vector below is that `pull` periodically `erase`s the consumed prefix, which
// memmoves the live tail, and that a std::deque of per-push segments would pop
// drained data in O(1) with no compaction at all. That was implemented and
// A/B-measured against this design, same harness, alternating runs, at the
// engine's real parameters (8 MiB through the 1 MiB cap, 64 KiB pushes, 64 KiB
// pulls = curl's default UPLOAD_BUFFERSIZE):
//
//     this design    0.55 0.57 0.58 0.62 0.63 ms
//     segment deque  1.12 1.12 1.16 1.25 1.36 ms   ~2x SLOWER
//
// The compaction is cheaper than what replacing it costs. This buffer is
// allocated once, grows to the cap, and then stays warm for the whole transfer,
// so a memmove inside it is a hot-cache operation. A segment queue instead does
// a malloc and a free of a fresh multi-kilobyte block per push — allocator
// traffic that dwarfs the copy it was meant to save.
//
// A standalone prototype of the deque suggested a 7x WIN, which is why this note
// exists: it reused one source buffer, so every allocation was served hot from
// the same free list and the malloc cost vanished. Benchmark the real class
// through this header, never a sketch of it.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace nitrohttp {

class BodyPipe {
 public:
  /// `softCapacityBytes` is advisory: `push` never rejects data (the Dart side
  /// has already committed the bytes), it just reports the depth so the runner
  /// can throttle. Exceeding it is a signal, not an error.
  explicit BodyPipe(size_t softCapacityBytes);

  BodyPipe(const BodyPipe&) = delete;
  BodyPipe& operator=(const BodyPipe&) = delete;

  /// Appends `n` bytes. Returns the total bytes now buffered.
  size_t push(const uint8_t* data, size_t n);

  /// Copies at most `n` bytes into `dst`. Returns bytes copied; 0 means either
  /// EOF (see `eof()`) or "nothing yet, pause the transfer".
  size_t pull(uint8_t* dst, size_t n);

  /// Marks a clean end of stream. `pull` drains the remainder then reports EOF.
  void finish();

  /// Aborts the upload. `pull` reports failure, which becomes a `sendFailure`
  /// on the response.
  void fail(std::string message);

  bool finished() const;
  bool failed() const;
  std::string failureMessage() const;

  /// True once `finish()` was called AND the buffer is drained.
  bool atEof() const;

  size_t buffered() const;
  size_t softCapacity() const { return softCapacity_; }

  /// True when the depth crossed below half the soft capacity since the last
  /// call — the trigger for emitting one `uploadDrain` event rather than one
  /// per `pull`.
  bool consumeDrainSignal();

 private:
  mutable std::mutex mtx_;
  std::vector<uint8_t> buf_;
  size_t readPos_ = 0;
  size_t softCapacity_;
  bool finished_ = false;
  bool failed_ = false;
  bool wasAboveWatermark_ = false;
  bool drainPending_ = false;
  std::string failure_;
};

}  // namespace nitrohttp
