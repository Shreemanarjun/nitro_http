// ─────────────────────────────────────────────────────────────────────────────
// CurlEngine against a real HTTP server.
//
// The invariant every test here defends is EXACTLY-ONCE COMPLETION: an accepted
// request posts precisely one message to its Dart port, on every path —
// success, a 500, a preparation failure, cancellation before or during the
// transfer, and engine shutdown. A request that never posts hangs a Dart Future
// forever, and a request that posts twice corrupts the runner's bookkeeping.
//
// The second invariant is that errors ride INSIDE the record: `errorKind ==
// none` means the transfer completed, so a 500 is a success with
// `statusCode == 500`.
// ─────────────────────────────────────────────────────────────────────────────

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#ifndef _WIN32
// Only for `AStalledTlsHandshakeIsAlsoAConnectTimeout`, which needs a raw
// listening socket that never accepts.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include "CancelRegistry.h"
#include "Common.h"
#include "CurlEngine.h"
#include "DeferredPayloads.h"
#include "EngineRegistry.h"
#include "HttpCache.h"
#include "RequestTask.h"
#include "support/HttpTestServer.h"
#include "support/TestSink.h"

using namespace nitrohttp;
using nitrohttp::test::CapturedChunk;
using nitrohttp::test::Captures;
using nitrohttp::test::HttpTestServer;

namespace fs = std::filesystem;

namespace {

template <typename Fn>
bool waitFor(Fn predicate, int timeoutMs = 15000) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return predicate();
}

RawHeader hdr(std::string name, std::string value) {
  RawHeader h{};
  h.name = std::move(name);
  h.value = std::move(value);
  return h;
}

bool contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

size_t countOccurrences(const std::string& haystack, const std::string& needle) {
  size_t n = 0;
  size_t at = haystack.find(needle);
  while (at != std::string::npos) {
    ++n;
    at = haystack.find(needle, at + needle.size());
  }
  return n;
}

std::string bodyOf(const RawResponse& r) {
  return std::string(r.body.begin(), r.body.end());
}

std::vector<CapturedChunk> chunksFor(int64_t requestId) {
  std::vector<CapturedChunk> out;
  for (const CapturedChunk& chunk : Captures::instance().chunks()) {
    if (chunk.requestId == requestId) out.push_back(chunk);
  }
  return out;
}

size_t dataChunkCount(int64_t requestId) {
  size_t n = 0;
  for (const CapturedChunk& chunk : chunksFor(requestId)) {
    if (chunk.kind == RAWCHUNKKIND_DATA) ++n;
  }
  return n;
}

/// The single terminal chunk, or nullptr while the stream is still running.
/// Also asserts there is at most one, which is the streamed-mode half of
/// exactly-once completion.
bool terminalChunk(int64_t requestId, CapturedChunk* out) {
  size_t found = 0;
  for (const CapturedChunk& chunk : chunksFor(requestId)) {
    if (chunk.kind == RAWCHUNKKIND_DONE || chunk.kind == RAWCHUNKKIND_ERROR) {
      ++found;
      if (out != nullptr) *out = chunk;
    }
  }
  EXPECT_LE(found, 1u) << "a streamed request must emit exactly one terminal "
                          "chunk";
  return found == 1;
}

std::vector<uint8_t> concatenatedPayload(int64_t requestId) {
  std::vector<uint8_t> out;
  for (const CapturedChunk& chunk : chunksFor(requestId)) {
    if (chunk.kind != RAWCHUNKKIND_DATA) continue;
    out.insert(out.end(), chunk.bytes.begin(), chunk.bytes.end());
  }
  return out;
}

std::vector<RawEvent> eventsFor(int64_t requestId, RawEventKind kind) {
  std::vector<RawEvent> out;
  for (const auto& captured : Captures::instance().events()) {
    if (captured.value.requestId == requestId && captured.value.kind == kind) {
      out.push_back(captured.value);
    }
  }
  return out;
}

class EngineTest : public ::testing::Test {
 protected:
  void SetUp() override {
    Captures::instance().clear();
    Captures::instance().setPortAlive(true);
    DeferredPayloads::instance().dropEverything();
    tempRoot_ = fs::temp_directory_path() /
                ("nitro_http_engine_test_" +
                 std::to_string(static_cast<unsigned long long>(
                     std::chrono::steady_clock::now()
                         .time_since_epoch()
                         .count())));
    fs::create_directories(tempRoot_);
  }

  void TearDown() override {
    Captures::instance().setPortAlive(true);
    DeferredPayloads::instance().dropEverything();
    std::error_code ec;
    fs::remove_all(tempRoot_, ec);
  }

  PendingRequest request(int64_t id, const std::string& path,
                         RespMode mode = RespMode::Buffered) const {
    PendingRequest pending;
    pending.req = nitrohttp::test::getRequest(id, server_.url(path));
    pending.mode = mode;
    pending.dartPort = 42 + id;
    pending.submittedAtMs = monotonicMs();
    return pending;
  }

  /// Submits and waits for the single post every accepted request owes.
  /// Only the NEW post is decoded: a `RawResponseHead` left over from an
  /// earlier streamed request in the same test has a different layout and
  /// would throw if fed through the `RawResponse` reader.
  RawResponse sendBuffered(CurlEngine& engine, PendingRequest pending) {
    const size_t before = Captures::instance().posts().size();
    engine.submit(std::move(pending));
    EXPECT_TRUE(Captures::instance().waitForPosts(before + 1))
        << "no completion posted";
    const std::vector<nitrohttp::test::CapturedPost> posts =
        Captures::instance().posts();
    EXPECT_EQ(posts.size(), before + 1) << "exactly-once completion violated";
    if (posts.size() <= before) return RawResponse{};
    const nitrohttp::test::CapturedPost& latest = posts[before];
    return RawResponse::fromNative(
        NitroCppBuffer{latest.payload.data(), latest.payload.size()});
  }

  fs::path writeTempFile(const std::string& name, const std::string& contents) {
    const fs::path path = tempRoot_ / name;
    std::ofstream out(path.string(), std::ios::binary);
    out.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    out.close();
    return path;
  }

  HttpTestServer server_;
  fs::path tempRoot_;
};

}  // namespace

// ─── Buffered GET ────────────────────────────────────────────────────────────

TEST_F(EngineTest, BufferedGetReportsEverythingTheCallerNeeds) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/echo?b=2&a=1"));

  EXPECT_EQ(r.requestId, 1);
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.engineErrorCode, 0);
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_EQ(r.version, RAWHTTPVERSION_HTTP11);
  EXPECT_EQ(r.finalUrl, server_.url("/echo?b=2&a=1"));
  EXPECT_EQ(r.redirectCount, 0);
  EXPECT_EQ(r.primaryIp, "127.0.0.1");
  EXPECT_EQ(r.primaryPort, server_.port());
  EXPECT_FALSE(r.fromCache);
  EXPECT_FALSE(r.revalidated);
  EXPECT_GT(r.timings.totalMs, 0.0);
  EXPECT_GE(r.timings.firstByteMs, 0.0);

  EXPECT_FALSE(r.headers.empty());
  const RawHeader* type = findHeader(r.headers, "content-type");
  ASSERT_NE(type, nullptr) << "header lookup must be case-insensitive";
  EXPECT_EQ(type->value, "application/json");

  const std::string body = bodyOf(r);
  EXPECT_TRUE(contains(body, "\"method\":\"GET\"")) << body;
  EXPECT_TRUE(contains(body, "\"path\":\"/echo\"")) << body;
  EXPECT_TRUE(contains(body, "\"query\":\"b=2&a=1\"")) << body;
  EXPECT_EQ(server_.requestCount("/echo"), 1);
}

TEST_F(EngineTest, AQueuedRequestDoesNotWaitForThePollTimeout) {
  // Regression guard for a one-second stall.
  //
  // The loop used to rely entirely on `curl_multi_wakeup` to break out of a
  // blocking `curl_multi_poll`. That call writes a byte to an internal
  // socketpair and can fail — and both call sites discard its return code — so a
  // dropped byte left a queued request sitting for the whole `kPollTimeoutMs`,
  // one second. `nextPollTimeoutMs` now refuses to block while the inbox is
  // non-empty, which makes the wakeup an optimisation rather than a correctness
  // requirement.
  //
  // Timing is the only way to observe this from outside: a request that has to
  // wait for the poll timeout takes ~1 s, and one that does not takes
  // milliseconds. The bound is deliberately far below a second and far above a
  // healthy loopback request, so the test cannot flake on a slow machine and
  // cannot pass if the stall returns.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  // Warm the loop so the first request is not paying connection setup.
  ASSERT_EQ(sendBuffered(engine, request(1, "/echo")).errorKind,
            RAWERRORKIND_NONE);

  // Let the spin window lapse, so the loop is genuinely in a blocking poll when
  // the next request is queued — the exact state the stall needed.
  std::this_thread::sleep_for(std::chrono::milliseconds(50));

  const auto start = std::chrono::steady_clock::now();
  const RawResponse r = sendBuffered(engine, request(2, "/echo"));
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - start)
                           .count();

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_LT(elapsed, 250)
      << "a request queued while the loop was in a blocking poll took " << elapsed
      << " ms; kPollTimeoutMs is " << 1000
      << ", so the loop is waiting out the timeout instead of noticing the inbox";
}

TEST_F(EngineTest, EasyHandlesAreRecycledRatherThanReallocated) {
  // `curl_easy_init` + `curl_easy_cleanup` per request was the bulk of the
  // engine's ~42 us of per-request overhead outside the transfer. The pool is
  // invisible from the outside by design, so this asserts it directly: nothing
  // spare before the first request, exactly one spare afterwards, and still one
  // after many more — proving each request took the same handle back rather than
  // allocating another.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  EXPECT_EQ(engine.pooledEasyHandlesForTesting(), 0u);

  const RawResponse first = sendBuffered(engine, request(1, "/echo"));
  ASSERT_EQ(first.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(engine.pooledEasyHandlesForTesting(), 1u)
      << "a completed transfer must hand its handle back";

  for (int64_t id = 2; id <= 20; ++id) {
    const RawResponse r = sendBuffered(engine, request(id, "/echo"));
    ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << "request " << id;
    ASSERT_EQ(r.statusCode, 200) << "request " << id;
  }

  EXPECT_EQ(engine.pooledEasyHandlesForTesting(), 1u)
      << "sequential requests must reuse the one spare handle";
  EXPECT_EQ(server_.requestCount("/echo"), 20);
}

TEST_F(EngineTest, ARecycledHandleCarriesNoStateFromThePreviousRequest) {
  // `curl_easy_reset` is what makes pooling safe. If it were skipped, options
  // from an earlier request would leak into a later one — the failure would be a
  // subtle wrong-header or wrong-method bug, not a crash. So: a POST with a body
  // and a custom header, then a plain GET on the recycled handle, and the GET
  // must show no trace of the POST.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest post = request(1, "/echo");
  post.req.method = RAWMETHOD_POST;
  post.req.bodyKind = RAWBODYKIND_BYTES;
  post.req.headers = {hdr("X-Leaked", "must-not-persist")};
  const std::string payload = "hi";
  post.body.assign(payload.begin(), payload.end());
  const RawResponse posted = sendBuffered(engine, std::move(post));
  ASSERT_EQ(posted.errorKind, RAWERRORKIND_NONE);
  const RawHeader* method = findHeader(posted.headers, "X-Echo-Method");
  ASSERT_NE(method, nullptr);
  EXPECT_EQ(method->value, "POST");
  EXPECT_EQ(bodyOf(posted), "hi");

  // `GET /echo` reflects the request headers back inside its JSON body, which is
  // what makes the leak observable.
  const RawResponse got = sendBuffered(engine, request(2, "/echo"));
  ASSERT_EQ(got.errorKind, RAWERRORKIND_NONE);

  const std::string echoed = bodyOf(got);
  EXPECT_TRUE(contains(echoed, "\"method\":\"GET\""))
      << "the POST method survived the reset: " << echoed;
  EXPECT_FALSE(contains(echoed, "must-not-persist"))
      << "a header from the previous request survived the reset: " << echoed;
  EXPECT_FALSE(contains(echoed, "content-length"))
      << "the previous request's body survived the reset: " << echoed;
}

TEST_F(EngineTest, EveryVerbReachesTheServer) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  struct Case {
    RawMethod method;
    const char* token;
    bool sendsBody;
  };
  const Case cases[] = {
      {RAWMETHOD_POST, "POST", true},   {RAWMETHOD_PUT, "PUT", true},
      {RAWMETHOD_PATCH, "PATCH", true}, {RAWMETHOD_DELETE, "DELETE", false},
      {RAWMETHOD_OPTIONS, "OPTIONS", false},
  };

  int64_t id = 10;
  for (const Case& c : cases) {
    PendingRequest pending = request(id, "/echo");
    pending.req.method = c.method;
    if (c.sendsBody) {
      const std::string payload = std::string("payload-for-") + c.token;
      pending.body.assign(payload.begin(), payload.end());
      pending.req.bodyKind = RAWBODYKIND_BYTES;
      pending.req.headers = {hdr("Content-Type", "application/x-nitro-test")};
    }
    const RawResponse r = sendBuffered(engine, std::move(pending));

    EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE) << c.token;
    EXPECT_EQ(r.statusCode, 200) << c.token;
    if (c.method == RAWMETHOD_OPTIONS) {
      EXPECT_EQ(bodyOf(r), "OPTIONS");
    } else {
      const RawHeader* echoed = findHeader(r.headers, "X-Echo-Method");
      ASSERT_NE(echoed, nullptr) << c.token;
      EXPECT_EQ(echoed->value, c.token);
    }
    if (c.sendsBody) {
      EXPECT_EQ(bodyOf(r), std::string("payload-for-") + c.token);
      const RawHeader* type = findHeader(r.headers, "X-Echo-Content-Type");
      ASSERT_NE(type, nullptr) << c.token;
      EXPECT_EQ(type->value, "application/x-nitro-test")
          << "Content-Type must reach the server";
    }
    ++id;
  }

  // HEAD shares the GET route and must come back with headers and no body.
  PendingRequest head = request(id, "/echo");
  head.req.method = RAWMETHOD_HEAD;
  const RawResponse r = sendBuffered(engine, std::move(head));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_TRUE(r.body.empty()) << "HEAD must not deliver a body";
  EXPECT_NE(findHeader(r.headers, "Content-Type"), nullptr);
}

TEST_F(EngineTest, APostBodyArrivesByteForByte) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  std::string payload;
  payload.reserve(64 * 1024);
  for (size_t i = 0; i < 64 * 1024; ++i) {
    payload.push_back(static_cast<char>(i * 17 + 3));
  }

  PendingRequest pending = request(1, "/upload");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_BYTES;
  pending.req.headers = {hdr("Content-Type", "application/octet-stream")};
  pending.body.assign(payload.begin(), payload.end());

  const RawResponse r = sendBuffered(engine, std::move(pending));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_TRUE(contains(bodyOf(r), "\"bytes\":" + std::to_string(payload.size())))
      << bodyOf(r);
  EXPECT_TRUE(contains(bodyOf(r),
                       hexSha256(payload.data(), payload.size())))
      << bodyOf(r);
}

TEST_F(EngineTest, DefaultHeadersAreSentAndARequestHeaderOverridesThem) {
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.defaultHeaders = {hdr("X-Only-Default", "from-client"),
                           hdr("X-Overridden", "from-client")};

  CurlEngine engine(1);
  engine.configure(config);

  PendingRequest pending = request(1, "/headers");
  pending.req.headers = {hdr("X-Overridden", "from-request")};

  const RawResponse r = sendBuffered(engine, std::move(pending));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE);
  const std::string echoed = bodyOf(r);

  EXPECT_TRUE(contains(echoed, "X-Only-Default: from-client")) << echoed;
  EXPECT_TRUE(contains(echoed, "X-Overridden: from-request")) << echoed;
  EXPECT_FALSE(contains(echoed, "X-Overridden: from-client"))
      << "the request header must REPLACE the default, not duplicate it:\n"
      << echoed;
  EXPECT_EQ(countOccurrences(echoed, "X-Overridden"), 1u) << echoed;
  EXPECT_TRUE(contains(echoed, "User-Agent: nitro_http-tests")) << echoed;
}

// Curl adds `Expect: 100-continue` by itself for a large body. The size that
// triggers it is not a documented constant and was found by observation: a
// 128 KiB body does not get the header, an 8 MiB body does, so the payload here
// is 8 MiB and shrinking it would quietly stop testing anything.
//
// Against a server that never answers the handshake — `dart:io`'s `HttpServer`,
// and therefore `shelf`, ignore it entirely — curl waits out
// `CURLOPT_EXPECT_100_TIMEOUT_MS` (1 s) before sending a single body byte. That
// measured as a flat one-second stall on every upload shape: 8 MiB took 1134 ms
// with the header and 120 ms without.
TEST_F(EngineTest, NoExpectContinueHeaderIsSentForABodyOverCurlsThreshold) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/headers");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_BYTES;
  // Without this curl labels the body `application/x-www-form-urlencoded`, which
  // the test server caps well below 128 KiB and answers 413.
  pending.req.headers = {hdr("Content-Type", "application/octet-stream")};
  const std::string payload(8 * 1024 * 1024, 'x');
  pending.body.assign(payload.begin(), payload.end());

  const RawResponse r = sendBuffered(engine, std::move(pending));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE);
  // Pinned: `/headers` used to answer GET only, so this test passed against a
  // 404 body that contained no header names at all and would have kept passing
  // with the suppression removed.
  ASSERT_EQ(r.statusCode, 200);
  const std::string echoed = bodyOf(r);
  ASSERT_TRUE(contains(echoed, "Content-Length")) << echoed;
  EXPECT_FALSE(contains(echoed, "Expect")) << echoed;
}

// The suppression is a default, not a policy: a caller who wants the handshake
// says so and curl's behaviour comes back.
TEST_F(EngineTest, AnExplicitExpectContinueHeaderIsHonoured) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/headers");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_BYTES;
  pending.req.headers = {hdr("Expect", "100-continue"),
                         hdr("Content-Type", "application/octet-stream")};
  const std::string payload(8 * 1024 * 1024, 'x');
  pending.body.assign(payload.begin(), payload.end());

  const RawResponse r = sendBuffered(engine, std::move(pending));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE);
  ASSERT_EQ(r.statusCode, 200);
  const std::string echoed = bodyOf(r);
  EXPECT_TRUE(contains(echoed, "Expect: 100-continue")) << echoed;
  EXPECT_EQ(countOccurrences(echoed, "Expect"), 1u) << echoed;
}

// A GET has no body, so curl would never add the header and there is nothing to
// suppress. Pinned because the guard is written in terms of `bodyKind`.
TEST_F(EngineTest, ABodylessRequestSendsNoExpectHeaderEither) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/headers"));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE);
  ASSERT_EQ(r.statusCode, 200);
  ASSERT_TRUE(contains(bodyOf(r), "User-Agent")) << bodyOf(r);
  EXPECT_FALSE(contains(bodyOf(r), "Expect")) << bodyOf(r);
}

// ─── Invariant 2: errors ride inside the record ──────────────────────────────

TEST_F(EngineTest, AServerErrorIsASuccessfulTransfer) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/status/500"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE)
      << "errorKind describes the TRANSPORT; a 500 arrived intact";
  EXPECT_EQ(r.statusCode, 500);
  EXPECT_EQ(bodyOf(r), "status 500");

  const RawResponse notFound = sendBuffered(engine, request(2, "/status/404"));
  EXPECT_EQ(notFound.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(notFound.statusCode, 404);
}

TEST_F(EngineTest, APreparationFailureStillPostsExactlyOnce) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/echo");
  pending.req.url = "";  // rejected before curl is ever touched
  const RawResponse r = sendBuffered(engine, std::move(pending));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_BAD_REQUEST);
  EXPECT_EQ(r.requestId, 1);
  EXPECT_FALSE(r.errorMessage.empty());

  PendingRequest custom = request(2, "/echo");
  custom.req.method = RAWMETHOD_CUSTOM;
  custom.req.customMethod = "   ";
  const RawResponse r2 = sendBuffered(engine, std::move(custom));
  EXPECT_EQ(r2.errorKind, RAWERRORKIND_BAD_REQUEST);
}

// ─── Redirects ───────────────────────────────────────────────────────────────

TEST_F(EngineTest, ARedirectChainIsFollowedAndCounted) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/redirect/3"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_EQ(r.redirectCount, 3);
  EXPECT_EQ(r.finalUrl, server_.url("/redirect/0"));
  EXPECT_EQ(bodyOf(r), "redirect-done");
  EXPECT_EQ(server_.requestCount("/redirect/0"), 1);
}

TEST_F(EngineTest, RedirectsDisabledReturnsThe3xxItself) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/redirect/2");
  pending.req.options.followRedirects = 0;
  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.statusCode, 302);
  EXPECT_EQ(r.redirectCount, 0);
  const RawHeader* location = findHeader(r.headers, "Location");
  ASSERT_NE(location, nullptr);
  EXPECT_EQ(location->value, "/redirect/1");
  EXPECT_EQ(server_.requestCount("/redirect/1"), 0)
      << "nothing beyond the first hop may be fetched";
}

// ─── Timeouts ────────────────────────────────────────────────────────────────

TEST_F(EngineTest, AConnectTimeoutIsClassifiedAsSuch) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/unused");
  // TEST-NET-1 (RFC 5737): reserved for documentation and never routed, so the
  // SYN goes nowhere rather than being refused.
  pending.req.url = "http://192.0.2.1:9/";
  pending.req.options.connectTimeoutMs = 400;
  pending.req.options.requestTimeoutMs = 15000;

  const RawResponse r = sendBuffered(engine, std::move(pending));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_TIMEOUT_CONNECT)
      << "the connection was never established, so the deadline that fired "
         "was the connect one, not the request one: "
      << r.errorMessage;
  EXPECT_EQ(r.statusCode, 0);
}

#ifndef _WIN32
TEST_F(EngineTest, AStalledTlsHandshakeIsAlsoAConnectTimeout) {
  // A listening socket that never calls accept(). The kernel completes the TCP
  // handshake from the backlog, so `CURLINFO_CONNECT_TIME` is non-zero, and the
  // TLS handshake then hangs forever. That combination is what made the old
  // classification wrong: it read CONNECT_TIME as "the connect phase finished"
  // and reported `timeoutRequest`, when `CURLOPT_CONNECTTIMEOUT_MS` covers the
  // TLS handshake too and it is the deadline that actually fired.
  //
  // POSIX-only, for the same reason `ws_session_test.cpp` is: the suite has no
  // winsock initialisation of its own.
  const int listener = ::socket(AF_INET, SOCK_STREAM, 0);
  ASSERT_GE(listener, 0);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  ASSERT_EQ(::bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)),
            0);
  ASSERT_EQ(::listen(listener, 8), 0);
  socklen_t addrLen = sizeof(addr);
  ASSERT_EQ(::getsockname(listener, reinterpret_cast<sockaddr*>(&addr),
                          &addrLen),
            0);
  const int blackHolePort = ntohs(addr.sin_port);

  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/unused");
  pending.req.url =
      "https://127.0.0.1:" + std::to_string(blackHolePort) + "/echo";
  pending.req.options.connectTimeoutMs = 700;
  pending.req.options.requestTimeoutMs = 30000;

  const RawResponse r = sendBuffered(engine, std::move(pending));
  ::close(listener);

  EXPECT_EQ(r.errorKind, RAWERRORKIND_TIMEOUT_CONNECT)
      << "the TLS handshake never completed, so the connect budget is the one "
         "that ran out: "
      << r.errorMessage;
  EXPECT_EQ(r.statusCode, 0);
}
#endif  // _WIN32

TEST_F(EngineTest, ATotalRequestTimeoutIsClassifiedAsSuch) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/slow/1500");
  pending.req.options.requestTimeoutMs = 400;
  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_TIMEOUT_REQUEST) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 0);
}

TEST_F(EngineTest, AStalledTransferIsAnIdleTimeout) {
  // No request budget at all: with one configured, a budget that expires first
  // is deliberately reported as `timeoutRequest`, and this case is about the
  // OTHER classification — connected, answered, then went quiet.
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.idleTimeoutMs = 400;
  config.requestTimeoutMs = 0;

  CurlEngine engine(1);
  engine.configure(config);

  PendingRequest pending = request(1, "/stall/4000");
  ASSERT_EQ(pending.req.options.requestTimeoutMs, -1) << "inherit, and the "
      "client has no budget either";
  const double startedAt = monotonicMs();
  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_TIMEOUT_IDLE)
      << "the transfer started and then stopped making progress, which is a "
         "different failure from never finishing in time: "
      << r.errorMessage;
  // Sub-second budgets have to be honoured as written. The previous
  // implementation mapped this onto `CURLOPT_LOW_SPEED_TIME`, whose unit is
  // whole seconds, so a 400 ms budget silently became 1000 ms.
  EXPECT_LT(monotonicMs() - startedAt, 2000.0)
      << "a 400 ms idle budget must not be rounded up to seconds";
}

TEST_F(EngineTest, AStallBetweenLargeChunksIsStillAnIdleTimeout) {
  // The regression that a rate floor cannot catch. `/drip` delivers 16 KiB and
  // then says nothing for three seconds: the transfer's average rate is still
  // kilobytes per second, so `CURLOPT_LOW_SPEED_LIMIT 1` never fires and the
  // whole body arrives — which is not what "abort a transfer that moves no
  // bytes for 400 ms" means.
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.idleTimeoutMs = 400;
  config.requestTimeoutMs = 0;

  CurlEngine engine(1);
  engine.configure(config);

  const double startedAt = monotonicMs();
  const RawResponse r = sendBuffered(engine, request(1, "/drip/3/16384/3000"));
  const double elapsed = monotonicMs() - startedAt;

  EXPECT_EQ(r.errorKind, RAWERRORKIND_TIMEOUT_IDLE) << r.errorMessage;
  EXPECT_LT(elapsed, 2500.0)
      << "the stall must be caught during the first gap, not after the body "
         "finished: " << elapsed << " ms";
  EXPECT_LT(r.body.size(), 3u * 16384u)
      << "the transfer was aborted, so it cannot have delivered every chunk";
}

TEST_F(EngineTest, ASlowButMovingTransferSurvivesTheIdleDeadline) {
  // The other half of the contract: a body that keeps arriving is not idle,
  // however long it takes in total. Three chunks 200 ms apart under a 600 ms
  // budget must complete, or the deadline is measuring the wrong thing.
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.idleTimeoutMs = 600;
  config.requestTimeoutMs = 0;

  CurlEngine engine(1);
  engine.configure(config);

  const RawResponse r = sendBuffered(engine, request(1, "/drip/3/4096/200"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.body.size(), 3u * 4096u);
}

TEST_F(EngineTest, ARequestBudgetThatExpiresFirstStaysTimeoutRequest) {
  // Both deadlines armed, and the budget is the one that fires. The transfer
  // did stall, but the honest answer is the deadline the caller set.
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.idleTimeoutMs = 30000;
  config.requestTimeoutMs = 500;

  CurlEngine engine(1);
  engine.configure(config);

  const RawResponse r = sendBuffered(engine, request(1, "/stall/4000"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_TIMEOUT_REQUEST) << r.errorMessage;
}

// ─── File upload ─────────────────────────────────────────────────────────────

TEST_F(EngineTest, AFileBodyIsReadStraightFromDiskByCurl) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  std::string contents;
  contents.reserve(300 * 1024);
  for (size_t i = 0; i < 300 * 1024; ++i) {
    contents.push_back(static_cast<char>((i * 29 + 11) & 0xff));
  }
  const fs::path path = writeTempFile("upload.bin", contents);

  PendingRequest pending = request(1, "/upload");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_FILE_PATH;
  pending.req.bodyFilePath = path.string();
  // Deliberately no inline body: a match on the hash proves curl read the file.
  const RawResponse r = sendBuffered(engine, std::move(pending));

  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_TRUE(contains(bodyOf(r), "\"bytes\":" + std::to_string(contents.size())))
      << bodyOf(r);
  EXPECT_TRUE(
      contains(bodyOf(r), hexSha256(contents.data(), contents.size())))
      << bodyOf(r);
}

TEST_F(EngineTest, AMissingBodyFileFailsBeforeTheNetwork) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/upload");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_FILE_PATH;
  pending.req.bodyFilePath = (tempRoot_ / "does-not-exist.bin").string();

  const RawResponse r = sendBuffered(engine, std::move(pending));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_IO) << r.errorMessage;
  EXPECT_EQ(server_.requestCount("/upload"), 0);
}

// ─── Streamed downloads ──────────────────────────────────────────────────────

TEST_F(EngineTest, StreamedModePostsOneHeadThenChunksThenOneTerminal) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  constexpr size_t kTotal = 1048576;
  PendingRequest pending = request(1, "/bytes/1048576", RespMode::Streamed);
  engine.submit(std::move(pending));
  // The runner grants its initial window right after starting the stream.
  engine.grantCredit(1, 100000, 0);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  ASSERT_TRUE(waitFor([] {
    CapturedChunk terminal;
    return terminalChunk(1, &terminal);
  })) << "the stream never terminated";

  const std::vector<RawResponseHead> heads = Captures::instance().heads();
  ASSERT_EQ(heads.size(), 1u) << "exactly one RawResponseHead post";
  EXPECT_EQ(heads[0].requestId, 1);
  EXPECT_EQ(heads[0].errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(heads[0].statusCode, 200);
  EXPECT_EQ(heads[0].contentLength, static_cast<int64_t>(kTotal));
  EXPECT_EQ(heads[0].primaryIp, "127.0.0.1");

  CapturedChunk terminal;
  ASSERT_TRUE(terminalChunk(1, &terminal));
  EXPECT_EQ(terminal.kind, RAWCHUNKKIND_DONE);
  EXPECT_EQ(terminal.aux, 0);

  EXPECT_GT(dataChunkCount(1), 1u) << "a 1 MiB body arrives in several writes";
  const std::vector<uint8_t> payload = concatenatedPayload(1);
  ASSERT_EQ(payload.size(), kTotal);
  EXPECT_EQ(hexSha256(payload.data(), payload.size()),
            HttpTestServer::bytesSha256(kTotal));
}

TEST_F(EngineTest, StreamedHeadReportsContentLengthOnlyWhenItDescribesTheBytes) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  engine.submit(request(1, "/bytes/65536", RespMode::Streamed));
  engine.grantCredit(1, 100000, 0);
  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(1, &t);
  }));
  ASSERT_EQ(Captures::instance().heads().size(), 1u);
  EXPECT_EQ(Captures::instance().heads()[0].contentLength, 65536)
      << "an identity body's Content-Length describes exactly the bytes Dart "
         "will receive";

  Captures::instance().clear();
  engine.submit(request(2, "/gzip", RespMode::Streamed));
  engine.grantCredit(2, 100000, 0);
  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(2, &t);
  }));
  ASSERT_EQ(Captures::instance().heads().size(), 1u);
  const RawResponseHead gzipHead = Captures::instance().heads()[0];
  EXPECT_EQ(gzipHead.contentLength, -1)
      << "the header describes the ENCODED length while the engine hands Dart "
         "the decoded bytes, so the honest answer is 'unknown'";
  EXPECT_EQ(findHeader(gzipHead.headers, "Content-Encoding"), nullptr)
      << "a decoded body must not carry the header that says it is encoded";
  EXPECT_EQ(findHeader(gzipHead.headers, "Content-Length"), nullptr);
  const std::vector<uint8_t> payload = concatenatedPayload(2);
  EXPECT_EQ(std::string(payload.begin(), payload.end()),
            HttpTestServer::gzipPlainText());
  EXPECT_NE(payload.size(), 0u);
}

TEST_F(EngineTest, ALargeStreamedBodyIsCoalescedIntoFewerChunks) {
  // A bulk download batches write callbacks into 64 KiB chunks rather than
  // emitting curl's 16 KiB buffer straight through. Measured on a 32 MiB body,
  // each emit costs 4.81 us in chunk struct, zero-copy proxy, credit and
  // `controller.add`, which is 9.9 ms — 7.4 % of the transfer.
  //
  // The bytes must be identical either way; batching that loses or reorders a
  // block would corrupt a download rather than slow it.
  constexpr int64_t kBody = 4 * 1024 * 1024;
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  engine.submit(request(1, "/bytes/" + std::to_string(kBody),
                        RespMode::Streamed));
  engine.grantCredit(1, 100000, 0);
  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(1, &t);
  }));

  const std::vector<uint8_t> payload = concatenatedPayload(1);
  ASSERT_EQ(static_cast<int64_t>(payload.size()), kBody)
      << "coalescing must not drop or duplicate a byte";

  // Count only the data chunks; the terminal one carries no body.
  size_t dataChunks = 0;
  for (const auto& c : Captures::instance().chunks()) {
    if (c.requestId == 1 && c.kind == RAWCHUNKKIND_DATA) ++dataChunks;
  }
  // 4 MiB at curl's 16 KiB buffer is ~256 callbacks; at 64 KiB it is ~64.
  const size_t uncoalesced = static_cast<size_t>(kBody) / (16 * 1024);
  EXPECT_LT(dataChunks, uncoalesced / 2)
      << "expected roughly " << (uncoalesced / 4) << " chunks, got "
      << dataChunks << "; coalescing is not engaging";
}

TEST_F(EngineTest, ASmallStreamedBodyIsNotHeldBackForCoalescing) {
  // The batching threshold exists so a trickling response — server-sent events,
  // a long poll — never has its bytes held waiting for more that may be seconds
  // away. Anything without a large declared length keeps emitting immediately.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  engine.submit(request(1, "/bytes/65536", RespMode::Streamed));
  engine.grantCredit(1, 100000, 0);
  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(1, &t);
  }));

  EXPECT_EQ(concatenatedPayload(1).size(), 65536u);

  size_t dataChunks = 0;
  for (const auto& c : Captures::instance().chunks()) {
    if (c.requestId == 1 && c.kind == RAWCHUNKKIND_DATA) ++dataChunks;
  }
  // 64 KiB would be a single chunk if it were coalesced; curl's own buffering
  // gives several. More than one proves the body was not held back.
  EXPECT_GT(dataChunks, 1u)
      << "a body below the coalescing threshold must stream as it arrives";
}

TEST_F(EngineTest, ACreditThrottledStreamStillCachesTheBodyByteForByte) {
  // curl re-delivers a paused block to WRITEFUNCTION after the unpause. Teeing
  // to the cache before the pause check therefore writes every paused block
  // twice, which shows up as a corrupt entry and not as a failed transfer.
  RawCacheConfig cacheConfig{};
  cacheConfig.enabled = true;
  cacheConfig.directory = tempRoot_.string();
  std::shared_ptr<HttpCache> cache = HttpCache::open(cacheConfig);
  ASSERT_NE(cache, nullptr);

  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.enableCache = true;

  CurlEngine engine(1);
  engine.configure(config);
  engine.setCache(cache);

  constexpr size_t kTotal = 262144;
  const std::string path = "/cachedbytes/600/262144";
  engine.submit(request(1, path, RespMode::Streamed));

  // A window of two, refilled only once the previous two have arrived, so the
  // transfer genuinely pauses and resumes many times over.
  int64_t granted = 2;
  engine.grantCredit(1, 2, 0);
  ASSERT_TRUE(waitFor(
      [&engine, &granted] {
        CapturedChunk terminal;
        if (terminalChunk(1, &terminal)) return true;
        if (dataChunkCount(1) >= static_cast<size_t>(granted)) {
          engine.grantCredit(1, 2, 0);
          granted += 2;
        }
        return false;
      },
      30000))
      << "the throttled stream never terminated";

  CapturedChunk terminal;
  ASSERT_TRUE(terminalChunk(1, &terminal));
  ASSERT_EQ(terminal.kind, RAWCHUNKKIND_DONE);
  EXPECT_GT(granted, 4) << "the window must actually have been refilled";

  const std::vector<uint8_t> streamed = concatenatedPayload(1);
  const std::vector<uint8_t> expected = HttpTestServer::lcgBytes(kTotal);
  ASSERT_EQ(streamed.size(), kTotal) << "the stream itself was not duplicated";
  EXPECT_EQ(streamed, expected);

  // Read the stored entry back without touching the network: `onlyIfCached`
  // fails outright rather than silently re-fetching, so a pass here is proof
  // the entry exists and is what it should be.
  const int before = server_.requestCount(path);
  PendingRequest replay = request(2, path);
  replay.req.options.cacheMode = RAWCACHEMODE_ONLY_IF_CACHED;
  const RawResponse cached = sendBuffered(engine, std::move(replay));

  ASSERT_EQ(cached.errorKind, RAWERRORKIND_NONE) << cached.errorMessage;
  EXPECT_TRUE(cached.fromCache);
  EXPECT_EQ(server_.requestCount(path), before)
      << "onlyIfCached must never reach the network";
  ASSERT_EQ(cached.body.size(), kTotal)
      << "a duplicated paused block would show up as a longer entry";
  EXPECT_EQ(cached.body, expected);
}

TEST_F(EngineTest, CreditBackpressureCapsChunksAtTheGrantedWindow) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  // 64 chunks of 16 KiB, flushed individually: far more writes than the four
  // credits granted below.
  engine.submit(request(1, "/chunked/64/16384", RespMode::Streamed));
  engine.grantCredit(1, 4, 0);

  ASSERT_TRUE(Captures::instance().waitForPosts(1)) << "no head posted";
  ASSERT_TRUE(waitFor([] { return dataChunkCount(1) >= 4; }))
      << "the granted window never filled";

  // Hold still and prove nothing more arrives. The transfer is paused, not
  // merely slow, so this window can be generous without being flaky.
  std::this_thread::sleep_for(std::chrono::milliseconds(600));
  EXPECT_EQ(dataChunkCount(1), 4u)
      << "native emitted past its credit: the whole point of the protocol is "
         "that it does not";
  CapturedChunk terminal;
  EXPECT_FALSE(terminalChunk(1, &terminal))
      << "a paused transfer has not finished";

  // Release the brake; the rest must follow.
  engine.grantCredit(1, 100000, 0);
  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(1, &t);
  })) << "the stream did not resume after more credit";

  ASSERT_TRUE(terminalChunk(1, &terminal));
  EXPECT_EQ(terminal.kind, RAWCHUNKKIND_DONE);
  const std::vector<uint8_t> payload = concatenatedPayload(1);
  const std::vector<uint8_t> expected = HttpTestServer::chunkedBody(64, 16384);
  EXPECT_EQ(payload, expected);
}

TEST_F(EngineTest, DeferredPayloadsAreFreedOnlyByTheTerminalGrant) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  engine.submit(request(1, "/chunked/16/16384", RespMode::Streamed));
  // Credit without acknowledgement: Dart has been handed the chunks but has
  // told native nothing about copying them, so every payload stays alive.
  engine.grantCredit(1, 100000, 0);

  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(1, &t);
  })) << "the stream never terminated";

  DeferredPayloads& deferred = DeferredPayloads::instance();
  ASSERT_TRUE(waitFor([&deferred] { return deferred.liveBytes() > 0; }))
      << "a retiring task must hand its unacked payloads to the registry, not "
         "free them: Dart may not have copied them yet";
  EXPECT_EQ(deferred.bucketCount(), 1u);

  // Still alive: an ordinary grant is not the terminal one.
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  EXPECT_GT(deferred.liveBytes(), 0u);

  // `grantCredit(id, 0, acked)` is the runner saying it has stopped reading.
  const int64_t received = static_cast<int64_t>(dataChunkCount(1)) + 1;
  engine.grantCredit(1, 0, received);
  EXPECT_TRUE(waitFor([&deferred] { return deferred.liveBytes() == 0; }))
      << "the terminal grant must release the bucket";
  EXPECT_EQ(deferred.bucketCount(), 0u);
}

// ─── Cancellation ────────────────────────────────────────────────────────────

TEST_F(EngineTest, CancelBeforeSubmitStillCompletesExactlyOnce) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  // The cancel overtakes its own submit — a real race when Dart cancels in the
  // same microtask that started the request.
  engine.cancel(1);
  engine.submit(request(1, "/slow/2000"));

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u);
  EXPECT_EQ(all[0].requestId, 1);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_CANCELLED);
  EXPECT_EQ(server_.requestCount("/slow/2000"), 0)
      << "a pre-cancelled request must never reach the network";
}

TEST_F(EngineTest, CancelImmediatelyAfterSubmitCompletesExactlyOnce) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  engine.submit(request(1, "/slow/2000"));
  engine.cancel(1);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u) << "exactly one post, whichever side won the race";
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_CANCELLED);
}

TEST_F(EngineTest, CancelMidTransferCompletesExactlyOnce) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  // 128 MiB, flushed 16 KiB at a time. Big enough that the transfer is still
  // running when the cancel lands, so this exercises the mid-flight abort
  // rather than racing a completed request. The stream is effectively
  // unbounded (~1.5 TB) on purpose: a CI loopback can move a finite body
  // faster than a cancel op reaches the loop thread, and the DONE terminal
  // then legitimately beats the cancel — which is a timing artefact, not the
  // behaviour under test. Cancelling disconnects, which stops the server's
  // content provider, so only the first few chunks ever transfer.
  const std::string path = "/chunked/100000000/16384";
  engine.submit(request(1, path));
  ASSERT_TRUE(waitFor([this, &path] { return server_.requestCount(path) == 1; }))
      << "the transfer never started";
  engine.cancel(1);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_CANCELLED);
  EXPECT_TRUE(all[0].body.empty())
      << "a cancelled buffered request delivers no partial body";
}

TEST_F(EngineTest, CancellingAStreamedTransferEmitsOneTerminalErrorChunk) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  engine.submit(request(1, "/chunked/100000000/16384", RespMode::Streamed));
  engine.grantCredit(1, 100000, 0);
  ASSERT_TRUE(waitFor([] { return dataChunkCount(1) >= 2; }))
      << "the stream never started";
  engine.cancel(1);

  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(1, &t);
  }));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));

  CapturedChunk terminal;
  ASSERT_TRUE(terminalChunk(1, &terminal));
  EXPECT_EQ(terminal.kind, RAWCHUNKKIND_ERROR);
  EXPECT_EQ(terminal.aux, static_cast<int64_t>(RAWERRORKIND_CANCELLED));
  EXPECT_EQ(Captures::instance().posts().size(), 1u)
      << "the head is the one and only post a streamed request makes";
}

TEST_F(EngineTest, CancelAllCompletesEveryInFlightRequestExactlyOnce) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  for (int64_t id = 1; id <= 4; ++id) {
    engine.submit(request(id, "/chunked/100000000/16384"));
  }
  ASSERT_TRUE(
      waitFor([this] { return server_.requestCount("/chunked/100000000/16384") >= 1; }));
  engine.cancelAll();

  ASSERT_TRUE(Captures::instance().waitForPosts(4));
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 4u) << "one post each, no more and no fewer";

  std::vector<int64_t> ids;
  for (const RawResponse& r : all) {
    EXPECT_EQ(r.errorKind, RAWERRORKIND_CANCELLED);
    ids.push_back(r.requestId);
  }
  std::sort(ids.begin(), ids.end());
  EXPECT_EQ(ids, (std::vector<int64_t>{1, 2, 3, 4}));
}

// ─── Cancellation tokens ─────────────────────────────────────────────────────
//
// A token is shared state behind an integer id, so it buys two things the
// per-request `cancel(id)` path cannot: a request submitted after the token was
// cancelled is refused before it opens a socket, and one store cancels every
// bound transfer at once. Both are asserted against the server's own request
// counter rather than against timing.

namespace {

/// A request bound to `tokenId`. Everything else matches `request()`.
PendingRequest tokenRequest(PendingRequest pending, int64_t tokenId) {
  pending.req.options.cancelTokenId = tokenId;
  return pending;
}

}  // namespace

TEST_F(EngineTest, ATokenCancelledBeforeSubmitNeverOpensASocket) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  // Cancelled while nothing is bound to it — the pre-emptive case. Unlike the
  // `preCancelled_` list this has no ordering window and no bound to overflow.
  nitrohttp::CancelRegistry::instance().cancel(7001, "gone before we started");
  engine.submit(tokenRequest(request(1, "/slow/2000"), 7001));

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_CANCELLED);
  EXPECT_EQ(server_.requestCount("/slow/2000"), 0)
      << "a request bound to an already-cancelled token must never reach the "
         "network";
  EXPECT_NE(all[0].errorMessage.find("gone before we started"),
            std::string::npos)
      << "the token's reason must survive into the error: " << all[0].errorMessage;
}

TEST_F(EngineTest, ATokenCancelledLongBeforeTheSubmitStillRefusesIt) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  nitrohttp::CancelRegistry::instance().cancel(7002, "");
  // A gap the bounded pre-cancel list could not survive if 1024 other ids were
  // cancelled in between; the token carries its own state, so elapsed time and
  // intervening traffic are irrelevant.
  for (int64_t noise = 9000; noise < 9200; ++noise) {
    nitrohttp::CancelRegistry::instance().cancel(noise, "");
  }
  engine.submit(tokenRequest(request(1, "/slow/2000"), 7002));

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_CANCELLED);
  EXPECT_EQ(server_.requestCount("/slow/2000"), 0);
}

TEST_F(EngineTest, OneTokenCancelsEveryBoundTransferExactlyOnce) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const std::string path = "/chunked/100000000/16384";
  for (int64_t id = 1; id <= 4; ++id) {
    engine.submit(tokenRequest(request(id, path), 7003));
  }
  ASSERT_TRUE(waitFor([this, &path] { return server_.requestCount(path) >= 1; }))
      << "no transfer ever started";

  // One store, then one sweep — the whole point. No per-request bookkeeping.
  nitrohttp::CancelRegistry::instance().cancel(7003, "bulk abort");
  engine.cancelToken(7003);

  ASSERT_TRUE(Captures::instance().waitForPosts(4));
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 4u) << "one post each, no more and no fewer";

  std::vector<int64_t> ids;
  for (const RawResponse& r : all) {
    EXPECT_EQ(r.errorKind, RAWERRORKIND_CANCELLED);
    EXPECT_NE(r.errorMessage.find("bulk abort"), std::string::npos);
    ids.push_back(r.requestId);
  }
  std::sort(ids.begin(), ids.end());
  EXPECT_EQ(ids, (std::vector<int64_t>{1, 2, 3, 4}));
}

TEST_F(EngineTest, ATokenCancelLeavesTransfersOnOtherTokensAlone) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const std::string slow = "/chunked/100000000/16384";
  engine.submit(tokenRequest(request(1, slow), 7004));
  engine.submit(tokenRequest(request(2, slow), 7005));
  ASSERT_TRUE(waitFor([this, &slow] { return server_.requestCount(slow) >= 1; }));

  nitrohttp::CancelRegistry::instance().cancel(7004, "only mine");
  engine.cancelToken(7004);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(250));
  std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u) << "the untouched token's transfer was also killed";
  EXPECT_EQ(all[0].requestId, 1);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_CANCELLED);

  // And the survivor is still cancellable on its own terms.
  nitrohttp::CancelRegistry::instance().cancel(7005, "");
  engine.cancelToken(7005);
  ASSERT_TRUE(Captures::instance().waitForPosts(2));
  all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 2u);
  EXPECT_EQ(all[1].requestId, 2);
  EXPECT_EQ(all[1].errorKind, RAWERRORKIND_CANCELLED);
}

TEST_F(EngineTest, ReleasingATokenMidTransferDoesNotStrandTheTransfer) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const std::string path = "/chunked/100000000/16384";
  engine.submit(tokenRequest(request(1, path), 7006));
  ASSERT_TRUE(waitFor([this, &path] { return server_.requestCount(path) >= 1; }));

  // Dart's finalizer can run at any moment, including while a transfer bound to
  // the token is live. The task holds its own shared_ptr, so this drops only the
  // registry's reference — cancelling afterwards must still work through the
  // reference the task kept.
  nitrohttp::CancelRegistry::instance().release(7006);
  nitrohttp::CancelRegistry::instance().cancel(7006, "after release");
  engine.cancelToken(7006);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_CANCELLED);
  // The reason came from a NEW state — the released one is unreachable — which
  // is exactly why the transfer must not have been resurrected or double-posted.
  EXPECT_EQ(all[0].requestId, 1);
}

TEST_F(EngineTest, CancellingATokenNothingIsBoundToIsHarmless) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  nitrohttp::CancelRegistry::instance().cancel(7007, "nobody home");
  engine.cancelToken(7007);
  // Also exercises the id-zero guard, which every entry point takes.
  engine.cancelToken(0);

  // An unrelated request still completes normally afterwards.
  const RawResponse r = sendBuffered(engine, request(1, "/echo"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.statusCode, 200);
}

TEST_F(EngineTest, AnUnboundRequestIgnoresTokenCancellationEntirely) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  nitrohttp::CancelRegistry::instance().cancel(7008, "not yours");
  engine.cancelToken(7008);

  // cancelTokenId stays 0, so none of the above may touch it.
  const RawResponse r = sendBuffered(engine, request(1, "/echo"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.statusCode, 200);
}

TEST(CancelRegistryTest, KeepsTheFirstReasonAndIsIdempotent) {
  nitrohttp::CancelRegistry& registry = nitrohttp::CancelRegistry::instance();
  registry.cancel(7100, "first");
  registry.cancel(7100, "second");

  const std::shared_ptr<nitrohttp::CancelState> state = registry.lookup(7100);
  ASSERT_NE(state, nullptr);
  EXPECT_TRUE(state->cancelled());
  EXPECT_EQ(state->reason(), "first")
      << "a later cancel must not rewrite the diagnosis already being reported";
  registry.release(7100);
}

TEST(CancelRegistryTest, ObtainCreatesLookupDoesNotAndZeroIsNoToken) {
  nitrohttp::CancelRegistry& registry = nitrohttp::CancelRegistry::instance();

  EXPECT_EQ(registry.lookup(7101), nullptr) << "lookup must not create";
  const std::shared_ptr<nitrohttp::CancelState> created = registry.obtain(7101);
  ASSERT_NE(created, nullptr);
  EXPECT_FALSE(created->cancelled());
  EXPECT_EQ(registry.obtain(7101), created) << "one state per id";
  EXPECT_EQ(registry.lookup(7101), created);

  // Zero is the "no token" sentinel and must never allocate.
  EXPECT_EQ(registry.obtain(0), nullptr);
  EXPECT_EQ(registry.lookup(0), nullptr);

  registry.release(7101);
  EXPECT_EQ(registry.lookup(7101), nullptr);
  EXPECT_FALSE(created->cancelled())
      << "release drops the registry's reference, it does not cancel";
}

TEST(CancelRegistryTest, ClearForgetsEveryTokenSoAReusedIdIsNotPoisoned) {
  nitrohttp::CancelRegistry& registry = nitrohttp::CancelRegistry::instance();
  registry.cancel(7200, "before the hot restart");
  registry.cancel(7201, "before the hot restart");
  ASSERT_TRUE(registry.lookup(7200)->cancelled());

  // What `resetNative` does. The Dart isolate that minted those ids is gone, so
  // every entry now describes a token nothing can refer to — and the next
  // incarnation starts allocating ids again from its own counter.
  registry.clear();

  EXPECT_EQ(registry.lookup(7200), nullptr);
  EXPECT_EQ(registry.lookup(7201), nullptr);
  EXPECT_EQ(registry.size(), 0u);

  // The id coming back must be a clean slate. If it were not, the first request
  // the reloaded app binds to it would be refused before it opened a socket,
  // reported as a cancellation the caller never requested.
  const std::shared_ptr<nitrohttp::CancelState> reborn = registry.obtain(7200);
  ASSERT_NE(reborn, nullptr);
  EXPECT_FALSE(reborn->cancelled());
  EXPECT_TRUE(reborn->reason().empty());
  registry.release(7200);
}

TEST_F(EngineTest, AResetClearsCancellationStateSoAReusedIdStillTransfers) {
  nitrohttp::CancelRegistry::instance().cancel(7300, "previous incarnation");

  // The reset a fresh Dart incarnation performs on first touch.
  nitrohttp::EngineRegistry::resetAll();

  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());
  const RawResponse r =
      sendBuffered(engine, tokenRequest(request(1, "/echo"), 7300));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE)
      << "a token id reused after a reset must not inherit the old flag: "
      << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
}

TEST(CancelRegistryTest, AReleasedIdComesBackAsAFreshState) {
  nitrohttp::CancelRegistry& registry = nitrohttp::CancelRegistry::instance();
  registry.cancel(7102, "old");
  const std::shared_ptr<nitrohttp::CancelState> old = registry.lookup(7102);
  ASSERT_NE(old, nullptr);
  registry.release(7102);

  // Dart ids are monotonic so this cannot happen in practice, but a stale flag
  // leaking into a reused id would silently kill an unrelated request.
  const std::shared_ptr<nitrohttp::CancelState> fresh = registry.obtain(7102);
  ASSERT_NE(fresh, nullptr);
  EXPECT_NE(fresh, old);
  EXPECT_FALSE(fresh->cancelled());
  EXPECT_TRUE(old->cancelled()) << "the old state stays valid for its holders";
  registry.release(7102);
}

TEST_F(EngineTest, ShutdownCompletesEveryInFlightRequestWithEngineError) {
  {
    CurlEngine engine(1);
    engine.configure(nitrohttp::test::defaultClientConfig());
    for (int64_t id = 1; id <= 3; ++id) {
      engine.submit(request(id, "/chunked/100000000/16384"));
    }
    ASSERT_TRUE(waitFor(
        [this] { return server_.requestCount("/chunked/100000000/16384") >= 1; }));

    engine.shutdown();  // must not hang
    engine.shutdown();  // idempotent
  }  // the destructor must not hang either

  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 3u);
  for (const RawResponse& r : all) {
    EXPECT_EQ(r.errorKind, RAWERRORKIND_ENGINE_ERROR) << r.errorMessage;
  }
}

TEST_F(EngineTest, SubmittingAfterShutdownStillCompletes) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());
  engine.shutdown();

  engine.submit(request(7, "/echo"));
  ASSERT_TRUE(Captures::instance().waitForPosts(1))
      << "a disposal race must not hang the caller's Future";
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u);
  EXPECT_EQ(all[0].requestId, 7);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_ENGINE_ERROR);
}

// ─── Streamed uploads ────────────────────────────────────────────────────────

TEST_F(EngineTest, AStreamedUploadArrivesIntact) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  std::string payload;
  payload.reserve(256 * 1024);
  for (size_t i = 0; i < 256 * 1024; ++i) {
    payload.push_back(static_cast<char>((i * 13 + 7) & 0xff));
  }

  PendingRequest pending = request(1, "/upload");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_STREAMED;
  pending.req.headers = {hdr("Content-Type", "application/octet-stream")};
  engine.submit(std::move(pending));

  constexpr size_t kBlock = 16 * 1024;
  for (size_t offset = 0; offset < payload.size(); offset += kBlock) {
    const size_t n = std::min(kBlock, payload.size() - offset);
    engine.feedUpload(1, reinterpret_cast<const uint8_t*>(payload.data() + offset),
                      n);
  }
  engine.finishUpload(1);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  const RawResponse r = Captures::instance().responses().back();
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_TRUE(contains(bodyOf(r), "\"bytes\":" + std::to_string(payload.size())))
      << bodyOf(r);
  EXPECT_TRUE(contains(bodyOf(r), hexSha256(payload.data(), payload.size())))
      << bodyOf(r);
}

TEST_F(EngineTest, BytesFedInTheSameBreathAsSubmitAreNotDropped) {
  // `feedUpload` can land between the inbox pop and the task's registration in
  // `tasks_`, where there is neither a queued submit to park the bytes on nor a
  // pipe to push them into. A runner that starts pumping in the same microtask
  // as `startStreamed` hits that window every time, and the symptom is a
  // silently truncated body rather than an error.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  std::string payload;
  payload.reserve(64 * 1024);
  for (size_t i = 0; i < 64 * 1024; ++i) {
    payload.push_back(static_cast<char>((i * 37 + 19) & 0xff));
  }

  PendingRequest pending = request(1, "/upload");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_STREAMED;
  pending.req.headers = {hdr("Content-Type", "application/octet-stream")};

  engine.submit(std::move(pending));
  // No wait, no sleep: this is the race.
  engine.feedUpload(1, reinterpret_cast<const uint8_t*>(payload.data()),
                    payload.size());
  engine.finishUpload(1);

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  const RawResponse r = Captures::instance().responses().back();
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_TRUE(contains(bodyOf(r), "\"bytes\":" + std::to_string(payload.size())))
      << "the server received a different number of bytes: " << bodyOf(r);
  EXPECT_TRUE(contains(bodyOf(r), hexSha256(payload.data(), payload.size())))
      << bodyOf(r);
}

TEST_F(EngineTest, AFailedUploadIsAFailureNotATruncatedSuccess) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const std::string head(64 * 1024, 'A');

  PendingRequest pending = request(1, "/upload");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_STREAMED;
  pending.req.options.uploadContentLength = 1024 * 1024;  // promises far more
  pending.req.headers = {hdr("Content-Type", "application/octet-stream")};
  engine.submit(std::move(pending));

  engine.feedUpload(1, reinterpret_cast<const uint8_t*>(head.data()),
                    head.size());
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  engine.failUpload(1, "source stream errored");

  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  const std::vector<RawResponse> all = Captures::instance().responses();
  ASSERT_EQ(all.size(), 1u);
  EXPECT_EQ(all[0].errorKind, RAWERRORKIND_SEND_FAILURE)
      << "a half-sent body must surface as a failure: "
      << static_cast<int>(all[0].errorKind) << " " << all[0].errorMessage;
  EXPECT_EQ(all[0].errorMessage, "source stream errored");
  EXPECT_EQ(all[0].statusCode, 0);
}

// ─── Cookies ─────────────────────────────────────────────────────────────────

TEST_F(EngineTest, CookiesAreStoredAndReplayedOnTheSameEngine) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse set = sendBuffered(engine, request(1, "/setcookie"));
  ASSERT_EQ(set.errorKind, RAWERRORKIND_NONE);

  const RawResponse read = sendBuffered(engine, request(2, "/readcookie"));
  ASSERT_EQ(read.errorKind, RAWERRORKIND_NONE);
  EXPECT_TRUE(contains(bodyOf(read), "nh_test=abc123"))
      << "the jar did not replay the cookie: '" << bodyOf(read) << "'";

  const std::vector<RawCookie> jar = engine.cookies();
  const auto found = std::find_if(
      jar.begin(), jar.end(),
      [](const RawCookie& c) { return c.name == "nh_test"; });
  ASSERT_NE(found, jar.end()) << "cookies() must list the stored cookie";
  EXPECT_EQ(found->value, "abc123");
  EXPECT_EQ(found->path, "/");
}

TEST_F(EngineTest, SetCookieInjectsACookieThatIsThenSent) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  RawCookie cookie{};
  cookie.name = "injected";
  cookie.value = "yes";
  cookie.domain = "127.0.0.1";
  cookie.path = "/";
  cookie.expiresEpochMs = 0;  // session cookie
  cookie.secure = false;
  cookie.httpOnly = false;
  engine.setCookie(cookie);

  const RawResponse read = sendBuffered(engine, request(1, "/readcookie"));
  ASSERT_EQ(read.errorKind, RAWERRORKIND_NONE);
  EXPECT_TRUE(contains(bodyOf(read), "injected=yes"))
      << "'" << bodyOf(read) << "'";
}

TEST_F(EngineTest, ClearCookiesEmptiesTheJar) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  ASSERT_EQ(sendBuffered(engine, request(1, "/setcookie")).errorKind,
            RAWERRORKIND_NONE);
  ASSERT_FALSE(engine.cookies().empty());

  engine.clearCookies();
  EXPECT_TRUE(engine.cookies().empty());

  const RawResponse read = sendBuffered(engine, request(2, "/readcookie"));
  EXPECT_FALSE(contains(bodyOf(read), "nh_test"))
      << "'" << bodyOf(read) << "'";
}

TEST_F(EngineTest, AJarPathPersistsCookiesAcrossEngines) {
  const std::string jarPath = (tempRoot_ / "cookies.txt").string();
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.cookies.enabled = true;
  config.cookies.persistPath = jarPath;

  {
    CurlEngine first(1);
    first.configure(config);
    ASSERT_EQ(sendBuffered(first, request(1, "/setcookie")).errorKind,
              RAWERRORKIND_NONE);
    first.flushCookies();
    first.shutdown();  // curl writes the jar during cleanup
  }
  ASSERT_TRUE(fs::exists(jarPath)) << "no jar was written to " << jarPath;

  Captures::instance().clear();
  CurlEngine second(2);
  second.configure(config);

  // Reading the jar must not require a transfer first: an app that lists
  // cookies at startup, before it has made a single request, is the normal
  // case for a session-restore screen.
  const std::vector<RawCookie> jar = second.cookies();
  const auto persisted = std::find_if(
      jar.begin(), jar.end(),
      [](const RawCookie& c) { return c.name == "nh_persist"; });
  ASSERT_NE(persisted, jar.end()) << "the jar did not survive the restart";
  EXPECT_EQ(persisted->value, "lives");
  EXPECT_EQ(persisted->domain, "127.0.0.1");
  EXPECT_EQ(persisted->path, "/");
  EXPECT_GT(persisted->expiresEpochMs, wallClockMs())
      << "the expiry round-tripped through the Netscape format";

  const auto session = std::find_if(
      jar.begin(), jar.end(),
      [](const RawCookie& c) { return c.name == "nh_test"; });
  ASSERT_NE(session, jar.end());
  EXPECT_EQ(session->expiresEpochMs, 0)
      << "expiry 0 is how the Netscape format spells 'session cookie'";

  const RawResponse read = sendBuffered(second, request(2, "/readcookie"));
  EXPECT_TRUE(contains(bodyOf(read), "nh_persist=lives"))
      << "'" << bodyOf(read) << "'";
  EXPECT_TRUE(contains(bodyOf(read), "nh_test=abc123"))
      << "'" << bodyOf(read) << "'";
}

// ─── Cache ───────────────────────────────────────────────────────────────────

TEST_F(EngineTest, AFreshCacheHitSkipsTheNetworkEntirely) {
  RawCacheConfig cacheConfig{};
  cacheConfig.enabled = true;
  cacheConfig.directory = tempRoot_.string();
  cacheConfig.maxSizeBytes = 0;
  cacheConfig.maxEntryBytes = 0;
  std::shared_ptr<HttpCache> cache = HttpCache::open(cacheConfig);
  ASSERT_NE(cache, nullptr);

  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.enableCache = true;

  CurlEngine engine(1);
  engine.configure(config);
  engine.setCache(cache);

  const RawResponse first = sendBuffered(engine, request(1, "/cache/60"));
  ASSERT_EQ(first.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(first.statusCode, 200);
  EXPECT_FALSE(first.fromCache);
  EXPECT_EQ(server_.requestCount("/cache/60"), 1);

  const RawResponse second = sendBuffered(engine, request(2, "/cache/60"));
  ASSERT_EQ(second.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(second.statusCode, 200);
  EXPECT_TRUE(second.fromCache) << "the second read must come off the disk";
  EXPECT_FALSE(second.revalidated);
  EXPECT_EQ(bodyOf(second), bodyOf(first));
  EXPECT_EQ(server_.requestCount("/cache/60"), 1)
      << "a fresh entry must not touch the network at all";
}

TEST_F(EngineTest, AStaleEntryIsRevalidatedWithoutRefetchingTheBody) {
  RawCacheConfig cacheConfig{};
  cacheConfig.enabled = true;
  cacheConfig.directory = tempRoot_.string();
  std::shared_ptr<HttpCache> cache = HttpCache::open(cacheConfig);
  ASSERT_NE(cache, nullptr);

  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.enableCache = true;

  CurlEngine engine(1);
  engine.configure(config);
  engine.setCache(cache);

  // `max-age=0` plus an ETag is exactly the revalidate case.
  const RawResponse first = sendBuffered(engine, request(1, "/cache/0"));
  ASSERT_EQ(first.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(server_.requestCount("/cache/0"), 1);

  const RawResponse second = sendBuffered(engine, request(2, "/cache/0"));
  ASSERT_EQ(second.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(second.statusCode, 200)
      << "the caller sees the stored 200, never the bare 304";
  EXPECT_TRUE(second.fromCache);
  EXPECT_TRUE(second.revalidated);
  EXPECT_EQ(bodyOf(second), bodyOf(first)) << "the body was not re-downloaded";
  EXPECT_EQ(server_.requestCount("/cache/0"), 2)
      << "a conditional request did go out";
}

TEST_F(EngineTest, EachRequestMovesTheHitMissCountersExactlyOnce) {
  // `CacheStats.hitRate` is derived from `hitCount` and `missCount`, so any
  // request that moves either of them twice makes the published rate wrong, and
  // `revalidationCount` is documented as counting as neither. Two things used
  // to go wrong on the `/cache/0` reuse below: the stale lookup counted a miss,
  // and then `RequestTask::finish` re-read the entry after the 304 and counted
  // a SECOND one — for a request that was ultimately served from disk.
  RawCacheConfig cacheConfig{};
  cacheConfig.enabled = true;
  cacheConfig.directory = tempRoot_.string();
  std::shared_ptr<HttpCache> cache = HttpCache::open(cacheConfig);
  ASSERT_NE(cache, nullptr);

  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.enableCache = true;

  CurlEngine engine(1);
  engine.configure(config);
  engine.setCache(cache);

  ASSERT_EQ(sendBuffered(engine, request(1, "/cache/60")).errorKind,
            RAWERRORKIND_NONE);  // nothing stored: a real miss
  ASSERT_EQ(sendBuffered(engine, request(2, "/cache/60")).errorKind,
            RAWERRORKIND_NONE);  // fresh: a hit
  ASSERT_EQ(sendBuffered(engine, request(3, "/cache/0")).errorKind,
            RAWERRORKIND_NONE);  // nothing stored: a real miss
  const RawResponse revalidated = sendBuffered(engine, request(4, "/cache/0"));
  ASSERT_EQ(revalidated.errorKind, RAWERRORKIND_NONE);
  ASSERT_TRUE(revalidated.revalidated);  // neither a hit nor a miss

  const RawCacheStats stats = cache->stats();
  EXPECT_EQ(stats.missCount, 2)
      << "four requests, and only two of them found nothing usable";
  EXPECT_EQ(stats.hitCount, 1);
  EXPECT_EQ(stats.revalidationCount, 1);
}

TEST_F(EngineTest, AStreamedRevalidationReplaysTheStoredBodyAsChunks) {
  // The buffered path reads `CacheHit::body`; the streamed path replays
  // `CacheHit::bodyPath` from disk. They are populated by the same branch but
  // consumed by different code, so a fix that covers one can miss the other.
  RawCacheConfig cacheConfig{};
  cacheConfig.enabled = true;
  cacheConfig.directory = tempRoot_.string();
  std::shared_ptr<HttpCache> cache = HttpCache::open(cacheConfig);
  ASSERT_NE(cache, nullptr);

  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.enableCache = true;

  CurlEngine engine(1);
  engine.configure(config);
  engine.setCache(cache);

  const RawResponse first = sendBuffered(engine, request(1, "/cache/0"));
  ASSERT_EQ(first.errorKind, RAWERRORKIND_NONE);
  const std::string expected = bodyOf(first);
  ASSERT_FALSE(expected.empty());
  ASSERT_EQ(server_.requestCount("/cache/0"), 1);

  Captures::instance().clear();
  engine.submit(request(2, "/cache/0", RespMode::Streamed));
  engine.grantCredit(2, 100000, 0);
  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(2, &t);
  })) << "the replayed stream never terminated";

  const std::vector<RawResponseHead> heads = Captures::instance().heads();
  ASSERT_EQ(heads.size(), 1u) << "exactly one head, as on any streamed request";
  EXPECT_EQ(heads[0].requestId, 2);
  EXPECT_EQ(heads[0].errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(heads[0].statusCode, 200) << "not the bare 304";
  EXPECT_TRUE(heads[0].fromCache);

  CapturedChunk terminal;
  ASSERT_TRUE(terminalChunk(2, &terminal));
  EXPECT_EQ(terminal.kind, RAWCHUNKKIND_DONE);

  const std::vector<uint8_t> replayed = concatenatedPayload(2);
  EXPECT_EQ(std::string(replayed.begin(), replayed.end()), expected)
      << "the stored body must be replayed from disk, not re-downloaded";
  EXPECT_EQ(server_.requestCount("/cache/0"), 2)
      << "one conditional request, and no body on the wire";
}

// ─── Progress events ─────────────────────────────────────────────────────────

TEST_F(EngineTest, ProgressEventsAreMonotonicWhenRequested) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/bytes/1048576");
  pending.req.options.reportProgress = true;
  const RawResponse r = sendBuffered(engine, std::move(pending));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE);

  const std::vector<RawEvent> progress =
      eventsFor(1, RAWEVENTKIND_DOWNLOAD_PROGRESS);
  ASSERT_FALSE(progress.empty())
      << "reportProgress must produce at least the synthesised terminal event";
  for (size_t i = 1; i < progress.size(); ++i) {
    EXPECT_GE(progress[i].a, progress[i - 1].a)
        << "downloaded byte counts must never go backwards, at event " << i;
  }
  EXPECT_EQ(progress.back().a, 1048576)
      << "the last event must report the full body, not 98 %";
}

TEST_F(EngineTest, UploadProgressEventsAreEmittedAndMonotonic) {
  // `XFERINFOFUNCTION` is throttled to one event per 100 ms, and a body that
  // fits in the socket buffer is handed to the kernel inside a single curl turn
  // — so on loopback the callback may never observe a non-zero `ulNow` at all.
  // Without the terminal event synthesised from `CURLINFO_SIZE_UPLOAD_T`, a
  // caller with an `onSendProgress` sees NOTHING for a small upload, which is
  // how this went unnoticed: the download side has had that backstop all along.
  const size_t total = 512 * 1024;
  std::string payload;
  payload.reserve(total);
  for (size_t i = 0; i < total; ++i) {
    payload.push_back(static_cast<char>((i * 31 + 7) & 0xff));
  }

  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/upload");
  pending.req.method = RAWMETHOD_POST;
  pending.req.bodyKind = RAWBODYKIND_BYTES;
  // Explicit, because `CURLOPT_POSTFIELDS` otherwise defaults to
  // `application/x-www-form-urlencoded` and httplib answers 413 for a form body
  // over 8 KiB. Any real caller sends a content type anyway.
  pending.req.headers.push_back(hdr("Content-Type", "application/octet-stream"));
  pending.body.assign(payload.begin(), payload.end());
  pending.req.options.reportProgress = true;
  const RawResponse r = sendBuffered(engine, std::move(pending));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);

  const std::vector<RawEvent> sent = eventsFor(1, RAWEVENTKIND_UPLOAD_PROGRESS);
  ASSERT_FALSE(sent.empty())
      << "a request that uploaded a body must report at least one send-progress "
         "event";
  for (size_t i = 1; i < sent.size(); ++i) {
    EXPECT_GE(sent[i].a, sent[i - 1].a)
        << "uploaded byte counts must never go backwards, at event " << i;
  }
  EXPECT_EQ(sent.back().a, static_cast<int64_t>(total))
      << "the last event must report the whole body";
}

TEST_F(EngineTest, NoUploadProgressEventsForABodylessRequest) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/bytes/1024");
  pending.req.options.reportProgress = true;
  const RawResponse r = sendBuffered(engine, std::move(pending));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  // The terminal synthesis is gated on bytes having actually gone out, so a GET
  // must not fake a 0-byte upload event at somebody's `onSendProgress`.
  EXPECT_TRUE(eventsFor(1, RAWEVENTKIND_UPLOAD_PROGRESS).empty());
}

TEST_F(EngineTest, NoProgressEventsWhenNotRequested) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/bytes/262144"));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_TRUE(eventsFor(1, RAWEVENTKIND_DOWNLOAD_PROGRESS).empty())
      << "progress reporting costs an allocation per event and is opt-in";
}

// ─── A dead Dart port ────────────────────────────────────────────────────────

TEST_F(EngineTest, ADeadPortNeitherCrashesNorLeaks) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  // Hot restart: the isolate is gone while native threads keep running.
  Captures::instance().setPortAlive(false);
  engine.submit(request(1, "/bytes/262144"));
  ASSERT_TRUE(waitFor([this] { return server_.requestCount("/bytes/262144") == 1; }));
  // Let the transfer run to completion against the dead port. The post hook
  // frees the blob on this path, which is what a sanitizer run is checking.
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  EXPECT_TRUE(Captures::instance().posts().empty())
      << "a dead port records nothing";

  // The engine is still usable once the port comes back.
  Captures::instance().setPortAlive(true);
  const RawResponse r = sendBuffered(engine, request(2, "/echo"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.requestId, 2);
}

TEST_F(EngineTest, ADeadPortDoesNotStrandStreamedPayloads) {
  {
    CurlEngine engine(1);
    engine.configure(nitrohttp::test::defaultClientConfig());
    Captures::instance().setPortAlive(false);
    engine.submit(request(1, "/chunked/8/16384", RespMode::Streamed));
    engine.grantCredit(1, 100000, 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
  }
  Captures::instance().setPortAlive(true);

  // The registry still owns whatever the task could not free. `resetAll` on a
  // hot restart is what releases it, and it must not double-free.
  DeferredPayloads::instance().dropEverything();
  EXPECT_EQ(DeferredPayloads::instance().liveBytes(), 0u);
  EXPECT_EQ(DeferredPayloads::instance().bucketCount(), 0u);
}

// ─── Content coding ──────────────────────────────────────────────────────────
//
// Decoding belongs to the engine, not to libcurl. `CURLOPT_ACCEPT_ENCODING ""`
// used to make curl advertise whatever it was built with and kill the transfer
// with CURLE_BAD_CONTENT_ENCODING (61) on anything else — two behaviours the
// `package:http` conformance suite rejects, and a set that differed between a
// vendored Android slice and a macOS system curl.

TEST_F(EngineTest, TheRequestAdvertisesExactlyWhatTheEngineCanDecode) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/headers"));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;

  const std::string echoed = bodyOf(r);
  EXPECT_TRUE(contains(echoed, "Accept-Encoding: " + acceptEncodingHeader()))
      << "advertising more than we can inflate turns a compressed response "
         "into an opaque one:\n"
      << echoed;
  EXPECT_EQ(countOccurrences(echoed, "Accept-Encoding"), 1u) << echoed;
  // The conformance suite asserts this one server-side.
  EXPECT_TRUE(contains(acceptEncodingHeader(), "gzip"));
}

TEST_F(EngineTest, GzipIsDecodedAndItsHeadersAreDropped) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/gzip"));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_EQ(bodyOf(r), HttpTestServer::gzipPlainText())
      << "zlib is linked into every build we ship";

  // Both headers describe the ENCODED bytes, which nobody above the engine ever
  // sees. Leaving them makes Content-Length a lie about the body next to it.
  EXPECT_EQ(findHeader(r.headers, "Content-Encoding"), nullptr);
  EXPECT_EQ(findHeader(r.headers, "Content-Length"), nullptr);
  EXPECT_NE(findHeader(r.headers, "Content-Type"), nullptr)
      << "only the two headers that lie are removed";
}

TEST_F(EngineTest, AnUnknownCodingPassesThroughByteForByteWithItsHeaders) {
  // THE regression test. This exact response — `Content-Encoding: upper` over a
  // plaintext body — used to come back as decompressionFailure with CURLcode 61
  // and is what the conformance suite's 'upper' cases serve.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/encoding/upper"));
  ASSERT_EQ(r.errorKind, RAWERRORKIND_NONE)
      << "an unrecognised coding is not a transport failure: " << r.errorMessage
      << " (CURLcode " << r.engineErrorCode << ")";
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_EQ(bodyOf(r), HttpTestServer::upperPlainText());

  const RawHeader* encoding = findHeader(r.headers, "Content-Encoding");
  ASSERT_NE(encoding, nullptr)
      << "a passed-through body is still encoded; the caller needs to know how";
  EXPECT_EQ(encoding->value, "upper");

  const RawHeader* length = findHeader(r.headers, "Content-Length");
  ASSERT_NE(length, nullptr);
  EXPECT_EQ(length->value,
            std::to_string(HttpTestServer::upperPlainText().size()))
      << "for a pass-through the header describes exactly the bytes delivered";
}

TEST_F(EngineTest, AnUnknownCodingIsReportedOnAStreamedHeadToo) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  engine.submit(request(1, "/encoding/upper", RespMode::Streamed));
  engine.grantCredit(1, 100000, 0);
  ASSERT_TRUE(waitFor([] {
    CapturedChunk t;
    return terminalChunk(1, &t);
  }));

  ASSERT_EQ(Captures::instance().heads().size(), 1u);
  const RawResponseHead head = Captures::instance().heads()[0];
  EXPECT_EQ(head.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(head.contentLength,
            static_cast<int64_t>(HttpTestServer::upperPlainText().size()))
      << "the encoded length IS the delivered length when nothing was decoded";
  EXPECT_NE(findHeader(head.headers, "Content-Encoding"), nullptr);

  const std::vector<uint8_t> payload = concatenatedPayload(1);
  EXPECT_EQ(std::string(payload.begin(), payload.end()),
            HttpTestServer::upperPlainText());
}

TEST_F(EngineTest, ACorruptGzipBodyIsADecompressionFailure) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const RawResponse r = sendBuffered(engine, request(1, "/badgzip"));
  EXPECT_EQ(r.errorKind, RAWERRORKIND_DECOMPRESSION_FAILURE)
      << "body: " << bodyOf(r);
  EXPECT_FALSE(r.errorMessage.empty())
      << "the decoder's own message is the only diagnostic there is";
  EXPECT_TRUE(contains(r.errorMessage, "gzip")) << r.errorMessage;

  // The client survives it: a bad body is one request's problem.
  const RawResponse good = sendBuffered(engine, request(2, "/gzip"));
  EXPECT_EQ(good.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(bodyOf(good), HttpTestServer::gzipPlainText());
}

TEST_F(EngineTest, AStreamedGzipResponseEmitsDecodedChunks) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  // One credit at a time, so the pause/unpause path runs over decoded bytes and
  // not over the compressed blocks curl delivered.
  engine.submit(request(1, "/gzip", RespMode::Streamed));
  engine.grantCredit(1, 1, 0);
  int64_t acked = 0;
  ASSERT_TRUE(waitFor([&] {
    CapturedChunk t;
    if (terminalChunk(1, &t)) return true;
    const int64_t seen = static_cast<int64_t>(dataChunkCount(1));
    if (seen > acked) {
      acked = seen;
      engine.grantCredit(1, 1, acked);
    }
    return false;
  }));

  CapturedChunk terminal;
  ASSERT_TRUE(terminalChunk(1, &terminal));
  EXPECT_EQ(terminal.kind, RAWCHUNKKIND_DONE) << "aux " << terminal.aux;

  const std::vector<uint8_t> payload = concatenatedPayload(1);
  EXPECT_EQ(std::string(payload.begin(), payload.end()),
            HttpTestServer::gzipPlainText());
  for (const CapturedChunk& chunk : chunksFor(1)) {
    if (chunk.kind == RAWCHUNKKIND_DATA) {
      EXPECT_FALSE(chunk.bytes.empty())
          << "an empty chunk would spend a credit for no body byte";
    }
  }
}

TEST_F(EngineTest, ACachedGzipResponseStoresAndReplaysDecodedBytes) {
  // The entry has no Content-Encoding header, so a replay has no way to inflate
  // anything. Storing compressed bytes would therefore serve garbage.
  RawCacheConfig cacheConfig{};
  cacheConfig.enabled = true;
  cacheConfig.directory = tempRoot_.string();
  std::shared_ptr<HttpCache> cache = HttpCache::open(cacheConfig);
  ASSERT_NE(cache, nullptr);

  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.enableCache = true;

  CurlEngine engine(1);
  engine.configure(config);
  engine.setCache(cache);

  const RawResponse live = sendBuffered(engine, request(1, "/cachedgzip/600"));
  ASSERT_EQ(live.errorKind, RAWERRORKIND_NONE) << live.errorMessage;
  EXPECT_FALSE(live.fromCache);
  EXPECT_EQ(bodyOf(live), HttpTestServer::gzipPlainText());
  EXPECT_EQ(server_.requestCount("/cachedgzip/600"), 1);

  const RawResponse replayed =
      sendBuffered(engine, request(2, "/cachedgzip/600"));
  ASSERT_EQ(replayed.errorKind, RAWERRORKIND_NONE) << replayed.errorMessage;
  EXPECT_TRUE(replayed.fromCache);
  EXPECT_EQ(bodyOf(replayed), HttpTestServer::gzipPlainText())
      << "the entry must hold decoded bytes";
  EXPECT_EQ(findHeader(replayed.headers, "Content-Encoding"), nullptr)
      << "a stored header that no longer describes the stored body";
  EXPECT_EQ(server_.requestCount("/cachedgzip/600"), 1)
      << "the replay must not have touched the network";
}

TEST_F(EngineTest, RequestingAnUnsupportedCodingDegradesRatherThanFailing) {
  // A caller may override Accept-Encoding with something this build cannot
  // inflate. That must degrade to a pass-through, never to a failure.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/echo");
  pending.req.headers = {hdr("Accept-Encoding", "br")};
  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE)
      << "brotli availability: " << (hasBrotli() ? "yes" : "no") << " — "
      << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
  EXPECT_TRUE(contains(bodyOf(r), "\"method\":\"GET\"")) << bodyOf(r);

  // Gzip still works on the same engine, so the odd request degraded rather
  // than the client.
  const RawResponse gzip = sendBuffered(engine, request(2, "/gzip"));
  EXPECT_EQ(gzip.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(bodyOf(gzip), HttpTestServer::gzipPlainText());
}

TEST_F(EngineTest, CapabilityQueriesDescribeWhatTheEngineCanActuallyDo) {
  EXPECT_FALSE(engineVersionString().empty());
  EXPECT_TRUE(hasWebSockets())
      << "RFC 6455 framing is ours, never curl's optional build flag";
  EXPECT_EQ(hasHttp3(), hasHttp3());  // a runtime fact about the linked curl

  // These two are no longer curl's business: they answer "can the ENGINE
  // decode it", which is exactly what the advertisement is built from.
  EXPECT_EQ(hasBrotli(),
            acceptEncodingHeader().find("br") != std::string::npos);
  EXPECT_EQ(hasZstd(),
            acceptEncodingHeader().find("zstd") != std::string::npos);
}

// ─── Response size ceiling ───────────────────────────────────────────────────
//
// Two checks enforce one setting: `CURLOPT_MAXFILESIZE_LARGE` refuses a
// declared `Content-Length` before the body is read, and the running count in
// `handleWrite` catches everything curl cannot see — a chunked body, an
// under-declared one, and anything the engine decodes itself.

TEST_F(EngineTest, ADeclaredLengthOverTheCeilingIsRefused) {
  CurlEngine engine(1);
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.maxResponseBytes = 1024;
  engine.configure(config);

  const RawResponse r = sendBuffered(engine, request(1, "/bytes/4096"));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_RESPONSE_TOO_LARGE);
  EXPECT_TRUE(contains(r.errorMessage, "1024")) << r.errorMessage;
  EXPECT_TRUE(r.body.empty());
}

TEST_F(EngineTest, ABodyExactlyAtTheCeilingIsAllowed) {
  // "Larger than", not "at least" — a ceiling that rejected its own value would
  // be unusable for an API with a known response size.
  CurlEngine engine(1);
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.maxResponseBytes = 1024;
  engine.configure(config);

  const RawResponse r = sendBuffered(engine, request(1, "/bytes/1024"));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE);
  EXPECT_EQ(r.body.size(), 1024u);
}

TEST_F(EngineTest, AChunkedBodyOverTheCeilingIsCaughtAsItArrives) {
  CurlEngine engine(1);
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.maxResponseBytes = 1024;
  engine.configure(config);

  // No `Content-Length` to refuse up front.
  const RawResponse r = sendBuffered(engine, request(1, "/chunked/16/512"));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_RESPONSE_TOO_LARGE);
}

TEST_F(EngineTest, TheCeilingCountsDecodedBytesNotWireBytes) {
  // The engine decodes, not curl, so curl's own check never sees a number over
  // the limit. Counting wire bytes would let a compressed response walk past
  // the ceiling — the same hole the decompression cap exists to close.
  CurlEngine engine(1);
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  // Above the compressed size of `/gzip` (repeating text, a few hundred bytes)
  // and below its 4096-byte decoded size, so only a counter that measures after
  // decoding can refuse it.
  config.maxResponseBytes = 1024;
  engine.configure(config);

  const RawResponse r = sendBuffered(engine, request(1, "/gzip"));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_RESPONSE_TOO_LARGE);
  EXPECT_EQ(r.engineErrorCode, 0)
      << "curl refused this on wire bytes; the running count should have";
}

TEST_F(EngineTest, ARedirectBodyDoesNotCountTowardTheFinalOne) {
  // `/redirect/<n>` sends "redirecting" as the body of each 302. The counter
  // resets on every status line, so only the body the caller receives is
  // measured.
  CurlEngine engine(1);
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.maxResponseBytes = 64;
  engine.configure(config);

  const RawResponse r = sendBuffered(engine, request(1, "/redirect/3"));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(bodyOf(r), "redirect-done");
}

TEST_F(EngineTest, AHeadRequestIsNotRefusedOnADeclaredLength) {
  // HEAD describes a body it never sends. Refusing on the declaration would
  // break the one thing HEAD is for: asking how big something is before
  // deciding to fetch it.
  CurlEngine engine(1);
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.maxResponseBytes = 16;
  engine.configure(config);

  PendingRequest pending = request(1, "/bytes/4096");
  pending.req.method = RawMethod::RAWMETHOD_HEAD;

  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
}

// ─── Writing the body to a file ──────────────────────────────────────────────

TEST_F(EngineTest, AResponseFilePathReceivesTheBodyInsteadOfTheCaller) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const fs::path target = tempRoot_ / "download.bin";
  PendingRequest pending = request(1, "/bytes/4096");
  pending.req.responseFilePath = target.string();

  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  EXPECT_EQ(r.statusCode, 200);
  // The bytes went to disk, so none of them crossed the bridge.
  EXPECT_TRUE(r.body.empty());
  ASSERT_TRUE(fs::exists(target));
  EXPECT_EQ(fs::file_size(target), 4096u);
}

TEST_F(EngineTest, AnErrorStatusLeavesNoFileAndReturnsTheBody) {
  // An error page under the name the caller chose is worse than no file:
  // nothing about it says it is not the download.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const fs::path target = tempRoot_ / "missing.bin";
  PendingRequest pending = request(1, "/status/404");
  pending.req.responseFilePath = target.string();

  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.statusCode, 404);
  EXPECT_FALSE(fs::exists(target));
  EXPECT_EQ(bodyOf(r), "status 404")
      << "the error body should still reach the caller";
}

TEST_F(EngineTest, ARedirectHopDoesNotLeaveItsBodyInTheFile) {
  // The file is opened before the first hop, so each 302's "redirecting" body
  // is written to it. Rewinding on the next status line is what keeps it from
  // being glued in front of the real body — a silently wrong file rather than
  // a missing one.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const fs::path target = tempRoot_ / "redirected.bin";
  PendingRequest pending = request(1, "/redirect/3");
  pending.req.responseFilePath = target.string();

  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_NONE) << r.errorMessage;
  ASSERT_TRUE(fs::exists(target));

  std::ifstream in(target.string(), std::ios::binary);
  const std::string contents((std::istreambuf_iterator<char>(in)),
                             std::istreambuf_iterator<char>());
  EXPECT_EQ(contents, "redirect-done");
}

TEST_F(EngineTest, AFailedTransferRemovesThePartialFile) {
  CurlEngine engine(1);
  RawClientConfig config = nitrohttp::test::defaultClientConfig();
  config.maxResponseBytes = 1024;
  engine.configure(config);

  const fs::path target = tempRoot_ / "partial.bin";
  PendingRequest pending = request(1, "/chunked/16/512");
  pending.req.responseFilePath = target.string();

  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_RESPONSE_TOO_LARGE);
  EXPECT_FALSE(fs::exists(target)) << "half a download was left behind";
}

TEST_F(EngineTest, AResponseFilePathIsRefusedOnAStreamedRequest) {
  // The body goes to one place or the other, never both, so this is refused
  // rather than silently picking one.
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  const fs::path target = tempRoot_ / "streamed.bin";
  PendingRequest pending = request(1, "/bytes/16", RespMode::Streamed);
  pending.req.responseFilePath = target.string();

  engine.submit(std::move(pending));
  ASSERT_TRUE(Captures::instance().waitForPosts(1));
  const RawResponseHead head = RawResponseHead::fromNative(NitroCppBuffer{
      Captures::instance().posts()[0].payload.data(),
      Captures::instance().posts()[0].payload.size()});

  EXPECT_EQ(head.errorKind, RAWERRORKIND_BAD_REQUEST);
  EXPECT_FALSE(fs::exists(target));
}

TEST_F(EngineTest, AnUnopenableResponseFilePathFailsBeforeTheRequest) {
  CurlEngine engine(1);
  engine.configure(nitrohttp::test::defaultClientConfig());

  PendingRequest pending = request(1, "/bytes/16");
  pending.req.responseFilePath = (tempRoot_ / "no" / "such" / "dir").string();

  const RawResponse r = sendBuffered(engine, std::move(pending));

  EXPECT_EQ(r.errorKind, RAWERRORKIND_IO);
  EXPECT_TRUE(contains(r.errorMessage, "response body file")) << r.errorMessage;
}
