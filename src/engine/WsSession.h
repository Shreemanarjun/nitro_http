// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — WebSockets (RFC 6455) over a curl-established connection.
//
// WHY NOT `curl_ws_recv`. curl's WebSocket API only exists when curl was built
// with `--enable-websockets`, which most system builds are not, and it is still
// marked experimental in several releases. Instead we take the connection from
// curl with `CURLOPT_CONNECT_ONLY = 2` (which performs the HTTP/1.1 Upgrade
// handshake for `ws://`/`wss://` URLs) or `= 1` plus a hand-written handshake,
// and then do RFC 6455 framing ourselves over `curl_easy_send` /
// `curl_easy_recv`.
//
// What we still get from curl: DNS, connection, TLS (including our CertStore
// trust configuration), proxies and redirect-free upgrade handling. What we own:
// framing, masking, fragmentation reassembly, ping/pong, close handshake. That
// is roughly 400 lines and buys portability across every libcurl build.
//
// KNOWN LIMITATION, stated plainly in the docs: HTTP/1.1 upgrade only. RFC 8441
// (WebSockets over HTTP/2) is not implemented here, and neither libcurl nor
// reqwest implements it either.
//
// THREADING  One receive thread per session. Sends run on the caller's thread,
// serialised against the receive loop by `ioMtx_` because a partial
// `curl_easy_send` must be completed before any other frame goes out.
// Backpressure works by simply not reading the socket while unacked frames
// exceed the credit window, which closes the TCP window naturally.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <curl/curl.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ChunkArena.h"
#include "Common.h"

namespace nitrohttp {

/// RFC 6455 opcodes, plus the sentinel we use to surface transport failures on
/// the frame stream rather than inventing a second channel for them.
namespace wsopcode {
constexpr int64_t kContinuation = 0;
constexpr int64_t kText = 1;
constexpr int64_t kBinary = 2;
constexpr int64_t kClose = 8;
constexpr int64_t kPing = 9;
constexpr int64_t kPong = 10;
constexpr int64_t kTransportError = 255;
}  // namespace wsopcode

class WsSession {
 public:
  explicit WsSession(int64_t socketId);
  ~WsSession();

  WsSession(const WsSession&) = delete;
  WsSession& operator=(const WsSession&) = delete;

  /// Starts the handshake on a background thread and posts exactly one
  /// `RawWsHandshake` to `dartPort`, success or failure. Returns immediately.
  void connect(RawWsConfig cfg, int64_t dartPort);

  /// Queues a frame and returns the bytes still awaiting transmission. Text and
  /// binary payloads are fragmented at `maxFrameBytes`. Control frames are sent
  /// ahead of queued data, as RFC 6455 requires.
  int64_t send(int64_t opcode, const uint8_t* payload, size_t n);

  /// Initiates the closing handshake. Waits for the peer's close frame up to a
  /// short deadline, then tears the connection down regardless.
  void close(int64_t code, const std::string& reason);

  /// Frame flow control and payload release — see ChunkArena.
  void grantCredit(int64_t frameCount, int64_t ackedFrames);

  /// Aborts everything and joins the receive thread. Idempotent.
  void shutdown();

  // ── Framing, exposed for direct unit testing ──────────────────────────────

  /// Encodes one frame. Client frames are always masked, per RFC 6455 §5.3.
  static std::vector<uint8_t> encodeFrame(int64_t opcode, bool fin,
                                          const uint8_t* payload, size_t n,
                                          uint32_t maskKey);

  struct ParsedFrame {
    bool complete = false;   ///< false = need more bytes
    bool fin = false;
    int64_t opcode = 0;
    size_t headerBytes = 0;
    size_t payloadBytes = 0;
    bool masked = false;
    uint32_t maskKey = 0;
    bool protocolError = false;
    const char* errorText = nullptr;
  };

  /// Parses a frame header out of `data`. Does not copy the payload.
  static ParsedFrame parseFrameHeader(const uint8_t* data, size_t n);

 private:
  void run(RawWsConfig cfg, int64_t dartPort);
  EngineError performHandshake(const RawWsConfig& cfg, int64_t* statusCode,
                              std::string* negotiatedProtocol,
                              std::vector<RawHeader>* responseHeaders);
  void receiveLoop();
  bool flushOutbox();
  bool sendRaw(const uint8_t* data, size_t n);
  void emitFrame(int64_t opcode, bool fin, const uint8_t* payload, size_t n);
  void emitTransportError(const EngineError& err);

  /// Emits a close frame Dart did not receive from the peer, so a close we
  /// initiated always terminates the event stream. `code` is the code WE sent;
  /// reporting 1006 here would be a lie, because the closure was orderly from
  /// the application's point of view.
  void emitSyntheticClose(int64_t code, const std::string& reason);
  void deliverMessage(int64_t opcode, std::vector<uint8_t>&& payload);

  int64_t socketId_;
  CURL* easy_ = nullptr;
  curl_socket_t sock_ = CURL_SOCKET_BAD;

  std::thread thread_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> connected_{false};
  std::atomic<bool> closeSent_{false};
  std::atomic<bool> closeReceived_{false};

  // The close handshake is waited out on the RECEIVE thread, never on the
  // caller's. `close()` is a sync FFI call from the Dart isolate: blocking it
  // for the handshake deadline would freeze a Flutter frame for two seconds.
  // When the deadline passes with no mirrored close, the receive thread
  // synthesises the terminal frame from `sentCloseCode_` so Dart still gets
  // exactly one close event and its `Future` never hangs.
  std::atomic<double> closeDeadlineMs_{0.0};
  std::atomic<int64_t> sentCloseCode_{1000};

  std::mutex ioMtx_;
  std::deque<std::vector<uint8_t>> outbox_;
  size_t outboxBytes_ = 0;
  size_t outboxHeadOffset_ = 0;

  // Reassembly of fragmented messages.
  std::vector<uint8_t> fragment_;
  int64_t fragmentOpcode_ = 0;

  // Credit window and payload lifetime.
  ChunkArena arena_;
  std::atomic<int64_t> credits_{0};
  int64_t emittedSeq_ = 0;

  int64_t maxFrameBytes_ = 1 << 20;
  int64_t pingIntervalMs_ = 0;
  double lastPingMs_ = 0;
};

}  // namespace nitrohttp
