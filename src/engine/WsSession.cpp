#include "WsSession.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <random>
#include <string>
#include <utility>
#include <vector>

#include "CertStore.h"
#include "DartPost.h"
#include "DeferredPayloads.h"
#include "Wire.h"

#ifdef _WIN32
#include <winsock2.h>
#else
#include <poll.h>
#endif

namespace nitrohttp {

// ── Local helpers ────────────────────────────────────────────────────────────
//
// A named namespace rather than an anonymous one: on Apple builds every engine
// source is `#include`d into EngineUnity.cpp, where all anonymous namespaces
// collapse into one and identically named helpers would collide.

namespace wsdetail {
namespace {

/// RFC 6455 §1.3. Concatenated with the client key and SHA-1'd to produce the
/// value the server must echo in `Sec-WebSocket-Accept`.
constexpr char kAcceptGuid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Frames the peer may push before Dart has granted anything. Without a seed
/// the receive loop would refuse to read until the first `wsGrantCredit`,
/// which never arrives for a socket that receives before Dart subscribes.
/// Kept well under the generated stream's 64-slot ring so a burst plus a
/// concurrent grant still cannot overflow it.
constexpr int64_t kInitialCredits = 16;

constexpr int64_t kDefaultMaxFrameBytes = 1 << 20;
constexpr int64_t kDefaultConnectTimeoutMs = 30000;

/// Longest a close frame's UTF-8 reason may be: control payloads cap at 125
/// bytes and the status code eats the first two.
constexpr size_t kMaxCloseReason = 123;

/// How long the receive loop may block in `poll` before it re-checks
/// `stopping_`, the keepalive deadline and the outbox.
constexpr int kPollSliceMs = 25;

/// How long `close` waits for the peer's mirroring close frame before tearing
/// the connection down anyway. RFC 6455 §7.1.1 explicitly permits this.
constexpr double kCloseHandshakeTimeoutMs = 2000.0;

constexpr size_t kRecvChunk = 16384;

// ── SHA-1 (RFC 3174) ───────────────────────────────────────────────────────
//
// `Sec-WebSocket-Accept` is defined in terms of SHA-1, not SHA-256, so
// `nitrohttp::hexSha256` cannot serve here. Sixty lines beats dragging in a
// crypto dependency for one non-security-critical digest — RFC 6455 uses this
// hash purely to prove the peer understood the handshake, never for integrity.

inline uint32_t rotl32(uint32_t v, int bits) {
  return (v << bits) | (v >> (32 - bits));
}

void sha1(const uint8_t* data, size_t len, uint8_t out[20]) {
  uint32_t h[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u,
                   0xC3D2E1F0u};

  std::vector<uint8_t> msg(data, data + len);
  msg.push_back(0x80);
  while (msg.size() % 64 != 56) msg.push_back(0x00);
  const uint64_t bitLen = static_cast<uint64_t>(len) * 8;
  for (int i = 7; i >= 0; --i) {
    msg.push_back(static_cast<uint8_t>((bitLen >> (i * 8)) & 0xFFu));
  }

  for (size_t off = 0; off < msg.size(); off += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
      const uint8_t* p = msg.data() + off + i * 4;
      w[i] = (static_cast<uint32_t>(p[0]) << 24) |
             (static_cast<uint32_t>(p[1]) << 16) |
             (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
    }
    for (int i = 16; i < 80; ++i) {
      w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; ++i) {
      uint32_t f, k;
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
      const uint32_t t = rotl32(a, 5) + f + e + k + w[i];
      e = d;
      d = c;
      c = rotl32(b, 30);
      b = a;
      a = t;
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

// ── Randomness ─────────────────────────────────────────────────────────────
//
// Masking exists to defeat cache-poisoning proxies, not attackers with the
// plaintext, so RFC 6455 §10.3 only asks for unpredictability from the network
// path's point of view. A shared, once-seeded Mersenne twister is both cheaper
// and less likely to exhaust entropy than a `random_device` per frame.

uint32_t random32() {
  static std::mutex mtx;
  static std::mt19937 rng(std::random_device{}());
  std::lock_guard<std::mutex> lock(mtx);
  return static_cast<uint32_t>(rng());
}

// ── Socket readiness ───────────────────────────────────────────────────────

constexpr int kReadable = 1;
constexpr int kWritable = 2;

/// Blocks up to `timeoutMs` for `fd` to become ready. Returns a bitmask of
/// `kReadable`/`kWritable`, 0 on timeout, -1 on a real failure. A signal
/// interruption reports a timeout so callers simply loop.
int waitSocket(curl_socket_t fd, bool forRead, bool forWrite, int timeoutMs) {
  if (fd == CURL_SOCKET_BAD) return -1;
#ifdef _WIN32
  fd_set rd, wr;
  FD_ZERO(&rd);
  FD_ZERO(&wr);
  if (forRead) FD_SET(fd, &rd);
  if (forWrite) FD_SET(fd, &wr);
  timeval tv;
  tv.tv_sec = timeoutMs / 1000;
  tv.tv_usec = (timeoutMs % 1000) * 1000;
  const int r = ::select(0, forRead ? &rd : nullptr, forWrite ? &wr : nullptr,
                         nullptr, &tv);
  if (r < 0) return -1;
  if (r == 0) return 0;
  int mask = 0;
  if (forRead && FD_ISSET(fd, &rd)) mask |= kReadable;
  if (forWrite && FD_ISSET(fd, &wr)) mask |= kWritable;
  return mask;
#else
  struct pollfd p;
  p.fd = fd;
  p.events = static_cast<short>((forRead ? POLLIN : 0) |
                                (forWrite ? POLLOUT : 0));
  p.revents = 0;
  const int r = ::poll(&p, 1, timeoutMs);
  if (r < 0) return errno == EINTR ? 0 : -1;
  if (r == 0) return 0;
  if (p.revents & (POLLERR | POLLNVAL)) return -1;
  int mask = 0;
  if (p.revents & (POLLIN | POLLHUP)) mask |= kReadable;
  if (p.revents & POLLOUT) mask |= kWritable;
  return mask;
#endif
}

void sleepMs(int ms) {
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// ── URL splitting ──────────────────────────────────────────────────────────

struct SplitUrl {
  bool ok = false;
  bool secure = false;
  std::string scheme;        ///< already rewritten to http/https for curl
  std::string hostHeader;    ///< host[:port], omitting the default port
  std::string pathAndQuery;  ///< request target, never empty
  std::string curlUrl;       ///< scheme-rewritten absolute URL
};

/// Splits a `ws://`/`wss://` (or plain `http://`/`https://`) URL into the parts
/// the hand-written handshake needs, rewriting the scheme on the way out:
/// curl's own `ws` scheme support is compiled out of most builds, whereas
/// `CONNECT_ONLY` over http/https is universally available and gives us the
/// identical socket.
SplitUrl splitUrl(const std::string& url) {
  SplitUrl out;
  const size_t schemeEnd = url.find("://");
  if (schemeEnd == std::string::npos) return out;

  const std::string scheme = asciiLower(url.substr(0, schemeEnd));
  if (scheme == "ws" || scheme == "http") {
    out.scheme = "http";
  } else if (scheme == "wss" || scheme == "https") {
    out.scheme = "https";
    out.secure = true;
  } else {
    return out;
  }

  const size_t authStart = schemeEnd + 3;
  size_t authEnd = url.size();
  for (size_t i = authStart; i < url.size(); ++i) {
    const char c = url[i];
    if (c == '/' || c == '?' || c == '#') {
      authEnd = i;
      break;
    }
  }

  std::string authority = url.substr(authStart, authEnd - authStart);
  const size_t at = authority.rfind('@');
  const std::string hostPort =
      at == std::string::npos ? authority : authority.substr(at + 1);
  if (hostPort.empty()) return out;

  // Split host from port without tripping over an IPv6 literal's colons.
  std::string host = hostPort;
  std::string port;
  const size_t bracket = hostPort.rfind(']');
  const size_t colon = hostPort.rfind(':');
  if (colon != std::string::npos &&
      (bracket == std::string::npos || colon > bracket)) {
    host = hostPort.substr(0, colon);
    port = hostPort.substr(colon + 1);
  }
  if (host.empty()) return out;

  const bool defaultPort =
      port.empty() || (out.secure ? port == "443" : port == "80");
  out.hostHeader = defaultPort ? host : host + ":" + port;

  size_t targetEnd = url.size();
  const size_t fragment = url.find('#', authEnd);
  if (fragment != std::string::npos) targetEnd = fragment;
  out.pathAndQuery = authEnd >= targetEnd ? std::string()
                                          : url.substr(authEnd, targetEnd - authEnd);
  if (out.pathAndQuery.empty() || out.pathAndQuery[0] != '/') {
    out.pathAndQuery = "/" + out.pathAndQuery;
  }

  out.curlUrl = out.scheme + "://" + url.substr(authStart, targetEnd - authStart);
  out.ok = true;
  return out;
}

/// True when `list` contains `token` as a comma-separated element, ignoring
/// ASCII case and surrounding whitespace. `Connection` is a list header, so a
/// literal string compare would reject the legal `keep-alive, Upgrade`.
bool listContainsToken(const std::string& list, const std::string& token) {
  size_t start = 0;
  while (start <= list.size()) {
    size_t comma = list.find(',', start);
    if (comma == std::string::npos) comma = list.size();
    if (asciiEqualIgnoreCase(trimAsciiSpace(list.substr(start, comma - start)),
                             token)) {
      return true;
    }
    start = comma + 1;
  }
  return false;
}

/// Bytes the handshake read past `\r\n\r\n`, handed from `performHandshake` to
/// `receiveLoop`. Thread-local rather than a member because both run on the
/// session's own receive thread and nothing else ever touches it — a session
/// member would suggest a cross-thread lifetime it does not have.
std::vector<uint8_t>& handshakeLeftover() {
  static thread_local std::vector<uint8_t> buf;
  return buf;
}

}  // namespace
}  // namespace wsdetail

// ── Construction ─────────────────────────────────────────────────────────────

WsSession::WsSession(int64_t socketId) : socketId_(socketId) {}

WsSession::~WsSession() { shutdown(); }

// ── Framing ──────────────────────────────────────────────────────────────────

std::vector<uint8_t> WsSession::encodeFrame(int64_t opcode, bool fin,
                                            const uint8_t* payload, size_t n,
                                            uint32_t maskKey) {
  const bool control = (opcode & 0x08) != 0;
  if (control && n > 125) n = 125;  // RFC 6455 §5.5

  std::vector<uint8_t> out;
  out.reserve(n + 14);
  out.push_back(static_cast<uint8_t>((fin ? 0x80 : 0x00) | (opcode & 0x0F)));

  // Bit 0x80 of the second byte is the mask flag: a client MUST set it.
  if (n < 126) {
    out.push_back(static_cast<uint8_t>(0x80 | n));
  } else if (n <= 0xFFFF) {
    out.push_back(static_cast<uint8_t>(0x80 | 126));
    out.push_back(static_cast<uint8_t>((n >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(n & 0xFF));
  } else {
    out.push_back(static_cast<uint8_t>(0x80 | 127));
    const uint64_t len = static_cast<uint64_t>(n);
    for (int i = 7; i >= 0; --i) {
      out.push_back(static_cast<uint8_t>((len >> (i * 8)) & 0xFF));
    }
  }

  const uint8_t mask[4] = {
      static_cast<uint8_t>((maskKey >> 24) & 0xFF),
      static_cast<uint8_t>((maskKey >> 16) & 0xFF),
      static_cast<uint8_t>((maskKey >> 8) & 0xFF),
      static_cast<uint8_t>(maskKey & 0xFF),
  };
  out.insert(out.end(), mask, mask + 4);
  for (size_t i = 0; i < n; ++i) {
    out.push_back(static_cast<uint8_t>(payload[i] ^ mask[i & 3]));
  }
  return out;
}

WsSession::ParsedFrame WsSession::parseFrameHeader(const uint8_t* data,
                                                   size_t n) {
  ParsedFrame f;
  // A protocol error is a verdict, not a shortage of bytes, so it is reported
  // as `complete` — otherwise a caller waiting for "more data" would spin.
  const auto fail = [&f](const char* text) {
    f.complete = true;
    f.protocolError = true;
    f.errorText = text;
    return f;
  };

  if (n < 2) return f;

  const uint8_t b0 = data[0];
  const uint8_t b1 = data[1];
  f.fin = (b0 & 0x80) != 0;
  f.opcode = b0 & 0x0F;
  f.masked = (b1 & 0x80) != 0;

  if ((b0 & 0x70) != 0) return fail("reserved bits set without a negotiated extension");
  if (f.masked) return fail("server frame is masked");

  const bool control = (f.opcode & 0x08) != 0;
  const bool known = f.opcode == wsopcode::kContinuation ||
                     f.opcode == wsopcode::kText ||
                     f.opcode == wsopcode::kBinary ||
                     f.opcode == wsopcode::kClose ||
                     f.opcode == wsopcode::kPing || f.opcode == wsopcode::kPong;
  if (!known) return fail("reserved opcode");
  if (control && !f.fin) return fail("fragmented control frame");

  uint64_t len = b1 & 0x7F;
  size_t need = 2;
  if (len == 126) {
    need += 2;
    if (n < need) return f;
    len = (static_cast<uint64_t>(data[2]) << 8) | data[3];
  } else if (len == 127) {
    need += 8;
    if (n < need) return f;
    len = 0;
    for (int i = 0; i < 8; ++i) {
      len = (len << 8) | data[2 + i];
    }
    if (len & 0x8000000000000000ULL) return fail("payload length has the high bit set");
  }
  if (control && len > 125) return fail("control frame payload exceeds 125 bytes");
  if (len > static_cast<uint64_t>(SIZE_MAX - need)) return fail("frame too large for this platform");

  f.headerBytes = need;
  f.payloadBytes = static_cast<size_t>(len);
  f.complete = true;
  return f;
}

// ── Connection ───────────────────────────────────────────────────────────────

void WsSession::connect(RawWsConfig cfg, int64_t dartPort) {
  if (thread_.joinable()) {
    // Exactly-once completion still applies to a misuse: the second port must
    // be answered or its Dart future hangs forever.
    RawWsHandshake hs{};
    hs.socketId = socketId_;
    hs.errorKind = RawErrorKind::RAWERRORKIND_BAD_REQUEST;
    hs.errorMessage = "wsConnect called twice on the same socket";
    postRecord(dartPort, wire::encodeWsHandshake(hs));
    return;
  }

  maxFrameBytes_ = cfg.maxFrameBytes > 0 ? cfg.maxFrameBytes
                                         : wsdetail::kDefaultMaxFrameBytes;
  pingIntervalMs_ = cfg.pingIntervalMs > 0 ? cfg.pingIntervalMs : 0;
  credits_.store(wsdetail::kInitialCredits);
  stopping_.store(false);

  thread_ = std::thread(&WsSession::run, this, std::move(cfg), dartPort);
}

void WsSession::run(RawWsConfig cfg, int64_t dartPort) {
  RawWsHandshake hs{};
  hs.socketId = socketId_;
  hs.errorKind = RawErrorKind::RAWERRORKIND_NONE;
  hs.statusCode = 0;

  EngineError err = EngineError::none();
  int64_t statusCode = 0;
  std::string negotiatedProtocol;
  std::vector<RawHeader> responseHeaders;

  if (stopping_.load()) {
    err = EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
                            "WebSocket session was shut down before connecting");
  } else {
    try {
      err = performHandshake(cfg, &statusCode, &negotiatedProtocol,
                             &responseHeaders);
    } catch (const std::exception& e) {
      err = EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR, e.what());
    } catch (...) {
      err = EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
                              "unknown native failure during the WebSocket handshake");
    }
  }

  hs.errorKind = err.kind;
  hs.errorMessage = err.message;
  hs.engineErrorCode = err.code;
  hs.statusCode = statusCode;
  hs.negotiatedProtocol = std::move(negotiatedProtocol);
  hs.responseHeaders = std::move(responseHeaders);
  postRecord(dartPort, wire::encodeWsHandshake(hs));

  if (!err.ok()) {
    stopping_.store(true);
    wsdetail::handshakeLeftover().clear();
    return;
  }

  connected_.store(true);
  receiveLoop();
  connected_.store(false);
}

EngineError WsSession::performHandshake(const RawWsConfig& cfg,
                                        int64_t* statusCode,
                                        std::string* negotiatedProtocol,
                                        std::vector<RawHeader>* responseHeaders) {
  using namespace wsdetail;
  handshakeLeftover().clear();
  ensureCurlGlobalInit();

  const SplitUrl url = splitUrl(cfg.url);
  if (!url.ok) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_UNSUPPORTED_SCHEME,
                             "not a WebSocket URL: " + cfg.url);
  }

  easy_ = curl_easy_init();
  if (!easy_) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
                             "curl_easy_init failed");
  }

  const int64_t connectTimeoutMs =
      cfg.connectTimeoutMs > 0 ? cfg.connectTimeoutMs : kDefaultConnectTimeoutMs;

  curl_easy_setopt(easy_, CURLOPT_URL, url.curlUrl.c_str());
  // CONNECT_ONLY = 1 stops after connect + TLS and hands us the socket; the
  // upgrade request below is ours, so curl never needs WebSocket support.
  curl_easy_setopt(easy_, CURLOPT_CONNECT_ONLY, 1L);
  // Required, not a preference: a WebSocket is an HTTP/1.1 Upgrade, but ALPN
  // offers h2 on wss:// and curl then reads through its nghttp2 filter, which a
  // CONNECT_ONLY handle is not part of — curl_easy_recv segfaults.
  curl_easy_setopt(easy_, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
  curl_easy_setopt(easy_, CURLOPT_CONNECTTIMEOUT_MS,
                   static_cast<long>(connectTimeoutMs));
  curl_easy_setopt(easy_, CURLOPT_NOSIGNAL, 1L);

  // Dart always fills this block, from a default TlsSettings when the caller
  // passes none — so wss:// honours custom roots, pinning and mTLS.
  const EngineError tlsErr = CertStore::apply(easy_, cfg.tls, std::string());
  if (!tlsErr.ok()) return tlsErr;

  const CURLcode rc = curl_easy_perform(easy_);
  if (rc != CURLE_OK) {
    return EngineError::make(mapCurlError(rc, false),
                             describeCurlError(rc, curl_easy_strerror(rc)), rc);
  }

  curl_socket_t sock = CURL_SOCKET_BAD;
  if (curl_easy_getinfo(easy_, CURLINFO_ACTIVESOCKET, &sock) != CURLE_OK ||
      sock == CURL_SOCKET_BAD) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_CONNECTION_FAILED,
                             "curl did not expose an active socket");
  }
  sock_ = sock;

  // ── Client handshake ──────────────────────────────────────────────────────

  uint8_t keyBytes[16];
  for (int i = 0; i < 16; i += 4) {
    const uint32_t r = random32();
    keyBytes[i + 0] = static_cast<uint8_t>(r >> 24);
    keyBytes[i + 1] = static_cast<uint8_t>(r >> 16);
    keyBytes[i + 2] = static_cast<uint8_t>(r >> 8);
    keyBytes[i + 3] = static_cast<uint8_t>(r);
  }
  const std::string key = base64Encode(keyBytes, sizeof(keyBytes));

  std::string protocols;
  for (const std::string& p : cfg.protocols) {
    if (p.empty()) continue;
    if (!protocols.empty()) protocols += ", ";
    protocols += p;
  }

  std::string req;
  req.reserve(512);
  req += "GET " + url.pathAndQuery + " HTTP/1.1\r\n";
  req += "Host: " + url.hostHeader + "\r\n";
  req += "Upgrade: websocket\r\n";
  req += "Connection: Upgrade\r\n";
  req += "Sec-WebSocket-Key: " + key + "\r\n";
  req += "Sec-WebSocket-Version: 13\r\n";
  if (!protocols.empty()) req += "Sec-WebSocket-Protocol: " + protocols + "\r\n";
  for (const RawHeader& h : cfg.headers) {
    // Caller headers may not restate the handshake's own fields: a duplicate
    // Sec-WebSocket-Key or Connection makes the request ambiguous and servers
    // reject it outright.
    if (h.name.empty()) continue;
    if (asciiEqualIgnoreCase(h.name, "host") ||
        asciiEqualIgnoreCase(h.name, "upgrade") ||
        asciiEqualIgnoreCase(h.name, "connection") ||
        asciiEqualIgnoreCase(h.name, "content-length") ||
        asciiEqualIgnoreCase(h.name, "sec-websocket-key") ||
        asciiEqualIgnoreCase(h.name, "sec-websocket-version") ||
        asciiEqualIgnoreCase(h.name, "sec-websocket-extensions") ||
        (!protocols.empty() &&
         asciiEqualIgnoreCase(h.name, "sec-websocket-protocol"))) {
      continue;
    }
    req += h.name + ": " + h.value + "\r\n";
  }
  req += "\r\n";

  if (!sendRaw(reinterpret_cast<const uint8_t*>(req.data()), req.size())) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_SEND_FAILURE,
                             "failed to write the WebSocket upgrade request");
  }

  // ── Server handshake ──────────────────────────────────────────────────────
  //
  // Read a byte at a time so the buffer never runs past `\r\n\r\n`: the reply
  // may be followed immediately by frames, and stopping exactly on the
  // terminator leaves the receive loop starting on a frame boundary with
  // nothing dropped.
  std::string head;
  head.reserve(512);
  const double deadline = monotonicMs() + static_cast<double>(connectTimeoutMs);
  while (head.size() < 4 ||
         head.compare(head.size() - 4, 4, "\r\n\r\n") != 0) {
    if (stopping_.load()) {
      return EngineError::make(RawErrorKind::RAWERRORKIND_CANCELLED,
                               "WebSocket handshake cancelled");
    }
    if (monotonicMs() > deadline) {
      return EngineError::make(RawErrorKind::RAWERRORKIND_TIMEOUT_CONNECT,
                               "timed out waiting for the WebSocket upgrade response");
    }
    if (head.size() > 64 * 1024) {
      return EngineError::make(RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
                               "WebSocket upgrade response headers exceed 64 KiB");
    }

    char byte = 0;
    size_t got = 0;
    const CURLcode rrc = curl_easy_recv(easy_, &byte, 1, &got);
    if (rrc == CURLE_AGAIN) {
      const int remainingMs =
          static_cast<int>(std::max(0.0, deadline - monotonicMs()));
      if (waitSocket(sock_, true, false, std::min(remainingMs, kPollSliceMs)) < 0) {
        return EngineError::make(RawErrorKind::RAWERRORKIND_RECEIVE_FAILURE,
                                 "socket failed while awaiting the upgrade response");
      }
      continue;
    }
    if (rrc != CURLE_OK) {
      return EngineError::make(mapCurlError(rrc, false),
                               describeCurlError(rrc, curl_easy_strerror(rrc)),
                               rrc);
    }
    if (got == 0) {
      return EngineError::make(RawErrorKind::RAWERRORKIND_CONNECTION_RESET,
                               "peer closed the connection during the upgrade");
    }
    head.push_back(byte);
  }

  // ── Validation ────────────────────────────────────────────────────────────

  std::vector<std::string> lines;
  size_t pos = 0;
  while (pos < head.size()) {
    const size_t eol = head.find("\r\n", pos);
    if (eol == std::string::npos || eol == pos) break;
    lines.push_back(head.substr(pos, eol - pos));
    pos = eol + 2;
  }
  if (lines.empty()) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
                             "empty WebSocket upgrade response");
  }

  int status = 0;
  if (!parseStatusLine(lines[0], &status)) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
                             "malformed status line: " + lines[0]);
  }
  *statusCode = status;

  for (size_t i = 1; i < lines.size(); ++i) {
    RawHeader h;
    if (parseHeaderLine(lines[i], &h.name, &h.value)) {
      responseHeaders->push_back(std::move(h));
    }
  }

  if (status != 101) {
    return EngineError::make(
        RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
        "server refused the WebSocket upgrade with HTTP " + std::to_string(status));
  }

  const RawHeader* upgrade = findHeader(*responseHeaders, "upgrade");
  if (!upgrade || !asciiEqualIgnoreCase(trimAsciiSpace(upgrade->value), "websocket")) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
                             "upgrade response is missing 'Upgrade: websocket'");
  }
  const RawHeader* connection = findHeader(*responseHeaders, "connection");
  if (!connection || !listContainsToken(connection->value, "upgrade")) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
                             "upgrade response is missing 'Connection: Upgrade'");
  }

  const std::string material = key + kAcceptGuid;
  uint8_t digest[20];
  sha1(reinterpret_cast<const uint8_t*>(material.data()), material.size(), digest);
  const std::string expected = base64Encode(digest, sizeof(digest));
  const RawHeader* accept = findHeader(*responseHeaders, "sec-websocket-accept");
  if (!accept || trimAsciiSpace(accept->value) != expected) {
    return EngineError::make(
        RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
        "Sec-WebSocket-Accept mismatch: expected " + expected + ", got " +
            (accept ? trimAsciiSpace(accept->value) : std::string("<absent>")));
  }

  // We advertise no extensions, so any the server names are ones it invented.
  const RawHeader* extensions = findHeader(*responseHeaders, "sec-websocket-extensions");
  if (extensions && !trimAsciiSpace(extensions->value).empty()) {
    return EngineError::make(
        RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
        "server selected unrequested WebSocket extensions: " + extensions->value);
  }

  const RawHeader* chosen = findHeader(*responseHeaders, "sec-websocket-protocol");
  if (chosen) {
    const std::string value = trimAsciiSpace(chosen->value);
    bool offered = value.empty();
    for (const std::string& p : cfg.protocols) {
      if (asciiEqualIgnoreCase(p, value)) {
        offered = true;
        break;
      }
    }
    if (!offered) {
      return EngineError::make(
          RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR,
          "server selected the unoffered subprotocol '" + value + "'");
    }
    *negotiatedProtocol = value;
  }

  return EngineError::none();
}

// ── Receive loop ─────────────────────────────────────────────────────────────

void WsSession::receiveLoop() {
  using namespace wsdetail;

  std::vector<uint8_t> rx;
  rx.swap(handshakeLeftover());
  lastPingMs_ = monotonicMs();

  bool running = true;
  // Every protocol violation gets the same two-part treatment: tell the peer
  // why with a close frame, then give Dart its single terminal event. Calling
  // close() here instead would block this very thread waiting for a mirrored
  // close that we have already stopped reading for.
  const auto failProtocol = [this, &running](int64_t code, const std::string& text) {
    std::vector<uint8_t> payload;
    payload.push_back(static_cast<uint8_t>((code >> 8) & 0xFF));
    payload.push_back(static_cast<uint8_t>(code & 0xFF));
    const size_t take = std::min(text.size(), kMaxCloseReason);
    payload.insert(payload.end(), text.begin(),
                   text.begin() + static_cast<std::ptrdiff_t>(take));
    send(wsopcode::kClose, payload.data(), payload.size());
    flushOutbox();
    emitTransportError(
        EngineError::make(RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR, text));
    running = false;
  };

  while (running && !stopping_.load()) {
    if (!flushOutbox()) {
      emitTransportError(EngineError::make(RawErrorKind::RAWERRORKIND_SEND_FAILURE,
                                           "WebSocket send failed"));
      break;
    }

    // The close handshake deadline lives here, not in `close()`: the caller is
    // the Dart isolate and must not be blocked. A peer that answers our close by
    // simply dropping the connection — which is legal, and what `dart:io`'s
    // server does — would otherwise leave Dart with no terminal event at all.
    if (closeSent_.load() && !closeReceived_.load()) {
      const double deadline = closeDeadlineMs_.load();
      if (deadline > 0.0 && monotonicMs() >= deadline) {
        emitSyntheticClose(sentCloseCode_.load(), "no close frame from peer");
        break;
      }
    }

    if (pingIntervalMs_ > 0 &&
        monotonicMs() - lastPingMs_ >= static_cast<double>(pingIntervalMs_)) {
      lastPingMs_ = monotonicMs();
      send(wsopcode::kPing, nullptr, 0);
    }

    // ── Drain whatever is already buffered ────────────────────────────────
    size_t consumed = 0;
    while (running) {
      // The window governs emission, not just reading: one socket read can
      // carry a dozen frames, so draining them all would overshoot the credit
      // Dart granted. Leaving them parsed-but-unconsumed in `rx` costs one
      // buffer's worth of memory and keeps the invariant exact.
      if (credits_.load() <= 0) break;
      const ParsedFrame f =
          parseFrameHeader(rx.data() + consumed, rx.size() - consumed);
      if (!f.complete) break;
      if (f.protocolError) {
        failProtocol(1002, f.errorText ? f.errorText : "protocol error");
        break;
      }
      if (rx.size() - consumed < f.headerBytes + f.payloadBytes) break;

      const uint8_t* payload = rx.data() + consumed + f.headerBytes;
      const size_t payloadLen = f.payloadBytes;
      consumed += f.headerBytes + f.payloadBytes;

      switch (f.opcode) {
        case wsopcode::kPing:
          // Answered here rather than surfaced to Dart: RFC 6455 §5.5.2 wants
          // the pong "as soon as practical", which a Dart round trip is not.
          send(wsopcode::kPong, payload, payloadLen);
          break;

        case wsopcode::kPong:
          // Our own keepalive came back; nothing for Dart to do with it.
          break;

        case wsopcode::kClose: {
          closeReceived_.store(true);
          emitFrame(wsopcode::kClose, true, payload, payloadLen);
          if (!closeSent_.load()) {
            // Mirror the peer's status code, as RFC 6455 §5.5.1 requires.
            uint8_t echo[2] = {0x03, 0xE8};  // 1000, normal closure
            size_t echoLen = 0;
            if (payloadLen >= 2) {
              echo[0] = payload[0];
              echo[1] = payload[1];
              echoLen = 2;
            }

            send(wsopcode::kClose, echo, echoLen);
            flushOutbox();
          }
          running = false;
          break;
        }

        case wsopcode::kContinuation:
        case wsopcode::kText:
        case wsopcode::kBinary: {
          // Fragment sequencing lives here, not in `parseFrameHeader`: the
          // parser is static and stateless by design, and only the session
          // knows whether a message is already in progress.
          const bool continuation = f.opcode == wsopcode::kContinuation;
          if (continuation && fragmentOpcode_ == 0) {
            failProtocol(1002, "continuation frame with no message in progress");
            break;
          }
          if (!continuation && fragmentOpcode_ != 0) {
            failProtocol(1002, "new data frame while a message is still fragmented");
            break;
          }
          if (fragment_.size() + payloadLen > static_cast<size_t>(maxFrameBytes_)) {
            failProtocol(1009, "message exceeds the configured maximum size");
            break;
          }

          // A lone unfragmented frame skips the reassembly buffer entirely.
          if (!continuation && f.fin) {
            deliverMessage(f.opcode,
                           std::vector<uint8_t>(payload, payload + payloadLen));
          } else {
            if (!continuation) fragmentOpcode_ = f.opcode;
            fragment_.insert(fragment_.end(), payload, payload + payloadLen);
            if (f.fin) {
              const int64_t opcode = fragmentOpcode_;
              fragmentOpcode_ = 0;
              deliverMessage(opcode, std::move(fragment_));
              fragment_.clear();
            }
          }
          break;
        }

        default:
          // `parseFrameHeader` already rejected every other opcode.
          break;
      }
    }
    if (consumed > 0) {
      rx.erase(rx.begin(), rx.begin() + static_cast<std::ptrdiff_t>(consumed));
    }
    if (!running || stopping_.load()) break;

    // ── Backpressure ──────────────────────────────────────────────────────
    //
    // With no credit we simply do not read. The kernel receive buffer fills,
    // the TCP window closes and the peer stops sending — real backpressure,
    // with no Dart-side queue to grow without bound.
    if (credits_.load() <= 0) {
      sleepMs(5);
      continue;
    }

    // Try the read before polling: a TLS record already decrypted inside curl
    // is invisible to poll(), so poll-first would stall on buffered data.
    uint8_t buf[kRecvChunk];
    size_t got = 0;
    CURLcode rrc;
    size_t pending = 0;
    {
      std::lock_guard<std::mutex> lock(ioMtx_);
      rrc = curl_easy_recv(easy_, buf, sizeof(buf), &got);
      pending = outbox_.size();
    }
    if (rrc == CURLE_AGAIN) {
      if (waitSocket(sock_, true, pending > 0, kPollSliceMs) < 0) {
        emitTransportError(EngineError::make(RawErrorKind::RAWERRORKIND_IO,
                                             "WebSocket socket failed"));
        break;
      }
      continue;
    }
    if (rrc != CURLE_OK) {
      emitTransportError(EngineError::make(
          mapCurlError(rrc, false), describeCurlError(rrc, curl_easy_strerror(rrc)),
          rrc));
      break;
    }
    if (got == 0) {
      if (closeReceived_.load()) {
        // Both sides exchanged close frames; Dart already has its terminal
        // event.
      } else if (closeSent_.load()) {
        // We asked to close and the peer answered by dropping the connection.
        // That is a normal completion of OUR close, not a transport failure, so
        // report the code we sent rather than 1006.
        emitSyntheticClose(sentCloseCode_.load(),
                           "peer closed the connection after our close frame");
      } else {
        // A clean TCP close with no close frame from either side is an abnormal
        // WebSocket termination; Dart needs to hear about it exactly once.
        emitTransportError(EngineError::make(
            RawErrorKind::RAWERRORKIND_CONNECTION_RESET,
            "peer closed the connection without a close frame"));
      }
      break;
    }
    rx.insert(rx.end(), buf, buf + got);
  }
}

// ── Emission ─────────────────────────────────────────────────────────────────

void WsSession::deliverMessage(int64_t opcode, std::vector<uint8_t>&& payload) {
  const std::vector<uint8_t> owned = std::move(payload);
  emitFrame(opcode, true, owned.data(), owned.size());
}

void WsSession::emitSyntheticClose(int64_t code, const std::string& reason) {
  // Exactly once: the deadline path and the TCP-close path can both fire for the
  // same closure, and Dart's event stream terminates on the first close it sees.
  if (closeReceived_.exchange(true)) return;
  std::vector<uint8_t> payload;
  payload.push_back(static_cast<uint8_t>((code >> 8) & 0xFF));
  payload.push_back(static_cast<uint8_t>(code & 0xFF));
  const size_t take = std::min(reason.size(), wsdetail::kMaxCloseReason);
  payload.insert(payload.end(), reason.begin(),
                 reason.begin() + static_cast<std::ptrdiff_t>(take));
  emitFrame(wsopcode::kClose, true, payload.data(), payload.size());
}

void WsSession::emitFrame(int64_t opcode, bool fin, const uint8_t* payload,
                          size_t n) {
  const StreamSink& sink = streamSink();
  if (!sink.wsFrame) return;

  Blob blob = Blob::copy(payload, n);
  if (!blob.data) {
    // An empty payload copies to a null pointer, and the Dart proxy would call
    // asTypedList() on it. One byte keeps the pointer dereferenceable.
    blob.data = static_cast<uint8_t*>(std::malloc(1));
    blob.size = 0;
    if (!blob.data) return;
  }

  arena_.track(emittedSeq_, blob);

  RawWsFrame frame{};
  frame.payload = blob.data;
  frame.payloadLength = static_cast<int64_t>(n);
  frame.socketId = socketId_;
  frame.opcode = opcode;
  frame.flags = fin ? 1 : 0;
  sink.wsFrame(frame);

  ++emittedSeq_;
  credits_.fetch_sub(1);
}

void WsSession::emitTransportError(const EngineError& err) {
  const std::string text =
      err.message.empty() ? std::string("WebSocket transport failure") : err.message;
  emitFrame(wsopcode::kTransportError, true,
            reinterpret_cast<const uint8_t*>(text.data()), text.size());
  stopping_.store(true);
}

// ── Sending ──────────────────────────────────────────────────────────────────

int64_t WsSession::send(int64_t opcode, const uint8_t* payload, size_t n) {
  const bool control = opcode == wsopcode::kClose ||
                       opcode == wsopcode::kPing || opcode == wsopcode::kPong;
  const bool data = opcode == wsopcode::kContinuation ||
                    opcode == wsopcode::kText || opcode == wsopcode::kBinary;
  if (!control && !data) {
    std::lock_guard<std::mutex> lock(ioMtx_);
    return static_cast<int64_t>(outboxBytes_);
  }
  if (data && closeSent_.load()) {
    // RFC 6455 §5.5.1: nothing may follow a close frame we already queued.
    std::lock_guard<std::mutex> lock(ioMtx_);
    return static_cast<int64_t>(outboxBytes_);
  }
  if (opcode == wsopcode::kClose) closeSent_.store(true);

  std::vector<std::vector<uint8_t>> frames;
  if (control) {
    if (n > 125) n = 125;
    frames.push_back(encodeFrame(opcode, true, payload, n, wsdetail::random32()));
  } else {
    const size_t limit =
        maxFrameBytes_ > 0 ? static_cast<size_t>(maxFrameBytes_) : n;
    if (n <= limit) {
      frames.push_back(encodeFrame(opcode, true, payload, n, wsdetail::random32()));
    } else {
      size_t off = 0;
      bool first = true;
      while (off < n) {
        const size_t take = std::min(limit, n - off);
        const bool last = off + take == n;
        frames.push_back(encodeFrame(first ? opcode : wsopcode::kContinuation,
                                     last, payload + off, take,
                                     wsdetail::random32()));
        off += take;
        first = false;
      }
    }
  }

  {
    std::lock_guard<std::mutex> lock(ioMtx_);
    for (std::vector<uint8_t>& frame : frames) {
      outboxBytes_ += frame.size();
      if (control) {
        // Control frames jump the queue, but never ahead of a head buffer that
        // is already half-written — the peer would see interleaved garbage.
        const auto at = outbox_.begin() + (outboxHeadOffset_ > 0 ? 1 : 0);
        outbox_.insert(at, std::move(frame));
      } else {
        outbox_.push_back(std::move(frame));
      }
    }
  }

  // Before the handshake completes there is no socket to write to; the receive
  // loop flushes these on its first pass.
  if (connected_.load()) flushOutbox();

  std::lock_guard<std::mutex> lock(ioMtx_);
  return static_cast<int64_t>(outboxBytes_);
}

bool WsSession::flushOutbox() {
  std::lock_guard<std::mutex> lock(ioMtx_);
  if (!easy_ || sock_ == CURL_SOCKET_BAD) return true;

  while (!outbox_.empty()) {
    std::vector<uint8_t>& head = outbox_.front();
    const size_t remaining = head.size() - outboxHeadOffset_;
    size_t sent = 0;
    const CURLcode rc =
        curl_easy_send(easy_, head.data() + outboxHeadOffset_, remaining, &sent);

    outboxHeadOffset_ += sent;
    outboxBytes_ -= sent;
    if (outboxHeadOffset_ >= head.size()) {
      outbox_.pop_front();
      outboxHeadOffset_ = 0;
    }

    if (rc == CURLE_AGAIN) return true;  // socket buffer full; resume next pass
    if (rc != CURLE_OK) return false;
  }
  return true;
}

bool WsSession::sendRaw(const uint8_t* data, size_t n) {
  size_t off = 0;
  while (off < n) {
    if (stopping_.load()) return false;
    size_t sent = 0;
    CURLcode rc;
    {
      std::lock_guard<std::mutex> lock(ioMtx_);
      rc = curl_easy_send(easy_, data + off, n - off, &sent);
    }
    off += sent;
    if (rc == CURLE_AGAIN) {
      if (wsdetail::waitSocket(sock_, false, true, wsdetail::kPollSliceMs) < 0) {
        return false;
      }
      continue;
    }
    if (rc != CURLE_OK) return false;
  }
  return true;
}

// ── Teardown ─────────────────────────────────────────────────────────────────

void WsSession::close(int64_t code, const std::string& reason) {
  // Returns immediately. This runs on the Dart isolate thread as a synchronous
  // FFI call, so waiting out the close handshake here would block a Flutter
  // frame for up to `kCloseHandshakeTimeoutMs`. The receive thread owns the
  // deadline and synthesises the terminal frame if the peer never mirrors the
  // close — which is common: a peer is entitled to answer by simply dropping
  // the TCP connection, and `dart:io`'s server does exactly that.
  if (!connected_.load() || closeSent_.load()) {
    // Nothing to negotiate. If the receive loop is already gone there will be no
    // terminal frame from it, so tear down here instead of leaving Dart waiting.
    if (!thread_.joinable()) shutdown();
    return;
  }

  std::vector<uint8_t> payload;
  if (code > 0) {
    payload.push_back(static_cast<uint8_t>((code >> 8) & 0xFF));
    payload.push_back(static_cast<uint8_t>(code & 0xFF));
    const size_t take = std::min(reason.size(), wsdetail::kMaxCloseReason);
    payload.insert(payload.end(), reason.begin(),
                   reason.begin() + static_cast<std::ptrdiff_t>(take));
  }
  sentCloseCode_.store(code > 0 ? code : 1000);
  closeDeadlineMs_.store(monotonicMs() + wsdetail::kCloseHandshakeTimeoutMs);
  send(wsopcode::kClose, payload.data(), payload.size());
  flushOutbox();
}

void WsSession::grantCredit(int64_t frameCount, int64_t ackedFrames) {
  if (frameCount > 0) credits_.fetch_add(frameCount);
  arena_.ack(ackedFrames);
  // A grant can arrive after the session tore down — Dart's terminal ack races
  // the close frame it is reacting to. Release from the deferred registry too.
  DeferredPayloads& deferred = DeferredPayloads::instance();
  if (frameCount == 0) {
    deferred.releaseAll(PayloadOwner::Socket, socketId_);
  } else {
    deferred.ack(PayloadOwner::Socket, socketId_, ackedFrames);
  }
}

void WsSession::shutdown() {
  stopping_.store(true);

  if (thread_.joinable()) {
    // Joining from the receive thread would deadlock. The loop is already
    // unwinding thanks to `stopping_`; whoever owns the session (close() or
    // the destructor) performs the join and the cleanup below.
    if (thread_.get_id() == std::this_thread::get_id()) return;
    thread_.join();
  }

  if (easy_) {
    curl_easy_cleanup(easy_);
    easy_ = nullptr;
  }
  sock_ = CURL_SOCKET_BAD;
  connected_.store(false);

  {
    std::lock_guard<std::mutex> lock(ioMtx_);
    outbox_.clear();
    outboxBytes_ = 0;
    outboxHeadOffset_ = 0;
  }
  fragment_.clear();
  fragmentOpcode_ = 0;

  // NOT `arena_.releaseAll()`. `Dart_PostCObject_DL` returning true means
  // DELIVERED, not PROCESSED: frames already posted may still be sitting in the
  // isolate's queue, and the Dart proxy reads their payload lazily. Hand them to
  // the deferred registry, which frees them on Dart's terminal
  // `wsGrantCredit(0, acked)` — sent only after it has stopped reading.
  DeferredPayloads::instance().adopt(PayloadOwner::Socket, socketId_, arena_);
}

}  // namespace nitrohttp
