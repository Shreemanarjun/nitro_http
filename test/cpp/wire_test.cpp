// ─────────────────────────────────────────────────────────────────────────────
// Wire and Common: the binary contract with Dart, plus the primitives every
// other layer trusts.
//
// A bug here is invisible at compile time and produces plausible-looking
// garbage at runtime — a header that decodes as a body, an offset table that
// seeks one record short. So every codec is exercised against a fully
// populated record and every helper against known-answer vectors.
// ─────────────────────────────────────────────────────────────────────────────

#include <curl/curl.h>
#include <gtest/gtest.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Common.h"
#include "Wire.h"

using namespace nitrohttp;

namespace {

RawHeader header(std::string name, std::string value) {
  RawHeader h{};
  h.name = std::move(name);
  h.value = std::move(value);
  return h;
}

/// Encodes a record to its `[4B len][payload]` block and decodes it back
/// through `fromNative`, freeing the block in between so nothing survives by
/// pointing at it.
template <typename T>
T roundTrip(const T& value) {
  const NitroCppBuffer owned = value.toNativeBuffer();
  EXPECT_NE(owned.data, nullptr);
  int32_t payloadLen = 0;
  std::memcpy(&payloadLen, owned.data, sizeof(int32_t));
  std::vector<uint8_t> copy(owned.data + sizeof(int32_t),
                            owned.data + sizeof(int32_t) + payloadLen);
  ::free(const_cast<uint8_t*>(owned.data));
  return T::fromNative(NitroCppBuffer{copy.data(), copy.size()});
}

void expectHeadersEqual(const std::vector<RawHeader>& a,
                        const std::vector<RawHeader>& b) {
  ASSERT_EQ(a.size(), b.size());
  for (size_t i = 0; i < a.size(); ++i) {
    EXPECT_EQ(a[i].name, b[i].name) << "at index " << i;
    EXPECT_EQ(a[i].value, b[i].value) << "at index " << i;
  }
}

RawTimings populatedTimings() {
  RawTimings t{};
  t.queueMs = 1.5;
  t.dnsMs = 2.25;
  t.connectMs = 3.125;
  t.tlsMs = 4.0625;
  t.firstByteMs = 5.5;
  t.redirectMs = 6.75;
  t.totalMs = 7.875;
  return t;
}

void expectTimingsEqual(const RawTimings& a, const RawTimings& b) {
  EXPECT_DOUBLE_EQ(a.queueMs, b.queueMs);
  EXPECT_DOUBLE_EQ(a.dnsMs, b.dnsMs);
  EXPECT_DOUBLE_EQ(a.connectMs, b.connectMs);
  EXPECT_DOUBLE_EQ(a.tlsMs, b.tlsMs);
  EXPECT_DOUBLE_EQ(a.firstByteMs, b.firstByteMs);
  EXPECT_DOUBLE_EQ(a.redirectMs, b.redirectMs);
  EXPECT_DOUBLE_EQ(a.totalMs, b.totalMs);
}

}  // namespace

// ─── mapCurlError ────────────────────────────────────────────────────────────

TEST(MapCurlError, EveryNamedCodeMapsToItsKind) {
  struct Case {
    CURLcode code;
    RawErrorKind kind;
  };
  const Case cases[] = {
      {CURLE_OK, RAWERRORKIND_NONE},
      {CURLE_OPERATION_TIMEDOUT, RAWERRORKIND_TIMEOUT_REQUEST},
      {CURLE_COULDNT_RESOLVE_HOST, RAWERRORKIND_DNS_FAILURE},
      {CURLE_COULDNT_CONNECT, RAWERRORKIND_CONNECTION_REFUSED},
      {CURLE_RECV_ERROR, RAWERRORKIND_CONNECTION_RESET},
      {CURLE_SSL_SHUTDOWN_FAILED, RAWERRORKIND_CONNECTION_RESET},
      {CURLE_SEND_ERROR, RAWERRORKIND_SEND_FAILURE},
      {CURLE_SEND_FAIL_REWIND, RAWERRORKIND_SEND_FAILURE},
      {CURLE_UPLOAD_FAILED, RAWERRORKIND_SEND_FAILURE},
      {CURLE_HTTP_POST_ERROR, RAWERRORKIND_SEND_FAILURE},
      {CURLE_PARTIAL_FILE, RAWERRORKIND_RECEIVE_FAILURE},
      {CURLE_INTERFACE_FAILED, RAWERRORKIND_CONNECTION_FAILED},
      {CURLE_NO_CONNECTION_AVAILABLE, RAWERRORKIND_CONNECTION_FAILED},
      {CURLE_SSL_CONNECT_ERROR, RAWERRORKIND_TLS_HANDSHAKE},
      {CURLE_SSL_CIPHER, RAWERRORKIND_TLS_HANDSHAKE},
      {CURLE_USE_SSL_FAILED, RAWERRORKIND_TLS_HANDSHAKE},
      {CURLE_PEER_FAILED_VERIFICATION, RAWERRORKIND_CERTIFICATE_INVALID},
      {CURLE_SSL_CACERT_BADFILE, RAWERRORKIND_CERTIFICATE_INVALID},
      {CURLE_SSL_CRL_BADFILE, RAWERRORKIND_CERTIFICATE_INVALID},
      {CURLE_SSL_ISSUER_ERROR, RAWERRORKIND_CERTIFICATE_INVALID},
      {CURLE_SSL_INVALIDCERTSTATUS, RAWERRORKIND_CERTIFICATE_INVALID},
      {CURLE_SSL_PINNEDPUBKEYNOTMATCH, RAWERRORKIND_CERTIFICATE_PIN_MISMATCH},
      {CURLE_SSL_CERTPROBLEM, RAWERRORKIND_CERTIFICATE_CLIENT_AUTH},
      {CURLE_TOO_MANY_REDIRECTS, RAWERRORKIND_TOO_MANY_REDIRECTS},
      {CURLE_UNSUPPORTED_PROTOCOL, RAWERRORKIND_UNSUPPORTED_SCHEME},
      {CURLE_URL_MALFORMAT, RAWERRORKIND_UNSUPPORTED_SCHEME},
      {CURLE_HTTP2, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_HTTP2_STREAM, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_WEIRD_SERVER_REPLY, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_GOT_NOTHING, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_HTTP_RETURNED_ERROR, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_RANGE_ERROR, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_BAD_DOWNLOAD_RESUME, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_LOGIN_DENIED, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_REMOTE_ACCESS_DENIED, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_BAD_CONTENT_ENCODING, RAWERRORKIND_DECOMPRESSION_FAILURE},
      {CURLE_ABORTED_BY_CALLBACK, RAWERRORKIND_CANCELLED},
      {CURLE_WRITE_ERROR, RAWERRORKIND_IO},
      {CURLE_READ_ERROR, RAWERRORKIND_IO},
      {CURLE_FILE_COULDNT_READ_FILE, RAWERRORKIND_IO},
      {CURLE_FILESIZE_EXCEEDED, RAWERRORKIND_RESPONSE_TOO_LARGE},
      {CURLE_CHUNK_FAILED, RAWERRORKIND_IO},
      {CURLE_BAD_FUNCTION_ARGUMENT, RAWERRORKIND_BAD_REQUEST},
      {CURLE_FAILED_INIT, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_NOT_BUILT_IN, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_OUT_OF_MEMORY, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_FUNCTION_NOT_FOUND, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_UNKNOWN_OPTION, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_SETOPT_OPTION_SYNTAX, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_SSL_ENGINE_NOTFOUND, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_SSL_ENGINE_SETFAILED, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_SSL_ENGINE_INITFAILED, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_AGAIN, RAWERRORKIND_ENGINE_ERROR},
      {CURLE_RECURSIVE_API_CALL, RAWERRORKIND_ENGINE_ERROR},
#if LIBCURL_VERSION_NUM >= 0x074d00
      {CURLE_SSL_CLIENTCERT, RAWERRORKIND_CERTIFICATE_CLIENT_AUTH},
#endif
#if LIBCURL_VERSION_NUM >= 0x080800
      {CURLE_ECH_REQUIRED, RAWERRORKIND_TLS_HANDSHAKE},
#endif
#if LIBCURL_VERSION_NUM >= 0x074900
      {CURLE_PROXY, RAWERRORKIND_PROXY_FAILURE},
#endif
#if LIBCURL_VERSION_NUM >= 0x074200
      {CURLE_HTTP3, RAWERRORKIND_PROTOCOL_ERROR},
      {CURLE_AUTH_ERROR, RAWERRORKIND_PROTOCOL_ERROR},
#endif
#if LIBCURL_VERSION_NUM >= 0x074500
      {CURLE_QUIC_CONNECT_ERROR, RAWERRORKIND_PROTOCOL_ERROR},
#endif
#if LIBCURL_VERSION_NUM >= 0x080600
      {CURLE_TOO_LARGE, RAWERRORKIND_BAD_REQUEST},
#endif
#if LIBCURL_VERSION_NUM >= 0x075400
      {CURLE_UNRECOVERABLE_POLL, RAWERRORKIND_ENGINE_ERROR},
#endif
  };

  for (const Case& c : cases) {
    EXPECT_EQ(mapCurlError(static_cast<int>(c.code), false), c.kind)
        << "CURLcode " << static_cast<int>(c.code);
    // Only CURLE_COULDNT_RESOLVE_PROXY is allowed to change answer with the
    // proxy flag; everything else must be stable.
    EXPECT_EQ(mapCurlError(static_cast<int>(c.code), true), c.kind)
        << "CURLcode " << static_cast<int>(c.code) << " with proxyInUse";
  }
}

TEST(MapCurlError, ResolveProxyDependsOnWhetherAProxyIsConfigured) {
  EXPECT_EQ(mapCurlError(CURLE_COULDNT_RESOLVE_PROXY, true),
            RAWERRORKIND_PROXY_FAILURE);
  EXPECT_EQ(mapCurlError(CURLE_COULDNT_RESOLVE_PROXY, false),
            RAWERRORKIND_DNS_FAILURE);
}

TEST(MapCurlError, UnnamedProtocolsFallThroughToUnknown) {
  // FTP is a protocol this engine never speaks, so its codes must not be
  // silently mapped onto an HTTP-shaped failure.
  EXPECT_EQ(mapCurlError(CURLE_FTP_WEIRD_PASS_REPLY, false),
            RAWERRORKIND_UNKNOWN);
  EXPECT_EQ(mapCurlError(CURLE_LDAP_CANNOT_BIND, false), RAWERRORKIND_UNKNOWN);
  // A code from a curl newer than this build.
  EXPECT_EQ(mapCurlError(9999, false), RAWERRORKIND_UNKNOWN);
}

TEST(DescribeCurlError, PrefixesTheClassificationAndKeepsTheCode) {
  EXPECT_EQ(describeCurlError(CURLE_COULDNT_CONNECT, "Connection refused"),
            "connectionRefused: Connection refused (CURLcode 7)");
  EXPECT_EQ(describeCurlError(CURLE_ABORTED_BY_CALLBACK, "aborted"),
            "cancelled: aborted (CURLcode 42)");
}

TEST(DescribeCurlError, FallsBackToCurlStrerrorWhenTheMessageIsMissing) {
  const std::string fromNull =
      describeCurlError(CURLE_OPERATION_TIMEDOUT, nullptr);
  const std::string fromEmpty = describeCurlError(CURLE_OPERATION_TIMEDOUT, "");
  EXPECT_EQ(fromNull, fromEmpty);
  EXPECT_EQ(fromNull.rfind("timeoutRequest: ", 0), 0u);
  EXPECT_NE(fromNull.find(curl_easy_strerror(CURLE_OPERATION_TIMEDOUT)),
            std::string::npos);
  EXPECT_NE(fromNull.find("(CURLcode 28)"), std::string::npos);
}

// ─── canonicalizeUrl ─────────────────────────────────────────────────────────

TEST(CanonicalizeUrl, LowercasesSchemeAndHostButNotPath) {
  EXPECT_EQ(canonicalizeUrl("HTTP://Example.COM/MixedCase/Path"),
            "http://example.com/MixedCase/Path");
}

TEST(CanonicalizeUrl, DropsDefaultPortsAndKeepsOthers) {
  EXPECT_EQ(canonicalizeUrl("http://example.com:80/x"), "http://example.com/x");
  EXPECT_EQ(canonicalizeUrl("https://example.com:443/x"),
            "https://example.com/x");
  EXPECT_EQ(canonicalizeUrl("ws://example.com:80/x"), "ws://example.com/x");
  EXPECT_EQ(canonicalizeUrl("wss://example.com:443/x"), "wss://example.com/x");
  EXPECT_EQ(canonicalizeUrl("http://example.com:8080/x"),
            "http://example.com:8080/x");
  // 443 is not the default for http, so it stays.
  EXPECT_EQ(canonicalizeUrl("http://example.com:443/x"),
            "http://example.com:443/x");
}

TEST(CanonicalizeUrl, SortsQueryParametersAndDropsTheFragment) {
  EXPECT_EQ(canonicalizeUrl("http://example.com/p?b=2&a=1&c=3#section"),
            "http://example.com/p?a=1&b=2&c=3");
  EXPECT_EQ(canonicalizeUrl("http://example.com/p?a=1&b=2"),
            canonicalizeUrl("http://example.com/p?b=2&a=1"));
}

TEST(CanonicalizeUrl, KeepsValuelessAndEmptyValuedParametersDistinct) {
  EXPECT_EQ(canonicalizeUrl("http://example.com/p?a"), "http://example.com/p?a");
  EXPECT_EQ(canonicalizeUrl("http://example.com/p?a="),
            "http://example.com/p?a=");
  EXPECT_NE(canonicalizeUrl("http://example.com/p?a"),
            canonicalizeUrl("http://example.com/p?a="));
}

TEST(CanonicalizeUrl, SuppliesTheRootPathWhenThereIsNone) {
  EXPECT_EQ(canonicalizeUrl("http://example.com"), "http://example.com/");
  EXPECT_EQ(canonicalizeUrl("http://example.com?a=1"),
            "http://example.com/?a=1");
  EXPECT_EQ(canonicalizeUrl("http://example.com#frag"), "http://example.com/");
}

TEST(CanonicalizeUrl, HandlesIpv6LiteralsWithAndWithoutAPort) {
  EXPECT_EQ(canonicalizeUrl("http://[::1]/x"), "http://[::1]/x");
  EXPECT_EQ(canonicalizeUrl("http://[::1]:80/x"), "http://[::1]/x");
  EXPECT_EQ(canonicalizeUrl("http://[::1]:8080/x"), "http://[::1]:8080/x");
  EXPECT_EQ(canonicalizeUrl("HTTP://[2001:DB8::1]:8080/X"),
            "http://[2001:db8::1]:8080/X");
}

TEST(CanonicalizeUrl, KeepsUserinfoAndStillNormalisesTheHost) {
  EXPECT_EQ(canonicalizeUrl("http://User:Pass@Example.com:80/x"),
            "http://User:Pass@example.com/x");
}

TEST(CanonicalizeUrl, LeavesUndecomposableInputAloneExceptTheFragment) {
  EXPECT_EQ(canonicalizeUrl("  not-a-url#frag  "), "not-a-url");
  EXPECT_EQ(canonicalizeUrl("://example.com/x"), "://example.com/x");
}

// ─── hexSha256 ───────────────────────────────────────────────────────────────

TEST(HexSha256, MatchesTheFips1804KnownAnswers) {
  EXPECT_EQ(hexSha256("", 0),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  EXPECT_EQ(hexSha256("abc", 3),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  EXPECT_EQ(hexSha256(
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

  const std::string million(1000000, 'a');
  EXPECT_EQ(hexSha256(million.data(), million.size()),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

TEST(HexSha256, TreatsANullPointerAsTheEmptyInput) {
  EXPECT_EQ(hexSha256(nullptr, 17), hexSha256("", 0));
}

TEST(HexSha256, CoversBothTailBlockLengths) {
  // 55 bytes leaves room for the length word; 56 forces a second tail block.
  const std::string fiftyFive(55, 'x');
  const std::string fiftySix(56, 'x');
  EXPECT_EQ(hexSha256(fiftyFive.data(), 55).size(), 64u);
  EXPECT_EQ(hexSha256(fiftySix.data(), 56).size(), 64u);
  EXPECT_NE(hexSha256(fiftyFive.data(), 55), hexSha256(fiftySix.data(), 56));
  // Cross-check the 56-byte case against an independent known answer.
  const std::string fiftySixZeros(56, '\0');
  EXPECT_EQ(hexSha256(fiftySixZeros.data(), 56),
            "d4817aa5497628e7c77e6b606107042bbba3130888c5f47a375e6179be789fbb");
}

// ─── base64 ──────────────────────────────────────────────────────────────────

TEST(Base64, EncodesTheRfc4648Vectors) {
  EXPECT_EQ(base64Encode("", 0), "");
  EXPECT_EQ(base64Encode("f", 1), "Zg==");
  EXPECT_EQ(base64Encode("fo", 2), "Zm8=");
  EXPECT_EQ(base64Encode("foo", 3), "Zm9v");
  EXPECT_EQ(base64Encode("foob", 4), "Zm9vYg==");
  EXPECT_EQ(base64Encode("fooba", 5), "Zm9vYmE=");
  EXPECT_EQ(base64Encode("foobar", 6), "Zm9vYmFy");
}

TEST(Base64, DecodesTheRfc4648Vectors) {
  const std::pair<const char*, const char*> cases[] = {
      {"", ""},          {"Zg==", "f"},      {"Zm8=", "fo"},
      {"Zm9v", "foo"},   {"Zm9vYg==", "foob"}, {"Zm9vYmE=", "fooba"},
      {"Zm9vYmFy", "foobar"}};
  for (const auto& c : cases) {
    std::vector<uint8_t> out;
    ASSERT_TRUE(base64Decode(c.first, &out)) << c.first;
    EXPECT_EQ(std::string(out.begin(), out.end()), std::string(c.second));
  }
}

TEST(Base64, RoundTripsEveryByteValue) {
  std::vector<uint8_t> data(256);
  for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<uint8_t>(i);
  const std::string encoded = base64Encode(data.data(), data.size());
  EXPECT_EQ(encoded.size(), 344u);  // ceil(256/3)*4

  std::vector<uint8_t> decoded;
  ASSERT_TRUE(base64Decode(encoded, &decoded));
  EXPECT_EQ(decoded, data);
}

TEST(Base64, AcceptsUnpaddedAndWhitespacedInput) {
  std::vector<uint8_t> out;
  ASSERT_TRUE(base64Decode("Zg", &out));
  EXPECT_EQ(std::string(out.begin(), out.end()), "f");
  ASSERT_TRUE(base64Decode("Zm9v\nYmFy\n", &out));
  EXPECT_EQ(std::string(out.begin(), out.end()), "foobar");
}

TEST(Base64, RejectsMalformedInput) {
  std::vector<uint8_t> out{0xff};
  EXPECT_FALSE(base64Decode("Z", &out)) << "a lone sextet carries no byte";
  EXPECT_TRUE(out.empty());
  EXPECT_FALSE(base64Decode("Zm9v!", &out)) << "invalid alphabet character";
  EXPECT_FALSE(base64Decode("Zg=x", &out)) << "data after padding";
  EXPECT_FALSE(base64Decode("Zh==", &out)) << "non-zero leftover bits";
  EXPECT_FALSE(base64Decode("Zg", nullptr)) << "null output";
}

// ─── parseStatusLine / parseHeaderLine / findHeader ──────────────────────────

TEST(ParseStatusLine, AcceptsEveryHttpVersionCurlSynthesises) {
  int code = 0;
  ASSERT_TRUE(parseStatusLine("HTTP/1.1 200 OK", &code));
  EXPECT_EQ(code, 200);
  ASSERT_TRUE(parseStatusLine("HTTP/1.0 301 Moved Permanently", &code));
  EXPECT_EQ(code, 301);
  ASSERT_TRUE(parseStatusLine("HTTP/2 404", &code));
  EXPECT_EQ(code, 404);
  ASSERT_TRUE(parseStatusLine("HTTP/3 503 ", &code));
  EXPECT_EQ(code, 503);
  ASSERT_TRUE(parseStatusLine("HTTP/1.1\t204 No Content", &code));
  EXPECT_EQ(code, 204);
}

TEST(ParseStatusLine, RejectsAnythingThatIsNotAStatusLine) {
  int code = -1;
  EXPECT_FALSE(parseStatusLine("", &code));
  EXPECT_FALSE(parseStatusLine("Content-Type: text/html", &code));
  EXPECT_FALSE(parseStatusLine("HTTP/1.1", &code));
  EXPECT_FALSE(parseStatusLine("HTTP/ 200 OK", &code));
  EXPECT_FALSE(parseStatusLine("HTTP/1.1 20 OK", &code));
  EXPECT_FALSE(parseStatusLine("HTTP/1.1 2000 OK", &code));
  EXPECT_FALSE(parseStatusLine("HTTP/1.1200 OK", &code));
  EXPECT_FALSE(parseStatusLine("\r\n", &code));
  EXPECT_EQ(code, -1) << "a rejected line must not write the out parameter";
}

TEST(ParseStatusLine, ToleratesANullOutParameter) {
  EXPECT_TRUE(parseStatusLine("HTTP/1.1 200 OK", nullptr));
}

TEST(ParseHeaderLine, SplitsAndTrims) {
  std::string name;
  std::string value;
  ASSERT_TRUE(parseHeaderLine("Content-Type: text/html", &name, &value));
  EXPECT_EQ(name, "Content-Type");
  EXPECT_EQ(value, "text/html");

  ASSERT_TRUE(parseHeaderLine("X-Trailing:   spaced   \r\n", &name, &value));
  EXPECT_EQ(name, "X-Trailing");
  EXPECT_EQ(value, "spaced");

  ASSERT_TRUE(parseHeaderLine("Tight:value", &name, &value));
  EXPECT_EQ(name, "Tight");
  EXPECT_EQ(value, "value");

  ASSERT_TRUE(parseHeaderLine("Empty:", &name, &value));
  EXPECT_EQ(name, "Empty");
  EXPECT_EQ(value, "");
}

TEST(ParseHeaderLine, RejectsMalformedLines) {
  std::string name = "untouched";
  std::string value = "untouched";
  EXPECT_FALSE(parseHeaderLine("", &name, &value));
  EXPECT_FALSE(parseHeaderLine("NoColonHere", &name, &value));
  EXPECT_FALSE(parseHeaderLine(":novalue", &name, &value));
  EXPECT_FALSE(parseHeaderLine(" obs-fold continuation", &name, &value))
      << "a leading space continues the previous header";
  EXPECT_FALSE(parseHeaderLine("\tobs-fold continuation", &name, &value));
  EXPECT_FALSE(parseHeaderLine("Bad Name: v", &name, &value))
      << "RFC 9110 forbids whitespace before the colon";
  EXPECT_FALSE(parseHeaderLine("Bad\tName: v", &name, &value));
  EXPECT_EQ(name, "untouched");
  EXPECT_EQ(value, "untouched");
}

TEST(FindHeader, IsCaseInsensitiveAndReturnsTheFirstOfDuplicates) {
  const std::vector<RawHeader> headers = {
      header("Content-Type", "text/plain"),
      header("Set-Cookie", "a=1"),
      header("set-cookie", "b=2"),
  };
  const RawHeader* found = findHeader(headers, "CONTENT-TYPE");
  ASSERT_NE(found, nullptr);
  EXPECT_EQ(found->value, "text/plain");

  const RawHeader* cookie = findHeader(headers, "Set-Cookie");
  ASSERT_NE(cookie, nullptr);
  EXPECT_EQ(cookie->value, "a=1") << "the first duplicate wins";

  // Duplicates must survive in the vector: Set-Cookie depends on it.
  size_t cookies = 0;
  for (const RawHeader& h : headers) {
    if (asciiEqualIgnoreCase(h.name, "set-cookie")) ++cookies;
  }
  EXPECT_EQ(cookies, 2u);

  EXPECT_EQ(findHeader(headers, "X-Absent"), nullptr);
  EXPECT_EQ(findHeader({}, "Anything"), nullptr);
}

// ─── methodToken / methodIsBodyless ──────────────────────────────────────────

TEST(MethodToken, CoversEveryMethod) {
  struct Case {
    RawMethod method;
    const char* token;
    bool bodyless;
  };
  const Case cases[] = {
      {RAWMETHOD_GET, "GET", true},        {RAWMETHOD_HEAD, "HEAD", true},
      {RAWMETHOD_POST, "POST", false},     {RAWMETHOD_PUT, "PUT", false},
      {RAWMETHOD_DELETE, "DELETE", true},  {RAWMETHOD_PATCH, "PATCH", false},
      {RAWMETHOD_OPTIONS, "OPTIONS", true},{RAWMETHOD_TRACE, "TRACE", true},
  };
  for (const Case& c : cases) {
    RawRequest req{};
    req.method = c.method;
    EXPECT_EQ(wire::methodToken(req), c.token);
    EXPECT_EQ(wire::methodIsBodyless(req), c.bodyless) << c.token;
  }
}

TEST(MethodToken, CustomKeepsCaseAndTrimsWhitespace) {
  RawRequest req{};
  req.method = RAWMETHOD_CUSTOM;
  req.customMethod = "  Report  ";
  EXPECT_EQ(wire::methodToken(req), "Report")
      << "custom tokens are case-sensitive per RFC 9110 §9.1";
  EXPECT_FALSE(wire::methodIsBodyless(req));

  req.customMethod = "get";
  EXPECT_EQ(wire::methodToken(req), "get");
  EXPECT_TRUE(wire::methodIsBodyless(req))
      << "bodylessness is a property of the method, not of its spelling";
}

TEST(MethodToken, EmptyCustomMethodYieldsTheEmptyToken) {
  RawRequest req{};
  req.method = RAWMETHOD_CUSTOM;
  req.customMethod = "   ";
  EXPECT_EQ(wire::methodToken(req), "")
      << "an empty token is the signal the task rejects as badRequest";
  EXPECT_FALSE(wire::methodIsBodyless(req));
}

// ─── Record round trips ──────────────────────────────────────────────────────

TEST(RecordCodec, RawRequestRoundTripsEveryField) {
  RawRequest src{};
  src.requestId = 0x0123456789abcdefLL;
  src.method = RAWMETHOD_CUSTOM;
  src.customMethod = "PROPFIND";
  src.url = "https://example.com/a/b?q=1&r=2#frag";
  src.headers = {header("Accept", "application/json"),
                 header("X-Empty", ""),
                 header("X-Unicode", "héllo — wörld")};
  src.bodyKind = RAWBODYKIND_FILE_PATH;
  src.bodyFilePath = "/tmp/nitro/upload.bin";
  src.options.connectTimeoutMs = 1234;
  src.options.requestTimeoutMs = 56789;
  src.options.followRedirects = 1;
  src.options.maxRedirects = 7;
  src.options.cacheMode = RAWCACHEMODE_ONLY_IF_CACHED;
  src.options.reportProgress = true;
  src.options.wantTimings = false;
  src.options.uploadContentLength = 987654321;
  src.options.pinnedSpkiOverride = "sha256/AAAA";

  const RawRequest out = roundTrip(src);
  EXPECT_EQ(out.requestId, src.requestId);
  EXPECT_EQ(out.method, src.method);
  EXPECT_EQ(out.customMethod, src.customMethod);
  EXPECT_EQ(out.url, src.url);
  expectHeadersEqual(out.headers, src.headers);
  EXPECT_EQ(out.bodyKind, src.bodyKind);
  EXPECT_EQ(out.bodyFilePath, src.bodyFilePath);
  EXPECT_EQ(out.options.connectTimeoutMs, src.options.connectTimeoutMs);
  EXPECT_EQ(out.options.requestTimeoutMs, src.options.requestTimeoutMs);
  EXPECT_EQ(out.options.followRedirects, src.options.followRedirects);
  EXPECT_EQ(out.options.maxRedirects, src.options.maxRedirects);
  EXPECT_EQ(out.options.cacheMode, src.options.cacheMode);
  EXPECT_EQ(out.options.reportProgress, src.options.reportProgress);
  EXPECT_EQ(out.options.wantTimings, src.options.wantTimings);
  EXPECT_EQ(out.options.uploadContentLength, src.options.uploadContentLength);
  EXPECT_EQ(out.options.pinnedSpkiOverride, src.options.pinnedSpkiOverride);
}

TEST(RecordCodec, RawResponseRoundTripsEveryFieldIncludingTheBody) {
  RawResponse src{};
  src.requestId = 42;
  src.errorKind = RAWERRORKIND_TIMEOUT_IDLE;
  src.errorMessage = "idle for too long";
  src.engineErrorCode = 28;
  src.statusCode = 503;
  src.version = RAWHTTPVERSION_HTTP2;
  src.finalUrl = "https://example.com/final";
  src.redirectCount = 3;
  src.headers = {header("Server", "nitro"), header("Set-Cookie", "a=1"),
                 header("Set-Cookie", "b=2")};
  src.body.resize(1024);
  for (size_t i = 0; i < src.body.size(); ++i) {
    src.body[i] = static_cast<uint8_t>(i * 31 + 7);
  }
  src.fromCache = true;
  src.revalidated = true;
  src.primaryIp = "2001:db8::1";
  src.primaryPort = 8443;
  src.timings = populatedTimings();

  const RawResponse out = roundTrip(src);
  EXPECT_EQ(out.requestId, src.requestId);
  EXPECT_EQ(out.errorKind, src.errorKind);
  EXPECT_EQ(out.errorMessage, src.errorMessage);
  EXPECT_EQ(out.engineErrorCode, src.engineErrorCode);
  EXPECT_EQ(out.statusCode, src.statusCode);
  EXPECT_EQ(out.version, src.version);
  EXPECT_EQ(out.finalUrl, src.finalUrl);
  EXPECT_EQ(out.redirectCount, src.redirectCount);
  expectHeadersEqual(out.headers, src.headers);
  EXPECT_EQ(out.body, src.body);
  EXPECT_EQ(out.fromCache, src.fromCache);
  EXPECT_EQ(out.revalidated, src.revalidated);
  EXPECT_EQ(out.primaryIp, src.primaryIp);
  EXPECT_EQ(out.primaryPort, src.primaryPort);
  expectTimingsEqual(out.timings, src.timings);
}

TEST(RecordCodec, RawResponseSurvivesAnEmptyBodyAndNoHeaders) {
  RawResponse src{};
  src.requestId = 1;
  src.errorKind = RAWERRORKIND_NONE;
  src.statusCode = 204;
  src.version = RAWHTTPVERSION_HTTP11;
  src.timings = wire::zeroTimings();

  const RawResponse out = roundTrip(src);
  EXPECT_EQ(out.statusCode, 204);
  EXPECT_TRUE(out.headers.empty());
  EXPECT_TRUE(out.body.empty());
}

TEST(RecordCodec, RawResponseHeadRoundTripsEveryField) {
  RawResponseHead src{};
  src.requestId = 7;
  src.errorKind = RAWERRORKIND_NONE;
  src.errorMessage = "";
  src.engineErrorCode = 0;
  src.statusCode = 206;
  src.version = RAWHTTPVERSION_HTTP3;
  src.finalUrl = "https://cdn.example.com/big.bin";
  src.redirectCount = 1;
  src.headers = {header("Content-Range", "bytes 0-1023/8192")};
  src.fromCache = false;
  src.contentLength = 8192;
  src.primaryIp = "203.0.113.7";
  src.primaryPort = 443;
  src.timings = populatedTimings();

  const RawResponseHead out = roundTrip(src);
  EXPECT_EQ(out.requestId, src.requestId);
  EXPECT_EQ(out.errorKind, src.errorKind);
  EXPECT_EQ(out.errorMessage, src.errorMessage);
  EXPECT_EQ(out.engineErrorCode, src.engineErrorCode);
  EXPECT_EQ(out.statusCode, src.statusCode);
  EXPECT_EQ(out.version, src.version);
  EXPECT_EQ(out.finalUrl, src.finalUrl);
  EXPECT_EQ(out.redirectCount, src.redirectCount);
  expectHeadersEqual(out.headers, src.headers);
  EXPECT_EQ(out.fromCache, src.fromCache);
  EXPECT_EQ(out.contentLength, src.contentLength);
  EXPECT_EQ(out.primaryIp, src.primaryIp);
  EXPECT_EQ(out.primaryPort, src.primaryPort);
  expectTimingsEqual(out.timings, src.timings);
}

TEST(RecordCodec, RawEventRoundTripsEveryField) {
  RawEvent src{};
  src.requestId = -1;
  src.kind = RAWEVENTKIND_UPLOAD_DRAIN;
  src.a = 4096;
  src.b = -1;
  src.message = "drain";

  const RawEvent out = roundTrip(src);
  EXPECT_EQ(out.requestId, src.requestId);
  EXPECT_EQ(out.kind, src.kind);
  EXPECT_EQ(out.a, src.a);
  EXPECT_EQ(out.b, src.b);
  EXPECT_EQ(out.message, src.message);
}

TEST(RecordCodec, RawWsHandshakeRoundTripsEveryField) {
  RawWsHandshake src{};
  src.socketId = 99;
  src.errorKind = RAWERRORKIND_PROTOCOL_ERROR;
  src.errorMessage = "bad upgrade";
  src.engineErrorCode = 15;
  src.statusCode = 426;
  src.negotiatedProtocol = "chat.v2";
  src.responseHeaders = {header("Upgrade", "websocket"),
                         header("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")};

  const RawWsHandshake out = roundTrip(src);
  EXPECT_EQ(out.socketId, src.socketId);
  EXPECT_EQ(out.errorKind, src.errorKind);
  EXPECT_EQ(out.errorMessage, src.errorMessage);
  EXPECT_EQ(out.engineErrorCode, src.engineErrorCode);
  EXPECT_EQ(out.statusCode, src.statusCode);
  EXPECT_EQ(out.negotiatedProtocol, src.negotiatedProtocol);
  expectHeadersEqual(out.responseHeaders, src.responseHeaders);
}

TEST(RecordCodec, RawCacheStatsRoundTripsEveryField) {
  RawCacheStats src{};
  src.entryCount = 12;
  src.sizeBytes = 345678;
  src.hitCount = 9;
  src.missCount = 3;
  src.revalidationCount = 2;
  src.evictionCount = 1;

  const RawCacheStats out = roundTrip(src);
  EXPECT_EQ(out.entryCount, src.entryCount);
  EXPECT_EQ(out.sizeBytes, src.sizeBytes);
  EXPECT_EQ(out.hitCount, src.hitCount);
  EXPECT_EQ(out.missCount, src.missCount);
  EXPECT_EQ(out.revalidationCount, src.revalidationCount);
  EXPECT_EQ(out.evictionCount, src.evictionCount);
}

TEST(RecordCodec, RawClientConfigRoundTripsNestedRecordsAndLists) {
  RawClientConfig src{};
  src.httpVersion = RAWHTTPVERSIONPREF_HTTP2_ONLY;
  src.connectTimeoutMs = 1000;
  src.requestTimeoutMs = 2000;
  src.idleTimeoutMs = 3000;
  src.followRedirects = false;
  src.maxRedirects = 4;
  src.enableCompression = true;
  src.enableCache = true;
  src.userAgent = "nitro_http/1.0";
  src.altSvcCachePath = "/tmp/altsvc";
  src.defaultHeaders = {header("X-A", "1"), header("X-B", "2")};
  src.tls.verifyCertificates = false;
  src.tls.rootCaSource = 2;
  src.tls.trustedRootsPem = "-----BEGIN CERTIFICATE-----";
  src.tls.clientCertPem = "cert";
  src.tls.clientKeyPem = "key";
  src.tls.clientKeyPassword = "hunter2";
  src.tls.pinnedSpkiSha256 = {"sha256/AAA", "sha256/BBB"};
  src.tls.minTlsVersion = 12;
  src.tls.maxTlsVersion = 13;
  src.tls.sniHostname = "sni.example.com";
  src.proxy.mode = RAWPROXYMODE_SOCKS5_HOSTNAME;
  src.proxy.url = "socks5h://127.0.0.1:1080";
  src.proxy.username = "u";
  src.proxy.password = "p";
  src.proxy.noProxyHosts = "localhost,127.0.0.1";
  src.dns.staticOverrides = {"example.com:443:203.0.113.9"};
  src.dns.dohUrl = "https://dns.example/dns-query";
  src.cookies.enabled = true;
  src.cookies.persistPath = "/tmp/cookies.txt";
  src.pool.maxConnections = 32;
  src.pool.maxConnectionsPerHost = 8;
  src.pool.idleTimeoutMs = 45000;
  src.pool.maxLifetimeMs = 300000;
  src.pool.keepAlivePingMs = 15000;

  const RawClientConfig out = roundTrip(src);
  EXPECT_EQ(out.httpVersion, src.httpVersion);
  EXPECT_EQ(out.connectTimeoutMs, src.connectTimeoutMs);
  EXPECT_EQ(out.requestTimeoutMs, src.requestTimeoutMs);
  EXPECT_EQ(out.idleTimeoutMs, src.idleTimeoutMs);
  EXPECT_EQ(out.followRedirects, src.followRedirects);
  EXPECT_EQ(out.maxRedirects, src.maxRedirects);
  EXPECT_EQ(out.enableCompression, src.enableCompression);
  EXPECT_EQ(out.enableCache, src.enableCache);
  EXPECT_EQ(out.userAgent, src.userAgent);
  EXPECT_EQ(out.altSvcCachePath, src.altSvcCachePath);
  expectHeadersEqual(out.defaultHeaders, src.defaultHeaders);
  EXPECT_EQ(out.tls.verifyCertificates, src.tls.verifyCertificates);
  EXPECT_EQ(out.tls.rootCaSource, src.tls.rootCaSource);
  EXPECT_EQ(out.tls.trustedRootsPem, src.tls.trustedRootsPem);
  EXPECT_EQ(out.tls.clientCertPem, src.tls.clientCertPem);
  EXPECT_EQ(out.tls.clientKeyPem, src.tls.clientKeyPem);
  EXPECT_EQ(out.tls.clientKeyPassword, src.tls.clientKeyPassword);
  EXPECT_EQ(out.tls.pinnedSpkiSha256, src.tls.pinnedSpkiSha256);
  EXPECT_EQ(out.tls.minTlsVersion, src.tls.minTlsVersion);
  EXPECT_EQ(out.tls.maxTlsVersion, src.tls.maxTlsVersion);
  EXPECT_EQ(out.tls.sniHostname, src.tls.sniHostname);
  EXPECT_EQ(out.proxy.mode, src.proxy.mode);
  EXPECT_EQ(out.proxy.url, src.proxy.url);
  EXPECT_EQ(out.proxy.username, src.proxy.username);
  EXPECT_EQ(out.proxy.password, src.proxy.password);
  EXPECT_EQ(out.proxy.noProxyHosts, src.proxy.noProxyHosts);
  EXPECT_EQ(out.dns.staticOverrides, src.dns.staticOverrides);
  EXPECT_EQ(out.dns.dohUrl, src.dns.dohUrl);
  EXPECT_EQ(out.cookies.enabled, src.cookies.enabled);
  EXPECT_EQ(out.cookies.persistPath, src.cookies.persistPath);
  EXPECT_EQ(out.pool.maxConnections, src.pool.maxConnections);
  EXPECT_EQ(out.pool.maxConnectionsPerHost, src.pool.maxConnectionsPerHost);
  EXPECT_EQ(out.pool.idleTimeoutMs, src.pool.idleTimeoutMs);
  EXPECT_EQ(out.pool.maxLifetimeMs, src.pool.maxLifetimeMs);
  EXPECT_EQ(out.pool.keepAlivePingMs, src.pool.keepAlivePingMs);
}

// ─── errorResponse / errorResponseHead ───────────────────────────────────────

TEST(ErrorEnvelope, CarriesTheFailureAndNothingElse) {
  const EngineError err = EngineError::make(RAWERRORKIND_CANCELLED,
                                            "cancelled by caller", 42);
  const RawResponse r = wire::errorResponse(11, err);
  EXPECT_EQ(r.requestId, 11);
  EXPECT_EQ(r.errorKind, RAWERRORKIND_CANCELLED);
  EXPECT_EQ(r.errorMessage, "cancelled by caller");
  EXPECT_EQ(r.engineErrorCode, 42);
  EXPECT_EQ(r.statusCode, 0);
  EXPECT_TRUE(r.headers.empty());
  EXPECT_TRUE(r.body.empty());
  EXPECT_FALSE(r.fromCache);
  EXPECT_FALSE(r.revalidated);

  const RawResponseHead h = wire::errorResponseHead(11, err);
  EXPECT_EQ(h.requestId, 11);
  EXPECT_EQ(h.errorKind, RAWERRORKIND_CANCELLED);
  EXPECT_EQ(h.contentLength, -1)
      << "-1 means the server declared no length; a failed transfer never got "
         "a declaration at all";
}

// ─── encodeCookieList: the indexed LazyRecordList layout ─────────────────────

namespace {

/// Decodes exactly the way Dart's `LazyRecordList.decode` does: read the offset
/// table, then seek. Deliberately does NOT read sequentially — that is the bug
/// this layout exists to catch.
struct LazyRecordList {
  std::vector<uint8_t> payload;  ///< the block after the 4-byte length prefix
  int32_t count = 0;
  std::vector<int64_t> offsets;
};

LazyRecordList decodeLazyList(const Blob& blob) {
  EXPECT_NE(blob.data, nullptr);
  int32_t payloadLen = 0;
  std::memcpy(&payloadLen, blob.data, sizeof(int32_t));
  EXPECT_EQ(static_cast<size_t>(payloadLen) + sizeof(int32_t), blob.size);

  LazyRecordList list;
  list.payload.assign(blob.data + sizeof(int32_t),
                      blob.data + sizeof(int32_t) + payloadLen);
  std::memcpy(&list.count, list.payload.data(), sizeof(int32_t));
  list.offsets.resize(static_cast<size_t>(list.count));
  for (int32_t i = 0; i < list.count; ++i) {
    std::memcpy(&list.offsets[static_cast<size_t>(i)],
                list.payload.data() + 4 + 8 * static_cast<size_t>(i),
                sizeof(int64_t));
  }
  return list;
}

RawCookie makeCookie(const std::string& name, const std::string& value) {
  RawCookie c{};
  c.name = name;
  c.value = value;
  c.domain = "example.com";
  c.path = "/";
  c.expiresEpochMs = 1700000000000LL;
  c.secure = true;
  c.httpOnly = false;
  return c;
}

}  // namespace

TEST(EncodeCookieList, ProducesAnIndexedListDartCanSeekThrough) {
  const std::vector<RawCookie> cookies = {
      makeCookie("session", "abc"), makeCookie("theme", "dark-mode-preference"),
      makeCookie("x", "")};

  Blob blob = wire::encodeCookieList(cookies);
  ASSERT_FALSE(blob.empty());
  LazyRecordList list = decodeLazyList(blob);

  ASSERT_EQ(list.count, 3);
  ASSERT_EQ(list.offsets.size(), 3u);
  EXPECT_EQ(list.offsets[0], 4 + 8 * 3)
      << "the first item sits immediately after the offset table";

  // Seek in REVERSE order: sequential decoding would still pass, seeking will
  // not unless every offset is right.
  for (int i = 2; i >= 0; --i) {
    const size_t at = static_cast<size_t>(list.offsets[static_cast<size_t>(i)]);
    ASSERT_LT(at, list.payload.size());
    NitroRecordReader reader(list.payload.data() + at,
                             list.payload.size() - at);
    const RawCookie decoded = RawCookie::fromReader(reader);
    EXPECT_EQ(decoded.name, cookies[static_cast<size_t>(i)].name);
    EXPECT_EQ(decoded.value, cookies[static_cast<size_t>(i)].value);
    EXPECT_EQ(decoded.domain, cookies[static_cast<size_t>(i)].domain);
    EXPECT_EQ(decoded.path, cookies[static_cast<size_t>(i)].path);
    EXPECT_EQ(decoded.expiresEpochMs,
              cookies[static_cast<size_t>(i)].expiresEpochMs);
    EXPECT_EQ(decoded.secure, cookies[static_cast<size_t>(i)].secure);
    EXPECT_EQ(decoded.httpOnly, cookies[static_cast<size_t>(i)].httpOnly);
    if (i == 2) {
      // The final item must end exactly at the payload end — no slack, no
      // truncation.
      EXPECT_EQ(at + reader._offset, list.payload.size());
    }
  }
  blob.release();
}

TEST(EncodeCookieList, AnEmptyJarIsAWellFormedZeroElementList) {
  Blob blob = wire::encodeCookieList({});
  ASSERT_FALSE(blob.empty()) << "an empty jar must not decode as a null buffer";
  const LazyRecordList list = decodeLazyList(blob);
  EXPECT_EQ(list.count, 0);
  EXPECT_TRUE(list.offsets.empty());
  EXPECT_EQ(list.payload.size(), 4u) << "count word only";
  blob.release();
}

TEST(EncodeCookieList, OffsetsAdvanceByExactlyEachItemsEncodedSize) {
  const std::vector<RawCookie> cookies = {makeCookie("a", "1"),
                                          makeCookie("bb", "22"),
                                          makeCookie("ccc", "333")};
  Blob blob = wire::encodeCookieList(cookies);
  const LazyRecordList list = decodeLazyList(blob);
  ASSERT_EQ(list.count, 3);
  for (size_t i = 0; i < cookies.size(); ++i) {
    NitroRecordWriter w;
    cookies[i].encodeInto(w);
    const size_t itemSize = w.toBuffer().size;
    const size_t next = i + 1 < cookies.size()
                            ? static_cast<size_t>(list.offsets[i + 1])
                            : list.payload.size();
    EXPECT_EQ(next - static_cast<size_t>(list.offsets[i]), itemSize)
        << "at index " << i;
  }
  blob.release();
}

// ─── The arena-lifetime contract ─────────────────────────────────────────────

TEST(ArenaLifetime, DecodedRequestSurvivesTheCallerFreeingItsSourceBuffer) {
  RawRequest src{};
  src.requestId = 5150;
  src.method = RAWMETHOD_POST;
  src.customMethod = "";
  src.url = "https://arena.example.com/deep/path?with=query";
  src.headers = {header("Authorization", "Bearer a-fairly-long-token-value"),
                 header("Content-Type", "application/json"),
                 header("X-Correlation-Id", "01HQ8Z0000000000000000000")};
  src.bodyKind = RAWBODYKIND_BYTES;
  src.bodyFilePath = "";
  src.options.connectTimeoutMs = 111;
  src.options.requestTimeoutMs = 222;
  src.options.pinnedSpkiOverride = "sha256/ZZZZ";

  // Encode into a heap block, exactly as the bridge hands one to us.
  const NitroCppBuffer owned = src.toNativeBuffer();
  ASSERT_NE(owned.data, nullptr);
  int32_t payloadLen = 0;
  std::memcpy(&payloadLen, owned.data, sizeof(int32_t));

  const RawRequest decoded = wire::decodeRequest(NitroCppBuffer{
      owned.data + sizeof(int32_t), static_cast<size_t>(payloadLen)});

  // Poison then free: any field still pointing into the arena is now garbage,
  // which is precisely what this test must fail on.
  std::memset(const_cast<uint8_t*>(owned.data), 0xab, owned.size);
  ::free(const_cast<uint8_t*>(owned.data));

  EXPECT_EQ(decoded.requestId, 5150);
  EXPECT_EQ(decoded.method, RAWMETHOD_POST);
  EXPECT_EQ(decoded.url, "https://arena.example.com/deep/path?with=query");
  ASSERT_EQ(decoded.headers.size(), 3u);
  EXPECT_EQ(decoded.headers[0].name, "Authorization");
  EXPECT_EQ(decoded.headers[0].value, "Bearer a-fairly-long-token-value");
  EXPECT_EQ(decoded.headers[1].name, "Content-Type");
  EXPECT_EQ(decoded.headers[1].value, "application/json");
  EXPECT_EQ(decoded.headers[2].name, "X-Correlation-Id");
  EXPECT_EQ(decoded.headers[2].value, "01HQ8Z0000000000000000000");
  EXPECT_EQ(decoded.bodyKind, RAWBODYKIND_BYTES);
  EXPECT_EQ(decoded.options.connectTimeoutMs, 111);
  EXPECT_EQ(decoded.options.requestTimeoutMs, 222);
  EXPECT_EQ(decoded.options.pinnedSpkiOverride, "sha256/ZZZZ");
}

TEST(ArenaLifetime, EveryDecoderReturnsAnOwningValue) {
  RawClientConfig cfg{};
  cfg.userAgent = "owning-value-check";
  cfg.defaultHeaders = {header("X-Owned", "yes")};
  cfg.tls.pinnedSpkiSha256 = {"sha256/OWNED"};
  cfg.dns.staticOverrides = {"a.example:443:198.51.100.4"};
  cfg.cookies.persistPath = "/tmp/jar";
  cfg.proxy.url = "http://proxy.example:3128";

  const NitroCppBuffer owned = cfg.toNativeBuffer();
  int32_t len = 0;
  std::memcpy(&len, owned.data, sizeof(int32_t));
  const RawClientConfig decoded = wire::decodeClientConfig(
      NitroCppBuffer{owned.data + sizeof(int32_t), static_cast<size_t>(len)});
  std::memset(const_cast<uint8_t*>(owned.data), 0xcd, owned.size);
  ::free(const_cast<uint8_t*>(owned.data));

  EXPECT_EQ(decoded.userAgent, "owning-value-check");
  ASSERT_EQ(decoded.defaultHeaders.size(), 1u);
  EXPECT_EQ(decoded.defaultHeaders[0].value, "yes");
  ASSERT_EQ(decoded.tls.pinnedSpkiSha256.size(), 1u);
  EXPECT_EQ(decoded.tls.pinnedSpkiSha256[0], "sha256/OWNED");
  ASSERT_EQ(decoded.dns.staticOverrides.size(), 1u);
  EXPECT_EQ(decoded.dns.staticOverrides[0], "a.example:443:198.51.100.4");
  EXPECT_EQ(decoded.cookies.persistPath, "/tmp/jar");
  EXPECT_EQ(decoded.proxy.url, "http://proxy.example:3128");
}

// ─── Sentinels ───────────────────────────────────────────────────────────────

TEST(Sentinels, NegativeMeansInherit) {
  EXPECT_EQ(wire::inherit(-1, 5000), 5000);
  EXPECT_EQ(wire::inherit(0, 5000), 0) << "zero is a value, not a sentinel";
  EXPECT_EQ(wire::inherit(250, 5000), 250);

  EXPECT_TRUE(wire::inheritBool(-1, true));
  EXPECT_FALSE(wire::inheritBool(-1, false));
  EXPECT_FALSE(wire::inheritBool(0, true));
  EXPECT_TRUE(wire::inheritBool(1, false));
}
