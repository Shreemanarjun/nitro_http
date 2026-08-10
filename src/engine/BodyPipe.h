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
