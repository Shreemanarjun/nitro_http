// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — shared vocabulary implementation.
//
// Nothing here may depend on the generated bridge class, on a Dart VM, or on a
// TLS library's headers: this file is linked into the C++ test binary as-is.
// That is why SHA-256 and base64 are hand-rolled rather than borrowed from
// OpenSSL — the vendored TLS library is symbol-prefixed on some platforms, so
// its headers are not reliably reachable from engine sources.
// ─────────────────────────────────────────────────────────────────────────────

#include "Common.h"

#include <curl/curl.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <utility>

namespace nitrohttp {

// ── Time ─────────────────────────────────────────────────────────────────────

double monotonicMs() {
  using clock = std::chrono::steady_clock;
  const auto now = clock::now().time_since_epoch();
  return std::chrono::duration<double, std::milli>(now).count();
}

int64_t wallClockMs() {
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
}

// ── Byte buffers ─────────────────────────────────────────────────────────────

Blob Blob::copy(const void* src, size_t n) {
  if (src == nullptr || n == 0) return Blob{};
  auto* p = static_cast<uint8_t*>(::malloc(n));
  if (p == nullptr) return Blob{};
  std::memcpy(p, src, n);
  return Blob{p, n};
}

void Blob::release() {
  ::free(data);
  data = nullptr;
  size = 0;
}

// ── Errors ───────────────────────────────────────────────────────────────────

RawErrorKind mapCurlError(int curlCode, bool proxyInUse) {
  switch (static_cast<CURLcode>(curlCode)) {
    case CURLE_OK:
      return RawErrorKind::RAWERRORKIND_NONE;

    // ── Timeouts ─────────────────────────────────────────────────────────────
    // curl reports one code for every deadline it enforces. Distinguishing a
    // connect timeout from a request timeout needs CURLINFO_CONNECT_TIME, which
    // only the task holding the handle can read, so it refines this at the call
    // site; the honest default here is the request deadline.
    case CURLE_OPERATION_TIMEDOUT:
      return RawErrorKind::RAWERRORKIND_TIMEOUT_REQUEST;

    // ── Name resolution ──────────────────────────────────────────────────────
    case CURLE_COULDNT_RESOLVE_HOST:
      return RawErrorKind::RAWERRORKIND_DNS_FAILURE;
    case CURLE_COULDNT_RESOLVE_PROXY:
      return proxyInUse ? RawErrorKind::RAWERRORKIND_PROXY_FAILURE
                        : RawErrorKind::RAWERRORKIND_DNS_FAILURE;

    // ── Connection ───────────────────────────────────────────────────────────
    case CURLE_COULDNT_CONNECT:
      return RawErrorKind::RAWERRORKIND_CONNECTION_REFUSED;
    case CURLE_RECV_ERROR:
    case CURLE_SSL_SHUTDOWN_FAILED:
      return RawErrorKind::RAWERRORKIND_CONNECTION_RESET;
    case CURLE_SEND_ERROR:
    case CURLE_SEND_FAIL_REWIND:
    case CURLE_UPLOAD_FAILED:
    case CURLE_HTTP_POST_ERROR:
      return RawErrorKind::RAWERRORKIND_SEND_FAILURE;
    case CURLE_PARTIAL_FILE:
      return RawErrorKind::RAWERRORKIND_RECEIVE_FAILURE;
    case CURLE_INTERFACE_FAILED:
    case CURLE_NO_CONNECTION_AVAILABLE:
      return RawErrorKind::RAWERRORKIND_CONNECTION_FAILED;

    // ── TLS ──────────────────────────────────────────────────────────────────
    case CURLE_SSL_CONNECT_ERROR:
    case CURLE_SSL_CIPHER:
    case CURLE_USE_SSL_FAILED:
      return RawErrorKind::RAWERRORKIND_TLS_HANDSHAKE;
    // CURLE_SSL_CACERT is a deprecated alias of CURLE_PEER_FAILED_VERIFICATION
    // (both 60), so it cannot appear as a second label.
    case CURLE_PEER_FAILED_VERIFICATION:
    case CURLE_SSL_CACERT_BADFILE:
    case CURLE_SSL_CRL_BADFILE:
    case CURLE_SSL_ISSUER_ERROR:
    case CURLE_SSL_INVALIDCERTSTATUS:
      return RawErrorKind::RAWERRORKIND_CERTIFICATE_INVALID;
    case CURLE_SSL_PINNEDPUBKEYNOTMATCH:
      return RawErrorKind::RAWERRORKIND_CERTIFICATE_PIN_MISMATCH;
    case CURLE_SSL_CERTPROBLEM:
      return RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH;
#if LIBCURL_VERSION_NUM >= 0x074d00  // 7.77.0
    case CURLE_SSL_CLIENTCERT:
      return RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH;
#endif
#if LIBCURL_VERSION_NUM >= 0x080800  // 8.8.0
    case CURLE_ECH_REQUIRED:
      return RawErrorKind::RAWERRORKIND_TLS_HANDSHAKE;
#endif

    // ── Redirects and proxies ────────────────────────────────────────────────
    case CURLE_TOO_MANY_REDIRECTS:
      return RawErrorKind::RAWERRORKIND_TOO_MANY_REDIRECTS;
#if LIBCURL_VERSION_NUM >= 0x074900  // 7.73.0
    case CURLE_PROXY:
      return RawErrorKind::RAWERRORKIND_PROXY_FAILURE;
#endif

    // ── Scheme ───────────────────────────────────────────────────────────────
    // UNSUPPORTED_PROTOCOL is a scheme problem, not a framing problem: curl
    // returns it when the URL names a protocol this build cannot speak, which
    // is exactly what `unsupportedScheme` tells the user to fix.
    case CURLE_UNSUPPORTED_PROTOCOL:
    case CURLE_URL_MALFORMAT:
      return RawErrorKind::RAWERRORKIND_UNSUPPORTED_SCHEME;

    // ── Protocol framing and server behaviour ────────────────────────────────
    case CURLE_HTTP2:
    case CURLE_HTTP2_STREAM:
    case CURLE_WEIRD_SERVER_REPLY:
    case CURLE_GOT_NOTHING:
    case CURLE_HTTP_RETURNED_ERROR:
    case CURLE_RANGE_ERROR:
    case CURLE_BAD_DOWNLOAD_RESUME:
    case CURLE_LOGIN_DENIED:
    case CURLE_REMOTE_ACCESS_DENIED:
      return RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR;
#if LIBCURL_VERSION_NUM >= 0x074200  // 7.66.0
    case CURLE_HTTP3:
    case CURLE_AUTH_ERROR:
      return RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR;
#endif
#if LIBCURL_VERSION_NUM >= 0x074500  // 7.69.0
    case CURLE_QUIC_CONNECT_ERROR:
      return RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR;
#endif

    // ── Content coding ───────────────────────────────────────────────────────
    case CURLE_BAD_CONTENT_ENCODING:
      return RawErrorKind::RAWERRORKIND_DECOMPRESSION_FAILURE;

    // ── Cancellation ─────────────────────────────────────────────────────────
    // Our XFERINFOFUNCTION returns non-zero to abort, which surfaces here.
    case CURLE_ABORTED_BY_CALLBACK:
      return RawErrorKind::RAWERRORKIND_CANCELLED;

    // ── Local I/O ────────────────────────────────────────────────────────────
    case CURLE_WRITE_ERROR:
    case CURLE_READ_ERROR:
    case CURLE_FILE_COULDNT_READ_FILE:
    case CURLE_CHUNK_FAILED:
      return RawErrorKind::RAWERRORKIND_IO;

    // Only `CURLOPT_MAXFILESIZE_LARGE` produces this, and only when a declared
    // Content-Length is over the ceiling — so it means the same thing as our own
    // running byte check, just earlier.
    case CURLE_FILESIZE_EXCEEDED:
      return RawErrorKind::RAWERRORKIND_RESPONSE_TOO_LARGE;

    // ── Caller-supplied nonsense ─────────────────────────────────────────────
    case CURLE_BAD_FUNCTION_ARGUMENT:
      return RawErrorKind::RAWERRORKIND_BAD_REQUEST;
#if LIBCURL_VERSION_NUM >= 0x080600  // 8.6.0
    case CURLE_TOO_LARGE:
      return RawErrorKind::RAWERRORKIND_BAD_REQUEST;
#endif

    // ── Our own bugs and environment failures ────────────────────────────────
    case CURLE_FAILED_INIT:
    case CURLE_NOT_BUILT_IN:
    case CURLE_OUT_OF_MEMORY:
    case CURLE_FUNCTION_NOT_FOUND:
    case CURLE_UNKNOWN_OPTION:
    case CURLE_SETOPT_OPTION_SYNTAX:
    case CURLE_SSL_ENGINE_NOTFOUND:
    case CURLE_SSL_ENGINE_SETFAILED:
    case CURLE_SSL_ENGINE_INITFAILED:
    case CURLE_AGAIN:
    case CURLE_RECURSIVE_API_CALL:
      return RawErrorKind::RAWERRORKIND_ENGINE_ERROR;
#if LIBCURL_VERSION_NUM >= 0x075400  // 7.84.0
    case CURLE_UNRECOVERABLE_POLL:
      return RawErrorKind::RAWERRORKIND_ENGINE_ERROR;
#endif

    // Everything left over belongs to a protocol we never speak (FTP, TFTP,
    // LDAP, SSH, RTSP) or to a curl release newer than this build.
    default:
      return RawErrorKind::RAWERRORKIND_UNKNOWN;
  }
}

namespace common_detail {

const char* kindToken(RawErrorKind kind) {
  switch (kind) {
    case RawErrorKind::RAWERRORKIND_NONE: return "none";
    case RawErrorKind::RAWERRORKIND_CANCELLED: return "cancelled";
    case RawErrorKind::RAWERRORKIND_TIMEOUT_CONNECT: return "timeoutConnect";
    case RawErrorKind::RAWERRORKIND_TIMEOUT_REQUEST: return "timeoutRequest";
    case RawErrorKind::RAWERRORKIND_TIMEOUT_IDLE: return "timeoutIdle";
    case RawErrorKind::RAWERRORKIND_DNS_FAILURE: return "dnsFailure";
    case RawErrorKind::RAWERRORKIND_CONNECTION_REFUSED: return "connectionRefused";
    case RawErrorKind::RAWERRORKIND_CONNECTION_RESET: return "connectionReset";
    case RawErrorKind::RAWERRORKIND_CONNECTION_FAILED: return "connectionFailed";
    case RawErrorKind::RAWERRORKIND_TLS_HANDSHAKE: return "tlsHandshake";
    case RawErrorKind::RAWERRORKIND_CERTIFICATE_INVALID: return "certificateInvalid";
    case RawErrorKind::RAWERRORKIND_CERTIFICATE_PIN_MISMATCH: return "certificatePinMismatch";
    case RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH: return "certificateClientAuth";
    case RawErrorKind::RAWERRORKIND_TOO_MANY_REDIRECTS: return "tooManyRedirects";
    case RawErrorKind::RAWERRORKIND_PROXY_FAILURE: return "proxyFailure";
    case RawErrorKind::RAWERRORKIND_PROTOCOL_ERROR: return "protocolError";
    case RawErrorKind::RAWERRORKIND_UNSUPPORTED_SCHEME: return "unsupportedScheme";
    case RawErrorKind::RAWERRORKIND_SEND_FAILURE: return "sendFailure";
    case RawErrorKind::RAWERRORKIND_RECEIVE_FAILURE: return "receiveFailure";
    case RawErrorKind::RAWERRORKIND_DECOMPRESSION_FAILURE: return "decompressionFailure";
    case RawErrorKind::RAWERRORKIND_RESPONSE_TOO_LARGE: return "responseTooLarge";
    case RawErrorKind::RAWERRORKIND_IO: return "io";
    case RawErrorKind::RAWERRORKIND_CACHE_MISS: return "cacheMiss";
    case RawErrorKind::RAWERRORKIND_ENGINE_ERROR: return "engineError";
    case RawErrorKind::RAWERRORKIND_BAD_REQUEST: return "badRequest";
    case RawErrorKind::RAWERRORKIND_UNKNOWN: return "unknown";
  }
  return "unknown";
}

}  // namespace common_detail

std::string describeCurlError(int curlCode, const char* curlMessage) {
  const char* text = (curlMessage != nullptr && curlMessage[0] != '\0')
                         ? curlMessage
                         : curl_easy_strerror(static_cast<CURLcode>(curlCode));
  std::string out = common_detail::kindToken(mapCurlError(curlCode, false));
  out += ": ";
  out += (text != nullptr) ? text : "unknown libcurl failure";
  out += " (CURLcode ";
  out += std::to_string(curlCode);
  out += ')';
  return out;
}

std::string cancelledMessage(const std::string& reason) {
  std::string out = "request cancelled";
  if (!reason.empty()) {
    out += ": ";
    out += reason;
  }
  return out;
}

EngineError cancelledError(const std::string& reason) {
  return EngineError::make(RawErrorKind::RAWERRORKIND_CANCELLED,
                           cancelledMessage(reason));
}

// ── Stream sink ──────────────────────────────────────────────────────────────
//
// Installed exactly once, from the library constructor in HybridNitroHttp.cpp,
// before any engine exists and therefore before any emit. That ordering is what
// makes the unsynchronised read safe: there is no point in the process at which
// one thread emits while another installs.

StreamSink& streamSink() {
  static StreamSink sink;
  return sink;
}

void installStreamSink(StreamSink sink) { streamSink() = std::move(sink); }

// ── Small helpers ────────────────────────────────────────────────────────────

namespace common_detail {

inline char lowerAscii(char c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

inline bool isAsciiSpace(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' ||
         c == '\v';
}

inline bool isAsciiDigit(char c) { return c >= '0' && c <= '9'; }

/// One `key[=value]` pair of a query string. `hasEquals` is carried separately
/// because `?a` and `?a=` are distinct resources.
struct QueryParam {
  std::string key;
  std::string value;
  bool hasEquals;
};

}  // namespace common_detail

bool asciiEqualIgnoreCase(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (common_detail::lowerAscii(a[i]) != common_detail::lowerAscii(b[i])) {
      return false;
    }
  }
  return true;
}

std::string asciiLower(std::string s) {
  for (char& c : s) c = common_detail::lowerAscii(c);
  return s;
}

std::string trimAsciiSpace(const std::string& s) {
  size_t begin = 0;
  size_t end = s.size();
  while (begin < end && common_detail::isAsciiSpace(s[begin])) ++begin;
  while (end > begin && common_detail::isAsciiSpace(s[end - 1])) --end;
  return s.substr(begin, end - begin);
}

const RawHeader* findHeader(const std::vector<RawHeader>& headers,
                            const std::string& name) {
  for (const RawHeader& h : headers) {
    if (asciiEqualIgnoreCase(h.name, name)) return &h;
  }
  return nullptr;
}

bool parseStatusLine(const std::string& line, int* statusCode,
                     std::string* reasonPhrase) {
  // "HTTP/" version SP 3DIGIT [SP reason]. HTTP/2 and HTTP/3 status lines
  // (synthesised by curl from the :status pseudo-header) carry a single-digit
  // version and frequently no reason phrase at all.
  static const char kPrefix[] = "HTTP/";
  static const size_t kPrefixLen = sizeof(kPrefix) - 1;
  if (line.size() < kPrefixLen + 5) return false;  // "HTTP/" + "2 200"
  if (line.compare(0, kPrefixLen, kPrefix) != 0) return false;

  size_t i = kPrefixLen;
  const size_t versionStart = i;
  while (i < line.size() &&
         (common_detail::isAsciiDigit(line[i]) || line[i] == '.')) {
    ++i;
  }
  if (i == versionStart) return false;

  if (i >= line.size() || (line[i] != ' ' && line[i] != '\t')) return false;
  while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;

  if (i + 3 > line.size()) return false;
  if (!common_detail::isAsciiDigit(line[i]) ||
      !common_detail::isAsciiDigit(line[i + 1]) ||
      !common_detail::isAsciiDigit(line[i + 2])) {
    return false;
  }
  const int code = (line[i] - '0') * 100 + (line[i + 1] - '0') * 10 +
                   (line[i + 2] - '0');
  i += 3;
  // A fourth digit means this is not a status code.
  if (i < line.size() && common_detail::isAsciiDigit(line[i])) return false;

  if (statusCode != nullptr) *statusCode = code;
  if (reasonPhrase != nullptr) {
    // Everything after the code, minus the separating space and the CRLF curl
    // leaves on the line.
    while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;
    *reasonPhrase = trimAsciiSpace(line.substr(i));
  }
  return true;
}

bool parseHeaderLine(const std::string& line, std::string* name,
                     std::string* value) {
  if (line.empty()) return false;
  // A leading space or tab is an obs-fold continuation of the previous header,
  // not a header of its own.
  if (line[0] == ' ' || line[0] == '\t') return false;

  const size_t colon = line.find(':');
  if (colon == std::string::npos || colon == 0) return false;

  // RFC 9110 forbids whitespace between the field name and the colon; a line
  // that has it is malformed and must not be treated as a header.
  std::string rawName = line.substr(0, colon);
  for (char c : rawName) {
    if (common_detail::isAsciiSpace(c)) return false;
    if (static_cast<unsigned char>(c) < 0x21 ||
        static_cast<unsigned char>(c) > 0x7e) {
      return false;
    }
  }

  if (name != nullptr) *name = std::move(rawName);
  if (value != nullptr) *value = trimAsciiSpace(line.substr(colon + 1));
  return true;
}

std::string canonicalizeUrl(const std::string& url) {
  const std::string input = trimAsciiSpace(url);

  const size_t schemeEnd = input.find("://");
  if (schemeEnd == 0 || schemeEnd == std::string::npos) {
    // Not something we can decompose. Still drop the fragment so the two
    // spellings that differ only there hash the same.
    const size_t hash = input.find('#');
    return hash == std::string::npos ? input : input.substr(0, hash);
  }

  const std::string scheme = asciiLower(input.substr(0, schemeEnd));
  size_t pos = schemeEnd + 3;

  const size_t authorityEnd = input.find_first_of("/?#", pos);
  std::string authority = input.substr(
      pos, authorityEnd == std::string::npos ? std::string::npos
                                            : authorityEnd - pos);
  pos = authorityEnd;

  // Userinfo is kept verbatim: two sets of credentials address two distinct
  // resources as far as a cache is concerned, and every consumer of this key
  // hashes it before it reaches a filesystem.
  std::string userinfo;
  const size_t at = authority.rfind('@');
  if (at != std::string::npos) {
    userinfo = authority.substr(0, at);
    authority.erase(0, at + 1);
  }

  std::string host = authority;
  std::string port;
  {
    // An IPv6 literal is bracketed, so only a colon after the closing bracket
    // introduces a port.
    const size_t searchFrom =
        (!authority.empty() && authority[0] == '[') ? authority.find(']') : 0;
    if (searchFrom != std::string::npos) {
      const size_t colon = authority.find(':', searchFrom);
      if (colon != std::string::npos) {
        host = authority.substr(0, colon);
        port = authority.substr(colon + 1);
      }
    }
  }
  host = asciiLower(host);

  const bool defaultPort =
      ((scheme == "http" || scheme == "ws") && port == "80") ||
      ((scheme == "https" || scheme == "wss") && port == "443");
  if (defaultPort || port.empty()) port.clear();

  std::string path;
  std::string query;
  if (pos != std::string::npos) {
    const size_t hash = input.find('#', pos);
    const std::string rest = input.substr(
        pos, hash == std::string::npos ? std::string::npos : hash - pos);
    const size_t question = rest.find('?');
    if (question == std::string::npos) {
      path = rest;
    } else {
      path = rest.substr(0, question);
      query = rest.substr(question + 1);
    }
  }
  if (path.empty()) path = "/";

  // Sorting by (key, value) makes `?b=2&a=1` and `?a=1&b=2` one cache entry.
  // Parameter order is semantically insignificant for every API worth caching,
  // and a server that disagrees is not one we can cache correctly anyway.
  if (!query.empty()) {
    std::vector<common_detail::QueryParam> params;
    size_t start = 0;
    while (start <= query.size()) {
      size_t amp = query.find('&', start);
      if (amp == std::string::npos) amp = query.size();
      if (amp > start) {
        const std::string token = query.substr(start, amp - start);
        const size_t eq = token.find('=');
        if (eq == std::string::npos) {
          params.push_back({token, std::string(), false});
        } else {
          params.push_back({token.substr(0, eq), token.substr(eq + 1), true});
        }
      }
      if (amp == query.size()) break;
      start = amp + 1;
    }
    std::stable_sort(params.begin(), params.end(),
                     [](const common_detail::QueryParam& a,
                        const common_detail::QueryParam& b) {
                       if (a.key != b.key) return a.key < b.key;
                       return a.value < b.value;
                     });
    query.clear();
    for (size_t i = 0; i < params.size(); ++i) {
      if (i != 0) query += '&';
      query += params[i].key;
      // `?a=` and `?a` are different query strings; keep them different keys.
      if (params[i].hasEquals) {
        query += '=';
        query += params[i].value;
      }
    }
  }

  std::string out;
  out.reserve(input.size());
  out += scheme;
  out += "://";
  if (!userinfo.empty()) {
    out += userinfo;
    out += '@';
  }
  out += host;
  if (!port.empty()) {
    out += ':';
    out += port;
  }
  out += path;
  if (!query.empty()) {
    out += '?';
    out += query;
  }
  return out;
}

// ── SHA-256 (FIPS 180-4) ─────────────────────────────────────────────────────

namespace common_detail {

constexpr uint32_t kSha256K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};

inline uint32_t rotr32(uint32_t v, unsigned n) {
  return (v >> n) | (v << (32 - n));
}

void sha256Block(const uint8_t* p, uint32_t h[8]) {
  uint32_t w[64];
  for (unsigned i = 0; i < 16; ++i) {
    w[i] = (static_cast<uint32_t>(p[i * 4]) << 24) |
           (static_cast<uint32_t>(p[i * 4 + 1]) << 16) |
           (static_cast<uint32_t>(p[i * 4 + 2]) << 8) |
           static_cast<uint32_t>(p[i * 4 + 3]);
  }
  for (unsigned i = 16; i < 64; ++i) {
    const uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
    const uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }

  uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
  uint32_t e = h[4], f = h[5], g = h[6], hh = h[7];
  for (unsigned i = 0; i < 64; ++i) {
    const uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
    const uint32_t ch = (e & f) ^ (~e & g);
    const uint32_t t1 = hh + S1 + ch + kSha256K[i] + w[i];
    const uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
    const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    const uint32_t t2 = S0 + maj;
    hh = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d;
  h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

}  // namespace common_detail

std::string hexSha256(const void* data, size_t len) {
  uint32_t h[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                   0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};

  const auto* p = static_cast<const uint8_t*>(data);
  size_t remaining = (p == nullptr) ? 0 : len;
  const uint64_t bitLen = static_cast<uint64_t>(remaining) * 8;

  while (remaining >= 64) {
    common_detail::sha256Block(p, h);
    p += 64;
    remaining -= 64;
  }

  // Tail: the remainder, 0x80, zero padding, then the 64-bit big-endian length.
  // Two blocks are needed when the remainder leaves no room for the length.
  uint8_t tail[128] = {0};
  if (remaining > 0) std::memcpy(tail, p, remaining);
  tail[remaining] = 0x80;
  const size_t tailBlocks = (remaining >= 56) ? 2 : 1;
  const size_t lenAt = tailBlocks * 64 - 8;
  for (unsigned i = 0; i < 8; ++i) {
    tail[lenAt + i] = static_cast<uint8_t>(bitLen >> (56 - 8 * i));
  }
  for (size_t b = 0; b < tailBlocks; ++b) {
    common_detail::sha256Block(tail + b * 64, h);
  }

  static const char kHex[] = "0123456789abcdef";
  std::string out;
  out.resize(64);
  for (unsigned i = 0; i < 8; ++i) {
    for (unsigned j = 0; j < 4; ++j) {
      const uint8_t byte = static_cast<uint8_t>(h[i] >> (24 - 8 * j));
      out[i * 8 + j * 2] = kHex[byte >> 4];
      out[i * 8 + j * 2 + 1] = kHex[byte & 0x0f];
    }
  }
  return out;
}

// ── Base64 ───────────────────────────────────────────────────────────────────

namespace common_detail {

const char kB64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// -1 = invalid, -2 = ignorable whitespace, -3 = padding.
int b64Value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  if (c == '=') return -3;
  if (isAsciiSpace(c)) return -2;
  return -1;
}

}  // namespace common_detail

std::string base64Encode(const void* data, size_t len) {
  const auto* p = static_cast<const uint8_t*>(data);
  if (p == nullptr || len == 0) return std::string();

  std::string out;
  out.reserve(((len + 2) / 3) * 4);
  size_t i = 0;
  for (; i + 3 <= len; i += 3) {
    const uint32_t v = (static_cast<uint32_t>(p[i]) << 16) |
                       (static_cast<uint32_t>(p[i + 1]) << 8) | p[i + 2];
    out += common_detail::kB64Alphabet[(v >> 18) & 0x3f];
    out += common_detail::kB64Alphabet[(v >> 12) & 0x3f];
    out += common_detail::kB64Alphabet[(v >> 6) & 0x3f];
    out += common_detail::kB64Alphabet[v & 0x3f];
  }
  if (i < len) {
    const bool twoLeft = (len - i) == 2;
    const uint32_t v = (static_cast<uint32_t>(p[i]) << 16) |
                       (twoLeft ? (static_cast<uint32_t>(p[i + 1]) << 8) : 0u);
    out += common_detail::kB64Alphabet[(v >> 18) & 0x3f];
    out += common_detail::kB64Alphabet[(v >> 12) & 0x3f];
    out += twoLeft ? common_detail::kB64Alphabet[(v >> 6) & 0x3f] : '=';
    out += '=';
  }
  return out;
}

bool base64Decode(const std::string& in, std::vector<uint8_t>* out) {
  if (out == nullptr) return false;
  out->clear();
  out->reserve((in.size() / 4) * 3);

  uint32_t acc = 0;
  unsigned bits = 0;
  unsigned quantum = 0;  // sextets seen in the current 4-character group
  bool sawPadding = false;

  for (const char c : in) {
    const int v = common_detail::b64Value(c);
    if (v == -2) continue;
    if (v == -1) {
      out->clear();
      return false;
    }
    if (v == -3) {
      sawPadding = true;
      continue;
    }
    if (sawPadding) {  // data after padding is malformed
      out->clear();
      return false;
    }
    acc = (acc << 6) | static_cast<uint32_t>(v);
    bits += 6;
    quantum = (quantum + 1) & 3;
    if (bits >= 8) {
      bits -= 8;
      out->push_back(static_cast<uint8_t>((acc >> bits) & 0xff));
    }
  }

  // A trailing group of one sextet carries no whole byte, so it is truncation
  // rather than a legal short group.
  if (quantum == 1) {
    out->clear();
    return false;
  }
  // Leftover bits must be zero padding, not dropped data.
  if (bits > 0 && (acc & ((1u << bits) - 1)) != 0) {
    out->clear();
    return false;
  }
  return true;
}

// ── Debug thread guard ───────────────────────────────────────────────────────

namespace common_detail {

uint64_t currentThreadKey() {
  const uint64_t h = static_cast<uint64_t>(
      std::hash<std::thread::id>{}(std::this_thread::get_id()));
  // 0 is the "unbound" sentinel, so a thread that legitimately hashes to zero
  // must not be able to impersonate it.
  return h == 0 ? 1u : h;
}

}  // namespace common_detail

void ThreadGuard::bind() {
  owner_.store(common_detail::currentThreadKey(), std::memory_order_release);
}

bool ThreadGuard::onOwningThread() const {
  const uint64_t owner = owner_.load(std::memory_order_acquire);
  return owner == 0 || owner == common_detail::currentThreadKey();
}

#ifndef NDEBUG
void assertThread(const ThreadGuard& guard, const char* file, int line) {
  if (guard.onOwningThread()) return;
  std::fprintf(stderr,
               "nitro_http: curl handle touched from the wrong thread at "
               "%s:%d — only the engine loop thread may do this\n",
               file, line);
  std::fflush(stderr);
  std::abort();
}
#endif

// ── Capability queries ───────────────────────────────────────────────────────
//
// Everything optional is probed at RUNTIME. Compile-time `#ifdef
// CURL_VERSION_*` would bake this build's curl into the answer, which is wrong
// the moment a platform links a different one.

namespace common_detail {

const curl_version_info_data* versionInfo() {
  static const curl_version_info_data* info = curl_version_info(CURLVERSION_NOW);
  return info;
}

bool hasFeatureBit(unsigned int bit) {
  const curl_version_info_data* info = versionInfo();
  return info != nullptr && (static_cast<unsigned int>(info->features) & bit) != 0;
}

/// Searches the structured feature-name list (curl 7.87+) and falls back to the
/// human-readable version banner, which names every compiled-in coding.
bool hasFeatureNamed(const char* name) {
  const curl_version_info_data* info = versionInfo();
  if (info == nullptr) return false;

#if LIBCURL_VERSION_NUM >= 0x075700  // 7.87.0 — CURLVERSION_ELEVENTH
  if (info->age >= CURLVERSION_ELEVENTH && info->feature_names != nullptr) {
    for (const char* const* f = info->feature_names; *f != nullptr; ++f) {
      if (asciiEqualIgnoreCase(*f, name)) return true;
    }
    // The list is authoritative when present.
    return false;
  }
#endif

  const char* banner = curl_version();
  if (banner == nullptr) return false;
  const std::string haystack = asciiLower(banner);
  return haystack.find(asciiLower(name)) != std::string::npos;
}

}  // namespace common_detail

std::string engineVersionString() {
  const char* v = curl_version();
  return v != nullptr ? std::string(v) : std::string("libcurl/unknown");
}

bool hasHttp3() {
  return common_detail::hasFeatureBit(CURL_VERSION_HTTP3) ||
         common_detail::hasFeatureNamed("HTTP3");
}

bool hasWebSockets() {
  // RFC 6455 framing is ours: WsSession drives a CONNECT_ONLY handle and does
  // its own masking and fragmentation, so curl's optional `--enable-websockets`
  // is irrelevant. Never gate on CURL_VERSION_WEBSOCKETS.
  return true;
}

// The codings below are compile-time facts about what THIS binary is linked
// against, mirroring src/engine/ContentDecoder.cpp. `curl_version_info` is
// deliberately not consulted any more: `CURLOPT_HTTP_CONTENT_DECODING` is off,
// so what curl can inflate has no bearing on what a caller gets.
#ifndef NITRO_HTTP_HAS_ZLIB
#define NITRO_HTTP_HAS_ZLIB 1
#endif

bool hasBrotli() {
#if NITRO_HTTP_HAS_BROTLI
  return true;
#else
  return false;
#endif
}

bool hasZstd() {
#if NITRO_HTTP_HAS_ZSTD
  return true;
#else
  return false;
#endif
}

const std::string& acceptEncodingHeader() {
  static const std::string value = [] {
    // gzip and deflate are unconditional: zlib is present on every platform,
    // and ContentDecoder `#error`s if it somehow is not.
    std::string list = "gzip, deflate";
#if NITRO_HTTP_HAS_BROTLI
    list += ", br";
#endif
#if NITRO_HTTP_HAS_ZSTD
    list += ", zstd";
#endif
    return list;
  }();
  return value;
}

void ensureCurlGlobalInit() {
  static std::once_flag once;
  std::call_once(once, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });
  // Deliberately never paired with curl_global_cleanup: with a hot-restarted
  // isolate and live native threads, tearing down curl's globals is a crash for
  // the sake of a few KB at unload.
}

}  // namespace nitrohttp
