// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — response content decoding.
//
// Content decoding is OURS, not libcurl's. `CURLOPT_ACCEPT_ENCODING ""` asks
// curl to advertise whatever the local libcurl was compiled to inflate and to
// inflate it in-process — and, fatally, to abort the whole transfer with
// `CURLE_BAD_CONTENT_ENCODING` when a server answers with a coding curl does
// not know. `dart:io`, `cupertino_http` and the `package:http` conformance
// suite all require the opposite: decode what you recognise, hand back an
// unrecognised coding byte-for-byte.
//
// curl cannot express that. `Curl_build_unencoding_stack` runs while the header
// is parsed, strictly before our HEADERFUNCTION observes it, so the decision
// cannot be deferred to us. The only way to get one behaviour is to take the
// job: `CURLOPT_HTTP_CONTENT_DECODING 0`, advertise exactly what THIS decoder
// is linked against, and run the bytes through here.
//
// That also removes a platform split that contradicted the whole point of the
// plugin: the vendored slices link brotlidec and zstd while a macOS or Linux
// system curl typically does not, so "which codings work" used to depend on the
// host. Now the answer is a compile-time property of one file.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace nitrohttp {

namespace decoderdetail {
class Stage;
}

class ContentDecoder {
 public:
  /// A decoded body larger than this is treated as an attack rather than a
  /// payload. 512 MiB is far past any legitimate in-memory HTTP response and
  /// far below what a 1 KB gzip bomb can reach.
  static constexpr size_t kDefaultMaxOutputBytes = size_t{512} * 1024 * 1024;

  /// Builds a decoder for a `Content-Encoding` header value, which may name a
  /// chain (`gzip, br`) applied in order.
  ///
  /// Returns null when the header is empty, `identity`, or names ANY token this
  /// build cannot decode — in which case the caller must pass the body through
  /// untouched, exactly as `dart:io` does. All-or-nothing is deliberate: half a
  /// chain is not a body anyone can use.
  static std::unique_ptr<ContentDecoder> forHeader(
      const std::string& contentEncoding,
      size_t maxOutputBytes = kDefaultMaxOutputBytes);

  /// True when `forHeader` would return a decoder. Cheap; no allocation.
  static bool canDecode(const std::string& contentEncoding);

  ~ContentDecoder();

  ContentDecoder(const ContentDecoder&) = delete;
  ContentDecoder& operator=(const ContentDecoder&) = delete;

  /// Appends decoded bytes to `out`. False on corrupt input; `failure()` then
  /// carries the reason and every later call is a no-op returning false.
  bool write(const uint8_t* data, size_t n, std::vector<uint8_t>* out);

  /// Flushes any tail state. False when the stream ended mid-member.
  bool finish(std::vector<uint8_t>* out);

  const std::string& failure() const { return failure_; }

 private:
  ContentDecoder();

  bool fail(std::string message);

  std::vector<std::unique_ptr<decoderdetail::Stage>> stages_;
  /// Hand-off buffers between chained stages; `stages_.size() - 1` of them,
  /// reused across calls so a streamed body does not allocate per write.
  std::vector<std::vector<uint8_t>> scratch_;
  std::string failure_;
  bool failed_ = false;
  bool sawInput_ = false;
};

}  // namespace nitrohttp
