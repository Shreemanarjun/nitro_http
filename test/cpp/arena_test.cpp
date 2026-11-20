// ─────────────────────────────────────────────────────────────────────────────
// Payload lifetime: ChunkArena, BodyPipe, DeferredPayloads.
//
// This is the bug class the whole credit protocol exists to prevent — a chunk
// freed while Dart still holds a view of it, or never freed at all. Every test
// here allocates real blobs and checks the accounting to the byte, so running
// the suite under AddressSanitizer turns a lifetime mistake into a hard failure
// rather than a rare crash in someone's app.
// ─────────────────────────────────────────────────────────────────────────────

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "BodyPipe.h"
#include "ChunkArena.h"
#include "DeferredPayloads.h"

using namespace nitrohttp;

namespace {

Blob mkBlob(size_t n, uint8_t fill) {
  std::vector<uint8_t> src(n, fill);
  return Blob::copy(src.data(), src.size());
}

}  // namespace

// ─── ChunkArena ──────────────────────────────────────────────────────────────

TEST(ChunkArena, AckFreesAPrefixAndOnlyAPrefix) {
  ChunkArena arena;
  const size_t sizes[5] = {16, 32, 64, 128, 256};
  for (int64_t seq = 0; seq < 5; ++seq) {
    arena.track(seq, mkBlob(sizes[seq], static_cast<uint8_t>('a' + seq)));
  }
  EXPECT_EQ(arena.liveCount(), 5u);
  EXPECT_EQ(arena.liveBytes(), 16u + 32u + 64u + 128u + 256u);

  arena.ack(3);  // frees seq 0, 1, 2
  EXPECT_EQ(arena.liveCount(), 2u);
  EXPECT_EQ(arena.liveBytes(), 128u + 256u);

  // What is left is the SUFFIX, in emission order.
  const auto rest = arena.drain();
  ASSERT_EQ(rest.size(), 2u);
  EXPECT_EQ(rest[0].first, 3);
  EXPECT_EQ(rest[1].first, 4);
  for (auto entry : rest) entry.second.release();
}

TEST(ChunkArena, RepeatedAckIsANoOp) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 4; ++seq) arena.track(seq, mkBlob(10, 0x11));
  arena.ack(2);
  EXPECT_EQ(arena.liveCount(), 2u);
  arena.ack(2);
  arena.ack(2);
  EXPECT_EQ(arena.liveCount(), 2u);
  EXPECT_EQ(arena.liveBytes(), 20u);
}

TEST(ChunkArena, AckBelowTheFrontFreesNothing) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 4; ++seq) arena.track(seq, mkBlob(10, 0x22));
  arena.ack(3);
  ASSERT_EQ(arena.liveCount(), 1u);
  // A stale ack that arrives out of order must not double-free the prefix it
  // already released.
  arena.ack(1);
  arena.ack(0);
  EXPECT_EQ(arena.liveCount(), 1u);
  EXPECT_EQ(arena.liveBytes(), 10u);
}

TEST(ChunkArena, AckBeyondEverythingEmptiesTheArena) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 4; ++seq) arena.track(seq, mkBlob(10, 0x33));
  arena.ack(1000);
  EXPECT_EQ(arena.liveCount(), 0u);
  EXPECT_EQ(arena.liveBytes(), 0u);
}

TEST(ChunkArena, ZeroLengthPayloadsAreNotTracked) {
  ChunkArena arena;
  arena.track(0, Blob{});
  arena.track(1, Blob{nullptr, 0});
  EXPECT_EQ(arena.liveCount(), 0u)
      << "a zero-length emit owns nothing; tracking it would make ack free a "
         "pointer it never allocated";
  EXPECT_EQ(arena.liveBytes(), 0u);

  // A real payload after the empty ones still lands, with its own sequence.
  arena.track(2, mkBlob(8, 0x44));
  EXPECT_EQ(arena.liveCount(), 1u);
  EXPECT_EQ(arena.liveBytes(), 8u);
  arena.ack(3);
  EXPECT_EQ(arena.liveCount(), 0u);
}

TEST(ChunkArena, DrainHandsOverInEmissionOrderAndEmpties) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 6; ++seq) {
    arena.track(seq, mkBlob(4, static_cast<uint8_t>(seq)));
  }
  auto taken = arena.drain();
  ASSERT_EQ(taken.size(), 6u);
  for (size_t i = 0; i < taken.size(); ++i) {
    EXPECT_EQ(taken[i].first, static_cast<int64_t>(i));
    ASSERT_EQ(taken[i].second.size, 4u);
    EXPECT_EQ(taken[i].second.data[0], static_cast<uint8_t>(i));
  }
  EXPECT_EQ(arena.liveCount(), 0u);
  EXPECT_EQ(arena.liveBytes(), 0u);

  // Ownership moved to us: the arena's destructor must not touch these.
  for (auto entry : taken) entry.second.release();
}

TEST(ChunkArena, DrainOnAnEmptyArenaIsEmpty) {
  ChunkArena arena;
  EXPECT_TRUE(arena.drain().empty());
}

TEST(ChunkArena, ReleaseAllFreesEverythingAndResetsAccounting) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 3; ++seq) arena.track(seq, mkBlob(100, 0x55));
  ASSERT_EQ(arena.liveBytes(), 300u);
  arena.releaseAll();
  EXPECT_EQ(arena.liveCount(), 0u);
  EXPECT_EQ(arena.liveBytes(), 0u);
  arena.releaseAll();  // idempotent
  EXPECT_EQ(arena.liveCount(), 0u);
}

TEST(ChunkArena, DestructorFreesWhatIsStillTracked) {
  // Correctness here is only visible under a sanitizer; the assertion is that
  // the accounting was live right up to the destructor.
  ChunkArena arena;
  for (int64_t seq = 0; seq < 32; ++seq) arena.track(seq, mkBlob(1024, 0x66));
  EXPECT_EQ(arena.liveBytes(), 32u * 1024u);
}

// ─── BodyPipe ────────────────────────────────────────────────────────────────

TEST(BodyPipe, PushReturnsTheCurrentDepth) {
  BodyPipe pipe(1024);
  const std::vector<uint8_t> data(100, 0x77);
  EXPECT_EQ(pipe.push(data.data(), 100), 100u);
  EXPECT_EQ(pipe.push(data.data(), 100), 200u);
  EXPECT_EQ(pipe.buffered(), 200u);
  EXPECT_EQ(pipe.push(nullptr, 0), 200u);
}

TEST(BodyPipe, PullReadsPartiallyAndInOrder) {
  BodyPipe pipe(1024);
  std::vector<uint8_t> src(10);
  for (size_t i = 0; i < src.size(); ++i) src[i] = static_cast<uint8_t>(i);
  pipe.push(src.data(), src.size());

  uint8_t dst[4] = {};
  EXPECT_EQ(pipe.pull(dst, 4), 4u);
  EXPECT_EQ(std::memcmp(dst, src.data(), 4), 0);
  EXPECT_EQ(pipe.buffered(), 6u);

  EXPECT_EQ(pipe.pull(dst, 4), 4u);
  EXPECT_EQ(std::memcmp(dst, src.data() + 4, 4), 0);

  // The last read is short, not padded.
  EXPECT_EQ(pipe.pull(dst, 4), 2u);
  EXPECT_EQ(std::memcmp(dst, src.data() + 8, 2), 0);
  EXPECT_EQ(pipe.buffered(), 0u);
}

TEST(BodyPipe, PullReturningZeroMeansPauseBeforeEofAndEofAfterFinish) {
  BodyPipe pipe(1024);
  uint8_t dst[8] = {};

  // Nothing buffered, stream still open: 0 is the pause signal.
  EXPECT_EQ(pipe.pull(dst, sizeof(dst)), 0u);
  EXPECT_FALSE(pipe.finished());
  EXPECT_FALSE(pipe.atEof())
      << "0 before finish() must NOT look like end of stream";

  const std::vector<uint8_t> data(3, 0x88);
  pipe.push(data.data(), data.size());
  pipe.finish();
  EXPECT_TRUE(pipe.finished());
  EXPECT_FALSE(pipe.atEof()) << "finish() still drains the remainder first";

  EXPECT_EQ(pipe.pull(dst, sizeof(dst)), 3u);
  EXPECT_TRUE(pipe.atEof());
  EXPECT_EQ(pipe.pull(dst, sizeof(dst)), 0u);
  EXPECT_TRUE(pipe.atEof()) << "now 0 is the EOF signal";
}

TEST(BodyPipe, PushAfterFinishIsDropped) {
  BodyPipe pipe(1024);
  const std::vector<uint8_t> data(4, 0x99);
  pipe.push(data.data(), data.size());
  pipe.finish();
  EXPECT_EQ(pipe.push(data.data(), data.size()), 4u)
      << "late bytes must not be appended to a closed body";
  EXPECT_EQ(pipe.buffered(), 4u);
}

TEST(BodyPipe, ZeroSizedOrNullPullIsRefused) {
  BodyPipe pipe(1024);
  const std::vector<uint8_t> data(4, 0xaa);
  pipe.push(data.data(), data.size());
  uint8_t dst[4] = {};
  EXPECT_EQ(pipe.pull(nullptr, 4), 0u);
  EXPECT_EQ(pipe.pull(dst, 0), 0u);
  EXPECT_EQ(pipe.buffered(), 4u);
}

TEST(BodyPipe, DrainSignalFiresOncePerCrossingNotPerPull) {
  BodyPipe pipe(1000);  // watermark = 500
  const std::vector<uint8_t> data(600, 0xbb);
  ASSERT_EQ(pipe.push(data.data(), data.size()), 600u);
  EXPECT_FALSE(pipe.consumeDrainSignal()) << "no crossing yet";

  std::vector<uint8_t> dst(200);
  ASSERT_EQ(pipe.pull(dst.data(), 200), 200u);  // depth 400 → crossed down
  EXPECT_TRUE(pipe.consumeDrainSignal());
  EXPECT_FALSE(pipe.consumeDrainSignal()) << "consumed exactly once";

  // Draining further, still below the watermark: no new signal.
  ASSERT_EQ(pipe.pull(dst.data(), 200), 200u);
  ASSERT_EQ(pipe.pull(dst.data(), 200), 200u);
  EXPECT_FALSE(pipe.consumeDrainSignal());

  // Re-arm by going back above the watermark, then cross down again.
  ASSERT_EQ(pipe.push(data.data(), data.size()), 600u);
  EXPECT_FALSE(pipe.consumeDrainSignal());
  ASSERT_EQ(pipe.pull(dst.data(), 200), 200u);
  EXPECT_TRUE(pipe.consumeDrainSignal());
}

TEST(BodyPipe, FailStopsDeliveryAndReportsTheMessage) {
  BodyPipe pipe(1024);
  const std::vector<uint8_t> data(64, 0xcc);
  pipe.push(data.data(), data.size());
  ASSERT_EQ(pipe.buffered(), 64u);

  pipe.fail("source stream errored");
  EXPECT_TRUE(pipe.failed());
  EXPECT_EQ(pipe.failureMessage(), "source stream errored");
  EXPECT_EQ(pipe.buffered(), 0u);

  uint8_t dst[64] = {};
  EXPECT_EQ(pipe.pull(dst, sizeof(dst)), 0u)
      << "sending a truncated body is worse than aborting the transfer";
  EXPECT_EQ(pipe.push(data.data(), data.size()), 0u);
  EXPECT_EQ(pipe.buffered(), 0u);
}

TEST(BodyPipe, AReservationIsWrittenInPlaceAndOnlyCommittedBytesAreRead) {
  BodyPipe pipe(1024);
  uint8_t* region = pipe.reserve(8);
  ASSERT_NE(region, nullptr);
  std::memcpy(region, "abcdefgh", 8);
  EXPECT_EQ(pipe.buffered(), 0u) << "nothing is visible until it is committed";

  EXPECT_EQ(pipe.commit(5), 5u);
  uint8_t out[16] = {0};
  EXPECT_EQ(pipe.pull(out, sizeof out), 5u);
  EXPECT_EQ(std::string(reinterpret_cast<char*>(out), 5), "abcde");
}

TEST(BodyPipe, CommitNeverPublishesMoreThanWasLent) {
  BodyPipe pipe(1024);
  ASSERT_NE(pipe.reserve(4), nullptr);
  EXPECT_EQ(pipe.commit(400), 4u);
  // A commit with no reservation open publishes nothing at all.
  EXPECT_EQ(pipe.commit(8), 4u);
}

TEST(BodyPipe, TheReaderNeverMovesTheBufferUnderAnOpenReservation) {
  // The producer holds a raw pointer between `reserve` and `commit`, with no
  // lock, while curl drains on another thread. Draining everything must leave
  // that pointer exactly where it was.
  BodyPipe pipe(1024);
  const std::string first(300, 'a');
  pipe.push(reinterpret_cast<const uint8_t*>(first.data()), first.size());

  uint8_t* region = pipe.reserve(200);
  ASSERT_NE(region, nullptr);
  std::vector<uint8_t> sink(1024);
  EXPECT_EQ(pipe.pull(sink.data(), sink.size()), 300u);  // emptied

  std::memset(region, 'b', 200);
  EXPECT_EQ(pipe.commit(200), 200u);
  EXPECT_EQ(pipe.pull(sink.data(), sink.size()), 200u);
  EXPECT_EQ(std::string(reinterpret_cast<char*>(sink.data()), 200),
            std::string(200, 'b'));
}

TEST(BodyPipe, ReservingKeepsWhatIsUnreadWhenItHasToMakeRoom) {
  // Room is made by reclaiming the consumed prefix, then by growing; either
  // way the bytes curl has not taken yet must come out intact and in order.
  BodyPipe pipe(64);
  std::string expected;
  std::string taken;
  std::vector<uint8_t> sink(4096);
  for (int round = 0; round < 200; ++round) {
    const size_t n = 17 + static_cast<size_t>(round % 23) * 31;  // up to ~700
    uint8_t* region = pipe.reserve(n);
    ASSERT_NE(region, nullptr);
    for (size_t i = 0; i < n; ++i) {
      region[i] = static_cast<uint8_t>((round * 7 + i) & 0xff);
      expected.push_back(static_cast<char>(region[i]));
    }
    pipe.commit(n);
    // Drain an awkward amount so a tail is usually left behind.
    const size_t got = pipe.pull(sink.data(), 1 + static_cast<size_t>(round % 5) * 97);
    taken.append(reinterpret_cast<char*>(sink.data()), got);
  }
  for (;;) {
    const size_t got = pipe.pull(sink.data(), sink.size());
    if (got == 0) break;
    taken.append(reinterpret_cast<char*>(sink.data()), got);
  }
  EXPECT_EQ(taken, expected);
}

TEST(BodyPipe, AChunkLargerThanTheSoftCapacityIsStillTaken) {
  // The capacity is advisory: a source is free to produce one enormous chunk,
  // and the pipe takes it whole rather than splitting it across drain events.
  BodyPipe pipe(1024);
  const size_t n = 256 * 1024;
  uint8_t* region = pipe.reserve(n);
  ASSERT_NE(region, nullptr);
  std::memset(region, 0x5a, n);
  EXPECT_EQ(pipe.commit(n), n);
}

TEST(BodyPipe, ReserveIsRefusedOnceTheStreamCanTakeNoMore) {
  {
    BodyPipe pipe(1024);
    pipe.finish();
    EXPECT_EQ(pipe.reserve(8), nullptr);
  }
  {
    BodyPipe pipe(1024);
    pipe.fail("boom");
    EXPECT_EQ(pipe.reserve(8), nullptr);
  }
  {
    // The transfer ended while the producer was still going.
    BodyPipe pipe(1024);
    uint8_t* region = pipe.reserve(8);
    ASSERT_NE(region, nullptr);
    pipe.closeProducer();
    std::memset(region, 1, 8);  // still valid memory: must not crash under ASan
    pipe.commit(8);
    EXPECT_EQ(pipe.reserve(8), nullptr);
  }
}

TEST(BodyPipe, FailingUnderAnOpenReservationLeavesItsMemoryAlone) {
  BodyPipe pipe(1024);
  uint8_t* region = pipe.reserve(64);
  ASSERT_NE(region, nullptr);
  pipe.fail("aborted");
  std::memset(region, 2, 64);  // the producer may be mid-write: ASan checks this
  EXPECT_EQ(pipe.commit(64), 0u);
  uint8_t out[8];
  EXPECT_EQ(pipe.pull(out, sizeof out), 0u);
}

TEST(BodyPipe, ExchangeReportsAStarvedReaderExactlyOnce) {
  BodyPipe pipe(1024);
  uint8_t sink[64];

  BodyPipe::Exchange step = pipe.exchange(0, 16);
  ASSERT_NE(step.region, nullptr);
  EXPECT_FALSE(step.readerStarved) << "nobody has asked for data yet";

  EXPECT_EQ(pipe.pull(sink, sizeof sink), 0u);  // curl comes up empty
  std::memset(step.region, 1, 16);
  step = pipe.exchange(16, 16);
  EXPECT_TRUE(step.readerStarved) << "this commit has to wake the reader";
  EXPECT_EQ(step.buffered, 16u);
  EXPECT_EQ(step.softCapacity, 1024u);

  step = pipe.exchange(0, 16);
  EXPECT_FALSE(step.readerStarved) << "reported once, not on every step";

  // A read that found something is not a starvation.
  EXPECT_EQ(pipe.pull(sink, sizeof sink), 16u);
  step = pipe.exchange(0, 16);
  EXPECT_FALSE(step.readerStarved);
}

TEST(BodyPipe, APullLargerThanOneSliceStillReturnsEverythingInOrder) {
  // The copy is done a slice at a time so the lock is never held for long;
  // the caller must not be able to tell.
  BodyPipe pipe(4 * 1024 * 1024);
  std::string expected;
  for (int i = 0; i < 700 * 1024; ++i) {
    expected.push_back(static_cast<char>((i * 13 + 5) & 0xff));
  }
  pipe.push(reinterpret_cast<const uint8_t*>(expected.data()), expected.size());
  std::vector<uint8_t> sink(1024 * 1024);
  ASSERT_EQ(pipe.pull(sink.data(), sink.size()), expected.size());
  EXPECT_EQ(std::string(reinterpret_cast<char*>(sink.data()), expected.size()),
            expected);
}

TEST(BodyPipe, TwoThreadsNeverSeeATornOrReorderedByte) {
  // Neither side copies under the lock, so the producer may make room while a
  // read is still copying. This drives both producer APIs against a reader on
  // another thread, with a buffer small enough that relocation is constant,
  // and checks every byte arrives once and in order. Under ASan it is also the
  // test for the buffer hand-over: nothing freed while it is being read.
  constexpr size_t kTotal = 24 * 1024 * 1024;
  BodyPipe pipe(64 * 1024);

  std::thread reader([&pipe] {
    std::vector<uint8_t> sink(300 * 1024);
    size_t seen = 0;
    unsigned step = 1;
    while (seen < kTotal) {
      step = step * 1103515245u + 12345u;
      const size_t want = 1 + (step >> 8) % sink.size();
      const size_t got = pipe.pull(sink.data(), want);
      for (size_t i = 0; i < got; ++i) {
        if (sink[i] != static_cast<uint8_t>((seen + i) * 131u >> 3)) {
          ADD_FAILURE() << "byte " << (seen + i) << " is wrong";
          seen = kTotal;  // stop
          return;
        }
      }
      seen += got;
      if (got == 0) std::this_thread::yield();
    }
  });

  size_t sent = 0;
  unsigned step = 7;
  while (sent < kTotal) {
    step = step * 1664525u + 1013904223u;
    const size_t n = std::min<size_t>(kTotal - sent, 1 + (step >> 9) % (90 * 1024));
    if ((step >> 4) % 3 == 0) {
      std::vector<uint8_t> block(n);
      for (size_t i = 0; i < n; ++i) {
        block[i] = static_cast<uint8_t>((sent + i) * 131u >> 3);
      }
      pipe.push(block.data(), n);
    } else {
      uint8_t* region = pipe.reserve(n);
      ASSERT_NE(region, nullptr);
      for (size_t i = 0; i < n; ++i) {
        region[i] = static_cast<uint8_t>((sent + i) * 131u >> 3);
      }
      pipe.commit(n);
    }
    sent += n;
    // Keep the depth bounded the way the runner does, so the buffer cycles.
    while (pipe.buffered() > 256 * 1024) std::this_thread::yield();
  }
  reader.join();
  EXPECT_EQ(pipe.buffered(), 0u);
}

TEST(BodyPipe, FailingWhileAReadIsInFlightHandsNothingOver) {
  // `fail` releases the buffer, and a read may be copying out of it on the
  // other thread at that moment.
  for (int round = 0; round < 200; ++round) {
    BodyPipe pipe(1024 * 1024);
    std::vector<uint8_t> block(512 * 1024, 0x33);
    pipe.push(block.data(), block.size());
    std::thread reader([&pipe] {
      std::vector<uint8_t> sink(512 * 1024);
      (void)pipe.pull(sink.data(), sink.size());
    });
    pipe.fail("aborted mid-read");
    reader.join();
    uint8_t out[8];
    EXPECT_EQ(pipe.pull(out, sizeof out), 0u);
  }
}

TEST(BodyPipe, LandingExactlyOnTheWatermarkIsADrain) {
  // curl reads half the pipe at a time. If "half gone" only counted once the
  // depth was strictly below half, a reader taking exact halves would not be
  // heard until it had taken the second half too — with nothing left to send
  // while Dart wakes up.
  BodyPipe pipe(1024);
  std::vector<uint8_t> block(1024, 0xab);
  pipe.push(block.data(), 1024);  // full
  uint8_t sink[512];
  EXPECT_EQ(pipe.pull(sink, 512), 512u);  // exactly half left
  EXPECT_TRUE(pipe.consumeDrainSignal());
  EXPECT_FALSE(pipe.consumeDrainSignal()) << "once per crossing";

  // Sitting at the mark without having been above it is not a crossing.
  EXPECT_EQ(pipe.pull(sink, 512), 512u);
  EXPECT_FALSE(pipe.consumeDrainSignal());
  pipe.push(block.data(), 512);  // back up to the mark, not past it
  EXPECT_EQ(pipe.pull(sink, 100), 100u);
  EXPECT_FALSE(pipe.consumeDrainSignal());
}

TEST(BodyPipe, ABufferIsHandedOnToTheNextPipe) {
  // Not observable through the API by design; this pins the behaviour that
  // matters — a pipe built after another was destroyed still works, repeatedly,
  // and under ASan nothing is freed twice or used after the hand-over.
  for (int round = 0; round < 8; ++round) {
    BodyPipe pipe(64 * 1024);
    std::vector<uint8_t> block(48 * 1024, static_cast<uint8_t>(round));
    pipe.push(block.data(), block.size());
    std::vector<uint8_t> sink(block.size());
    ASSERT_EQ(pipe.pull(sink.data(), sink.size()), block.size());
    EXPECT_EQ(sink, block);
    if (round % 2 == 1) pipe.fail("exercise the release-on-failure path");
  }
}

TEST(BodyPipe, ABodyThatFitsItsPipeIsNeverMoved) {
  // The case the depth policy exists for: a body no longer than the pipe is
  // written into one buffer from start to finish, while curl reads behind it.
  // Each region must follow straight on from the last. If the buffer were
  // compacted, relocated or regrown on the way, it would not — and the upload
  // would be paying for a copy of itself.
  constexpr size_t kChunk = 64 * 1024;
  constexpr size_t kTotal = 2 * 1024 * 1024;
  BodyPipe pipe(kTotal);

  std::thread reader([&pipe] {
    std::vector<uint8_t> sink(256 * 1024);
    while (!pipe.atEof() && !pipe.failed()) {
      if (pipe.pull(sink.data(), sink.size()) == 0) std::this_thread::yield();
    }
  });

  BodyPipe::Exchange step = pipe.exchange(0, kChunk);
  const uint8_t* const base = step.region;
  bool contiguous = base != nullptr;
  for (size_t written = 0; contiguous && written < kTotal; written += kChunk) {
    contiguous = step.region == base + written;
    if (!contiguous) break;
    std::memset(step.region, 0x5a, kChunk);
    step = pipe.exchange(kChunk, kChunk);
  }
  // Ended either way, so a failure cannot leave the reader spinning.
  pipe.finish();
  reader.join();
  ASSERT_TRUE(contiguous);
}

TEST(BodyPipe, OvershootingTheDepthByAChunkGrowsByThatChunk) {
  // The runner stops once the depth is reached, which leaves it one chunk past
  // the mark with the next reservation still to come. The buffer grows by
  // that chunk rather than doubling, so it stays small enough to recycle.
  constexpr size_t kChunk = 64 * 1024;
  constexpr size_t kDepth = 1024 * 1024;
  releaseIdleUploadSpare(true);
  {
    BodyPipe pipe(kDepth);
    BodyPipe::Exchange step = pipe.exchange(0, kChunk);
    for (size_t written = 0; written < kDepth + kChunk; written += kChunk) {
      ASSERT_NE(step.region, nullptr);
      std::memset(step.region, 1, kChunk);
      step = pipe.exchange(kChunk, kChunk);  // nobody is reading
    }
    EXPECT_EQ(step.buffered, kDepth + kChunk);
  }
  // What the pipe left behind is the buffer it ended up with.
  EXPECT_EQ(uploadSpareBytes(), kDepth + 2 * kChunk);
  releaseIdleUploadSpare(true);
}

TEST(BodyPipe, TheSpareBufferIsReusedAndThenLetGo) {
  releaseIdleUploadSpare(true);
  ASSERT_EQ(uploadSpareBytes(), 0u);
  std::vector<uint8_t> block(48 * 1024, 7);
  {
    BodyPipe pipe(64 * 1024);
    pipe.push(block.data(), block.size());
  }
  const size_t kept = uploadSpareBytes();
  EXPECT_GT(kept, 0u);
  {
    BodyPipe pipe(64 * 1024);
    pipe.push(block.data(), block.size());
    EXPECT_EQ(uploadSpareBytes(), 0u) << "taken over, not allocated again";
  }
  EXPECT_EQ(uploadSpareBytes(), kept);

  // Parked a moment ago: an idle sweep leaves it for the next upload...
  releaseIdleUploadSpare();
  EXPECT_EQ(uploadSpareBytes(), kept);
  // ...and frees it once that upload is not coming.
  releaseIdleUploadSpare(true);
  EXPECT_EQ(uploadSpareBytes(), 0u);
}

TEST(BodyPipe, ADirectWritersDepthFollowsTheDeclaredLength) {
  EXPECT_EQ(uploadPipeCapacityFor(-1), kUploadPipeSoftCapBytes);
  EXPECT_EQ(uploadPipeCapacityFor(10), kUploadPipeSoftCapBytes);
  EXPECT_EQ(uploadPipeCapacityFor(3 * 1024 * 1024), 3u * 1024 * 1024);
  EXPECT_EQ(uploadPipeCapacityFor(int64_t{1} << 40), kUploadPipeMaxCapBytes);
}

TEST(BodyPipe, RaisingTheDepthMovesTheDrainMarkWithIt) {
  // A writer raises the depth after the pipe exists. The drain signal has to
  // follow, or the runner — which now pauses at the new depth — would wait for
  // a signal armed for the old one.
  BodyPipe pipe(1024);
  pipe.setSoftCapacity(4096);
  std::vector<uint8_t> block(4096, 1);
  pipe.push(block.data(), block.size());
  std::vector<uint8_t> sink(4096);
  EXPECT_EQ(pipe.pull(sink.data(), 1024), 1024u);  // 3072 left: above half
  EXPECT_FALSE(pipe.consumeDrainSignal());
  EXPECT_EQ(pipe.pull(sink.data(), 1024), 1024u);  // 2048 left: on the mark
  EXPECT_TRUE(pipe.consumeDrainSignal());
  EXPECT_EQ(pipe.softCapacity(), 4096u);
}

TEST(BodyPipe, DepthStaysBoundedOverAMegabyteOfTraffic) {
  // The buffer compacts its consumed prefix, so pushing far more than the soft
  // capacity through a small window must never let the live depth grow past
  // what is genuinely outstanding.
  BodyPipe pipe(64 * 1024);
  std::vector<uint8_t> block(4096);
  for (size_t i = 0; i < block.size(); ++i) {
    block[i] = static_cast<uint8_t>(i * 7);
  }
  std::vector<uint8_t> sink(4096);

  size_t pushed = 0;
  size_t pulled = 0;
  size_t maxDepth = 0;
  while (pushed < 1024u * 1024u) {
    pipe.push(block.data(), block.size());
    pushed += block.size();
    maxDepth = std::max(maxDepth, pipe.buffered());
    pulled += pipe.pull(sink.data(), sink.size());
  }
  while (pipe.buffered() > 0) pulled += pipe.pull(sink.data(), sink.size());

  EXPECT_EQ(pulled, pushed);
  EXPECT_LE(maxDepth, 8192u)
      << "one block outstanding at a time; anything larger means the consumed "
         "prefix is never dropped";
}

TEST(BodyPipe, ConcurrentProducerAndConsumerPreserveByteOrder) {
  constexpr size_t kTotal = 1024u * 1024u;
  constexpr size_t kBlock = 4096;
  BodyPipe pipe(64 * 1024);

  std::thread producer([&] {
    std::vector<uint8_t> block(kBlock);
    size_t sent = 0;
    while (sent < kTotal) {
      for (size_t i = 0; i < kBlock; ++i) {
        block[i] = static_cast<uint8_t>((sent + i) * 31 + 5);
      }
      // Honour the advertised backpressure the way the Dart runner does: push
      // once, then wait on the reported depth. Calling `push` again to re-test
      // the condition would append the same block a second time.
      if (pipe.push(block.data(), kBlock) > pipe.softCapacity()) {
        while (pipe.buffered() > pipe.softCapacity() / 2) {
          std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
      }
      sent += kBlock;
    }
    pipe.finish();
  });

  std::vector<uint8_t> received;
  received.reserve(kTotal);
  std::vector<uint8_t> dst(1024);
  while (!pipe.atEof()) {
    const size_t got = pipe.pull(dst.data(), dst.size());
    if (got == 0) {
      std::this_thread::sleep_for(std::chrono::microseconds(200));
      continue;
    }
    received.insert(received.end(), dst.begin(), dst.begin() + static_cast<std::ptrdiff_t>(got));
  }
  producer.join();

  ASSERT_EQ(received.size(), kTotal);
  for (size_t i = 0; i < kTotal; ++i) {
    ASSERT_EQ(received[i], static_cast<uint8_t>(i * 31 + 5))
        << "byte " << i << " arrived out of order";
  }
}

// ─── DeferredPayloads ────────────────────────────────────────────────────────

class DeferredPayloadsTest : public ::testing::Test {
 protected:
  void SetUp() override { DeferredPayloads::instance().dropEverything(); }
  void TearDown() override { DeferredPayloads::instance().dropEverything(); }
};

TEST_F(DeferredPayloadsTest, AdoptMovesAnArenasEntries) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 4; ++seq) arena.track(seq, mkBlob(50, 0xdd));
  ASSERT_EQ(arena.liveBytes(), 200u);

  DeferredPayloads& deferred = DeferredPayloads::instance();
  deferred.adopt(PayloadOwner::Request, 7, arena);

  EXPECT_EQ(arena.liveCount(), 0u) << "the arena no longer owns them";
  EXPECT_EQ(deferred.bucketCount(), 1u);
  EXPECT_EQ(deferred.liveBytes(), 200u);
}

TEST_F(DeferredPayloadsTest, AdoptingAnEmptyArenaCreatesNoBucket) {
  ChunkArena arena;
  DeferredPayloads& deferred = DeferredPayloads::instance();
  deferred.adopt(PayloadOwner::Request, 7, arena);
  EXPECT_EQ(deferred.bucketCount(), 0u)
      << "the common case — a consumer that kept up — must cost nothing";
}

TEST_F(DeferredPayloadsTest, AckReleasesAPrefixOfARetiredBucket) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 5; ++seq) arena.track(seq, mkBlob(100, 0xee));
  DeferredPayloads& deferred = DeferredPayloads::instance();
  deferred.adopt(PayloadOwner::Request, 3, arena);
  ASSERT_EQ(deferred.liveBytes(), 500u);

  deferred.ack(PayloadOwner::Request, 3, 2);
  EXPECT_EQ(deferred.liveBytes(), 300u);
  EXPECT_EQ(deferred.bucketCount(), 1u);

  // Acking everything drops the bucket entirely rather than leaving a husk.
  deferred.ack(PayloadOwner::Request, 3, 5);
  EXPECT_EQ(deferred.liveBytes(), 0u);
  EXPECT_EQ(deferred.bucketCount(), 0u);

  // An ack for an id with no bucket is harmless.
  deferred.ack(PayloadOwner::Request, 3, 99);
  EXPECT_EQ(deferred.bucketCount(), 0u);
}

TEST_F(DeferredPayloadsTest, ReleaseAllDropsTheWholeBucket) {
  ChunkArena arena;
  for (int64_t seq = 0; seq < 3; ++seq) arena.track(seq, mkBlob(256, 0x01));
  DeferredPayloads& deferred = DeferredPayloads::instance();
  deferred.adopt(PayloadOwner::Request, 12, arena);
  ASSERT_EQ(deferred.liveBytes(), 768u);

  deferred.releaseAll(PayloadOwner::Request, 12);
  EXPECT_EQ(deferred.bucketCount(), 0u);
  EXPECT_EQ(deferred.liveBytes(), 0u);
  deferred.releaseAll(PayloadOwner::Request, 12);  // idempotent
  EXPECT_EQ(deferred.bucketCount(), 0u);
}

TEST_F(DeferredPayloadsTest, RequestAndSocketIdsDoNotCollide) {
  DeferredPayloads& deferred = DeferredPayloads::instance();
  {
    ChunkArena requestArena;
    requestArena.track(0, mkBlob(10, 0x02));
    deferred.adopt(PayloadOwner::Request, 5, requestArena);
  }
  {
    ChunkArena socketArena;
    socketArena.track(0, mkBlob(20, 0x03));
    deferred.adopt(PayloadOwner::Socket, 5, socketArena);
  }
  ASSERT_EQ(deferred.bucketCount(), 2u);
  ASSERT_EQ(deferred.liveBytes(), 30u);

  deferred.releaseAll(PayloadOwner::Request, 5);
  EXPECT_EQ(deferred.bucketCount(), 1u);
  EXPECT_EQ(deferred.liveBytes(), 20u)
      << "the socket bucket with the same numeric id must survive";

  deferred.releaseAll(PayloadOwner::Socket, 5);
  EXPECT_EQ(deferred.bucketCount(), 0u);
}

TEST_F(DeferredPayloadsTest, ExceedingTheBucketCapEvictsOldestFirst) {
  DeferredPayloads& deferred = DeferredPayloads::instance();
  const size_t cap = DeferredPayloads::kMaxBuckets;
  for (size_t i = 0; i <= cap; ++i) {  // cap + 1 buckets
    ChunkArena arena;
    arena.track(0, mkBlob(1, static_cast<uint8_t>(i)));
    deferred.adopt(PayloadOwner::Request, static_cast<int64_t>(i), arena);
  }
  EXPECT_EQ(deferred.bucketCount(), cap);
  EXPECT_EQ(deferred.liveBytes(), cap);

  // Bucket 0 was adopted first, so it is the one that went.
  deferred.releaseAll(PayloadOwner::Request, 0);
  EXPECT_EQ(deferred.bucketCount(), cap)
      << "releasing the evicted id must be a no-op, not an underflow";
  deferred.releaseAll(PayloadOwner::Request, static_cast<int64_t>(cap));
  EXPECT_EQ(deferred.bucketCount(), cap - 1)
      << "the newest bucket is still present";
}

TEST_F(DeferredPayloadsTest, ExceedingTheByteCapEvicts) {
  DeferredPayloads& deferred = DeferredPayloads::instance();
  constexpr size_t kMiB = 1024u * 1024u;
  const size_t buckets = DeferredPayloads::kMaxBytes / kMiB + 1;  // 33
  for (size_t i = 0; i < buckets; ++i) {
    ChunkArena arena;
    arena.track(0, mkBlob(kMiB, static_cast<uint8_t>(i)));
    deferred.adopt(PayloadOwner::Request, static_cast<int64_t>(i), arena);
  }
  EXPECT_LE(deferred.liveBytes(), DeferredPayloads::kMaxBytes);
  EXPECT_EQ(deferred.liveBytes(), DeferredPayloads::kMaxBytes)
      << "eviction stops as soon as the cap is met, not one bucket later";
  EXPECT_EQ(deferred.bucketCount(), buckets - 1);
}

TEST_F(DeferredPayloadsTest, DropEverythingClearsEveryOwner) {
  DeferredPayloads& deferred = DeferredPayloads::instance();
  for (int64_t i = 0; i < 4; ++i) {
    ChunkArena a;
    a.track(0, mkBlob(64, 0x04));
    deferred.adopt(PayloadOwner::Request, i, a);
    ChunkArena b;
    b.track(0, mkBlob(64, 0x05));
    deferred.adopt(PayloadOwner::Socket, i, b);
  }
  ASSERT_EQ(deferred.bucketCount(), 8u);

  deferred.dropEverything();
  EXPECT_EQ(deferred.bucketCount(), 0u);
  EXPECT_EQ(deferred.liveBytes(), 0u);
}

TEST_F(DeferredPayloadsTest, AdoptingTwiceAppendsToTheSameBucket) {
  DeferredPayloads& deferred = DeferredPayloads::instance();
  {
    ChunkArena a;
    a.track(0, mkBlob(10, 0x06));
    a.track(1, mkBlob(10, 0x07));
    deferred.adopt(PayloadOwner::Request, 1, a);
  }
  {
    ChunkArena b;
    b.track(2, mkBlob(10, 0x08));
    deferred.adopt(PayloadOwner::Request, 1, b);
  }
  EXPECT_EQ(deferred.bucketCount(), 1u);
  EXPECT_EQ(deferred.liveBytes(), 30u);

  // Sequences stay ordered across adoptions, so an ack still frees a prefix.
  deferred.ack(PayloadOwner::Request, 1, 2);
  EXPECT_EQ(deferred.liveBytes(), 10u);
}

// ─── Payloads offered to Dart ────────────────────────────────────────────────

TEST(OfferedPayload, AnAdoptedBlockIsNotFreedByItsArena) {
  ChunkArena arena;
  Blob blob = mkBlob(64, 'x');
  uint8_t* block = blob.data;
  offerPayload(&blob);
  ASSERT_NE(blob.offer, 0u);
  arena.track(0, blob);

  EXPECT_EQ(adoptPayload(blob.offer), block);
  // The arena's entry is stale now. Under AddressSanitizer a free here is a
  // double free against the one below.
  arena.ack(1);
  EXPECT_EQ(arena.liveCount(), 0u);
  EXPECT_EQ(block[63], 'x');
  ::free(block);
}

TEST(OfferedPayload, AReleasedBlockCannotBeAdopted) {
  ChunkArena arena;
  Blob blob = mkBlob(64, 'y');
  offerPayload(&blob);
  const uint64_t offer = blob.offer;
  arena.track(0, blob);
  arena.releaseAll();

  EXPECT_EQ(adoptPayload(offer), nullptr);
}

TEST(OfferedPayload, AnOfferIsAdoptedOnce) {
  Blob blob = mkBlob(64, 'z');
  offerPayload(&blob);
  void* block = adoptPayload(blob.offer);
  ASSERT_NE(block, nullptr);
  EXPECT_EQ(adoptPayload(blob.offer), nullptr);
  ::free(block);
}
