// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — bounded upload ring with a pause/resume protocol.
//
// Streamed request bodies flow Dart → native on the Dart isolate thread — by
// `uploadWrite`, straight into this buffer, or by `feedUploadChunk`, copied in
// — while curl's `READFUNCTION` drains on the engine loop thread. The ring is
// the only synchronisation point between them.
//
// Backpressure is two-sided and honest:
//   • Dart side: `push` returns the currently buffered byte count, and the
//     runner pauses its source stream above a high-water mark, resuming on the
//     `uploadDrain` event.
//   • curl side: `pull` returning 0 while neither EOF nor failure is set makes
//     `READFUNCTION` answer `CURL_READFUNC_PAUSE`, so curl stops asking and the
//     socket goes quiet instead of spinning.
//
// DIRECT WRITE. The producer has two ways in. `push` copies bytes it is handed.
// `reserve`/`commit` instead lend the producer a region of the buffer to fill
// itself, which is how the Dart runner writes a chunk straight into native
// memory: no staging copy, no per-chunk allocation. The lifetime rule that
// makes lending safe: only the PRODUCER ever moves or grows the buffer (inside
// `push`/`reserve`), `pull` only reads below the committed end, and nothing
// frees it while a reservation is open.
//
// NEITHER SIDE COPIES UNDER THE LOCK. The mutex guards positions, not bytes:
// the producer fills its reservation with the lock released, and `pull` copies
// out with the lock released too, having marked a read in flight. A producer
// that has to make room while a read is in flight does not shift bytes under
// the reader; it moves the unread part to another buffer and leaves the old
// one alive until the read lets go of it. The engine additionally pins the
// pipe for as long as a writer exists (see `CurlEngine::uploadWrite`), so a
// transfer that ends mid-upload cannot take the memory away from under it.
//
// ONE FLAT BUFFER, not a queue of per-push segments. A segment queue does a
// malloc and a free per push, which costs more than the occasional compaction
// of a buffer that stays warm for the whole transfer.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
namespace nitrohttp {

/// Depth at which a streamed body asks Dart to pause, when its length is not
/// known — and the depth the copying `feedUpload` path always uses, because the
/// runner's own threshold for that path is this same megabyte.
constexpr size_t kUploadPipeSoftCapBytes = 1024 * 1024;

/// Ceiling on that depth for a direct-written body whose length is declared.
constexpr size_t kUploadPipeMaxCapBytes = 8 * 1024 * 1024;

/// How deep a direct writer may fill the pipe before pausing its source, given
/// the declared length (`< 0` = unknown).
///
/// A body that fits under the ceiling is taken whole: the depth is its length,
/// so the producer is never paused and the buffer never has to make room. A
/// longer body streams through a pipe of the ceiling's depth, and one of
/// unknown length through the default megabyte; both pay for pauses and
/// compactions. The ceiling bounds what one in-flight upload can hold in native
/// memory when its source outruns the network.
inline size_t uploadPipeCapacityFor(int64_t contentLength) {
  if (contentLength < 0) return kUploadPipeSoftCapBytes;
  const auto length = static_cast<size_t>(contentLength);
  if (length <= kUploadPipeSoftCapBytes) return kUploadPipeSoftCapBytes;
  return length < kUploadPipeMaxCapBytes ? length : kUploadPipeMaxCapBytes;
}

/// Frees the buffer kept warm between uploads once nothing has used it for a
/// few seconds (`force` skips the wait). The engine loop calls this when it
/// wakes with nothing to do.
void releaseIdleUploadSpare(bool force = false);

/// Bytes currently held in that spare buffer. For tests and diagnostics.
size_t uploadSpareBytes();

class BodyPipe {
 public:
  /// `softCapacityBytes` is advisory: the pipe never rejects data (the Dart side
  /// has already committed the bytes), it just reports the depth so the runner
  /// can throttle. Exceeding it is a signal, not an error.
  explicit BodyPipe(size_t softCapacityBytes);
  ~BodyPipe();
  BodyPipe(const BodyPipe&) = delete;
  BodyPipe& operator=(const BodyPipe&) = delete;

  /// Appends `n` bytes. Returns the total bytes now buffered.
  size_t push(const uint8_t* data, size_t n);

  /// Lends the producer `n` writable bytes at the tail and returns where they
  /// start, or null once the stream has finished, failed or lost its reader.
  /// The region stays put until the producer's next `reserve`/`push`.
  uint8_t* reserve(size_t n);

  /// Publishes the first `n` bytes of the open reservation and closes it.
  /// Returns the total bytes now buffered.
  size_t commit(size_t n);

  /// What one direct-write step reports back to the producer.
  struct Exchange {
    uint8_t* region = nullptr;  ///< next writable region, null once closed
    size_t buffered = 0;        ///< depth after the commit
    size_t softCapacity = 0;    ///< depth at which the producer should pause
    bool readerStarved = false; ///< a `pull` came up empty since the last step
  };

  /// `commit(commitBytes)` then `reserve(reserveBytes)` under a single lock —
  /// the whole per-chunk cost of a direct writer. `readerStarved` is how the
  /// engine knows whether the loop thread needs waking at all: it is recorded
  /// by `pull` and cleared here under the same lock, so a writer that stays
  /// ahead of curl never pays for a wake-up nobody is waiting on, and one that
  /// falls behind can never miss the starvation it has to answer.
  Exchange exchange(size_t commitBytes, size_t reserveBytes);

  /// The reader is gone (the transfer ended). `reserve` answers null from here
  /// on, so a producer that is still running stops instead of filling a buffer
  /// nobody will drain. An open reservation remains valid memory.
  void closeProducer();

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
  size_t softCapacity() const;
  /// Raised by a direct writer, which buffers cheaply enough to run deeper than
  /// the copying path. See `uploadPipeCapacityFor`.
  void setSoftCapacity(size_t bytes);
  /// True when the depth came back down to half the soft capacity since the
  /// last call — the trigger for emitting one `uploadDrain` event rather than
  /// one per `pull`. Landing exactly on the mark counts: a reader that takes
  /// half the pipe at a time must be heard while the other half is still there,
  /// not once it has taken that too.
  bool consumeDrainSignal();

 private:
  /// Guarantees `n` free bytes at the tail, reclaiming the consumed prefix
  /// before growing. Producer side only. False on allocation failure.
  bool makeRoomLocked(size_t n);
  size_t commitLocked(size_t n);
  uint8_t* reserveLocked(size_t n);
  size_t noteDepthLocked();
  void failLocked(std::string message);
  void releaseBufferLocked();

  mutable std::mutex mtx_;
  std::unique_ptr<uint8_t[]> data_;
  size_t capacity_ = 0;
  size_t size_ = 0;      // committed end
  size_t readPos_ = 0;
  size_t reserved_ = 0;  // bytes lent to the producer; 0 = no reservation open
  /// A `pull` is copying out of `data_` (or, after the producer relocated,
  /// out of `retired_`) with the lock released.
  bool reading_ = false;
  /// The buffer a read in flight is still copying from, kept alive after the
  /// producer moved on to another one.
  std::unique_ptr<uint8_t[]> retired_;
  size_t retiredCapacity_ = 0;
  size_t softCapacity_;
  bool finished_ = false;
  bool failed_ = false;
  bool producerClosed_ = false;
  bool readerStarved_ = false;
  bool wasAboveWatermark_ = false;
  bool drainPending_ = false;
  std::string failure_;
};
}  // namespace nitrohttp
