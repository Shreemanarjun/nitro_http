#include "support/HttpTestServer.h"

#include <zlib.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <stdexcept>
#include <thread>

#include "Common.h"
#include "HttpCache.h"
#include "httplib.h"

namespace nitrohttp::test {
namespace {

/// A 32-bit LCG (Numerical Recipes constants). Deterministic across platforms
/// because every operation is on `uint32_t`, so `/bytes/<n>` has one hash
/// everywhere.
std::vector<uint8_t> lcg(size_t n, uint32_t seed) {
  std::vector<uint8_t> out;
  out.resize(n);
  uint32_t x = seed;
  for (size_t i = 0; i < n; ++i) {
    x = x * 1664525u + 1013904223u;
    out[i] = static_cast<uint8_t>(x >> 24);
  }
  return out;
}

std::string jsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (const char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c & 0xff);
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

std::string queryOf(const httplib::Request& req) {
  const size_t q = req.target.find('?');
  return q == std::string::npos ? std::string() : req.target.substr(q + 1);
}

std::string headersJson(const httplib::Request& req) {
  std::string out = "{";
  bool first = true;
  for (const auto& kv : req.headers) {
    if (!first) out += ',';
    first = false;
    out += '"';
    out += jsonEscape(kv.first);
    out += "\":\"";
    out += jsonEscape(kv.second);
    out += '"';
  }
  out += '}';
  return out;
}

std::string gzipCompress(const std::string& in) {
  z_stream zs{};
  // 15 window bits + 16 selects the gzip wrapper rather than raw zlib.
  if (deflateInit2(&zs, Z_BEST_SPEED, Z_DEFLATED, 15 + 16, 8,
                   Z_DEFAULT_STRATEGY) != Z_OK) {
    return std::string();
  }
  zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(in.data()));
  zs.avail_in = static_cast<uInt>(in.size());

  std::string out;
  char buf[16384];
  int rc = Z_OK;
  do {
    zs.next_out = reinterpret_cast<Bytef*>(buf);
    zs.avail_out = sizeof(buf);
    rc = deflate(&zs, Z_FINISH);
    out.append(buf, sizeof(buf) - zs.avail_out);
  } while (rc == Z_OK);
  deflateEnd(&zs);
  return rc == Z_STREAM_END ? out : std::string();
}

size_t toSize(const std::string& s) {
  return static_cast<size_t>(std::strtoull(s.c_str(), nullptr, 10));
}

uint8_t chunkFill(size_t index) {
  return static_cast<uint8_t>('A' + static_cast<int>(index % 26));
}

}  // namespace

std::vector<uint8_t> HttpTestServer::lcgBytes(size_t n) { return lcg(n, 12345u); }

std::string HttpTestServer::bytesSha256(size_t n) {
  const std::vector<uint8_t> body = lcgBytes(n);
  return hexSha256(body.data(), body.size());
}

std::vector<uint8_t> HttpTestServer::chunkedBody(size_t count, size_t size) {
  std::vector<uint8_t> out;
  out.reserve(count * size);
  for (size_t i = 0; i < count; ++i) out.insert(out.end(), size, chunkFill(i));
  return out;
}

std::string HttpTestServer::gzipPlainText() {
  std::string out;
  out.reserve(4096);
  while (out.size() < 4096) out += "the quick brown fox jumps over the lazy dog\n";
  out.resize(4096);
  return out;
}

std::string HttpTestServer::upperPlainText() {
  std::string out = gzipPlainText();
  for (char& c : out) {
    if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
  }
  return out;
}

HttpTestServer::HttpTestServer() : server_(new httplib::Server()) {
  install();
  port_ = server_->bind_to_any_port("127.0.0.1");
  if (port_ <= 0) {
    throw std::runtime_error("HttpTestServer: could not bind a loopback port");
  }
  httplib::Server* raw = server_.get();
  thread_ = std::thread([raw] { raw->listen_after_bind(); });
  server_->wait_until_ready();
}

HttpTestServer::~HttpTestServer() {
  server_->stop();
  if (thread_.joinable()) thread_.join();
}

std::string HttpTestServer::url(const std::string& path) const {
  return "http://127.0.0.1:" + std::to_string(port_) + path;
}

int HttpTestServer::requestCount(const std::string& path) const {
  std::lock_guard<std::mutex> lock(countMtx_);
  const auto it = counts_.find(path);
  return it == counts_.end() ? 0 : it->second;
}

void HttpTestServer::resetCounts() {
  std::lock_guard<std::mutex> lock(countMtx_);
  counts_.clear();
}

void HttpTestServer::install() {
  httplib::Server& s = *server_;

  // Counted BEFORE routing, so a 304 counts exactly like a 200 — which is the
  // whole point: a cache test proves the request never left the process.
  s.set_pre_routing_handler([this](const httplib::Request& req,
                                   httplib::Response&) {
    std::lock_guard<std::mutex> lock(countMtx_);
    counts_[req.path] += 1;
    return httplib::Server::HandlerResponse::Unhandled;
  });

  // ── /echo ──────────────────────────────────────────────────────────────────

  s.Get("/echo", [](const httplib::Request& req, httplib::Response& res) {
    std::string body = "{\"method\":\"";
    body += jsonEscape(req.method);
    body += "\",\"path\":\"";
    body += jsonEscape(req.path);
    body += "\",\"query\":\"";
    body += jsonEscape(queryOf(req));
    body += "\",\"headers\":";
    body += headersJson(req);
    body += '}';
    res.set_content(body, "application/json");
  });

  const auto echoBody = [](const httplib::Request& req,
                           httplib::Response& res) {
    const std::string type = req.get_header_value("Content-Type");
    res.set_header("X-Echo-Method", req.method);
    res.set_header("X-Echo-Content-Type", type);
    res.set_content(req.body,
                    type.empty() ? "application/octet-stream" : type.c_str());
  };
  s.Post("/echo", echoBody);
  s.Put("/echo", echoBody);
  s.Patch("/echo", echoBody);
  s.Delete("/echo", echoBody);
  s.Options("/echo", [](const httplib::Request& req, httplib::Response& res) {
    res.set_header("Allow", "GET,POST,PUT,PATCH,DELETE,OPTIONS");
    res.set_content(req.method, "text/plain");
  });
  // HEAD is answered by the GET handler; httplib routes it there itself.

  // ── /bytes/<n> ─────────────────────────────────────────────────────────────

  s.Get(R"(/bytes/(\d+))", [](const httplib::Request& req,
                              httplib::Response& res) {
    const std::vector<uint8_t> body = lcgBytes(toSize(req.matches[1]));
    res.set_content(reinterpret_cast<const char*>(body.data()), body.size(),
                    "application/octet-stream");
  });

  // ── /chunked/<count>/<size> ────────────────────────────────────────────────

  s.Get(R"(/chunked/(\d+)/(\d+))", [](const httplib::Request& req,
                                      httplib::Response& res) {
    const size_t count = toSize(req.matches[1]);
    const size_t size = toSize(req.matches[2]);
    res.set_chunked_content_provider(
        "application/octet-stream",
        [count, size](size_t offset, httplib::DataSink& sink) {
          const size_t index = size == 0 ? count : offset / size;
          if (index >= count) {
            sink.done();
            return true;
          }
          const std::string chunk(size, static_cast<char>(chunkFill(index)));
          // One write per HTTP chunk: httplib flushes each one, so the engine
          // sees genuinely incremental delivery rather than one buffered blob.
          sink.write(chunk.data(), chunk.size());
          return true;
        });
  });

  // ── /slow/<ms> ─────────────────────────────────────────────────────────────

  s.Get(R"(/slow/(\d+))", [](const httplib::Request& req,
                             httplib::Response& res) {
    std::this_thread::sleep_for(std::chrono::milliseconds(
        static_cast<long long>(toSize(req.matches[1]))));
    res.set_content("slow", "text/plain");
  });

  // ── /stall/<ms> ────────────────────────────────────────────────────────────
  // Headers and one byte go out immediately, then the connection goes quiet.
  // That is the shape an IDLE timeout has to detect and a total-request timeout
  // does not: the transfer started, then stopped making progress.

  s.Get(R"(/stall/(\d+))", [](const httplib::Request& req,
                              httplib::Response& res) {
    const long long ms = static_cast<long long>(toSize(req.matches[1]));
    res.set_chunked_content_provider(
        "application/octet-stream",
        [ms](size_t offset, httplib::DataSink& sink) {
          if (offset == 0) {
            sink.write("S", 1);
            return true;
          }
          // Sliced rather than one long sleep: once the client gives up and
          // closes the socket there is nothing left to wait for, and a worker
          // still asleep would hold up the server's own shutdown.
          const auto deadline = std::chrono::steady_clock::now() +
                                std::chrono::milliseconds(ms);
          while (std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            if (sink.is_writable && !sink.is_writable()) return false;
          }
          sink.write("E", 1);
          sink.done();
          return true;
        });
  });

  // ── /drip/<count>/<size>/<gapMs> ───────────────────────────────────────────
  // `count` chunks of `size` bytes with `gapMs` of silence BETWEEN them.
  //
  // The shape `/stall` cannot express: every chunk is large, so the transfer's
  // AVERAGE rate stays high across the gap. That is exactly what defeated
  // `CURLOPT_LOW_SPEED_LIMIT` — a rate floor cannot see a stall that is
  // amortised over kilobytes — and it is what the engine's own idle deadline
  // has to catch.

  s.Get(R"(/drip/(\d+)/(\d+)/(\d+))", [](const httplib::Request& req,
                                         httplib::Response& res) {
    const size_t count = toSize(req.matches[1]);
    const size_t size = toSize(req.matches[2]);
    const long long gapMs = static_cast<long long>(toSize(req.matches[3]));
    res.set_chunked_content_provider(
        "application/octet-stream",
        [count, size, gapMs](size_t offset, httplib::DataSink& sink) {
          const size_t index = size == 0 ? count : offset / size;
          if (index >= count) {
            sink.done();
            return true;
          }
          if (index > 0) {
            // Sliced, so a client that gives up does not hold the server's own
            // shutdown behind a long sleep.
            const auto deadline = std::chrono::steady_clock::now() +
                                  std::chrono::milliseconds(gapMs);
            while (std::chrono::steady_clock::now() < deadline) {
              std::this_thread::sleep_for(std::chrono::milliseconds(20));
              if (sink.is_writable && !sink.is_writable()) return false;
            }
          }
          const std::string chunk(size, static_cast<char>(chunkFill(index)));
          sink.write(chunk.data(), chunk.size());
          return true;
        });
  });

  // ── /redirect/<n> ──────────────────────────────────────────────────────────

  s.Get(R"(/redirect/(\d+))", [](const httplib::Request& req,
                                 httplib::Response& res) {
    const size_t n = toSize(req.matches[1]);
    if (n == 0) {
      res.set_content("redirect-done", "text/plain");
      return;
    }
    res.status = 302;
    res.set_header("Location", "/redirect/" + std::to_string(n - 1));
    res.set_content("redirecting", "text/plain");
  });

  // ── /status/<code> ─────────────────────────────────────────────────────────

  s.Get(R"(/status/(\d+))", [](const httplib::Request& req,
                               httplib::Response& res) {
    res.status = static_cast<int>(toSize(req.matches[1]));
    res.set_content("status " + std::string(req.matches[1]), "text/plain");
  });

  // ── Content codings ────────────────────────────────────────────────────────
  //
  // Decoding is the ENGINE's job now, so these three routes cover the three
  // outcomes it has to tell apart: a coding we know, a coding we do not, and a
  // coding we know applied to a body that is not actually in it.

  s.Get("/gzip", [](const httplib::Request&, httplib::Response& res) {
    const std::string packed = gzipCompress(gzipPlainText());
    res.set_header("Content-Encoding", "gzip");
    res.set_content(packed, "text/plain");
  });

  // The `package:http` conformance suite's own fixture: `upper` is not a real
  // coding, the body is plaintext, and both headers describe it accurately.
  // libcurl aborts this with CURLE_BAD_CONTENT_ENCODING (61).
  s.Get("/encoding/upper", [](const httplib::Request&, httplib::Response& res) {
    res.set_header("Content-Encoding", "upper");
    res.set_content(upperPlainText(), "text/plain");
  });

  s.Get("/badgzip", [](const httplib::Request&, httplib::Response& res) {
    std::string packed = gzipCompress(gzipPlainText());
    // Past the 10-byte gzip header and past the first output byte, so this is
    // unambiguous corruption rather than a mislabelled wrapper.
    for (size_t i = 64; i < 128 && i < packed.size(); ++i) {
      packed[i] = static_cast<char>(~packed[i]);
    }
    res.set_header("Content-Encoding", "gzip");
    res.set_content(packed, "text/plain");
  });

  // Cacheable, so a test can prove the entry holds DECODED bytes: a replay has
  // no Content-Encoding header to re-inflate by.
  s.Get(R"(/cachedgzip/(\d+))", [](const httplib::Request& req,
                                   httplib::Response& res) {
    const std::string age = req.matches[1];
    res.set_header("Cache-Control", "max-age=" + age);
    res.set_header("ETag", "\"cachedgzip-" + age + "\"");
    res.set_header("Date", HttpCache::formatHttpDate(wallClockMs()));
    res.set_header("Content-Encoding", "gzip");
    res.set_content(gzipCompress(gzipPlainText()), "text/plain");
  });

  // ── /cache/<maxAge> ────────────────────────────────────────────────────────

  s.Get(R"(/cache/(\d+))", [](const httplib::Request& req,
                              httplib::Response& res) {
    const std::string age = req.matches[1];
    const std::string etag = "\"cache-" + age + "\"";
    res.set_header("Cache-Control", "max-age=" + age);
    res.set_header("ETag", etag);
    res.set_header("Date", HttpCache::formatHttpDate(wallClockMs()));
    if (req.get_header_value("If-None-Match") == etag) {
      res.status = 304;
      return;
    }
    res.set_content("cache-body-" + age, "text/plain");
  });

  // ── /cachedbytes/<maxAge>/<n> ──────────────────────────────────────────────
  // A body big enough that curl delivers it in many WRITEFUNCTION calls, and
  // cacheable, so a credit-throttled stream can be checked byte-for-byte
  // against what landed in the cache.

  s.Get(R"(/cachedbytes/(\d+)/(\d+))", [](const httplib::Request& req,
                                          httplib::Response& res) {
    const std::string age = req.matches[1];
    res.set_header("Cache-Control", "max-age=" + age);
    res.set_header("ETag", "\"cachedbytes-" + age + "-" +
                               std::string(req.matches[2]) + "\"");
    res.set_header("Date", HttpCache::formatHttpDate(wallClockMs()));
    const std::vector<uint8_t> body = lcgBytes(toSize(req.matches[2]));
    res.set_content(reinterpret_cast<const char*>(body.data()), body.size(),
                    "application/octet-stream");
  });

  // ── Cookies ────────────────────────────────────────────────────────────────

  // Two cookies, because the difference between them is load-bearing: a
  // session cookie must NOT survive a jar round trip, and a persistent one
  // must.
  s.Get("/setcookie", [](const httplib::Request&, httplib::Response& res) {
    res.set_header("Set-Cookie", "nh_test=abc123; Path=/");
    res.set_header("Set-Cookie", "nh_persist=lives; Path=/; Max-Age=3600");
    res.set_content("cookie set", "text/plain");
  });

  s.Get("/readcookie", [](const httplib::Request& req,
                          httplib::Response& res) {
    res.set_content(req.get_header_value("Cookie"), "text/plain");
  });

  // ── /upload ────────────────────────────────────────────────────────────────

  s.Post("/upload", [](const httplib::Request& req, httplib::Response& res) {
    std::string body = "{\"bytes\":";
    body += std::to_string(req.body.size());
    body += ",\"sha256\":\"";
    body += hexSha256(req.body.data(), req.body.size());
    body += "\"}";
    res.set_content(body, "application/json");
  });

  // ── /headers ───────────────────────────────────────────────────────────────

  // Registered for both verbs: the headers a request carries depend on whether
  // it has a body (curl adds `Content-Length`, and would add
  // `Expect: 100-continue`), so the echo has to be reachable by POST too.
  const auto echoHeaders = [](const httplib::Request& req,
                              httplib::Response& res) {
    std::string body;
    for (const auto& kv : req.headers) {
      body += kv.first;
      body += ": ";
      body += kv.second;
      body += '\n';
    }
    res.set_content(body, "text/plain");
  };
  s.Get("/headers", echoHeaders);
  s.Post("/headers", echoHeaders);
}

}  // namespace nitrohttp::test
