// A minimal RFC 6455 server on a raw loopback socket.
//
// `WsSession` takes the connection from curl with `CURLOPT_CONNECT_ONLY` and
// speaks framing itself, so cpp-httplib cannot host it — httplib never yields
// the socket. This fixture is the smallest thing that can complete the upgrade
// (which `WsSession` validates in full, `Sec-WebSocket-Accept` included) and
// then behave, or misbehave, exactly as a test needs.
//
// The misbehaviour is the point: a server that accepts a close frame and never
// answers it is legal, common, and the shape that used to hang the client.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace nitrohttp::test {

class WsTestServer {
 public:
  struct Options {
    /// Answer a client close frame with a mirrored close. False leaves the
    /// connection open and silent, which is what forces the client's own
    /// close deadline to fire.
    bool mirrorClose = true;
    /// Close the TCP connection, without a close frame, as soon as a client
    /// close arrives. Ignored when `mirrorClose` is true.
    bool dropAfterClose = false;
    /// Echo text and binary frames back to the client.
    bool echo = true;
    /// Sent back in `Sec-WebSocket-Protocol` when non-empty.
    std::string subprotocol;
    /// Send a ping as soon as the upgrade is answered, so the client's
    /// automatic pong can be observed.
    bool pingOnConnect = false;
    /// Echo each message as two fragments (a non-final data frame followed by
    /// a continuation) instead of one whole frame.
    bool fragmentEchoes = false;
    /// Send one data frame of this many bytes right after the upgrade. Used to
    /// drive a client past `maxFrameBytes`.
    size_t oversizeBytes = 0;
  };

  /// A well-behaved echo server. `Options` picks the misbehaviour.
  WsTestServer() : WsTestServer(Options{}) {}
  explicit WsTestServer(Options options);
  ~WsTestServer();

  WsTestServer(const WsTestServer&) = delete;
  WsTestServer& operator=(const WsTestServer&) = delete;

  /// `ws://127.0.0.1:<port><path>`.
  std::string url(const std::string& path = "/") const;
  int port() const { return port_; }

  /// True once the upgrade has been answered.
  bool handshakeCompleted() const;
  /// How many pong frames the client sent, which is how an automatic answer to
  /// a server ping is observed.
  int pongCount() const;
  /// How many close frames the client sent.
  int closeFramesReceived() const;
  /// The status code carried by the last client close frame, or -1.
  int lastCloseCode() const;
  /// Text and binary payloads received, in order.
  std::vector<std::string> messages() const;

  /// Blocks until the upgrade has been answered, or the deadline passes.
  bool waitForHandshake(int timeoutMs = 5000) const;
  /// Blocks until the client's close frame arrives, or the deadline passes.
  bool waitForClose(int timeoutMs = 5000) const;
  bool waitForMessages(size_t count, int timeoutMs = 5000) const;

 private:
  void run();
  void serve(int client);

  Options options_;
  std::atomic<int> listenFd_{-1};
  int port_ = 0;
  std::thread thread_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> handshaked_{false};
  std::atomic<int> closeFrames_{0};
  std::atomic<int> pongFrames_{0};
  std::atomic<int> lastCloseCode_{-1};

  mutable std::mutex messageMtx_;
  std::vector<std::string> messages_;
};

}  // namespace nitrohttp::test
