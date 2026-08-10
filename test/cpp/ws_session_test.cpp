// ─────────────────────────────────────────────────────────────────────────────
// WsSession against a real WebSocket peer.
//
// `ws_frame_test.cpp` covers the framing in isolation; this file covers the
// part that needs a socket and a peer that can be told to misbehave. The
// behaviour that matters most is the closing handshake, because the failure
// mode is invisible from the framing layer: `close()` runs as a SYNCHRONOUS FFI
// call on the Dart isolate thread, so a peer that never mirrors the close must
// not be able to hold that thread for the handshake deadline — and the caller's
// `Future` must still be completed by exactly one terminal close frame.
// ─────────────────────────────────────────────────────────────────────────────

#include <gtest/gtest.h>

#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "Common.h"
#include "WsSession.h"
#include "support/TestSink.h"
#include "support/WsTestServer.h"

using namespace nitrohttp;
using nitrohttp::test::CapturedFrame;
using nitrohttp::test::Captures;
using nitrohttp::test::WsTestServer;

namespace {

template <typename Fn>
bool waitFor(Fn predicate, int timeoutMs = 10000) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return predicate();
}

std::vector<CapturedFrame> framesOf(int64_t socketId, int64_t opcode) {
  std::vector<CapturedFrame> out;
  for (const CapturedFrame& frame : Captures::instance().frames()) {
    if (frame.socketId == socketId && frame.opcode == opcode) {
      out.push_back(frame);
    }
  }
  return out;
}

int closeCodeOf(const CapturedFrame& frame) {
  if (frame.payload.size() < 2) return -1;
  return (static_cast<int>(frame.payload[0]) << 8) | frame.payload[1];
}

RawWsConfig wsConfig(int64_t socketId, const std::string& url) {
  RawWsConfig cfg{};
  cfg.socketId = socketId;
  cfg.url = url;
  cfg.pingIntervalMs = 0;
  cfg.maxFrameBytes = 1 << 20;
  cfg.connectTimeoutMs = 5000;
  return cfg;
}

class WsSessionTest : public ::testing::Test {
 protected:
  void SetUp() override {
    Captures::instance().clear();
    Captures::instance().setPortAlive(true);
  }
  void TearDown() override { Captures::instance().setPortAlive(true); }
};

}  // namespace

TEST_F(WsSessionTest, TheUpgradeSucceedsAndPostsExactlyOneHandshake) {
  WsTestServer server;
  WsSession session(7);
  session.connect(wsConfig(7, server.url("/socket")), /*dartPort=*/99);

  ASSERT_TRUE(Captures::instance().waitForPosts(1)) << "no handshake posted";
  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 1u);
  EXPECT_EQ(handshakes[0].socketId, 7);
  EXPECT_EQ(handshakes[0].errorKind, RAWERRORKIND_NONE)
      << handshakes[0].errorMessage;
  EXPECT_EQ(handshakes[0].statusCode, 101);
  EXPECT_FALSE(handshakes[0].responseHeaders.empty());
  EXPECT_TRUE(server.handshakeCompleted());

  // A second post must never appear: `wsConnect` owes its port exactly one.
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  EXPECT_EQ(Captures::instance().posts().size(), 1u);
  session.shutdown();
}

TEST_F(WsSessionTest, ARefusedUpgradeStillPostsExactlyOneHandshake) {
  WsSession session(8);
  // Nothing is listening on the discard port, so the connect fails outright.
  session.connect(wsConfig(8, "ws://127.0.0.1:9/"), /*dartPort=*/99);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 1u);
  EXPECT_EQ(handshakes[0].socketId, 8);
  EXPECT_NE(handshakes[0].errorKind, RAWERRORKIND_NONE)
      << "a failed upgrade must still complete the caller's Future";
  session.shutdown();
}

TEST_F(WsSessionTest, TextFramesRoundTrip) {
  WsTestServer server;
  WsSession session(11);
  session.connect(wsConfig(11, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  const std::string message = "hello websocket";
  session.send(wsopcode::kText,
               reinterpret_cast<const uint8_t*>(message.data()),
               message.size());

  ASSERT_TRUE(waitFor([] { return !framesOf(11, wsopcode::kText).empty(); }))
      << "the echo never came back";
  const std::vector<CapturedFrame> frames = framesOf(11, wsopcode::kText);
  ASSERT_EQ(frames.size(), 1u);
  EXPECT_EQ(std::string(frames[0].payload.begin(), frames[0].payload.end()),
            message);

  ASSERT_TRUE(server.waitForMessages(1));
  EXPECT_EQ(server.messages().at(0), message)
      << "the server must have received the unmasked payload";
  session.shutdown();
}

// ─── The closing handshake ───────────────────────────────────────────────────

TEST_F(WsSessionTest, CloseReturnsImmediatelyWhenThePeerNeverMirrorsIt) {
  WsTestServer::Options options;
  options.mirrorClose = false;  // legal, common, and the shape that used to hang
  WsTestServer server(options);

  WsSession session(21);
  session.connect(wsConfig(21, server.url("/socket")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  const auto started = std::chrono::steady_clock::now();
  session.close(4321, "client is done");
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - started)
                           .count();

  // The handshake deadline is 2 s. `close()` runs on the Dart isolate thread as
  // a synchronous FFI call, so waiting it out here would freeze a Flutter frame
  // for two seconds.
  EXPECT_LT(elapsed, 500) << "close() blocked its caller for " << elapsed
                          << " ms; the receive thread owns the deadline";

  ASSERT_TRUE(server.waitForClose()) << "the close frame never went out";
  EXPECT_EQ(server.lastCloseCode(), 4321);

  // The deadline still has to produce a terminal frame, or the Dart Future
  // hangs forever because its event stream never ends.
  ASSERT_TRUE(waitFor([] { return !framesOf(21, wsopcode::kClose).empty(); }))
      << "no terminal close frame reached the sink";
  std::this_thread::sleep_for(std::chrono::milliseconds(300));

  const std::vector<CapturedFrame> closes = framesOf(21, wsopcode::kClose);
  ASSERT_EQ(closes.size(), 1u) << "exactly one close event, never two";
  EXPECT_EQ(closeCodeOf(closes[0]), 4321)
      << "the synthetic close reports the code WE sent, not 1006";
  session.shutdown();
}

TEST_F(WsSessionTest, ClosingAnAlreadyClosedSessionDoesNotHang) {
  WsTestServer::Options options;
  options.mirrorClose = false;
  WsTestServer server(options);

  WsSession session(22);
  session.connect(wsConfig(22, server.url("/socket")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  session.close(1000, "first");
  ASSERT_TRUE(waitFor([] { return !framesOf(22, wsopcode::kClose).empty(); }));

  for (int attempt = 0; attempt < 3; ++attempt) {
    const auto started = std::chrono::steady_clock::now();
    session.close(1000, "again");
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - started)
                             .count();
    EXPECT_LT(elapsed, 500) << "repeat close blocked for " << elapsed << " ms";
  }

  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  EXPECT_EQ(framesOf(22, wsopcode::kClose).size(), 1u)
      << "a repeated close must not emit a second terminal frame";

  const auto started = std::chrono::steady_clock::now();
  session.shutdown();
  session.shutdown();  // idempotent
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - started)
                           .count();
  EXPECT_LT(elapsed, 3000) << "shutdown hung for " << elapsed << " ms";
}

TEST_F(WsSessionTest, AMirroredCloseTerminatesWithThePeersCode) {
  WsTestServer server;  // mirrors by default
  WsSession session(23);
  session.connect(wsConfig(23, server.url("/socket")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  session.close(1001, "going away");
  ASSERT_TRUE(waitFor([] { return !framesOf(23, wsopcode::kClose).empty(); }));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));

  const std::vector<CapturedFrame> closes = framesOf(23, wsopcode::kClose);
  ASSERT_EQ(closes.size(), 1u);
  EXPECT_EQ(closeCodeOf(closes[0]), 1001);
  EXPECT_EQ(server.closeFramesReceived(), 1);
  session.shutdown();
}

TEST_F(WsSessionTest, APeerThatDropsTcpAfterOurCloseIsStillAnOrderlyClose) {
  WsTestServer::Options options;
  options.mirrorClose = false;
  options.dropAfterClose = true;  // close frame in, FIN out, no close frame back
  WsTestServer server(options);

  WsSession session(24);
  session.connect(wsConfig(24, server.url("/socket")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  session.close(4002, "bye");
  ASSERT_TRUE(waitFor([] { return !framesOf(24, wsopcode::kClose).empty(); }));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));

  const std::vector<CapturedFrame> closes = framesOf(24, wsopcode::kClose);
  ASSERT_EQ(closes.size(), 1u);
  EXPECT_EQ(closeCodeOf(closes[0]), 4002)
      << "we asked to close and the peer simply hung up; that is orderly, and "
         "1006 would be a lie";
  EXPECT_TRUE(framesOf(24, wsopcode::kTransportError).empty())
      << "a TCP close AFTER our close frame is not a transport failure";
  session.shutdown();
}

TEST_F(WsSessionTest, ShutdownWithoutACloseStillJoinsPromptly) {
  WsTestServer server;
  WsSession session(25);
  session.connect(wsConfig(25, server.url("/socket")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  const auto started = std::chrono::steady_clock::now();
  session.shutdown();
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - started)
                           .count();
  EXPECT_LT(elapsed, 3000) << "shutdown hung for " << elapsed << " ms";
}
