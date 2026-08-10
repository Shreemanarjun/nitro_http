// ─────────────────────────────────────────────────────────────────────────────
// HttpCache, with no network anywhere near it.
//
// The cache is an RFC 9111 subset, and the subset is the interesting part: the
// exact set of things it will and will not store, how it computes freshness,
// and what a 304 is allowed to change. All of that is decided by pure functions
// and a directory of files, so all of it is testable directly — which is worth
// far more than driving it through curl and hoping.
// ─────────────────────────────────────────────────────────────────────────────

#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

#include "Common.h"
#include "HttpCache.h"

using namespace nitrohttp;
namespace fs = std::filesystem;

namespace {

RawHeader hdr(std::string name, std::string value) {
  RawHeader h{};
  h.name = std::move(name);
  h.value = std::move(value);
  return h;
}

int countHeaders(const std::vector<RawHeader>& headers, const std::string& name) {
  int n = 0;
  for (const RawHeader& h : headers) {
    if (asciiEqualIgnoreCase(h.name, name)) ++n;
  }
  return n;
}

std::string headerOf(const std::vector<RawHeader>& headers,
                     const std::string& name) {
  const RawHeader* h = findHeader(headers, name);
  return h == nullptr ? std::string() : h->value;
}

bool writeAll(CacheWriter& writer, const std::string& body) {
  return writer.write(reinterpret_cast<const uint8_t*>(body.data()),
                      body.size());
}

std::string bodyString(const CacheHit& hit) {
  return std::string(hit.body.begin(), hit.body.end());
}

/// A cache rooted in a directory this test owns and deletes.
class CacheFixture : public ::testing::Test {
 protected:
  void SetUp() override {
    // Unique per test AND per run, so a crashed run's leftovers cannot make the
    // next one pass or fail for the wrong reason.
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch();
    dir_ = fs::temp_directory_path() /
           ("nitro_http_cache_test_" +
            std::to_string(static_cast<unsigned long long>(stamp.count())) +
            "_" + std::to_string(counter_++));
    fs::create_directories(dir_);
  }

  void TearDown() override {
    cache_.reset();
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }

  RawCacheConfig config(int64_t maxSize = 0, int64_t maxEntry = 0) const {
    RawCacheConfig cfg{};
    cfg.enabled = true;
    cfg.directory = dir_.string();
    cfg.maxSizeBytes = maxSize;
    cfg.maxEntryBytes = maxEntry;
    return cfg;
  }

  std::shared_ptr<HttpCache> openCache(int64_t maxSize = 0,
                                       int64_t maxEntry = 0) {
    cache_ = HttpCache::open(config(maxSize, maxEntry));
    return cache_;
  }

  fs::path entriesDir() const {
    return dir_ / "nitro_http_cache" / "v1" / "e";
  }

  size_t countFilesWithExtension(const std::string& ext) const {
    size_t n = 0;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(entriesDir(), ec)) {
      if (entry.path().extension() == ext) ++n;
    }
    return n;
  }

  /// Stores `body` under `url` and returns the key it landed on.
  std::string store(HttpCache& cache, const std::string& url,
                    const std::vector<RawHeader>& responseHeaders,
                    const std::string& body,
                    const std::vector<RawHeader>& requestHeaders = {}) {
    const std::string key = cache.keyFor("GET", url, requestHeaders);
    std::unique_ptr<CacheWriter> writer = cache.beginWrite(
        key, 200, responseHeaders, requestHeaders, "GET", url);
    EXPECT_NE(writer, nullptr) << url;
    if (writer == nullptr) return key;
    EXPECT_TRUE(writeAll(*writer, body));
    writer->commit();
    return cache.keyFor("GET", url, requestHeaders);
  }

  fs::path dir_;
  std::shared_ptr<HttpCache> cache_;
  static int counter_;
};

int CacheFixture::counter_ = 0;

constexpr int64_t kNov6_1994 = 784111777000LL;

}  // namespace

// ─── parseHttpDate ───────────────────────────────────────────────────────────

TEST(CacheDate, ParsesAllThreeLegalSpellingsToTheSameInstant) {
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"),
            kNov6_1994)
      << "IMF-fixdate";
  EXPECT_EQ(HttpCache::parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT"),
            kNov6_1994)
      << "RFC 850";
  EXPECT_EQ(HttpCache::parseHttpDate("Sun Nov  6 08:49:37 1994"), kNov6_1994)
      << "asctime";
}

TEST(CacheDate, RoundTripsThroughFormat) {
  EXPECT_EQ(HttpCache::formatHttpDate(kNov6_1994),
            "Sun, 06 Nov 1994 08:49:37 GMT");
  EXPECT_EQ(HttpCache::parseHttpDate(HttpCache::formatHttpDate(kNov6_1994)),
            kNov6_1994);

  // Every hour of a day, so a weekday or hour-of-day off-by-one cannot hide.
  for (int64_t hour = 0; hour < 24; ++hour) {
    const int64_t t = kNov6_1994 + hour * 3600000;
    EXPECT_EQ(HttpCache::parseHttpDate(HttpCache::formatHttpDate(t)), t)
        << "hour " << hour;
  }
}

TEST(CacheDate, HandlesLeapDaysAndTheCenturyBoundary) {
  EXPECT_EQ(HttpCache::parseHttpDate("Mon, 29 Feb 2016 12:00:00 GMT"),
            1456747200000LL);
  // 2000 is a leap year despite being a century — the classic calendar bug.
  EXPECT_EQ(HttpCache::parseHttpDate("Tue, 29 Feb 2000 00:00:00 GMT"),
            951782400000LL);
  EXPECT_EQ(HttpCache::parseHttpDate("Fri, 31 Dec 1999 23:59:59 GMT"),
            946684799000LL);
  EXPECT_EQ(HttpCache::parseHttpDate("Sat, 01 Jan 2000 00:00:00 GMT"),
            946684800000LL);
  EXPECT_EQ(HttpCache::parseHttpDate("Sat, 01 Jan 2000 00:00:00 GMT") -
                HttpCache::parseHttpDate("Fri, 31 Dec 1999 23:59:59 GMT"),
            1000);
  EXPECT_EQ(HttpCache::formatHttpDate(951782400000LL),
            "Tue, 29 Feb 2000 00:00:00 GMT");
}

TEST(CacheDate, TwoDigitYearsAreWindowedAtSixtyNine) {
  EXPECT_EQ(HttpCache::parseHttpDate("Thursday, 01-Jan-70 00:00:00 GMT"),
            HttpCache::parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
  EXPECT_EQ(HttpCache::parseHttpDate("Thursday, 01-Jan-69 00:00:00 GMT"),
            HttpCache::parseHttpDate("Wed, 01 Jan 2069 00:00:00 GMT"));
}

TEST(CacheDate, ClampsALeapSecondRatherThanRejectingIt) {
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 06 Nov 1994 08:49:60 GMT"),
            kNov6_1994 + 22000)
      << "08:49:60 clamps to 08:49:59, 22 s after the 08:49:37 reference";
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 06 Nov 1994 08:49:60 GMT"),
            HttpCache::parseHttpDate("Sun, 06 Nov 1994 08:49:59 GMT"));
}

TEST(CacheDate, RejectsGarbage) {
  EXPECT_EQ(HttpCache::parseHttpDate(""), -1);
  EXPECT_EQ(HttpCache::parseHttpDate("not a date at all"), -1);
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 06 Xxx 1994 08:49:37 GMT"), -1)
      << "unknown month";
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 32 Nov 1994 08:49:37 GMT"), -1)
      << "day out of range";
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 06 Nov 1994 25:49:37 GMT"), -1)
      << "hour out of range";
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 06 Nov 1994 08:61:37 GMT"), -1)
      << "minute out of range";
  EXPECT_EQ(HttpCache::parseHttpDate("Sun, 06 Nov 1994 084937 GMT"), -1)
      << "time without separators";
}

TEST(CacheDate, FormatsTheEpochAndFarFuture) {
  EXPECT_EQ(HttpCache::formatHttpDate(0), "Thu, 01 Jan 1970 00:00:00 GMT");
  EXPECT_EQ(HttpCache::formatHttpDate(2147483648000LL),
            "Tue, 19 Jan 2038 03:14:08 GMT")
      << "the cache must outlive 32-bit time_t";
}

// ─── parseCacheControl ───────────────────────────────────────────────────────

TEST(CacheControl, ParsesEveryDirectiveItHonours) {
  const auto cc = HttpCache::parseCacheControl(
      {hdr("Cache-Control",
           "no-store, no-cache, private, must-revalidate, immutable, "
           "max-age=60, s-maxage=120")});
  EXPECT_TRUE(cc.noStore);
  EXPECT_TRUE(cc.noCache);
  EXPECT_TRUE(cc.isPrivate);
  EXPECT_TRUE(cc.mustRevalidate);
  EXPECT_TRUE(cc.immutable);
  EXPECT_EQ(cc.maxAgeMs, 60000);
  EXPECT_EQ(cc.sMaxAgeMs, 120000);
}

TEST(CacheControl, IsCaseInsensitiveAndIgnoresUnknownDirectives) {
  const auto cc = HttpCache::parseCacheControl(
      {hdr("cache-control", "NO-STORE, Max-Age=30, stale-while-revalidate=60, "
                            "surrogate-control=whatever")});
  EXPECT_TRUE(cc.noStore);
  EXPECT_EQ(cc.maxAgeMs, 30000);
  EXPECT_EQ(cc.sMaxAgeMs, -1);
  EXPECT_FALSE(cc.noCache);
}

TEST(CacheControl, AcceptsQuotedValuesAndFieldNamedForms) {
  const auto quoted =
      HttpCache::parseCacheControl({hdr("Cache-Control", "max-age=\"120\"")});
  EXPECT_EQ(quoted.maxAgeMs, 120000);

  // `no-cache="Set-Cookie"` is the qualified form; we treat it as no-cache.
  const auto qualified = HttpCache::parseCacheControl(
      {hdr("Cache-Control", "no-cache=\"Set-Cookie\", max-age=10")});
  EXPECT_TRUE(qualified.noCache);
  EXPECT_EQ(qualified.maxAgeMs, 10000);
}

TEST(CacheControl, JoinsRepeatedHeaders) {
  const auto cc = HttpCache::parseCacheControl(
      {hdr("Cache-Control", "max-age=60"), hdr("Cache-Control", "private")});
  EXPECT_EQ(cc.maxAgeMs, 60000);
  EXPECT_TRUE(cc.isPrivate);
}

TEST(CacheControl, AMalformedAgeLeavesTheSentinel) {
  const auto cc =
      HttpCache::parseCacheControl({hdr("Cache-Control", "max-age=abc")});
  EXPECT_EQ(cc.maxAgeMs, -1);
  EXPECT_EQ(HttpCache::parseCacheControl({}).maxAgeMs, -1);
}

// ─── isStorable ──────────────────────────────────────────────────────────────

TEST(IsStorable, TheStatusMatrix) {
  const std::vector<RawHeader> plain = {hdr("Cache-Control", "max-age=60")};
  for (const int64_t status : {200, 203, 301, 308}) {
    EXPECT_TRUE(HttpCache::isStorable(status, "GET", plain)) << status;
  }
  for (const int64_t status : {204, 206, 302, 400, 404, 500, 503}) {
    EXPECT_FALSE(HttpCache::isStorable(status, "GET", plain)) << status;
  }
}

TEST(IsStorable, TheMethodMatrix) {
  const std::vector<RawHeader> plain = {hdr("Cache-Control", "max-age=60")};
  EXPECT_TRUE(HttpCache::isStorable(200, "GET", plain));
  EXPECT_TRUE(HttpCache::isStorable(200, "get", plain)) << "case-insensitive";
  EXPECT_TRUE(HttpCache::isStorable(200, "HEAD", plain));
  for (const char* method : {"POST", "PUT", "PATCH", "DELETE", "OPTIONS"}) {
    EXPECT_FALSE(HttpCache::isStorable(200, method, plain)) << method;
  }
}

TEST(IsStorable, RespectsNoStoreAndPrivate) {
  EXPECT_FALSE(HttpCache::isStorable(
      200, "GET", {hdr("Cache-Control", "no-store")}));
  EXPECT_FALSE(HttpCache::isStorable(
      200, "GET", {hdr("Cache-Control", "private, max-age=60")}));
  // `no-cache` forbids REUSE without revalidation, not storage.
  EXPECT_TRUE(HttpCache::isStorable(200, "GET",
                                    {hdr("Cache-Control", "no-cache")}));
}

TEST(IsStorable, VaryStarIsUncacheableButANamedVaryIsFine) {
  EXPECT_FALSE(HttpCache::isStorable(200, "GET", {hdr("Vary", "*")}));
  EXPECT_FALSE(HttpCache::isStorable(200, "GET", {hdr("Vary", " * ")}));
  EXPECT_TRUE(
      HttpCache::isStorable(200, "GET", {hdr("Vary", "Accept-Encoding")}));
}

// ─── freshnessLifetimeMs ─────────────────────────────────────────────────────

TEST(Freshness, SMaxAgeBeatsMaxAge) {
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(
                {hdr("Cache-Control", "max-age=60, s-maxage=120")}, 0),
            120000);
  EXPECT_EQ(
      HttpCache::freshnessLifetimeMs({hdr("Cache-Control", "max-age=60")}, 0),
      60000);
}

TEST(Freshness, NoCacheIsZeroEvenBesideAMaxAge) {
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(
                {hdr("Cache-Control", "no-cache, max-age=600")}, 0),
            0)
      << "no-cache means revalidate every time, which is a zero lifetime";
}

TEST(Freshness, UsesExpiresMinusDateWhenThereIsNoMaxAge) {
  const int64_t date = kNov6_1994;
  const std::vector<RawHeader> headers = {
      hdr("Date", HttpCache::formatHttpDate(date)),
      hdr("Expires", HttpCache::formatHttpDate(date + 300000))};
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(headers, date), 300000);
}

TEST(Freshness, AnExpiresInThePastOrUnparseableIsAlreadyExpired) {
  const int64_t date = kNov6_1994;
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(
                {hdr("Date", HttpCache::formatHttpDate(date)),
                 hdr("Expires", HttpCache::formatHttpDate(date - 300000))},
                date),
            0);
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(
                {hdr("Date", HttpCache::formatHttpDate(date)),
                 hdr("Expires", "0")},
                date),
            0)
      << "RFC 9111 §5.3: an unparseable Expires means already expired";
}

TEST(Freshness, FallsBackToTenPercentOfTheLastModifiedAge) {
  const int64_t date = kNov6_1994;
  const std::vector<RawHeader> headers = {
      hdr("Date", HttpCache::formatHttpDate(date)),
      hdr("Last-Modified", HttpCache::formatHttpDate(date - 1000000))};
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(headers, date), 100000);
}

TEST(Freshness, TheHeuristicIsCappedAtTwentyFourHours) {
  const int64_t date = kNov6_1994;
  const int64_t hundredDays = int64_t{100} * 24 * 3600 * 1000;
  const std::vector<RawHeader> headers = {
      hdr("Date", HttpCache::formatHttpDate(date)),
      hdr("Last-Modified", HttpCache::formatHttpDate(date - hundredDays))};
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(headers, date),
            int64_t{24} * 3600 * 1000);
}

TEST(Freshness, IsMinusOneWhenNothingApplies) {
  EXPECT_EQ(HttpCache::freshnessLifetimeMs({}, kNov6_1994), -1);
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(
                {hdr("Date", HttpCache::formatHttpDate(kNov6_1994))},
                kNov6_1994),
            -1);
  // A Last-Modified in the FUTURE gives no usable age either.
  EXPECT_EQ(HttpCache::freshnessLifetimeMs(
                {hdr("Date", HttpCache::formatHttpDate(kNov6_1994)),
                 hdr("Last-Modified",
                     HttpCache::formatHttpDate(kNov6_1994 + 60000))},
                kNov6_1994),
            -1);
}

// ─── open() ──────────────────────────────────────────────────────────────────

TEST_F(CacheFixture, OpenReturnsNullForADisabledOrUnusableConfig) {
  RawCacheConfig disabled = config();
  disabled.enabled = false;
  EXPECT_EQ(HttpCache::open(disabled), nullptr);

  RawCacheConfig noDirectory = config();
  noDirectory.directory = "";
  EXPECT_EQ(HttpCache::open(noDirectory), nullptr);

  // A path whose parent is a regular file can never become a directory.
  const fs::path file = dir_ / "not-a-directory";
  { std::ofstream(file.string()) << "x"; }
  RawCacheConfig bad = config();
  bad.directory = (file / "under-a-file").string();
  EXPECT_EQ(HttpCache::open(bad), nullptr)
      << "a broken cache must read as 'no caching', never as an error";
}

// ─── Store / lookup ──────────────────────────────────────────────────────────

TEST_F(CacheFixture, StoreThenLookupReturnsBothTheBodyAndItsPath) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/resource";
  const std::string body = "hello cached world";
  const std::string key =
      store(*cache, url, {hdr("Cache-Control", "max-age=600"),
                          hdr("Content-Type", "text/plain")},
            body);

  const CacheHit hit = cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {});
  ASSERT_EQ(hit.outcome, CacheOutcome::Fresh);
  EXPECT_EQ(hit.statusCode, 200);
  EXPECT_EQ(bodyString(hit), body);
  EXPECT_EQ(hit.contentLength, static_cast<int64_t>(body.size()));
  ASSERT_FALSE(hit.bodyPath.empty())
      << "the streamed path replays from disk instead of holding it in memory";
  EXPECT_TRUE(fs::exists(hit.bodyPath));
  EXPECT_EQ(headerOf(hit.headers, "Content-Type"), "text/plain");

  const RawCacheStats stats = cache->stats();
  EXPECT_EQ(stats.entryCount, 1);
  EXPECT_EQ(stats.hitCount, 1);
  EXPECT_EQ(stats.sizeBytes, static_cast<int64_t>(body.size()));
}

TEST_F(CacheFixture, ALookupForAnUnknownKeyIsAMiss) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);
  const CacheHit hit = cache->lookup(cache->keyFor("GET", "http://a/b", {}),
                                     RAWCACHEMODE_NORMAL, "GET", {});
  EXPECT_EQ(hit.outcome, CacheOutcome::Miss);
  EXPECT_TRUE(hit.body.empty());
  EXPECT_EQ(cache->stats().missCount, 1);
}

TEST_F(CacheFixture, EveryCacheModeBehavesAsSpecified) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/modes";
  const std::string key = store(
      *cache, url,
      {hdr("Cache-Control", "max-age=600"), hdr("ETag", "\"v1\"")}, "fresh");

  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Fresh);
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NO_STORE, "GET", {}).outcome,
            CacheOutcome::Uncacheable);
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_BYPASS, "GET", {}).outcome,
            CacheOutcome::Miss);
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_ONLY_IF_CACHED, "GET", {}).outcome,
            CacheOutcome::Fresh);
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_REFRESH, "GET", {}).outcome,
            CacheOutcome::Stale)
      << "refresh forces the conditional request even on a fresh entry";

  // A non-cacheable method is uncacheable regardless of mode.
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "POST", {}).outcome,
            CacheOutcome::Uncacheable);
}

TEST_F(CacheFixture, OnlyIfCachedNeverReturnsStale) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/offline";
  const std::string key =
      store(*cache, url,
            {hdr("Cache-Control", "max-age=0"), hdr("ETag", "\"v1\"")},
            "stale body");

  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Stale)
      << "a validator plus a zero lifetime is exactly the revalidate case";
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_ONLY_IF_CACHED, "GET", {}).outcome,
            CacheOutcome::Miss)
      << "Stale means 'go to the network', which this mode must never do";
}

TEST_F(CacheFixture, AStaleEntryWithNoValidatorIsAMissNotAStale) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);
  const std::string key = store(*cache, "http://example.com/novalidator",
                                {hdr("Cache-Control", "max-age=0")}, "body");
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Miss)
      << "there is nothing to revalidate with";
}

TEST_F(CacheFixture, AStaleLookupSkipsTheBodyReadUnlessAskedForIt) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/lazy-stale";
  const std::string body = "the stored body";
  const std::string key =
      store(*cache, url,
            {hdr("Cache-Control", "max-age=0"), hdr("ETag", "\"v1\"")}, body);

  // The common stale path exists only to build a conditional request, and it
  // would throw the body away. Reading it off disk there is pure waste, so the
  // default must not.
  const CacheHit lazy =
      cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {},
                    /*loadBodyOnStale=*/false);
  ASSERT_EQ(lazy.outcome, CacheOutcome::Stale);
  EXPECT_TRUE(lazy.body.empty());
  EXPECT_TRUE(lazy.bodyPath.empty())
      << "an empty bodyPath is what tells the streamed path there is nothing "
         "to replay yet";
  EXPECT_EQ(lazy.etag, "\"v1\"") << "the validators are still there";

  // The post-304 path is the one caller that DOES intend to serve it.
  const CacheHit eager =
      cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {},
                    /*loadBodyOnStale=*/true);
  ASSERT_EQ(eager.outcome, CacheOutcome::Stale);
  EXPECT_EQ(bodyString(eager), body);
  ASSERT_FALSE(eager.bodyPath.empty());
  EXPECT_TRUE(fs::exists(eager.bodyPath));
  EXPECT_EQ(eager.contentLength, static_cast<int64_t>(body.size()));

  // `refresh` forces Stale even on a fresh entry, and must honour the flag the
  // same way.
  const std::string freshKey = store(*cache, "http://example.com/lazy-fresh",
                                     {hdr("Cache-Control", "max-age=600"),
                                      hdr("ETag", "\"v2\"")},
                                     "fresh body");
  const CacheHit forced =
      cache->lookup(freshKey, RAWCACHEMODE_REFRESH, "GET", {},
                    /*loadBodyOnStale=*/true);
  ASSERT_EQ(forced.outcome, CacheOutcome::Stale);
  EXPECT_EQ(bodyString(forced), "fresh body");
  EXPECT_TRUE(cache->lookup(freshKey, RAWCACHEMODE_REFRESH, "GET", {})
                  .body.empty());
}

TEST_F(CacheFixture, AStaleEntryWhoseBodyVanishedDegradesToAMiss) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string key =
      store(*cache, "http://example.com/vanished",
            {hdr("Cache-Control", "max-age=0"), hdr("ETag", "\"v1\"")},
            "doomed");

  const CacheHit located =
      cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {},
                    /*loadBodyOnStale=*/true);
  ASSERT_EQ(located.outcome, CacheOutcome::Stale);
  ASSERT_FALSE(located.bodyPath.empty());

  std::error_code ec;
  fs::remove(located.bodyPath, ec);
  ASSERT_FALSE(ec);

  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {},
                          /*loadBodyOnStale=*/true)
                .outcome,
            CacheOutcome::Miss)
      << "serving a body that is no longer there is worse than a miss";
}

// ─── Revalidation ────────────────────────────────────────────────────────────

TEST_F(CacheFixture, RefreshMetadataTurnsStaleBackIntoFreshAndMergesHeaders) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/revalidate";
  const std::string key =
      store(*cache, url,
            {hdr("Cache-Control", "max-age=0"), hdr("ETag", "\"v1\""),
             hdr("Content-Length", "11"), hdr("Content-Type", "text/plain")},
            "body bytes");

  const CacheHit stale = cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {});
  ASSERT_EQ(stale.outcome, CacheOutcome::Stale);
  EXPECT_EQ(stale.etag, "\"v1\"");

  cache->refreshMetadata(
      key, {hdr("Cache-Control", "max-age=600"), hdr("ETag", "\"v2\""),
            hdr("Content-Length", "999"), hdr("Content-Encoding", "gzip"),
            hdr("Date", HttpCache::formatHttpDate(wallClockMs()))});

  const CacheHit fresh = cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {});
  ASSERT_EQ(fresh.outcome, CacheOutcome::Fresh);
  EXPECT_EQ(bodyString(fresh), "body bytes") << "the body was never re-fetched";
  EXPECT_EQ(fresh.etag, "\"v2\"");

  // Same-named headers are REPLACED, not accumulated.
  EXPECT_EQ(countHeaders(fresh.headers, "Cache-Control"), 1);
  EXPECT_EQ(countHeaders(fresh.headers, "ETag"), 1);
  EXPECT_EQ(headerOf(fresh.headers, "Cache-Control"), "max-age=600");

  // A 304's Content-Length and Content-Encoding describe a body it did not
  // carry, so they must not touch the stored ones (RFC 9111 §4.3.4).
  EXPECT_EQ(headerOf(fresh.headers, "Content-Length"), "11");
  EXPECT_EQ(countHeaders(fresh.headers, "Content-Encoding"), 0);
  EXPECT_EQ(headerOf(fresh.headers, "Content-Type"), "text/plain")
      << "headers the 304 did not mention survive untouched";

  EXPECT_EQ(cache->stats().revalidationCount, 1);
}

TEST_F(CacheFixture, RefreshMetadataOnAnUnknownKeyDoesNothing) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);
  cache->refreshMetadata(cache->keyFor("GET", "http://nowhere/", {}),
                         {hdr("Cache-Control", "max-age=600")});
  EXPECT_EQ(cache->stats().entryCount, 0);
  EXPECT_EQ(cache->stats().revalidationCount, 0);
}

// ─── Vary ────────────────────────────────────────────────────────────────────

TEST_F(CacheFixture, TwoVaryVariantsShareABaseKeyAndAreServedSeparately) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/varies";
  const std::vector<RawHeader> gzipReq = {hdr("Accept-Encoding", "gzip")};
  const std::vector<RawHeader> brReq = {hdr("Accept-Encoding", "br")};
  const std::vector<RawHeader> resp = {hdr("Cache-Control", "max-age=600"),
                                       hdr("Vary", "Accept-Encoding")};

  store(*cache, url, resp, "gzip-body", gzipReq);
  store(*cache, url, resp, "br-body", brReq);

  const std::string gzipKey = cache->keyFor("GET", url, gzipReq);
  const std::string brKey = cache->keyFor("GET", url, brReq);
  EXPECT_NE(gzipKey, brKey) << "the Vary header must extend the key";

  const CacheHit gzipHit =
      cache->lookup(gzipKey, RAWCACHEMODE_NORMAL, "GET", gzipReq);
  ASSERT_EQ(gzipHit.outcome, CacheOutcome::Fresh);
  EXPECT_EQ(bodyString(gzipHit), "gzip-body");

  const CacheHit brHit = cache->lookup(brKey, RAWCACHEMODE_NORMAL, "GET", brReq);
  ASSERT_EQ(brHit.outcome, CacheOutcome::Fresh);
  EXPECT_EQ(bodyString(brHit), "br-body");

  // A third variant nobody stored is a miss, not somebody else's body.
  const std::vector<RawHeader> zstdReq = {hdr("Accept-Encoding", "zstd")};
  EXPECT_EQ(cache->lookup(cache->keyFor("GET", url, zstdReq),
                          RAWCACHEMODE_NORMAL, "GET", zstdReq)
                .outcome,
            CacheOutcome::Miss);

  EXPECT_EQ(cache->stats().entryCount, 2);
}

// ─── Writer failure paths ────────────────────────────────────────────────────

TEST_F(CacheFixture, MaxEntryBytesMakesTheWriterSelfDiscard) {
  auto cache = openCache(/*maxSize=*/0, /*maxEntry=*/16);
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/toobig";
  const std::string key = cache->keyFor("GET", url, {});
  std::unique_ptr<CacheWriter> writer = cache->beginWrite(
      key, 200, {hdr("Cache-Control", "max-age=600")}, {}, "GET", url);
  ASSERT_NE(writer, nullptr);

  EXPECT_TRUE(writeAll(*writer, "0123456789"));  // 10 bytes, under the cap
  EXPECT_FALSE(writeAll(*writer, "0123456789"))
      << "20 > 16: the writer must stop the caller teeing";
  EXPECT_FALSE(writer->active());
  writer->commit();  // no-op on a discarded writer
  writer.reset();

  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Miss);
  EXPECT_EQ(cache->stats().entryCount, 0);
  EXPECT_EQ(countFilesWithExtension(".tmp"), 0u);
}

TEST_F(CacheFixture, ADroppedWriterLeavesNoEntryAndNoTempFile) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/dropped";
  const std::string key = cache->keyFor("GET", url, {});
  {
    std::unique_ptr<CacheWriter> writer = cache->beginWrite(
        key, 200, {hdr("Cache-Control", "max-age=600")}, {}, "GET", url);
    ASSERT_NE(writer, nullptr);
    EXPECT_TRUE(writeAll(*writer, "half a body"));
    EXPECT_EQ(countFilesWithExtension(".tmp"), 1u) << "mid-write";
    // Destroyed without commit — a cancelled transfer.
  }
  EXPECT_EQ(countFilesWithExtension(".tmp"), 0u);
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Miss);
  EXPECT_EQ(cache->stats().entryCount, 0);
}

TEST_F(CacheFixture, AnExplicitDiscardLeavesNoEntryAndNoTempFile) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string url = "http://example.com/discarded";
  const std::string key = cache->keyFor("GET", url, {});
  std::unique_ptr<CacheWriter> writer = cache->beginWrite(
      key, 200, {hdr("Cache-Control", "max-age=600")}, {}, "GET", url);
  ASSERT_NE(writer, nullptr);
  EXPECT_TRUE(writeAll(*writer, "partial"));
  writer->discard();
  EXPECT_FALSE(writer->active());
  writer->commit();  // must not resurrect the entry
  writer.reset();

  EXPECT_EQ(countFilesWithExtension(".tmp"), 0u);
  EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Miss);
}

TEST_F(CacheFixture, BeginWriteReturnsNullForAnUnstorableResponse) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);
  const std::string url = "http://example.com/unstorable";
  const std::string key = cache->keyFor("GET", url, {});
  EXPECT_EQ(cache->beginWrite(key, 500, {}, {}, "GET", url), nullptr);
  EXPECT_EQ(cache->beginWrite(key, 200, {hdr("Cache-Control", "no-store")}, {},
                              "GET", url),
            nullptr);
  EXPECT_EQ(cache->beginWrite(key, 200, {}, {}, "POST", url), nullptr);
  EXPECT_EQ(countFilesWithExtension(".tmp"), 0u);
}

// ─── Eviction, clear, persistence ────────────────────────────────────────────

TEST_F(CacheFixture, LruEvictionKeepsTheCacheUnderMaxSizeBytes) {
  // 4000-byte cap, five 1000-byte entries: eviction targets 90 % of the cap,
  // so two of the five must go, oldest first.
  auto cache = openCache(/*maxSize=*/4000);
  ASSERT_NE(cache, nullptr);

  const std::string body(1000, 'z');
  std::vector<std::string> keys;
  for (int i = 0; i < 5; ++i) {
    keys.push_back(store(*cache, "http://example.com/lru/" + std::to_string(i),
                         {hdr("Cache-Control", "max-age=600")}, body));
    // Eviction orders by lastAccessMs, which has millisecond resolution.
    std::this_thread::sleep_for(std::chrono::milliseconds(3));
  }

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (cache->stats().sizeBytes > 3600 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  const RawCacheStats stats = cache->stats();
  EXPECT_LE(stats.sizeBytes, 3600) << "evicted down to 90 % of the cap";
  EXPECT_EQ(stats.entryCount, 3);
  EXPECT_GE(stats.evictionCount, 2);

  // The two oldest went; the three newest are still servable.
  EXPECT_EQ(cache->lookup(keys[0], RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Miss);
  EXPECT_EQ(cache->lookup(keys[1], RAWCACHEMODE_NORMAL, "GET", {}).outcome,
            CacheOutcome::Miss);
  for (size_t i = 2; i < keys.size(); ++i) {
    EXPECT_EQ(cache->lookup(keys[i], RAWCACHEMODE_NORMAL, "GET", {}).outcome,
              CacheOutcome::Fresh)
        << "key index " << i;
  }
}

TEST_F(CacheFixture, ClearEmptiesTheCacheAndItsFiles) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  std::vector<std::string> keys;
  for (int i = 0; i < 3; ++i) {
    keys.push_back(store(*cache, "http://example.com/clear/" + std::to_string(i),
                         {hdr("Cache-Control", "max-age=600")}, "body"));
  }
  ASSERT_EQ(cache->stats().entryCount, 3);

  cache->clear();
  const RawCacheStats stats = cache->stats();
  EXPECT_EQ(stats.entryCount, 0);
  EXPECT_EQ(stats.sizeBytes, 0);
  for (const std::string& key : keys) {
    EXPECT_EQ(cache->lookup(key, RAWCACHEMODE_NORMAL, "GET", {}).outcome,
              CacheOutcome::Miss);
  }
  EXPECT_EQ(countFilesWithExtension(".b"), 0u);
  EXPECT_EQ(countFilesWithExtension(".m"), 0u);
}

TEST_F(CacheFixture, EntriesAndTheVaryMapSurviveCloseAndReopen) {
  const std::string url = "http://example.com/persisted";
  const std::vector<RawHeader> gzipReq = {hdr("Accept-Encoding", "gzip")};
  const std::vector<RawHeader> brReq = {hdr("Accept-Encoding", "br")};

  std::string plainKey;
  {
    auto cache = openCache();
    ASSERT_NE(cache, nullptr);
    plainKey = store(*cache, "http://example.com/plain",
                     {hdr("Cache-Control", "max-age=600")}, "plain body");
    store(*cache, url,
          {hdr("Cache-Control", "max-age=600"), hdr("Vary", "Accept-Encoding")},
          "gzip-body", gzipReq);
    store(*cache, url,
          {hdr("Cache-Control", "max-age=600"), hdr("Vary", "Accept-Encoding")},
          "br-body", brReq);
    cache_.reset();  // closes the IO thread and syncs the index
  }

  auto reopened = openCache();
  ASSERT_NE(reopened, nullptr);

  const CacheHit plain =
      reopened->lookup(plainKey, RAWCACHEMODE_NORMAL, "GET", {});
  ASSERT_EQ(plain.outcome, CacheOutcome::Fresh);
  EXPECT_EQ(bodyString(plain), "plain body");

  // The Vary map is restored by the background scan, so wait for it rather
  // than racing it.
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (reopened->keyFor("GET", url, gzipReq) ==
             reopened->keyFor("GET", url, brReq) &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  ASSERT_NE(reopened->keyFor("GET", url, gzipReq),
            reopened->keyFor("GET", url, brReq))
      << "the Vary map did not survive the reopen";

  const CacheHit gzipHit = reopened->lookup(
      reopened->keyFor("GET", url, gzipReq), RAWCACHEMODE_NORMAL, "GET",
      gzipReq);
  ASSERT_EQ(gzipHit.outcome, CacheOutcome::Fresh);
  EXPECT_EQ(bodyString(gzipHit), "gzip-body");

  const CacheHit brHit = reopened->lookup(reopened->keyFor("GET", url, brReq),
                                          RAWCACHEMODE_NORMAL, "GET", brReq);
  ASSERT_EQ(brHit.outcome, CacheOutcome::Fresh);
  EXPECT_EQ(bodyString(brHit), "br-body");
}

// ─── Prefetch de-duplication ─────────────────────────────────────────────────

TEST_F(CacheFixture, ClaimPrefetchDeDuplicatesUntilReleased) {
  auto cache = openCache();
  ASSERT_NE(cache, nullptr);

  const std::string key = cache->keyFor("GET", "http://example.com/warm", {});
  EXPECT_TRUE(cache->claimPrefetch(key));
  EXPECT_FALSE(cache->claimPrefetch(key))
      << "an identical prefetch already in flight must not double the request";

  // A different resource is unaffected.
  const std::string other = cache->keyFor("GET", "http://example.com/other", {});
  EXPECT_TRUE(cache->claimPrefetch(other));

  cache->releasePrefetch(key);
  EXPECT_TRUE(cache->claimPrefetch(key)) << "released claims are reusable";
  cache->releasePrefetch(key);
  cache->releasePrefetch(key);  // idempotent
  cache->releasePrefetch(other);
  EXPECT_TRUE(cache->claimPrefetch(key));
}
