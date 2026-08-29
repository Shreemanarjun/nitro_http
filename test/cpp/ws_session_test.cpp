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

// ── Data frames ──────────────────────────────────────────────────────────────

TEST_F(WsSessionTest, BinaryFramesRoundTripWithEveryByteValue) {
  WsTestServer server;
  WsSession session(20);
  session.connect(wsConfig(20, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  // Every byte value, so a payload routed through any text path would be
  // mangled by UTF-8 validation or by a NUL terminator.
  std::vector<uint8_t> payload(256);
  for (size_t i = 0; i < payload.size(); ++i) {
    payload[i] = static_cast<uint8_t>(i);
  }
  session.send(wsopcode::kBinary, payload.data(), payload.size());

  ASSERT_TRUE(waitFor([] { return !framesOf(20, wsopcode::kBinary).empty(); }))
      << "the binary echo never came back";
  const std::vector<CapturedFrame> frames = framesOf(20, wsopcode::kBinary);
  ASSERT_EQ(frames.size(), 1u);
  EXPECT_EQ(frames[0].payload, payload);
  session.shutdown();
}

TEST_F(WsSessionTest, APayloadPastTheSixteenBitLengthFormSurvivesIntact) {
  WsTestServer server;
  WsSession session(21);
  session.connect(wsConfig(21, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  // Over 65535, so the frame uses the 64-bit length form and the payload is
  // certain to arrive across several socket reads.
  std::vector<uint8_t> payload(200000);
  for (size_t i = 0; i < payload.size(); ++i) {
    payload[i] = static_cast<uint8_t>(i * 31);
  }
  session.send(wsopcode::kBinary, payload.data(), payload.size());

  ASSERT_TRUE(waitFor([] { return !framesOf(21, wsopcode::kBinary).empty(); },
                      20000))
      << "the large echo never came back";
  const std::vector<CapturedFrame> frames = framesOf(21, wsopcode::kBinary);
  ASSERT_EQ(frames.size(), 1u) << "a reassembled message is one frame";
  ASSERT_EQ(frames[0].payload.size(), payload.size());
  EXPECT_EQ(frames[0].payload, payload) << "reassembly reordered or lost bytes";
  session.shutdown();
}

TEST_F(WsSessionTest, AnEmptyPayloadIsStillDelivered) {
  WsTestServer server;
  WsSession session(22);
  session.connect(wsConfig(22, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  // A zero-length frame is legal and must not be mistaken for "nothing to
  // deliver" or for a closed connection.
  session.send(wsopcode::kText, nullptr, 0);

  ASSERT_TRUE(waitFor([] { return !framesOf(22, wsopcode::kText).empty(); }))
      << "an empty frame was swallowed";
  EXPECT_TRUE(framesOf(22, wsopcode::kText).at(0).payload.empty());
  session.shutdown();
}

TEST_F(WsSessionTest, AFragmentedMessageArrivesAsOneReassembledFrame) {
  WsTestServer::Options options;
  options.fragmentEchoes = true;
  WsTestServer server(options);
  WsSession session(23);
  session.connect(wsConfig(23, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  const std::string message = "fragmented across two frames";
  session.send(wsopcode::kText,
               reinterpret_cast<const uint8_t*>(message.data()),
               message.size());

  ASSERT_TRUE(waitFor([] { return !framesOf(23, wsopcode::kText).empty(); }))
      << "the fragmented echo never came back";
  const std::vector<CapturedFrame> frames = framesOf(23, wsopcode::kText);
  ASSERT_EQ(frames.size(), 1u)
      << "fragments must be joined, not delivered one by one";
  EXPECT_EQ(std::string(frames[0].payload.begin(), frames[0].payload.end()),
            message);
  // The continuation opcode is an internal detail and must not reach the caller.
  EXPECT_TRUE(framesOf(23, wsopcode::kContinuation).empty());
  session.shutdown();
}

// ── Control frames ───────────────────────────────────────────────────────────

TEST_F(WsSessionTest, AServerPingIsAnsweredWithoutTheCallerDoingAnything) {
  WsTestServer::Options options;
  options.pingOnConnect = true;
  WsTestServer server(options);
  WsSession session(24);
  session.connect(wsConfig(24, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  // RFC 6455 requires the pong; a peer that does not get one drops the
  // connection, so this has to happen inside the session rather than being
  // left to the caller.
  ASSERT_TRUE(waitFor([&server] { return server.pongCount() > 0; }))
      << "the session never answered the ping";
  session.shutdown();
}

TEST_F(WsSessionTest, AFrameLargerThanMaxFrameBytesFailsTheSession) {
  WsTestServer::Options options;
  options.oversizeBytes = 64 * 1024;
  WsTestServer server(options);
  WsSession session(25);

  RawWsConfig cfg = wsConfig(25, server.url("/echo"));
  cfg.maxFrameBytes = 1024;  // far below what the peer is about to send
  session.connect(cfg, /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  // The limit exists so a hostile peer cannot make the client allocate without
  // bound, so the session ends the connection rather than buffering the frame.
  // The visible effect is on the wire: RFC 6455 gives 1009 for exactly this.
  ASSERT_TRUE(server.waitForClose())
      << "an oversized frame did not close the session";
  EXPECT_EQ(server.lastCloseCode(), 1009);
  session.shutdown();
}

TEST_F(WsSessionTest, ADataFrameSentAfterCloseNeverReachesThePeer) {
  WsTestServer server;
  WsSession session(26);
  session.connect(wsConfig(26, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  session.close(1000, "done");
  ASSERT_TRUE(server.waitForClose());

  const std::string late = "too late";
  session.send(wsopcode::kText,
               reinterpret_cast<const uint8_t*>(late.data()), late.size());

  // RFC 6455 §5.5.1: nothing may follow a close frame. `send` reports the
  // outbox depth rather than a status, so the contract worth asserting is on
  // the wire — the peer must never see it.
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  for (const std::string& message : server.messages()) {
    EXPECT_NE(message, late) << "a frame escaped after the close";
  }
  session.shutdown();
}

// ── Handshake failures ───────────────────────────────────────────────────────
//
// The upgrade is hand-written, so each way it can fail is its own code path and
// its own error kind. A caller acts on those: a timeout is worth retrying, an
// unsupported scheme never is.

TEST_F(WsSessionTest, AnUnsupportedSchemeIsRejectedBeforeAnySocket) {
  WsSession session(30);
  RawWsConfig cfg = wsConfig(30, "ftp://example.com/socket");
  session.connect(cfg, /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 1u);
  EXPECT_EQ(handshakes[0].errorKind,
            RawErrorKind::RAWERRORKIND_UNSUPPORTED_SCHEME);
  session.shutdown();
}

TEST_F(WsSessionTest, ConnectingTwiceOnOneSocketIsRefused) {
  WsTestServer server;
  WsSession session(31);
  session.connect(wsConfig(31, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  // The second call must answer rather than replace the live session, or the
  // first caller's Future would never complete.
  session.connect(wsConfig(31, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(2));

  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 2u);
  EXPECT_EQ(handshakes[0].errorKind, RawErrorKind::RAWERRORKIND_NONE);
  EXPECT_EQ(handshakes[1].errorKind, RawErrorKind::RAWERRORKIND_BAD_REQUEST);
  session.shutdown();
}

TEST_F(WsSessionTest, APeerThatHangsUpMidUpgradeReportsTheDisconnect) {
  WsTestServer::Options options;
  options.dropDuringUpgrade = true;
  WsTestServer server(options);
  WsSession session(32);
  session.connect(wsConfig(32, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 1u);
  EXPECT_NE(handshakes[0].errorKind, RawErrorKind::RAWERRORKIND_NONE)
      << "a connection that dies mid-upgrade is not a successful handshake";
  session.shutdown();
}

TEST_F(WsSessionTest, ASilentPeerEndsOnTheConnectDeadline) {
  WsTestServer::Options options;
  options.neverRespond = true;
  WsTestServer server(options);
  WsSession session(33);

  RawWsConfig cfg = wsConfig(33, server.url("/echo"));
  cfg.connectTimeoutMs = 300;  // short: the deadline is what is under test
  session.connect(cfg, /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 1u);
  EXPECT_EQ(handshakes[0].errorKind,
            RawErrorKind::RAWERRORKIND_TIMEOUT_CONNECT);
  session.shutdown();
}

TEST_F(WsSessionTest, AnOversizedUpgradeResponseIsAProtocolError) {
  WsTestServer::Options options;
  // Past the 64 KiB ceiling the handshake reader will accept.
  options.headerPadding = 80 * 1024;
  WsTestServer server(options);
  WsSession session(34);
  session.connect(wsConfig(34, server.url("/echo")), /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));

  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 1u);
  EXPECT_NE(handshakes[0].errorKind, RawErrorKind::RAWERRORKIND_NONE)
      << "an unbounded header block must not be accepted";
  session.shutdown();
}

// ── Upgrade request contents ─────────────────────────────────────────────────

TEST_F(WsSessionTest, CallerHeadersRideAlongButHandshakeOnesCannotBeForged) {
  WsTestServer server;
  WsSession session(35);

  RawWsConfig cfg = wsConfig(35, server.url("/echo"));
  cfg.headers.push_back(RawHeader{"X-Trace", "abc"});
  // Every one of these belongs to the handshake; letting a caller set them
  // would corrupt an upgrade that the session has to get exactly right.
  cfg.headers.push_back(RawHeader{"Upgrade", "nonsense"});
  cfg.headers.push_back(RawHeader{"Connection", "close"});
  cfg.headers.push_back(RawHeader{"Sec-WebSocket-Key", "forged"});
  cfg.headers.push_back(RawHeader{"Sec-WebSocket-Version", "1"});
  session.connect(cfg, /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  const std::string head = server.requestHead();
  EXPECT_NE(head.find("X-Trace: abc"), std::string::npos)
      << "an ordinary header should reach the server: " << head;
  EXPECT_EQ(head.find("forged"), std::string::npos)
      << "a forged Sec-WebSocket-Key reached the wire: " << head;
  EXPECT_EQ(head.find("Upgrade: nonsense"), std::string::npos);
  EXPECT_EQ(head.find("Connection: close"), std::string::npos);
  session.shutdown();
}

TEST_F(WsSessionTest, SeveralSubprotocolsAreOfferedAsOneCommaSeparatedList) {
  WsTestServer::Options options;
  options.subprotocol = "chat.v2";
  WsTestServer server(options);
  WsSession session(36);

  RawWsConfig cfg = wsConfig(36, server.url("/echo"));
  cfg.protocols.push_back("chat.v1");
  cfg.protocols.push_back("chat.v2");
  session.connect(cfg, /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  EXPECT_NE(server.requestHead().find("chat.v1, chat.v2"), std::string::npos)
      << "RFC 6455 offers the list in one header: " << server.requestHead();

  const std::vector<RawWsHandshake> handshakes =
      Captures::instance().handshakes();
  ASSERT_EQ(handshakes.size(), 1u);
  EXPECT_EQ(handshakes[0].negotiatedProtocol, "chat.v2")
      << "the server's choice must come back, not the offer";
  session.shutdown();
}

TEST_F(WsSessionTest, AUrlWithNoPathStillRequestsARootTarget) {
  WsTestServer server;
  WsSession session(37);
  // No trailing slash: the request line still has to name a target.
  session.connect(
      wsConfig(37, "ws://127.0.0.1:" + std::to_string(server.port())),
      /*dartPort=*/99);
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(server.waitForHandshake());

  EXPECT_EQ(server.requestHead().rfind("GET / HTTP/1.1", 0), 0u)
      << "expected a root target: " << server.requestHead();
  session.shutdown();
}
