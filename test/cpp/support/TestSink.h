// Test doubles for the engine's two Dart seams.
//
// `StreamSink` and `DartPost` are the ONLY places the engine touches Dart. Fake
// them and the whole engine — event loop, curl, cache, WebSockets — runs inside
// a plain C++ binary, with the exact bytes it would have posted available for
// assertions.
#pragma once

#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "ChunkArena.h"
#include "Common.h"
#include "DartPost.h"
#include "Wire.h"

namespace nitrohttp::test {

/// One `emit_chunks` call, with the payload copied out immediately — exactly
/// what the Dart runner does, and for the same reason.
struct CapturedChunk {
  int64_t requestId = 0;
  int64_t kind = 0;
  int64_t aux = 0;
  std::vector<uint8_t> bytes;
};

struct CapturedEvent {
  RawEvent value{};
};

struct CapturedFrame {
  int64_t socketId = 0;
  int64_t opcode = 0;
  int64_t flags = 0;
  std::vector<uint8_t> payload;
};

/// One `Dart_PostCObject_DL` a native-async method would have made. The blob is
/// decoded eagerly so a test can assert on the record, not on a pointer.
struct CapturedPost {
  int64_t port = 0;
  std::vector<uint8_t> payload;  ///< record payload, length prefix stripped
};

/// Process-global capture buffers. Global because the seams are.
class Captures {
 public:
  static Captures& instance();

  void addChunk(CapturedChunk chunk);
  void addEvent(CapturedEvent event);
  void addFrame(CapturedFrame frame);
  void addPost(CapturedPost post);

  std::vector<CapturedChunk> chunks() const;
  std::vector<CapturedEvent> events() const;
  std::vector<CapturedFrame> frames() const;
  std::vector<CapturedPost> posts() const;

  /// Blocks until at least `count` posts have arrived, or the deadline passes.
  /// Returns whether the count was reached. Every native-async call completes
  /// exactly once, so a test waits on the post rather than sleeping.
  bool waitForPosts(size_t count, int timeoutMs = 15000);
  bool waitForChunks(size_t count, int timeoutMs = 15000);
  bool waitForFrames(size_t count, int timeoutMs = 15000);

  /// Simulates a dead Dart port: subsequent posts and emits are reported as
  /// failed, which is what a hot restart looks like to the engine.
  void setPortAlive(bool alive);
  bool portAlive() const;

  void clear();

  /// Decodes every captured post as `RawResponse`.
  std::vector<RawResponse> responses() const;
  std::vector<RawResponseHead> heads() const;
  std::vector<RawWsHandshake> handshakes() const;

 private:
  mutable std::mutex mtx_;
  std::vector<CapturedChunk> chunks_;
  std::vector<CapturedEvent> events_;
  std::vector<CapturedFrame> frames_;
  std::vector<CapturedPost> posts_;
  bool portAlive_ = true;
};

/// Installs the fake sink and post hook. Call once, from `main`.
void installTestSeams();

/// Convenience: a `RawClientConfig` with sane defaults for tests — verification
/// on, platform roots, no proxy, compression on, cache off.
RawClientConfig defaultClientConfig();

/// Convenience: a GET request record.
RawRequest getRequest(int64_t requestId, const std::string& url);

/// Convenience: `RawRequestOptions` with every field at its inherit sentinel.
RawRequestOptions defaultOptions();

}  // namespace nitrohttp::test
