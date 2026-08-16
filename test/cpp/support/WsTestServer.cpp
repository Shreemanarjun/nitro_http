#include "support/WsTestServer.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstring>
#include <stdexcept>
#include <thread>

#include "Common.h"

namespace nitrohttp::test {
namespace {

constexpr const char* kAcceptGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// SHA-1 (FIPS 180-1). Here only because `Sec-WebSocket-Accept` is defined in
/// terms of it, and `WsSession` validates that header in full.
void sha1(const uint8_t* data, size_t len, uint8_t out[20]) {
  uint32_t h[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u,
                   0xC3D2E1F0u};
  const uint64_t bitLen = static_cast<uint64_t>(len) * 8;

  std::vector<uint8_t> buf(data, data + len);
  buf.push_back(0x80);
  while (buf.size() % 64 != 56) buf.push_back(0x00);
  for (int i = 7; i >= 0; --i) {
    buf.push_back(static_cast<uint8_t>((bitLen >> (i * 8)) & 0xff));
  }

  for (size_t off = 0; off < buf.size(); off += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
      w[i] = (static_cast<uint32_t>(buf[off + i * 4]) << 24) |
             (static_cast<uint32_t>(buf[off + i * 4 + 1]) << 16) |
             (static_cast<uint32_t>(buf[off + i * 4 + 2]) << 8) |
             static_cast<uint32_t>(buf[off + i * 4 + 3]);
    }
    for (int i = 16; i < 80; ++i) {
      const uint32_t v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = (v << 1) | (v >> 31);
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; ++i) {
      uint32_t f = 0;
      uint32_t k = 0;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999u;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1u;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDCu;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6u;
      }
      const uint32_t temp = ((a << 5) | (a >> 27)) + f + e + k + w[i];
      e = d;
      d = c;
      c = (b << 30) | (b >> 2);
      b = a;
      a = temp;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
  }

  for (int i = 0; i < 5; ++i) {
    out[i * 4 + 0] = static_cast<uint8_t>(h[i] >> 24);
    out[i * 4 + 1] = static_cast<uint8_t>(h[i] >> 16);
    out[i * 4 + 2] = static_cast<uint8_t>(h[i] >> 8);
    out[i * 4 + 3] = static_cast<uint8_t>(h[i]);
  }
}

bool sendAll(int fd, const void* data, size_t n) {
  const auto* p = static_cast<const uint8_t*>(data);
  size_t sent = 0;
  while (sent < n) {
    const ssize_t wrote = ::send(fd, p + sent, n - sent, 0);
    if (wrote <= 0) return false;
    sent += static_cast<size_t>(wrote);
  }
  return true;
}

/// A server frame: unmasked, per RFC 6455 §5.1.
std::vector<uint8_t> serverFrameEx(int opcode, bool fin, const uint8_t* payload,
                                  size_t n) {
  std::vector<uint8_t> out;
  out.push_back(static_cast<uint8_t>((fin ? 0x80 : 0x00) | (opcode & 0x0f)));
  if (n < 126) {
    out.push_back(static_cast<uint8_t>(n));
  } else if (n <= 0xffff) {
    out.push_back(126);
    out.push_back(static_cast<uint8_t>((n >> 8) & 0xff));
    out.push_back(static_cast<uint8_t>(n & 0xff));
  } else {
    out.push_back(127);
    for (int i = 7; i >= 0; --i) {
      out.push_back(static_cast<uint8_t>((n >> (i * 8)) & 0xff));
    }
  }
  out.insert(out.end(), payload, payload + n);
  return out;
}

std::vector<uint8_t> serverFrame(int opcode, const uint8_t* payload, size_t n) {
  return serverFrameEx(opcode, true, payload, n);
}

std::string headerValueOf(const std::string& head, const std::string& name) {
  const std::string lowerHead = asciiLower(head);
  const std::string needle = "\r\n" + asciiLower(name) + ":";
  const size_t at = lowerHead.find(needle);
  if (at == std::string::npos) return std::string();
  const size_t start = at + needle.size();
  const size_t eol = head.find("\r\n", start);
  if (eol == std::string::npos) return std::string();
  return trimAsciiSpace(head.substr(start, eol - start));
}

template <typename Fn>
bool waitUntil(Fn predicate, int timeoutMs) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return predicate();
}

}  // namespace

WsTestServer::WsTestServer(Options options) : options_(std::move(options)) {
  listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
  if (listenFd_ < 0) throw std::runtime_error("WsTestServer: socket() failed");

  int one = 1;
  ::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;  // ephemeral
  if (::bind(listenFd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      ::listen(listenFd_, 4) != 0) {
    ::close(listenFd_);
    throw std::runtime_error("WsTestServer: could not bind a loopback port");
  }

  socklen_t len = sizeof(addr);
  if (::getsockname(listenFd_, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
    ::close(listenFd_);
    throw std::runtime_error("WsTestServer: getsockname() failed");
  }
  port_ = ntohs(addr.sin_port);

  thread_ = std::thread([this] { run(); });
}

WsTestServer::~WsTestServer() {
  stopping_.store(true);
  const int fd = listenFd_.exchange(-1);
  if (fd >= 0) {
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
  }
  if (thread_.joinable()) thread_.join();
}

std::string WsTestServer::url(const std::string& path) const {
  return "ws://127.0.0.1:" + std::to_string(port_) + path;
}

bool WsTestServer::handshakeCompleted() const { return handshaked_.load(); }
int WsTestServer::closeFramesReceived() const { return closeFrames_.load(); }
int WsTestServer::pongCount() const { return pongFrames_.load(); }
int WsTestServer::lastCloseCode() const { return lastCloseCode_.load(); }

std::vector<std::string> WsTestServer::messages() const {
  std::lock_guard<std::mutex> lock(messageMtx_);
  return messages_;
}

bool WsTestServer::waitForHandshake(int timeoutMs) const {
  return waitUntil([this] { return handshaked_.load(); }, timeoutMs);
}

bool WsTestServer::waitForClose(int timeoutMs) const {
  return waitUntil([this] { return closeFrames_.load() > 0; }, timeoutMs);
}

bool WsTestServer::waitForMessages(size_t count, int timeoutMs) const {
  return waitUntil([this, count] { return messages().size() >= count; },
                   timeoutMs);
}

void WsTestServer::run() {
  while (!stopping_.load()) {
    const int listener = listenFd_.load();
    if (listener < 0) break;

    pollfd pfd{};
    pfd.fd = listener;
    pfd.events = POLLIN;
    const int ready = ::poll(&pfd, 1, 50);
    if (ready <= 0) continue;
    if (stopping_.load()) break;

    const int client = ::accept(listener, nullptr, nullptr);
    if (client < 0) break;
    serve(client);
    ::close(client);
  }
}

void WsTestServer::serve(int client) {
  int one = 1;
  ::setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

  // ── Upgrade ────────────────────────────────────────────────────────────────
  std::string head;
  while (head.size() < 4 || head.compare(head.size() - 4, 4, "\r\n\r\n") != 0) {
    if (stopping_.load() || head.size() > 64 * 1024) return;
    char byte = 0;
    const ssize_t got = ::recv(client, &byte, 1, 0);
    if (got <= 0) return;
    head.push_back(byte);
  }

  const std::string key = headerValueOf(head, "Sec-WebSocket-Key");
  if (key.empty()) return;

  const std::string material = key + kAcceptGuid;
  uint8_t digest[20];
  sha1(reinterpret_cast<const uint8_t*>(material.data()), material.size(),
       digest);

  std::string response =
      "HTTP/1.1 101 Switching Protocols\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Accept: " +
      base64Encode(digest, sizeof(digest)) + "\r\n";
  if (!options_.subprotocol.empty()) {
    response += "Sec-WebSocket-Protocol: " + options_.subprotocol + "\r\n";
  }
  response += "\r\n";
  if (!sendAll(client, response.data(), response.size())) return;
  handshaked_.store(true);

  if (options_.pingOnConnect) {
    const std::string body = "are you there";
    const std::vector<uint8_t> ping = serverFrame(
        0x9, reinterpret_cast<const uint8_t*>(body.data()), body.size());
    if (!sendAll(client, ping.data(), ping.size())) return;
  }

  if (options_.oversizeBytes > 0) {
    const std::vector<uint8_t> body(options_.oversizeBytes, 0x41);
    const std::vector<uint8_t> frame =
        serverFrame(0x2, body.data(), body.size());
    if (!sendAll(client, frame.data(), frame.size())) return;
  }

  // ── Frames ─────────────────────────────────────────────────────────────────
  std::vector<uint8_t> rx;
  while (!stopping_.load()) {
    // Drain every whole frame already buffered before asking for more bytes.
    bool progressed = true;
    while (progressed) {
      progressed = false;
      if (rx.size() < 2) break;

      const int opcode = rx[0] & 0x0f;
      const bool masked = (rx[1] & 0x80) != 0;
      uint64_t len = rx[1] & 0x7f;
      size_t header = 2;
      if (len == 126) {
        if (rx.size() < 4) break;
        len = (static_cast<uint64_t>(rx[2]) << 8) | rx[3];
        header = 4;
      } else if (len == 127) {
        if (rx.size() < 10) break;
        len = 0;
        for (int i = 0; i < 8; ++i) len = (len << 8) | rx[2 + i];
        header = 10;
      }
      uint8_t mask[4] = {0, 0, 0, 0};
      if (masked) {
        if (rx.size() < header + 4) break;
        std::memcpy(mask, rx.data() + header, 4);
        header += 4;
      }
      if (rx.size() < header + len) break;

      std::vector<uint8_t> payload(
          rx.begin() + static_cast<std::ptrdiff_t>(header),
          rx.begin() + static_cast<std::ptrdiff_t>(header + len));
      if (masked) {
        for (size_t i = 0; i < payload.size(); ++i) payload[i] ^= mask[i & 3];
      }
      rx.erase(rx.begin(), rx.begin() + static_cast<std::ptrdiff_t>(header + len));
      progressed = true;

      if (opcode == 0x8) {
        lastCloseCode_.store(payload.size() >= 2
                                 ? (static_cast<int>(payload[0]) << 8) | payload[1]
                                 : -1);
        closeFrames_.fetch_add(1);
        if (options_.mirrorClose) {
          const std::vector<uint8_t> reply =
              serverFrame(0x8, payload.data(), payload.size());
          sendAll(client, reply.data(), reply.size());
          return;
        }
        if (options_.dropAfterClose) return;
        // Otherwise: stay connected and say nothing. Legal, common, and the
        // shape that makes the client's own close deadline do the work.
        continue;
      }
      if (opcode == 0xA) {  // the client's answer to our ping
        pongFrames_.fetch_add(1);
      }

      if (opcode == 0x9) {  // ping → pong
        const std::vector<uint8_t> pong =
            serverFrame(0xa, payload.data(), payload.size());
        if (!sendAll(client, pong.data(), pong.size())) return;
        continue;
      }
      if (opcode == 0x1 || opcode == 0x2) {
        {
          std::lock_guard<std::mutex> lock(messageMtx_);
          messages_.emplace_back(payload.begin(), payload.end());
        }
        if (options_.echo) {
          if (options_.fragmentEchoes && payload.size() >= 2) {
            // Split down the middle: first frame keeps the opcode with FIN
            // clear, the rest rides a continuation (opcode 0).
            const size_t half = payload.size() / 2;
            const std::vector<uint8_t> first =
                serverFrameEx(opcode, false, payload.data(), half);
            const std::vector<uint8_t> rest = serverFrameEx(
                0x0, true, payload.data() + half, payload.size() - half);
            if (!sendAll(client, first.data(), first.size())) return;
            if (!sendAll(client, rest.data(), rest.size())) return;
          } else {
            const std::vector<uint8_t> echoed =
                serverFrame(opcode, payload.data(), payload.size());
            if (!sendAll(client, echoed.data(), echoed.size())) return;
          }
        }
      }
    }

    pollfd pfd{};
    pfd.fd = client;
    pfd.events = POLLIN;
    const int ready = ::poll(&pfd, 1, 50);
    if (ready < 0) return;
    if (ready == 0) continue;

    uint8_t buf[4096];
    const ssize_t got = ::recv(client, buf, sizeof(buf), 0);
    if (got <= 0) return;
    rx.insert(rx.end(), buf, buf + got);
  }
}

}  // namespace nitrohttp::test
