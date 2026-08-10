// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — ContentDecoder implementation.
//
// Every file-local helper lives in the NAMED namespace `nitrohttp::decoderdetail`
// rather than an anonymous one, because `EngineUnity.cpp` concatenates the whole
// engine into a single translation unit on Apple, where anonymous namespaces
// from different sources merge and collide. Same convention as `cachefs`,
// `wsdetail` and `common_detail`.
// ─────────────────────────────────────────────────────────────────────────────

#include "ContentDecoder.h"

// zlib is present on every platform this plugin supports: the Apple SDK and the
// Android NDK both ship it, the vendored slices build it, and the Windows and
// Linux system paths link it alongside libcurl. The default keeps the Apple
// podspec/SwiftPM path — which never runs src/deps.cmake — working unchanged.
#ifndef NITRO_HTTP_HAS_ZLIB
#define NITRO_HTTP_HAS_ZLIB 1
#endif

#if !NITRO_HTTP_HAS_ZLIB
#error "nitro_http requires zlib: gzip and deflate are not optional codings"
#endif

#include <zlib.h>

#if NITRO_HTTP_HAS_BROTLI
#include <brotli/decode.h>
#endif

#if NITRO_HTTP_HAS_ZSTD
#include <zstd.h>
#endif

#include <cstring>
#include <utility>

#include "Common.h"

namespace nitrohttp {
namespace decoderdetail {

/// Output block size for every stage. Big enough that a 4 MB body inflates in a
/// handful of iterations, small enough to sit on the stack of the loop thread.
constexpr size_t kDecodeBlockBytes = 32 * 1024;

/// One content coding, peeled off the right-hand end of the chain first.
class Stage {
 public:
  explicit Stage(size_t maxOutputBytes) : max_(maxOutputBytes) {}
  virtual ~Stage() = default;

  Stage(const Stage&) = delete;
  Stage& operator=(const Stage&) = delete;

  virtual bool write(const uint8_t* data, size_t n, std::vector<uint8_t>* out) = 0;
  virtual bool finish(std::vector<uint8_t>* out) = 0;

  const std::string& failure() const { return failure_; }

 protected:
  /// Appends and enforces the ceiling. A gzip bomb is a 1 KB request that
  /// expands to gigabytes, so the guard has to sit on the OUTPUT side of every
  /// stage rather than on the transfer size.
  bool emit(const uint8_t* data, size_t n, std::vector<uint8_t>* out) {
    if (n > max_ - produced_) {
      return fail("decoded response body exceeded the " +
                  std::to_string(max_) + "-byte content-decoding limit");
    }
    produced_ += n;
    out->insert(out->end(), data, data + n);
    return true;
  }

  /// Always returns false so callers can `return fail(...)`. The first failure
  /// wins: later ones are consequences of it.
  bool fail(std::string message) {
    if (failure_.empty()) failure_ = std::move(message);
    return false;
  }

  size_t producedBytes() const { return produced_; }

 private:
  size_t max_;
  size_t produced_ = 0;
  std::string failure_;
};

// ── gzip / deflate ───────────────────────────────────────────────────────────

/// `deflate` is the coding real servers get wrong. RFC 9110 says zlib-wrapped
/// (RFC 1950), but a long tail of servers sends a bare RFC 1951 stream, so every
/// browser and `dart:io` accept both. zlib cannot auto-detect a raw stream, so
/// the wrapped reader runs first and the raw reader takes over on the first
/// `Z_DATA_ERROR` — but only while nothing has been produced yet, because after
/// the first output byte a data error is genuine corruption, not the wrong
/// wrapper.
class ZlibStage final : public Stage {
 public:
  ZlibStage(const char* name, int windowBits, bool allowRawFallback, size_t max)
      : Stage(max), name_(name), rawFallback_(allowRawFallback) {
    ok_ = inflateInit2(&zs_, windowBits) == Z_OK;
  }

  ~ZlibStage() override {
    if (ok_) inflateEnd(&zs_);
  }

  bool write(const uint8_t* data, size_t n, std::vector<uint8_t>* out) override {
    if (!ok_) return fail("zlib inflate could not be initialised");
    // Bytes after `Z_STREAM_END` are not part of the body. Dropping them rather
    // than erroring matches curl and dart:io.
    if (done_ || n == 0) return true;
    if (rawFallback_) replay_.insert(replay_.end(), data, data + n);
    return pump(data, n, out);
  }

  bool finish(std::vector<uint8_t>*) override {
    if (!ok_) return fail("zlib inflate could not be initialised");
    if (done_) return true;
    return fail(std::string("truncated ") + name_ +
                " body: the stream ended before the end of a member");
  }

 private:
  bool pump(const uint8_t* data, size_t n, std::vector<uint8_t>* out) {
    zs_.next_in = const_cast<Bytef*>(reinterpret_cast<const Bytef*>(data));
    zs_.avail_in = static_cast<uInt>(n);

    uint8_t block[kDecodeBlockBytes];
    for (;;) {
      zs_.next_out = block;
      zs_.avail_out = static_cast<uInt>(sizeof(block));
      const int rc = inflate(&zs_, Z_NO_FLUSH);
      const size_t got = sizeof(block) - zs_.avail_out;

      // Z_BUF_ERROR only means "no progress possible right now", which is the
      // normal way inflate reports that it wants more input.
      if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
        if (rawFallback_ && producedBytes() == 0 && got == 0) {
          return restartRaw(out);
        }
        return fail(std::string("corrupt ") + name_ + " body: " +
                    zlibMessage(rc));
      }

      if (got > 0 && !emit(block, got, out)) return false;

      if (rc == Z_STREAM_END) {
        done_ = true;
        rawFallback_ = false;
        replay_.clear();
        replay_.shrink_to_fit();
        return true;
      }
      // Output space left over means inflate was input-bound, not output-bound.
      if (zs_.avail_out != 0) return true;
    }
  }

  bool restartRaw(std::vector<uint8_t>* out) {
    inflateEnd(&zs_);
    zs_ = z_stream{};
    // -15: no wrapper, 32 KiB window — a bare RFC 1951 stream.
    if (inflateInit2(&zs_, -15) != Z_OK) {
      ok_ = false;
      return fail("zlib inflate could not be initialised");
    }
    std::vector<uint8_t> replay;
    replay.swap(replay_);
    rawFallback_ = false;  // one attempt; a second data error is real
    return pump(replay.data(), replay.size(), out);
  }

  static std::string zlibMessage(int rc) {
    switch (rc) {
      case Z_DATA_ERROR: return "invalid compressed data";
      case Z_NEED_DICT: return "a preset dictionary is required";
      case Z_MEM_ERROR: return "out of memory";
      case Z_STREAM_ERROR: return "inconsistent stream state";
      default: return "zlib error " + std::to_string(rc);
    }
  }

  const char* name_;
  z_stream zs_{};
  bool ok_ = false;
  bool done_ = false;
  bool rawFallback_ = false;
  /// Every input byte seen so far, kept only while a raw-deflate retry is still
  /// possible. Dropped the moment the wrapped reader produces a byte or ends.
  std::vector<uint8_t> replay_;
};

// ── brotli ───────────────────────────────────────────────────────────────────

#if NITRO_HTTP_HAS_BROTLI
class BrotliStage final : public Stage {
 public:
  explicit BrotliStage(size_t max) : Stage(max) {
    state_ = BrotliDecoderCreateInstance(nullptr, nullptr, nullptr);
  }

  ~BrotliStage() override {
    if (state_ != nullptr) BrotliDecoderDestroyInstance(state_);
  }

  bool write(const uint8_t* data, size_t n, std::vector<uint8_t>* out) override {
    if (state_ == nullptr) return fail("brotli decoder could not be created");
    if (done_ || n == 0) return true;

    const uint8_t* next_in = data;
    size_t avail_in = n;
    uint8_t block[kDecodeBlockBytes];
    for (;;) {
      uint8_t* next_out = block;
      size_t avail_out = sizeof(block);
      const BrotliDecoderResult rc = BrotliDecoderDecompressStream(
          state_, &avail_in, &next_in, &avail_out, &next_out, nullptr);
      const size_t got = sizeof(block) - avail_out;
      if (got > 0 && !emit(block, got, out)) return false;

      switch (rc) {
        case BROTLI_DECODER_RESULT_SUCCESS:
          done_ = true;
          return true;
        case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT:
          return true;
        case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
          continue;
        default: {
          const char* text = BrotliDecoderErrorString(
              BrotliDecoderGetErrorCode(state_));
          return fail(std::string("corrupt br body: ") +
                      (text != nullptr ? text : "brotli decoder error"));
        }
      }
    }
  }

  bool finish(std::vector<uint8_t>*) override {
    if (state_ == nullptr) return fail("brotli decoder could not be created");
    if (done_) return true;
    return fail("truncated br body: the stream ended before the final block");
  }

 private:
  BrotliDecoderState* state_ = nullptr;
  bool done_ = false;
};
#endif  // NITRO_HTTP_HAS_BROTLI

// ── zstd ─────────────────────────────────────────────────────────────────────

#if NITRO_HTTP_HAS_ZSTD
class ZstdStage final : public Stage {
 public:
  explicit ZstdStage(size_t max) : Stage(max) { stream_ = ZSTD_createDStream(); }

  ~ZstdStage() override {
    if (stream_ != nullptr) ZSTD_freeDStream(stream_);
  }

  bool write(const uint8_t* data, size_t n, std::vector<uint8_t>* out) override {
    if (stream_ == nullptr) return fail("zstd decoder could not be created");
    if (n == 0) return true;

    ZSTD_inBuffer in{data, n, 0};
    uint8_t block[kDecodeBlockBytes];
    while (in.pos < in.size) {
      ZSTD_outBuffer chunk{block, sizeof(block), 0};
      const size_t rc = ZSTD_decompressStream(stream_, &chunk, &in);
      if (ZSTD_isError(rc)) {
        return fail(std::string("corrupt zstd body: ") + ZSTD_getErrorName(rc));
      }
      if (chunk.pos > 0 && !emit(block, chunk.pos, out)) return false;
      // 0 means the current frame is complete. `Content-Encoding: zstd` may
      // carry several frames back to back, so decoding simply continues.
      atFrameBoundary_ = rc == 0;
    }
    return true;
  }

  bool finish(std::vector<uint8_t>*) override {
    if (stream_ == nullptr) return fail("zstd decoder could not be created");
    if (atFrameBoundary_) return true;
    return fail("truncated zstd body: the stream ended mid-frame");
  }

 private:
  ZSTD_DStream* stream_ = nullptr;
  bool atFrameBoundary_ = false;
};
#endif  // NITRO_HTTP_HAS_ZSTD

// ── Header parsing ───────────────────────────────────────────────────────────

enum class Coding { Identity, Gzip, Deflate, Brotli, Zstd };

/// Recognises one token. `identity` and an empty token are accepted as no-ops:
/// `Content-Encoding: identity` is explicitly "not encoded", and a trailing
/// comma is sloppy but not an unknown coding.
bool parseCoding(const std::string& token, Coding* out) {
  const std::string t = asciiLower(trimAsciiSpace(token));
  if (t.empty() || t == "identity") {
    *out = Coding::Identity;
    return true;
  }
  // `x-gzip` is the pre-RFC-2616 spelling; Apache and IIS still emit it.
  if (t == "gzip" || t == "x-gzip") {
    *out = Coding::Gzip;
    return true;
  }
  if (t == "deflate") {
    *out = Coding::Deflate;
    return true;
  }
#if NITRO_HTTP_HAS_BROTLI
  if (t == "br") {
    *out = Coding::Brotli;
    return true;
  }
#endif
#if NITRO_HTTP_HAS_ZSTD
  if (t == "zstd") {
    *out = Coding::Zstd;
    return true;
  }
#endif
  return false;
}

/// Splits a `Content-Encoding` value. False when ANY token is unknown, which is
/// the caller's cue to pass the body through untouched. `out` receives the
/// non-identity codings in header order (i.e. application order).
bool parseCodings(const std::string& header, std::vector<Coding>* out) {
  size_t at = 0;
  for (;;) {
    const size_t comma = header.find(',', at);
    const std::string token = comma == std::string::npos
                                  ? header.substr(at)
                                  : header.substr(at, comma - at);
    Coding coding = Coding::Identity;
    if (!parseCoding(token, &coding)) return false;
    if (coding != Coding::Identity && out != nullptr) out->push_back(coding);
    if (comma == std::string::npos) return true;
    at = comma + 1;
  }
}

std::unique_ptr<Stage> makeStage(Coding coding, size_t max) {
  switch (coding) {
    case Coding::Gzip:
      // 47 = 32 (auto-detect gzip or zlib) + 15 (largest window). A server that
      // labels a zlib stream `gzip` is wrong but common, and this reads both.
      return std::unique_ptr<Stage>(
          new ZlibStage("gzip", 47, /*allowRawFallback=*/false, max));
    case Coding::Deflate:
      return std::unique_ptr<Stage>(
          new ZlibStage("deflate", 47, /*allowRawFallback=*/true, max));
#if NITRO_HTTP_HAS_BROTLI
    case Coding::Brotli:
      return std::unique_ptr<Stage>(new BrotliStage(max));
#endif
#if NITRO_HTTP_HAS_ZSTD
    case Coding::Zstd:
      return std::unique_ptr<Stage>(new ZstdStage(max));
#endif
    default:
      return nullptr;
  }
}

}  // namespace decoderdetail

// ── ContentDecoder ───────────────────────────────────────────────────────────

using decoderdetail::Coding;
using decoderdetail::Stage;

ContentDecoder::ContentDecoder() = default;
ContentDecoder::~ContentDecoder() = default;

bool ContentDecoder::canDecode(const std::string& contentEncoding) {
  std::vector<Coding> codings;
  if (!decoderdetail::parseCodings(contentEncoding, &codings)) return false;
  return !codings.empty();
}

std::unique_ptr<ContentDecoder> ContentDecoder::forHeader(
    const std::string& contentEncoding, size_t maxOutputBytes) {
  std::vector<Coding> codings;
  if (!decoderdetail::parseCodings(contentEncoding, &codings)) return nullptr;
  if (codings.empty()) return nullptr;

  std::unique_ptr<ContentDecoder> decoder(new ContentDecoder());
  // RFC 9110 §8.4: the codings are listed in the order they were APPLIED, so
  // they come off in reverse. `gzip, br` is brotli over gzip; the brotli wrapper
  // has to be removed before the gzip member underneath is even visible.
  for (size_t i = codings.size(); i-- > 0;) {
    std::unique_ptr<Stage> stage =
        decoderdetail::makeStage(codings[i], maxOutputBytes);
    if (!stage) return nullptr;  // unreachable: parseCodings already filtered
    decoder->stages_.push_back(std::move(stage));
  }
  decoder->scratch_.resize(decoder->stages_.size() - 1);
  return decoder;
}

bool ContentDecoder::fail(std::string message) {
  failed_ = true;
  if (failure_.empty()) {
    failure_ = message.empty() ? std::string("content decoding failed")
                               : std::move(message);
  }
  return false;
}

bool ContentDecoder::write(const uint8_t* data, size_t n,
                           std::vector<uint8_t>* out) {
  if (failed_) return false;
  if (n == 0) return true;
  sawInput_ = true;

  const uint8_t* in = data;
  size_t inLen = n;
  for (size_t i = 0; i < stages_.size(); ++i) {
    const bool last = i + 1 == stages_.size();
    std::vector<uint8_t>* target = last ? out : &scratch_[i];
    if (!last) target->clear();

    Stage& stage = *stages_[i];
    if (!stage.write(in, inLen, target)) return fail(stage.failure());
    if (last) break;

    // A stage can legitimately produce nothing yet — a gzip header split across
    // two socket reads, for instance. Feeding zero bytes downstream is a no-op,
    // so stop walking the chain instead.
    if (target->empty()) break;
    in = target->data();
    inLen = target->size();
  }
  return true;
}

bool ContentDecoder::finish(std::vector<uint8_t>* out) {
  if (failed_) return false;
  // A body-less response — HEAD, 204, 304 — still carries `Content-Encoding`.
  // There is no stream, so there is nothing that can have been truncated.
  if (!sawInput_) return true;

  // Each stage's tail is the next stage's input, so the flush walks the chain
  // exactly as a write does. In practice every stage here drains its own output
  // inside `write`, so these buffers come back empty and `finish` serves only to
  // prove the stream ended on a member boundary.
  const uint8_t* in = nullptr;
  size_t inLen = 0;
  for (size_t i = 0; i < stages_.size(); ++i) {
    const bool last = i + 1 == stages_.size();
    std::vector<uint8_t>* target = last ? out : &scratch_[i];
    if (!last) target->clear();

    Stage& stage = *stages_[i];
    if (inLen > 0 && !stage.write(in, inLen, target)) return fail(stage.failure());
    if (!stage.finish(target)) return fail(stage.failure());
    if (last) break;

    in = target->data();
    inLen = target->size();
  }
  return true;
}

}  // namespace nitrohttp
