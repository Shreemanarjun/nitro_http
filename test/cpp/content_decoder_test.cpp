// ─────────────────────────────────────────────────────────────────────────────
// ContentDecoder — the engine's own content decoding.
//
// The contract these tests defend is the one libcurl cannot express: decode
// every coding this build is linked against, and pass ANYTHING else through
// untouched instead of failing the transfer. `forHeader` returning null IS the
// pass-through signal, so "null" is the assertion for an unknown coding, not an
// error message.
//
// Every fixture body is compressed here with zlib rather than checked in, so a
// round trip proves the decoder against a real encoder rather than against a
// blob someone once generated.
// ─────────────────────────────────────────────────────────────────────────────

#include "ContentDecoder.h"

#include <gtest/gtest.h>
#include <zlib.h>

// Mirrors the decoder's own guard: this build only knows `zstd` when it is
// linked against libzstd, which is also the only case the fixtures compile in.
#if NITRO_HTTP_HAS_ZSTD
#include <zstd.h>
#endif

#include <algorithm>
#include <string>
#include <vector>

#include "Common.h"

using nitrohttp::ContentDecoder;

namespace {

std::string sampleText(size_t atLeast = 8192) {
  std::string out;
  out.reserve(atLeast + 64);
  while (out.size() < atLeast) {
    out += "the quick brown fox jumps over the lazy dog 0123456789\n";
  }
  return out;
}

/// Deliberately hard to compress, so the encoded stream is long enough to
/// corrupt somewhere in the MIDDLE of the deflate data. `sampleText` shrinks
/// 8 KiB to about 150 bytes, which leaves no middle to speak of.
std::string noisyText(size_t n) {
  std::string out;
  out.resize(n);
  uint32_t x = 987654321u;
  for (size_t i = 0; i < n; ++i) {
    x = x * 1664525u + 1013904223u;
    out[i] = static_cast<char>(x >> 24);
  }
  return out;
}

std::string stringOf(const std::vector<uint8_t>& v) {
  return std::string(v.begin(), v.end());
}

/// `windowBits`: 15 + 16 = gzip wrapper, 15 = zlib wrapper, -15 = raw deflate.
std::vector<uint8_t> zlibCompress(const std::string& in, int windowBits) {
  z_stream zs{};
  EXPECT_EQ(deflateInit2(&zs, Z_BEST_SPEED, Z_DEFLATED, windowBits, 8,
                         Z_DEFAULT_STRATEGY),
            Z_OK);
  zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(in.data()));
  zs.avail_in = static_cast<uInt>(in.size());

  std::vector<uint8_t> out;
  uint8_t buf[16384];
  int rc = Z_OK;
  do {
    zs.next_out = buf;
    zs.avail_out = sizeof(buf);
    rc = deflate(&zs, Z_FINISH);
    out.insert(out.end(), buf, buf + (sizeof(buf) - zs.avail_out));
  } while (rc == Z_OK);
  deflateEnd(&zs);
  EXPECT_EQ(rc, Z_STREAM_END);
  return out;
}

std::vector<uint8_t> gzipCompress(const std::string& in) {
  return zlibCompress(in, 15 + 16);
}

/// Feeds the whole body in one `write` and returns the decoded bytes. Fails the
/// calling test when anything reports an error.
std::string decodeAll(const std::string& header,
                      const std::vector<uint8_t>& encoded) {
  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader(header);
  EXPECT_NE(decoder, nullptr) << "expected '" << header << "' to be decodable";
  if (!decoder) return std::string();

  std::vector<uint8_t> out;
  EXPECT_TRUE(decoder->write(encoded.data(), encoded.size(), &out))
      << decoder->failure();
  EXPECT_TRUE(decoder->finish(&out)) << decoder->failure();
  return stringOf(out);
}

}  // namespace

// ─── Round trips ─────────────────────────────────────────────────────────────

TEST(ContentDecoderTest, GzipRoundTrips) {
  const std::string plain = sampleText();
  EXPECT_EQ(decodeAll("gzip", gzipCompress(plain)), plain);
}

TEST(ContentDecoderTest, XGzipIsTheSameCoding) {
  const std::string plain = sampleText();
  EXPECT_EQ(decodeAll("x-gzip", gzipCompress(plain)), plain);
}

TEST(ContentDecoderTest, ZlibWrappedDeflateRoundTrips) {
  const std::string plain = sampleText();
  EXPECT_EQ(decodeAll("deflate", zlibCompress(plain, 15)), plain);
}

TEST(ContentDecoderTest, RawDeflateRoundTrips) {
  // RFC 9110 says `deflate` is the zlib wrapper, but a long tail of servers
  // sends a bare RFC 1951 stream. Browsers and dart:io accept both, so the
  // decoder retries raw after the wrapped reader rejects the first byte.
  const std::string plain = sampleText();
  EXPECT_EQ(decodeAll("deflate", zlibCompress(plain, -15)), plain);
}

TEST(ContentDecoderTest, RawDeflateFallbackSurvivesASplitFirstBlock) {
  // The fallback replays every byte seen so far, so it must work even when the
  // data error surfaces several writes in.
  const std::string plain = sampleText(64 * 1024);
  const std::vector<uint8_t> encoded = zlibCompress(plain, -15);

  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("deflate");
  ASSERT_NE(decoder, nullptr);

  std::vector<uint8_t> out;
  for (size_t at = 0; at < encoded.size(); at += 7) {
    const size_t n = std::min<size_t>(7, encoded.size() - at);
    ASSERT_TRUE(decoder->write(encoded.data() + at, n, &out))
        << decoder->failure();
  }
  ASSERT_TRUE(decoder->finish(&out)) << decoder->failure();
  EXPECT_EQ(stringOf(out), plain);
}

TEST(ContentDecoderTest, AChainIsUnwrappedRightToLeft) {
  // `Content-Encoding: gzip, deflate` means gzip was applied FIRST and deflate
  // over it, so deflate comes off first. Decoding left to right would fail on
  // the very first byte.
  const std::string plain = sampleText();
  const std::vector<uint8_t> gzipped = gzipCompress(plain);
  const std::vector<uint8_t> both =
      zlibCompress(std::string(gzipped.begin(), gzipped.end()), 15);

  EXPECT_EQ(decodeAll("gzip, deflate", both), plain);
}

TEST(ContentDecoderTest, ASplitStreamDecodesToTheSameBytes) {
  const std::string plain = sampleText(128 * 1024);
  const std::vector<uint8_t> encoded = gzipCompress(plain);

  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("gzip");
  ASSERT_NE(decoder, nullptr);

  std::vector<uint8_t> out;
  // Deliberately tiny and uneven: curl hands over whatever the socket produced,
  // which regularly splits the gzip header itself across two calls.
  for (size_t at = 0; at < encoded.size(); at += 3) {
    const size_t n = std::min<size_t>(3, encoded.size() - at);
    ASSERT_TRUE(decoder->write(encoded.data() + at, n, &out))
        << decoder->failure();
  }
  ASSERT_TRUE(decoder->finish(&out)) << decoder->failure();
  EXPECT_EQ(stringOf(out), plain);
}

// ─── Pass-through: the whole point of owning this ────────────────────────────

TEST(ContentDecoderTest, AnUnknownCodingIsNotDecodable) {
  // The `package:http` conformance suite serves `Content-Encoding: upper` with
  // an UNCOMPRESSED body. libcurl kills that transfer with CURLcode 61; the
  // engine must hand the bytes back untouched, and a null decoder is how it
  // says so.
  EXPECT_FALSE(ContentDecoder::canDecode("upper"));
  EXPECT_EQ(ContentDecoder::forHeader("upper"), nullptr);
}

TEST(ContentDecoderTest, OneUnknownTokenPoisonsTheWholeChain) {
  // Half a chain is not a body anyone can use, so a recognised coding beside an
  // unrecognised one still means pass-through.
  EXPECT_FALSE(ContentDecoder::canDecode("gzip, upper"));
  EXPECT_EQ(ContentDecoder::forHeader("gzip, upper"), nullptr);
  EXPECT_FALSE(ContentDecoder::canDecode("upper, gzip"));
}

TEST(ContentDecoderTest, IdentityAndAnEmptyHeaderNeedNoDecoder) {
  EXPECT_FALSE(ContentDecoder::canDecode(""));
  EXPECT_EQ(ContentDecoder::forHeader(""), nullptr);

  EXPECT_FALSE(ContentDecoder::canDecode("identity"));
  EXPECT_EQ(ContentDecoder::forHeader("identity"), nullptr);

  EXPECT_FALSE(ContentDecoder::canDecode("  IDENTITY  "));
  EXPECT_EQ(ContentDecoder::forHeader("  IDENTITY  "), nullptr);
}

TEST(ContentDecoderTest, IdentityInAChainIsANoOp) {
  const std::string plain = sampleText();
  EXPECT_TRUE(ContentDecoder::canDecode("identity, gzip"));
  EXPECT_EQ(decodeAll("identity, gzip", gzipCompress(plain)), plain);
  EXPECT_EQ(decodeAll("gzip, identity", gzipCompress(plain)), plain);
}

// ─── Token syntax ────────────────────────────────────────────────────────────

TEST(ContentDecoderTest, TokensAreCaseInsensitiveAndWhitespaceTolerant) {
  const std::string plain = sampleText();
  EXPECT_TRUE(ContentDecoder::canDecode("GZIP"));
  EXPECT_EQ(decodeAll("GZIP", gzipCompress(plain)), plain);
  EXPECT_EQ(decodeAll("  GzIp  ", gzipCompress(plain)), plain);

  const std::vector<uint8_t> gzipped = gzipCompress(plain);
  const std::vector<uint8_t> both =
      zlibCompress(std::string(gzipped.begin(), gzipped.end()), 15);
  EXPECT_TRUE(ContentDecoder::canDecode(" gzip , deflate "));
  EXPECT_EQ(decodeAll(" gzip , DEFLATE ", both), plain);
}

TEST(ContentDecoderTest, ATrailingCommaIsSloppyNotUnknown) {
  const std::string plain = sampleText();
  EXPECT_TRUE(ContentDecoder::canDecode("gzip,"));
  EXPECT_EQ(decodeAll("gzip,", gzipCompress(plain)), plain);
}

// ─── Corruption ──────────────────────────────────────────────────────────────

TEST(ContentDecoderTest, ATruncatedGzipBodyFailsAtFinish) {
  const std::string plain = sampleText();
  std::vector<uint8_t> encoded = gzipCompress(plain);
  ASSERT_GT(encoded.size(), 32u);
  encoded.resize(encoded.size() - 16);  // drop the trailer and some data

  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("gzip");
  ASSERT_NE(decoder, nullptr);

  std::vector<uint8_t> out;
  // Truncation is invisible until the end: the bytes that DID arrive are valid.
  EXPECT_TRUE(decoder->write(encoded.data(), encoded.size(), &out))
      << decoder->failure();
  EXPECT_FALSE(decoder->finish(&out));
  EXPECT_NE(decoder->failure().find("truncated"), std::string::npos)
      << decoder->failure();
}

TEST(ContentDecoderTest, CorruptionMidStreamFailsTheWrite) {
  const std::string plain = noisyText(64 * 1024);
  std::vector<uint8_t> encoded = gzipCompress(plain);
  ASSERT_GT(encoded.size(), 16384u) << "fixture must be genuinely incompressible";
  // Deep inside the deflate data: past the gzip header, and long after inflate
  // has already produced output, so the raw-deflate fallback cannot mask it and
  // this is unambiguously corruption rather than a mislabelled wrapper.
  for (size_t i = 4096; i < 4160; ++i) {
    encoded[i] = static_cast<uint8_t>(~encoded[i]);
  }

  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("gzip");
  ASSERT_NE(decoder, nullptr);

  std::vector<uint8_t> out;
  EXPECT_FALSE(decoder->write(encoded.data(), encoded.size(), &out));
  EXPECT_FALSE(decoder->failure().empty());
  EXPECT_NE(decoder->failure().find("gzip"), std::string::npos)
      << decoder->failure();

  // A failed decoder stays failed; nothing downstream should get half a body.
  std::vector<uint8_t> more;
  EXPECT_FALSE(decoder->write(encoded.data(), encoded.size(), &more));
  EXPECT_FALSE(decoder->finish(&more));
  EXPECT_TRUE(more.empty());
}

TEST(ContentDecoderTest, GarbageThatIsNeitherWrappedNorRawDeflateFails) {
  // `deflate` retries raw exactly once. Random bytes fail both readers, and the
  // failure must be reported rather than silently producing nothing.
  std::vector<uint8_t> junk(512);
  for (size_t i = 0; i < junk.size(); ++i) junk[i] = static_cast<uint8_t>(i * 37 + 11);

  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("deflate");
  ASSERT_NE(decoder, nullptr);

  std::vector<uint8_t> out;
  const bool wroteOk = decoder->write(junk.data(), junk.size(), &out);
  // Raw inflate may accept a prefix as a stored block before it hits nonsense,
  // so the failure can surface at either call — but it must surface.
  EXPECT_FALSE(wroteOk && decoder->finish(&out));
  EXPECT_FALSE(decoder->failure().empty());
}

// ─── Zip-bomb ceiling ────────────────────────────────────────────────────────

TEST(ContentDecoderTest, TheOutputCeilingTripsAndNamesItself) {
  // 1 MiB of zeroes compresses to about a kilobyte. With a 4 KiB ceiling the
  // decoder must refuse rather than let a small response allocate a large one.
  const std::string zeros(1024 * 1024, '\0');
  const std::vector<uint8_t> encoded = gzipCompress(zeros);
  ASSERT_LT(encoded.size(), 8192u) << "fixture is not actually a bomb";

  std::unique_ptr<ContentDecoder> decoder =
      ContentDecoder::forHeader("gzip", /*maxOutputBytes=*/4096);
  ASSERT_NE(decoder, nullptr);

  std::vector<uint8_t> out;
  const bool ok = decoder->write(encoded.data(), encoded.size(), &out);
  EXPECT_FALSE(ok);
  EXPECT_LE(out.size(), 4096u) << "the ceiling must bound what was appended";
  EXPECT_NE(decoder->failure().find("4096"), std::string::npos)
      << "the message has to state the ceiling: " << decoder->failure();
}

TEST(ContentDecoderTest, ABodyUnderTheCeilingIsUnaffected) {
  const std::string plain = sampleText(4096);
  std::unique_ptr<ContentDecoder> decoder =
      ContentDecoder::forHeader("gzip", /*maxOutputBytes=*/8192);
  ASSERT_NE(decoder, nullptr);

  const std::vector<uint8_t> encoded = gzipCompress(plain);
  std::vector<uint8_t> out;
  ASSERT_TRUE(decoder->write(encoded.data(), encoded.size(), &out))
      << decoder->failure();
  ASSERT_TRUE(decoder->finish(&out)) << decoder->failure();
  EXPECT_EQ(stringOf(out), plain);
}

// ─── Body-less responses ─────────────────────────────────────────────────────

TEST(ContentDecoderTest, NoBodyAtAllIsNotATruncatedStream) {
  // HEAD, 204 and 304 carry `Content-Encoding` with no body. Reporting that as
  // truncated would turn every gzip-advertising HEAD into a decoding failure.
  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("gzip");
  ASSERT_NE(decoder, nullptr);

  std::vector<uint8_t> out;
  EXPECT_TRUE(decoder->finish(&out)) << decoder->failure();
  EXPECT_TRUE(out.empty());
}

// ─── Advertisement matches capability ────────────────────────────────────────

TEST(ContentDecoderTest, EveryAdvertisedCodingIsDecodable) {
  // The set the engine puts in `Accept-Encoding` and the set it can inflate must
  // be the same set, or a server taking us up on the offer is indistinguishable
  // from the `upper` case — a response we can only pass through.
  const std::string& advertised = nitrohttp::acceptEncodingHeader();
  EXPECT_NE(advertised.find("gzip"), std::string::npos)
      << "the conformance suite asserts gzip is advertised: " << advertised;

  size_t at = 0;
  size_t tokens = 0;
  while (at <= advertised.size()) {
    const size_t comma = advertised.find(',', at);
    const std::string token = comma == std::string::npos
                                  ? advertised.substr(at)
                                  : advertised.substr(at, comma - at);
    EXPECT_TRUE(ContentDecoder::canDecode(token))
        << "advertised but not decodable: '" << token << "'";
    ++tokens;
    if (comma == std::string::npos) break;
    at = comma + 1;
  }
  EXPECT_GE(tokens, 2u) << "gzip and deflate are unconditional";
}

TEST(ContentDecoderTest, CapabilityFlagsAgreeWithTheDecoder) {
  EXPECT_EQ(nitrohttp::hasBrotli(), ContentDecoder::canDecode("br"));
  EXPECT_EQ(nitrohttp::hasZstd(), ContentDecoder::canDecode("zstd"));
}

// ─── Optional codings ────────────────────────────────────────────────────────
//
// brotli and zstd are compiled in only when the build is linked against them —
// the vendored Android/iOS slices are, a macOS or Linux system-curl build is
// not. The guards below are `#if` rather than a runtime skip so the test binary
// does not reference symbols it cannot link.

#if NITRO_HTTP_HAS_BROTLI
TEST(ContentDecoderTest, BrotliIsAdvertisedAndDecodable) {
  EXPECT_TRUE(ContentDecoder::canDecode("br"));
  EXPECT_TRUE(nitrohttp::hasBrotli());
  EXPECT_NE(nitrohttp::acceptEncodingHeader().find("br"), std::string::npos);
  EXPECT_NE(ContentDecoder::forHeader("br"), nullptr);
}

TEST(ContentDecoderTest, ATruncatedBrotliBodyFails) {
  // Encoding needs libbrotlienc, which is not guaranteed to be linked, so this
  // asserts on the failure path only — which is the one that matters, because a
  // false "corrupt" verdict would break real responses.
  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("br");
  ASSERT_NE(decoder, nullptr);
  const uint8_t partial[] = {0x1b, 0x2e, 0x00, 0x00, 0x04};
  std::vector<uint8_t> out;
  decoder->write(partial, sizeof(partial), &out);
  EXPECT_FALSE(decoder->finish(&out));
  EXPECT_FALSE(decoder->failure().empty());
}
#else
TEST(ContentDecoderTest, BrotliIsNeitherAdvertisedNorClaimed) {
  // This build is not linked against brotlidec, so `br` must behave exactly like
  // `upper`: not advertised, not claimed, passed through.
  EXPECT_FALSE(ContentDecoder::canDecode("br"));
  EXPECT_EQ(ContentDecoder::forHeader("br"), nullptr);
  EXPECT_FALSE(nitrohttp::hasBrotli());
  EXPECT_EQ(nitrohttp::acceptEncodingHeader().find("br"), std::string::npos);
}
#endif

#if NITRO_HTTP_HAS_ZSTD
TEST(ContentDecoderTest, ZstdIsAdvertisedAndDecodable) {
  EXPECT_TRUE(ContentDecoder::canDecode("zstd"));
  EXPECT_TRUE(nitrohttp::hasZstd());
  EXPECT_NE(nitrohttp::acceptEncodingHeader().find("zstd"), std::string::npos);
  EXPECT_NE(ContentDecoder::forHeader("zstd"), nullptr);
}

TEST(ContentDecoderTest, ZstdRoundTripsAndChainsWithGzip) {
  // libzstd is one library: whenever the decoder is linked, so is the encoder,
  // so this is a real round trip rather than a hand-made fixture.
  const std::string plain = sampleText();
  std::vector<uint8_t> packed(ZSTD_compressBound(plain.size()));
  const size_t n = ZSTD_compress(packed.data(), packed.size(), plain.data(),
                                 plain.size(), 3);
  ASSERT_FALSE(ZSTD_isError(n)) << ZSTD_getErrorName(n);
  packed.resize(n);

  EXPECT_EQ(decodeAll("zstd", packed), plain);

  // `gzip, zstd`: gzip applied first, zstd over it, so zstd comes off first.
  const std::vector<uint8_t> gzipped = gzipCompress(plain);
  std::vector<uint8_t> both(ZSTD_compressBound(gzipped.size()));
  const size_t m = ZSTD_compress(both.data(), both.size(), gzipped.data(),
                                 gzipped.size(), 3);
  ASSERT_FALSE(ZSTD_isError(m)) << ZSTD_getErrorName(m);
  both.resize(m);
  EXPECT_EQ(decodeAll("gzip, zstd", both), plain);
}

TEST(ContentDecoderTest, ATruncatedZstdBodyFailsAtFinish) {
  const std::string plain = sampleText();
  std::vector<uint8_t> packed(ZSTD_compressBound(plain.size()));
  const size_t n = ZSTD_compress(packed.data(), packed.size(), plain.data(),
                                 plain.size(), 3);
  ASSERT_FALSE(ZSTD_isError(n));
  packed.resize(n - 8);

  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("zstd");
  ASSERT_NE(decoder, nullptr);
  std::vector<uint8_t> out;
  EXPECT_TRUE(decoder->write(packed.data(), packed.size(), &out))
      << decoder->failure();
  EXPECT_FALSE(decoder->finish(&out));
  EXPECT_NE(decoder->failure().find("truncated"), std::string::npos)
      << decoder->failure();
}

TEST(ContentDecoderTest, ACorruptZstdBodyFails) {
  std::unique_ptr<ContentDecoder> decoder = ContentDecoder::forHeader("zstd");
  ASSERT_NE(decoder, nullptr);
  // A valid zstd magic number followed by nonsense.
  const uint8_t junk[] = {0x28, 0xb5, 0x2f, 0xfd, 0xff, 0xff, 0xff, 0xff};
  std::vector<uint8_t> out;
  const bool wroteOk = decoder->write(junk, sizeof(junk), &out);
  EXPECT_FALSE(wroteOk && decoder->finish(&out));
  EXPECT_FALSE(decoder->failure().empty());
}
#else
TEST(ContentDecoderTest, ZstdIsNeitherAdvertisedNorClaimed) {
  EXPECT_FALSE(ContentDecoder::canDecode("zstd"));
  EXPECT_EQ(ContentDecoder::forHeader("zstd"), nullptr);
  EXPECT_FALSE(nitrohttp::hasZstd());
  EXPECT_EQ(nitrohttp::acceptEncodingHeader().find("zstd"), std::string::npos);
}
#endif
