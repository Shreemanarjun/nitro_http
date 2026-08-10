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
