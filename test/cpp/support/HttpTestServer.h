// A real HTTP server for the engine tests.
//
// Everything the engine does that matters — redirects, chunked transfer,
// cookies, revalidation, uploads — is observable only against a server that
// actually speaks HTTP. Mocking curl would test the mock. This is cpp-httplib
// on an ephemeral loopback port, with routes that are deterministic to the
// byte so a test can assert on a hash rather than on a length.
#pragma once

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace httplib {
class Server;
}

namespace nitrohttp::test {

class HttpTestServer {
 public:
  HttpTestServer();
  ~HttpTestServer();

  HttpTestServer(const HttpTestServer&) = delete;
  HttpTestServer& operator=(const HttpTestServer&) = delete;

  /// `http://127.0.0.1:<port><path>`. `path` must start with '/'.
  std::string url(const std::string& path) const;
  int port() const { return port_; }

  /// How many requests reached `path`, counted before routing so a 304 counts
  /// exactly like a 200. This is what proves the cache skipped the network.
  int requestCount(const std::string& path) const;
  void resetCounts();

  // ── Deterministic payloads, mirrored so a test can predict the bytes ───────

  /// The body `GET /bytes/<n>` serves: `n` bytes from a fixed LCG.
  static std::vector<uint8_t> lcgBytes(size_t n);
  /// `hexSha256` of `lcgBytes(n)`.
  static std::string bytesSha256(size_t n);
  /// The body `GET /chunked/<count>/<size>` serves, concatenated.
  static std::vector<uint8_t> chunkedBody(size_t count, size_t size);
  /// The plaintext behind `GET /gzip` and `GET /cachedgzip/<maxAge>`.
  static std::string gzipPlainText();
  /// The body `GET /encoding/upper` serves, uncompressed, behind a
  /// `Content-Encoding: upper` the engine cannot decode and must pass through.
  static std::string upperPlainText();

 private:
  void install();

  std::unique_ptr<httplib::Server> server_;
  std::thread thread_;
  int port_ = 0;

  mutable std::mutex countMtx_;
  std::map<std::string, int> counts_;
};

}  // namespace nitrohttp::test
