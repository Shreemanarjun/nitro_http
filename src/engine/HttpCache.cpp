#include "HttpCache.h"

#include <sys/stat.h>
#include <sys/types.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <shared_mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#else
#include <unistd.h>
#endif

#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif

namespace nitrohttp {

// Everything file-local lives in a NAMED namespace rather than an anonymous
// one: the Apple build concatenates every engine source into a single
// translation unit, where anonymous namespaces merge and same-named helpers
// from two sources would collide. For the same reason there is no
// namespace-scope `using namespace cachefs;` — that would leak these names into
// the sources included after this one. Member definitions import it per
// function instead.
namespace cachefs {

// ── Portable filesystem primitives ───────────────────────────────────────────
//
// <filesystem> is deliberately avoided: it still needs -lstdc++fs on some GCC
// versions, and its availability is gated on the macOS deployment target.
// Everything this cache needs is four POSIX calls that Windows spells with a
// leading underscore.

bool isDirectory(const std::string& path) {
  struct stat st;
  if (::stat(path.c_str(), &st) != 0) return false;
  return S_ISDIR(st.st_mode) != 0;
}

bool makeOneDir(const std::string& path) {
#ifdef _WIN32
  if (::_mkdir(path.c_str()) == 0) return true;
#else
  if (::mkdir(path.c_str(), 0700) == 0) return true;
#endif
  return isDirectory(path);  // lost a race, or it was already there
}

/// `mkdir -p`. Segments split on '/' only — every path this cache builds uses
/// forward slashes, which the Windows CRT accepts.
bool makeDirs(const std::string& path) {
  if (path.empty()) return false;
  if (isDirectory(path)) return true;

  std::string partial;
  partial.reserve(path.size());
  for (size_t i = 0; i < path.size(); ++i) {
    const char c = path[i];
    if (c == '/' && !partial.empty()) {
      // A bare drive prefix ("C:") is not a directory that can be created.
      const bool drivePrefix = partial.size() == 2 && partial[1] == ':';
      if (!drivePrefix && !makeOneDir(partial)) return false;
    }
    partial.push_back(c);
  }
  return makeOneDir(partial);
}

bool fileSize(const std::string& path, int64_t* out) {
  struct stat st;
  if (::stat(path.c_str(), &st) != 0) return false;
  if (out) *out = static_cast<int64_t>(st.st_size);
  return true;
}

void syncHandle(FILE* f) {
  if (!f) return;
  ::fflush(f);
#ifdef _WIN32
  (void)::_commit(::_fileno(f));
#else
  (void)::fsync(::fileno(f));
#endif
}

void removeFile(const std::string& path) { (void)::remove(path.c_str()); }

/// POSIX `rename` replaces the destination atomically. The Windows CRT refuses
/// an existing destination, so it gets an unlink first — a crash in that window
/// loses one entry, which the next lookup simply treats as a miss.
bool renameOver(const std::string& from, const std::string& to) {
#ifdef _WIN32
  (void)::remove(to.c_str());
#endif
  return ::rename(from.c_str(), to.c_str()) == 0;
}

bool readWholeFile(const std::string& path, std::vector<uint8_t>* out) {
  FILE* f = ::fopen(path.c_str(), "rb");
  if (!f) return false;
  out->clear();
  uint8_t buf[16384];
  size_t n;
  while ((n = ::fread(buf, 1, sizeof(buf), f)) > 0) {
    out->insert(out->end(), buf, buf + n);
  }
  const bool ok = ::ferror(f) == 0;
  ::fclose(f);
  if (!ok) out->clear();
  return ok;
}

bool writeWholeFileAtomic(const std::string& path, const void* data, size_t n) {
  const std::string tmp = path + ".tmp";
  FILE* f = ::fopen(tmp.c_str(), "wb");
  if (!f) return false;
  const bool wrote = (n == 0) || (::fwrite(data, 1, n, f) == n);
  if (wrote) syncHandle(f);
  ::fclose(f);
  if (!wrote || !renameOver(tmp, path)) {
    removeFile(tmp);
    return false;
  }
  return true;
}

// ── Little-endian binary codec ───────────────────────────────────────────────

struct BufWriter {
  std::vector<uint8_t> buf;

  void u32(uint32_t v) {
    buf.push_back(static_cast<uint8_t>(v));
    buf.push_back(static_cast<uint8_t>(v >> 8));
    buf.push_back(static_cast<uint8_t>(v >> 16));
    buf.push_back(static_cast<uint8_t>(v >> 24));
  }
  void i64(int64_t v) {
    const uint64_t u = static_cast<uint64_t>(v);
    for (int i = 0; i < 8; ++i) {
      buf.push_back(static_cast<uint8_t>(u >> (i * 8)));
    }
  }
  void str(const std::string& s) {
    u32(static_cast<uint32_t>(s.size()));
    buf.insert(buf.end(), s.begin(), s.end());
  }
};

struct BufReader {
  const uint8_t* p = nullptr;
  size_t n = 0;
  size_t off = 0;
  bool ok = true;

  BufReader(const uint8_t* data, size_t len) : p(data), n(len) {}

  bool need(size_t k) {
    if (!ok || off + k > n) {
      ok = false;
      return false;
    }
    return true;
  }
  uint32_t u32() {
    if (!need(4)) return 0;
    const uint32_t v = static_cast<uint32_t>(p[off]) |
                       (static_cast<uint32_t>(p[off + 1]) << 8) |
                       (static_cast<uint32_t>(p[off + 2]) << 16) |
                       (static_cast<uint32_t>(p[off + 3]) << 24);
    off += 4;
    return v;
  }
  int64_t i64() {
    if (!need(8)) return 0;
    uint64_t v = 0;
    for (size_t i = 0; i < 8; ++i) {
      v |= static_cast<uint64_t>(p[off + i]) << (i * 8);
    }
    off += 8;
    return static_cast<int64_t>(v);
  }
  std::string str() {
    const uint32_t len = u32();
    if (!need(len)) return std::string();
    std::string s(reinterpret_cast<const char*>(p + off), len);
    off += len;
    return s;
  }
};

// ── On-disk formats ──────────────────────────────────────────────────────────

const uint32_t kMetaMagic = 0x4d43484eu;   // "NHCM"
const uint32_t kMetaVersion = 1u;
const uint32_t kIndexMagic = 0x4943484eu;  // "NHCI"
const uint32_t kIndexVersion = 1u;

/// One index-log record: the 64-char key hash, the body size and the last
/// access time. A negative body size is a tombstone.
const size_t kIndexRecordSize = 64 + 8 + 8;

struct Meta {
  std::string url;
  std::string method;
  int64_t statusCode = 0;
  std::vector<RawHeader> headers;
  /// The request headers named by the response's `Vary`, holding the values the
  /// stored request carried. Names alone would suffice for keying; the values
  /// let `lookup` reject a variant mismatch.
  std::vector<RawHeader> varied;
  int64_t storedAtMs = 0;
  int64_t freshnessLifetimeMs = -1;
  std::string etag;
  std::string lastModified;
  int64_t bodyBytes = 0;
  int64_t lastAccessMs = 0;
  int64_t hitCount = 0;
};

std::vector<uint8_t> encodeMeta(const Meta& m) {
  BufWriter w;
  w.u32(kMetaMagic);
  w.u32(kMetaVersion);
  w.str(m.url);
  w.str(m.method);
  w.i64(m.statusCode);
  w.u32(static_cast<uint32_t>(m.headers.size()));
  for (const RawHeader& h : m.headers) {
    w.str(h.name);
    w.str(h.value);
  }
  w.u32(static_cast<uint32_t>(m.varied.size()));
  for (const RawHeader& h : m.varied) {
    w.str(h.name);
    w.str(h.value);
  }
  w.i64(m.storedAtMs);
  w.i64(m.freshnessLifetimeMs);
  w.str(m.etag);
  w.str(m.lastModified);
  w.i64(m.bodyBytes);
  w.i64(m.lastAccessMs);
  w.i64(m.hitCount);
  return std::move(w.buf);
}

bool decodeMeta(const std::vector<uint8_t>& bytes, Meta* out) {
  BufReader r(bytes.data(), bytes.size());
  if (r.u32() != kMetaMagic) return false;
  if (r.u32() != kMetaVersion) return false;

  Meta m;
  m.url = r.str();
  m.method = r.str();
  m.statusCode = r.i64();

  const uint32_t headerCount = r.u32();
  if (!r.ok || headerCount > 4096) return false;
  m.headers.reserve(headerCount);
  for (uint32_t i = 0; i < headerCount && r.ok; ++i) {
    RawHeader h;
    h.name = r.str();
    h.value = r.str();
    m.headers.push_back(std::move(h));
  }

  const uint32_t variedCount = r.u32();
  if (!r.ok || variedCount > 256) return false;
  m.varied.reserve(variedCount);
  for (uint32_t i = 0; i < variedCount && r.ok; ++i) {
    RawHeader h;
    h.name = r.str();
    h.value = r.str();
    m.varied.push_back(std::move(h));
  }

  m.storedAtMs = r.i64();
  m.freshnessLifetimeMs = r.i64();
  m.etag = r.str();
  m.lastModified = r.str();
  m.bodyBytes = r.i64();
  m.lastAccessMs = r.i64();
  m.hitCount = r.i64();
  if (!r.ok) return false;

  *out = std::move(m);
  return true;
}

// ── Small string helpers ─────────────────────────────────────────────────────

std::string hashHex(const std::string& s) {
  return hexSha256(s.data(), s.size());
}

bool isHexKey(const std::string& s) {
  if (s.size() != 64) return false;
  for (char c : s) {
    const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (!hex) return false;
  }
  return true;
}

/// Keys become file names, so anything that is not already a 64-char hex digest
/// gets hashed: a caller-supplied key can never escape the entries directory.
std::string safeKey(const std::string& key) {
  return isHexKey(key) ? key : hashHex(key);
}

std::string asciiUpper(std::string s) {
  for (char& c : s) {
    if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
  }
  return s;
}

std::string headerValue(const std::vector<RawHeader>& headers,
                        const std::string& name) {
  const RawHeader* h = findHeader(headers, name);
  return h ? h->value : std::string();
}

/// All values for `name`, comma-joined — `Vary` and `Cache-Control` may legally
/// arrive split across several field lines.
std::string joinedHeaderValues(const std::vector<RawHeader>& headers,
                               const std::string& name) {
  std::string out;
  for (const RawHeader& h : headers) {
    if (!asciiEqualIgnoreCase(h.name, name)) continue;
    if (!out.empty()) out += ", ";
    out += h.value;
  }
  return out;
}

std::vector<std::string> splitComma(const std::string& value) {
  std::vector<std::string> out;
  size_t start = 0;
  for (;;) {
    const size_t comma = value.find(',', start);
    const size_t end = (comma == std::string::npos) ? value.size() : comma;
    std::string token = trimAsciiSpace(value.substr(start, end - start));
    if (!token.empty()) out.push_back(std::move(token));
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  return out;
}

/// Lowercased `Vary` field names, deduplicated. `*` collapses to a single `"*"`
/// entry so callers can reject the response outright.
std::vector<std::string> varyNames(
    const std::vector<RawHeader>& responseHeaders) {
  std::vector<std::string> names;
  for (const std::string& token :
       splitComma(joinedHeaderValues(responseHeaders, "Vary"))) {
    const std::string lower = asciiLower(token);
    if (lower == "*") return std::vector<std::string>{std::string("*")};
    if (std::find(names.begin(), names.end(), lower) == names.end()) {
      names.push_back(lower);
    }
  }
  return names;
}

bool parseUInt(const std::string& s, int64_t* out) {
  if (s.empty()) return false;
  int64_t v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return false;
    if (v > (int64_t{1} << 40)) return false;  // absurd; reject before overflow
    v = v * 10 + (c - '0');
  }
  *out = v;
  return true;
}

// ── Civil-date arithmetic ────────────────────────────────────────────────────
//
// `timegm` is missing on Windows and `strptime` on MSVC, so both conversions are
// Howard Hinnant's days-from-civil pair: exact across the whole proleptic
// Gregorian range, with no locale, TZ database or global state involved.

int64_t daysFromCivil(int64_t y, unsigned m, unsigned d) {
  y -= (m <= 2) ? 1 : 0;
  const int64_t era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned doy = (153u * (m + (m > 2 ? -3u : 9u)) + 2u) / 5u + d - 1u;
  const unsigned doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;
  return era * 146097 + static_cast<int64_t>(doe) - 719468;
}

void civilFromDays(int64_t z, int64_t* year, unsigned* month, unsigned* day) {
  z += 719468;
  const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  const unsigned doe = static_cast<unsigned>(z - era * 146097);
  const unsigned yoe =
      (doe - doe / 1460u + doe / 36524u - doe / 146096u) / 365u;
  const int64_t y = static_cast<int64_t>(yoe) + era * 400;
  const unsigned doy = doe - (365u * yoe + yoe / 4u - yoe / 100u);
  const unsigned mp = (5u * doy + 2u) / 153u;
  const unsigned d = doy - (153u * mp + 2u) / 5u + 1u;
  const unsigned m = mp + (mp < 10u ? 3u : -9u);
  *year = y + ((m <= 2u) ? 1 : 0);
  *month = m;
  *day = d;
}

const char* const kWeekdays[7] = {"Sun", "Mon", "Tue", "Wed",
                                  "Thu", "Fri", "Sat"};
const char* const kMonths[12] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

int monthFromName(const std::string& token) {
  if (token.size() < 3) return -1;
  const std::string head = asciiLower(token.substr(0, 3));
  for (int i = 0; i < 12; ++i) {
    if (head == asciiLower(std::string(kMonths[i]))) return i + 1;
  }
  return -1;
}

// ── Index and entry state ────────────────────────────────────────────────────

struct IndexEntry {
  int64_t bodyBytes = 0;
  int64_t lastAccessMs = 0;
  int64_t hitCount = 0;
};

/// Every mutable piece of the cache. It is a standalone type rather than the
/// body of `HttpCache::Impl` because `CacheWriter` has to reach it on commit and
/// cannot name a private nested type of a class it is not a friend of.
struct CacheCore {
  RawCacheConfig cfg{};
  std::string root;
  std::string entriesDir;
  std::string indexPath;

  mutable std::shared_mutex indexMu;
  std::unordered_map<std::string, IndexEntry> index;
  /// Base key hash → the `Vary` field names the stored response declared. This
  /// is what lets `keyFor` extend a key before any response is in hand.
  std::unordered_map<std::string, std::vector<std::string>> varyByBase;
  int64_t sizeBytes = 0;

  std::mutex prefetchMu;
  std::unordered_set<std::string> prefetching;

  std::atomic<int64_t> hitCount{0};
  std::atomic<int64_t> missCount{0};
  std::atomic<int64_t> revalidationCount{0};
  std::atomic<int64_t> evictionCount{0};

  std::mutex logMu;
  FILE* logFile = nullptr;

  // Lock order, wherever two are held at once: indexMu → logMu. `ioMu` is only
  // ever taken alone.
  std::thread ioThread;
  std::mutex ioMu;
  std::condition_variable ioCv;
  bool ioStop = false;
  bool evictPending = false;
  bool scanPending = true;
  std::unordered_set<std::string> touchDirty;

  // ── Paths ──

  std::string entryBase(const std::string& key) const {
    return entriesDir + "/" + key;
  }
  std::string metaPath(const std::string& key) const {
    return entryBase(key) + ".m";
  }
  std::string bodyPath(const std::string& key) const {
    return entryBase(key) + ".b";
  }

  // ── Metadata IO ──

  bool loadMeta(const std::string& key, Meta* out) const {
    std::vector<uint8_t> bytes;
    if (!readWholeFile(metaPath(key), &bytes)) return false;
    return decodeMeta(bytes, out);
  }

  bool storeMeta(const std::string& key, const Meta& m) const {
    const std::vector<uint8_t> bytes = encodeMeta(m);
    return writeWholeFileAtomic(metaPath(key), bytes.data(), bytes.size());
  }

  // ── Index log ──

  void appendIndexRecord(const std::string& key, int64_t bodyBytes,
                         int64_t lastAccessMs) {
    BufWriter w;
    w.buf.insert(w.buf.end(), key.begin(), key.end());
    w.i64(bodyBytes);
    w.i64(lastAccessMs);
    if (w.buf.size() != kIndexRecordSize) return;  // never write a short record

    std::lock_guard<std::mutex> lk(logMu);
    if (!logFile) return;
    (void)::fwrite(w.buf.data(), 1, w.buf.size(), logFile);
  }

  void syncLog() {
    std::lock_guard<std::mutex> lk(logMu);
    if (logFile) syncHandle(logFile);
  }

  /// Rewrites `index.bin` from the in-memory map, closing and reopening the
  /// append handle around it. Used for open-time compaction and for `clear`.
  bool rewriteIndex() {
    {
      std::lock_guard<std::mutex> lk(logMu);
      if (logFile) {
        ::fclose(logFile);
        logFile = nullptr;
      }
    }

    BufWriter w;
    w.u32(kIndexMagic);
    w.u32(kIndexVersion);
    for (const auto& kv : index) {
      w.buf.insert(w.buf.end(), kv.first.begin(), kv.first.end());
      w.i64(kv.second.bodyBytes);
      w.i64(kv.second.lastAccessMs);
    }
    const bool ok = writeWholeFileAtomic(indexPath, w.buf.data(), w.buf.size());

    std::lock_guard<std::mutex> lk(logMu);
    logFile = ::fopen(indexPath.c_str(), "ab");
    return ok && logFile != nullptr;
  }

  /// Replays the append log into the map, last record per key winning, then
  /// compacts it back to disk. Called from `open` before the IO thread exists.
  bool loadIndex() {
    std::vector<uint8_t> bytes;
    if (readWholeFile(indexPath, &bytes) && bytes.size() >= 8) {
      BufReader r(bytes.data(), bytes.size());
      if (r.u32() == kIndexMagic && r.u32() == kIndexVersion) {
        while (r.off + kIndexRecordSize <= r.n) {
          const std::string key(reinterpret_cast<const char*>(r.p + r.off), 64);
          r.off += 64;
          const int64_t body = r.i64();
          const int64_t access = r.i64();
          if (!isHexKey(key)) break;  // torn tail: keep everything before it
          if (body < 0) {
            index.erase(key);
            continue;
          }
          IndexEntry& e = index[key];
          e.bodyBytes = body;
          e.lastAccessMs = access;
        }
      }
    }
    sizeBytes = 0;
    for (const auto& kv : index) sizeBytes += kv.second.bodyBytes;
    return rewriteIndex();
  }

  // ── Mutations ──

  void requestEvict() {
    {
      std::lock_guard<std::mutex> lk(ioMu);
      evictPending = true;
    }
    ioCv.notify_one();
  }

  void markTouched(const std::string& key) {
    {
      std::lock_guard<std::mutex> lk(ioMu);
      touchDirty.insert(key);
    }
    ioCv.notify_one();
  }

  void onCommitted(const std::string& key, int64_t bodyBytes,
                   const std::string& baseHash,
                   const std::vector<std::string>& vary) {
    const int64_t now = wallClockMs();
    {
      std::unique_lock<std::shared_mutex> lk(indexMu);
      IndexEntry& e = index[key];
      sizeBytes += bodyBytes - e.bodyBytes;
      e.bodyBytes = bodyBytes;
      e.lastAccessMs = now;
      e.hitCount = 0;
      if (vary.empty()) {
        varyByBase.erase(baseHash);
      } else {
        varyByBase[baseHash] = vary;
      }
    }
    appendIndexRecord(key, bodyBytes, now);
    requestEvict();
  }

  void dropEntry(const std::string& key) {
    {
      std::unique_lock<std::shared_mutex> lk(indexMu);
      auto it = index.find(key);
      if (it == index.end()) return;
      sizeBytes -= it->second.bodyBytes;
      if (sizeBytes < 0) sizeBytes = 0;
      index.erase(it);
    }
    appendIndexRecord(key, -1, wallClockMs());
    removeFile(metaPath(key));
    removeFile(bodyPath(key));
  }

  // ── IO thread ──

  void evictNow() {
    if (cfg.maxSizeBytes <= 0) return;  // unbounded by configuration

    std::vector<std::string> victims;
    {
      std::unique_lock<std::shared_mutex> lk(indexMu);
      if (sizeBytes <= cfg.maxSizeBytes) return;
      // Evict down to 90 % of the cap so a steady stream of commits does not
      // pay for an eviction pass on every single one.
      const int64_t target = (cfg.maxSizeBytes / 10) * 9;

      std::vector<std::pair<int64_t, std::string>> byAge;
      byAge.reserve(index.size());
      for (const auto& kv : index) {
        byAge.emplace_back(kv.second.lastAccessMs, kv.first);
      }
      std::sort(byAge.begin(), byAge.end(),
                [](const std::pair<int64_t, std::string>& a,
                   const std::pair<int64_t, std::string>& b) {
                  return a.first < b.first;
                });

      for (const std::pair<int64_t, std::string>& aged : byAge) {
        if (sizeBytes <= target) break;
        auto it = index.find(aged.second);
        if (it == index.end()) continue;
        sizeBytes -= it->second.bodyBytes;
        index.erase(it);
        victims.push_back(aged.second);
      }
      if (sizeBytes < 0) sizeBytes = 0;
    }

    if (victims.empty()) return;
    const int64_t now = wallClockMs();
    for (const std::string& key : victims) {
      appendIndexRecord(key, -1, now);
      removeFile(metaPath(key));
      removeFile(bodyPath(key));
    }
    evictionCount.fetch_add(static_cast<int64_t>(victims.size()));
    syncLog();
  }

  /// Persists coalesced hit counts and access times. Rewriting one metadata file
  /// per cache hit would double the IO of a hit, so hits only dirty the
  /// in-memory entry and land here at most once per IO tick.
  void flushTouched(const std::unordered_set<std::string>& keys) {
    if (keys.empty()) return;
    for (const std::string& key : keys) {
      IndexEntry snapshot;
      {
        std::shared_lock<std::shared_mutex> lk(indexMu);
        auto it = index.find(key);
        if (it == index.end()) continue;
        snapshot = it->second;
      }
      Meta m;
      if (!loadMeta(key, &m)) continue;
      m.lastAccessMs = snapshot.lastAccessMs;
      m.hitCount = snapshot.hitCount;
      (void)storeMeta(key, m);
    }
    syncLog();
  }

  /// Restores the per-entry state the index log does not carry (hit counts, the
  /// `Vary` map, true body sizes) and reaps entries whose files vanished. It
  /// runs off the request path so `open` stays a handful of syscalls even with
  /// thousands of entries.
  void scanEntries() {
    std::vector<std::string> keys;
    {
      std::shared_lock<std::shared_mutex> lk(indexMu);
      keys.reserve(index.size());
      for (const auto& kv : index) keys.push_back(kv.first);
    }

    std::vector<std::string> dead;
    std::unordered_map<std::string, std::vector<std::string>> vary;
    std::unordered_map<std::string, IndexEntry> restored;

    for (const std::string& key : keys) {
      Meta m;
      int64_t actual = 0;
      if (!loadMeta(key, &m) || !fileSize(bodyPath(key), &actual)) {
        dead.push_back(key);
        continue;
      }

      IndexEntry e;
      e.bodyBytes = actual;
      e.lastAccessMs = m.lastAccessMs;
      e.hitCount = m.hitCount;
      restored[key] = e;

      if (!m.varied.empty()) {
        std::vector<std::string> names;
        names.reserve(m.varied.size());
        for (const RawHeader& h : m.varied) names.push_back(asciiLower(h.name));
        const std::string baseHash =
            hashHex(asciiUpper(m.method) + "\n" + canonicalizeUrl(m.url));
        vary[baseHash] = std::move(names);
      }
    }

    {
      std::unique_lock<std::shared_mutex> lk(indexMu);
      for (const auto& kv : restored) {
        auto it = index.find(kv.first);
        if (it == index.end()) continue;  // evicted or cleared while scanning
        sizeBytes += kv.second.bodyBytes - it->second.bodyBytes;
        it->second = kv.second;
      }
      for (auto& kv : vary) varyByBase[kv.first] = std::move(kv.second);
      for (const std::string& key : dead) {
        auto it = index.find(key);
        if (it == index.end()) continue;
        sizeBytes -= it->second.bodyBytes;
        index.erase(it);
      }
      if (sizeBytes < 0) sizeBytes = 0;
    }

    const int64_t now = wallClockMs();
    for (const std::string& key : dead) {
      appendIndexRecord(key, -1, now);
      removeFile(metaPath(key));
      removeFile(bodyPath(key));
    }
    requestEvict();
  }

  void ioLoop() {
    for (;;) {
      bool doScan = false;
      bool doEvict = false;
      bool stopping = false;
      std::unordered_set<std::string> dirty;
      {
        std::unique_lock<std::mutex> lk(ioMu);
        ioCv.wait_for(lk, std::chrono::milliseconds(500), [this] {
          return ioStop || evictPending || scanPending || !touchDirty.empty();
        });
        doScan = scanPending;
        scanPending = false;
        doEvict = evictPending;
        evictPending = false;
        stopping = ioStop;
        dirty.swap(touchDirty);
      }

      if (doScan) scanEntries();
      flushTouched(dirty);
      if (doEvict) evictNow();
      if (stopping) break;
    }

    // Drain whatever arrived during the final pass, so shutdown never loses a
    // hit count or leaves the append log unsynced.
    std::unordered_set<std::string> tail;
    {
      std::lock_guard<std::mutex> lk(ioMu);
      tail.swap(touchDirty);
    }
    flushTouched(tail);
    evictNow();
    syncLog();
  }
};

/// True when the request's values for the stored `Vary` fields still match. The
/// key already encodes them, but a key computed before the `Vary` was known can
/// land on an entry selected by different headers.
bool variantMatches(const Meta& m,
                    const std::vector<RawHeader>& requestHeaders) {
  for (const RawHeader& stored : m.varied) {
    if (headerValue(requestHeaders, stored.name) != stored.value) return false;
  }
  return true;
}

}  // namespace cachefs

struct HttpCache::Impl : cachefs::CacheCore {};

// ── Policy: pure functions, no filesystem ────────────────────────────────────

HttpCache::CacheControl HttpCache::parseCacheControl(
    const std::vector<RawHeader>& headers) {
  using namespace cachefs;

  CacheControl cc;
  for (const std::string& token :
       splitComma(joinedHeaderValues(headers, "Cache-Control"))) {
    const size_t eq = token.find('=');
    const std::string name = asciiLower(trimAsciiSpace(
        eq == std::string::npos ? token : token.substr(0, eq)));
    std::string value = (eq == std::string::npos)
                            ? std::string()
                            : trimAsciiSpace(token.substr(eq + 1));
    if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
      value = value.substr(1, value.size() - 2);
    }

    if (name == "no-store") {
      cc.noStore = true;
    } else if (name == "no-cache") {
      cc.noCache = true;
    } else if (name == "private") {
      cc.isPrivate = true;
    } else if (name == "must-revalidate" || name == "proxy-revalidate") {
      cc.mustRevalidate = true;
    } else if (name == "immutable") {
      cc.immutable = true;
    } else if (name == "max-age" || name == "s-maxage") {
      int64_t seconds = 0;
      if (parseUInt(value, &seconds)) {
        if (name == "max-age") {
          cc.maxAgeMs = seconds * 1000;
        } else {
          cc.sMaxAgeMs = seconds * 1000;
        }
      }
    }
  }
  return cc;
}

int64_t HttpCache::parseHttpDate(const std::string& value) {
  using namespace cachefs;

  // Normalising the three legal spellings to whitespace-separated tokens turns
  // three grammars into one: IMF-fixdate and RFC 850 then differ only in year
  // width, and asctime only in field order.
  std::string norm;
  norm.reserve(value.size());
  for (char c : value) norm.push_back((c == ',' || c == '-') ? ' ' : c);

  std::vector<std::string> tok;
  size_t i = 0;
  while (i < norm.size()) {
    while (i < norm.size() && (norm[i] == ' ' || norm[i] == '\t')) ++i;
    const size_t start = i;
    while (i < norm.size() && norm[i] != ' ' && norm[i] != '\t') ++i;
    if (i > start) tok.push_back(norm.substr(start, i - start));
  }
  if (tok.size() < 5) return -1;

  std::string dayTok, monthTok, yearTok, timeTok;
  if (monthFromName(tok[1]) > 0) {
    // asctime: "Sun Nov  6 08:49:37 1994"
    monthTok = tok[1];
    dayTok = tok[2];
    timeTok = tok[3];
    yearTok = tok[4];
  } else {
    // IMF-fixdate / RFC 850: "Sun 06 Nov 1994 08:49:37 GMT"
    dayTok = tok[1];
    monthTok = tok[2];
    yearTok = tok[3];
    timeTok = tok[4];
  }

  const int month = monthFromName(monthTok);
  if (month < 0) return -1;

  int64_t day = 0;
  int64_t year = 0;
  if (!parseUInt(dayTok, &day) || !parseUInt(yearTok, &year)) return -1;
  if (day < 1 || day > 31) return -1;
  if (yearTok.size() <= 2) {
    // RFC 850's two-digit years, windowed the way RFC 6265 §5.1.1 specifies.
    year += (year <= 69) ? 2000 : 1900;
  }
  if (year < 1601 || year > 9999) return -1;

  const size_t c1 = timeTok.find(':');
  if (c1 == std::string::npos) return -1;
  const size_t c2 = timeTok.find(':', c1 + 1);
  if (c2 == std::string::npos) return -1;

  int64_t hour = 0;
  int64_t minute = 0;
  int64_t second = 0;
  if (!parseUInt(timeTok.substr(0, c1), &hour)) return -1;
  if (!parseUInt(timeTok.substr(c1 + 1, c2 - c1 - 1), &minute)) return -1;
  if (!parseUInt(timeTok.substr(c2 + 1), &second)) return -1;
  if (hour > 23 || minute > 59 || second > 60) return -1;
  if (second == 60) second = 59;  // leap second: clamp rather than reject

  const int64_t days = daysFromCivil(year, static_cast<unsigned>(month),
                                     static_cast<unsigned>(day));
  return days * 86400000 + hour * 3600000 + minute * 60000 + second * 1000;
}

std::string HttpCache::formatHttpDate(int64_t epochMs) {
  using namespace cachefs;

  int64_t seconds = epochMs / 1000;
  if (epochMs < 0 && (epochMs % 1000) != 0) --seconds;  // floor, not truncate
  int64_t days = seconds / 86400;
  int64_t rem = seconds % 86400;
  if (rem < 0) {
    rem += 86400;
    --days;
  }

  int64_t year = 0;
  unsigned month = 0;
  unsigned day = 0;
  civilFromDays(days, &year, &month, &day);

  int64_t weekday = (days + 4) % 7;  // 1970-01-01 was a Thursday
  if (weekday < 0) weekday += 7;

  char buf[64];
  ::snprintf(buf, sizeof(buf), "%s, %02d %s %04lld %02d:%02d:%02d GMT",
             kWeekdays[weekday], static_cast<int>(day), kMonths[month - 1],
             static_cast<long long>(year), static_cast<int>(rem / 3600),
             static_cast<int>((rem % 3600) / 60), static_cast<int>(rem % 60));
  return std::string(buf);
}

bool HttpCache::isStorable(int64_t statusCode, const std::string& method,
                           const std::vector<RawHeader>& responseHeaders) {
  using namespace cachefs;

  const std::string upper = asciiUpper(method);
  if (upper != "GET" && upper != "HEAD") return false;

  switch (statusCode) {
    case 200:
    case 203:
    case 301:
    case 308:
      break;
    default:
      return false;
  }

  const CacheControl cc = parseCacheControl(responseHeaders);
  if (cc.noStore || cc.isPrivate) return false;

  const std::vector<std::string> vary = varyNames(responseHeaders);
  return vary.empty() || vary[0] != "*";
}

int64_t HttpCache::freshnessLifetimeMs(
    const std::vector<RawHeader>& responseHeaders, int64_t responseTimeMs) {
  using namespace cachefs;

  const CacheControl cc = parseCacheControl(responseHeaders);
  // `no-cache` does not forbid storage, it forbids reuse without revalidation.
  // A zero lifetime is exactly that: every lookup comes back Stale.
  if (cc.noCache) return 0;
  if (cc.sMaxAgeMs >= 0) return cc.sMaxAgeMs;
  if (cc.maxAgeMs >= 0) return cc.maxAgeMs;

  const int64_t dateMs = parseHttpDate(headerValue(responseHeaders, "Date"));
  const int64_t originMs = (dateMs >= 0) ? dateMs : responseTimeMs;

  const std::string expires = headerValue(responseHeaders, "Expires");
  if (!expires.empty()) {
    const int64_t expiresMs = parseHttpDate(expires);
    // An unparseable `Expires` means "already expired" — RFC 9111 §5.3.
    if (expiresMs < 0) return 0;
    return (expiresMs > originMs) ? (expiresMs - originMs) : 0;
  }

  const int64_t lastModifiedMs =
      parseHttpDate(headerValue(responseHeaders, "Last-Modified"));
  if (lastModifiedMs >= 0 && originMs > lastModifiedMs) {
    const int64_t heuristic = (originMs - lastModifiedMs) / 10;
    const int64_t cap = int64_t{24} * 3600 * 1000;
    return (heuristic > cap) ? cap : heuristic;
  }

  return -1;
}

// ── CacheWriter ──────────────────────────────────────────────────────────────

struct CacheWriter::Impl {
  /// Borrowed. `RequestTask` owns the writer and a `shared_ptr` to the cache for
  /// the writer's whole lifetime, so the core always outlives it.
  cachefs::CacheCore* core = nullptr;
  std::string key;
  std::string baseHash;
  std::vector<std::string> vary;
  cachefs::Meta meta;
  FILE* file = nullptr;
  std::string tmpPath;
  int64_t written = 0;
  int64_t maxEntryBytes = 0;  // <= 0 means unlimited
  bool finished = false;

  void closeFile() {
    if (!file) return;
    ::fclose(file);
    file = nullptr;
  }
};

CacheWriter::CacheWriter() : impl_(new Impl()) {}

CacheWriter::~CacheWriter() {
  // A writer dropped mid-transfer — cancellation, transport error, an early
  // return — must never leave a renamed half body behind.
  if (!impl_->finished) discard();
}

bool CacheWriter::active() const {
  return !impl_->finished && impl_->file != nullptr;
}

bool CacheWriter::write(const uint8_t* data, size_t n) {
  using namespace cachefs;

  if (!active()) return false;
  if (n == 0) return true;

  if (impl_->maxEntryBytes > 0 &&
      impl_->written + static_cast<int64_t>(n) > impl_->maxEntryBytes) {
    discard();
    return false;
  }
  if (::fwrite(data, 1, n, impl_->file) != n) {
    discard();
    return false;
  }
  impl_->written += static_cast<int64_t>(n);
  return true;
}

void CacheWriter::discard() {
  using namespace cachefs;

  if (impl_->finished) return;
  impl_->finished = true;
  impl_->closeFile();
  if (!impl_->tmpPath.empty()) removeFile(impl_->tmpPath);
}

void CacheWriter::commit() {
  using namespace cachefs;

  if (!active()) return;

  syncHandle(impl_->file);
  impl_->closeFile();

  const int64_t now = wallClockMs();
  Meta& m = impl_->meta;
  m.bodyBytes = impl_->written;
  m.storedAtMs = now;
  m.lastAccessMs = now;
  m.hitCount = 0;
  // Freshness is computed here, not in `beginWrite`: `storedAtMs` is the instant
  // the entry becomes usable, and the two can be far apart on a slow transfer.
  m.freshnessLifetimeMs = HttpCache::freshnessLifetimeMs(m.headers, now);

  const std::string finalBody = impl_->core->bodyPath(impl_->key);
  if (!impl_->core->storeMeta(impl_->key, m) ||
      !renameOver(impl_->tmpPath, finalBody)) {
    discard();
    removeFile(impl_->core->metaPath(impl_->key));  // no orphan metadata
    return;
  }

  impl_->finished = true;
  impl_->core->onCommitted(impl_->key, impl_->written, impl_->baseHash,
                           impl_->vary);
}

// ── HttpCache ────────────────────────────────────────────────────────────────

HttpCache::HttpCache() : impl_(new Impl()) {}

HttpCache::~HttpCache() {
  using namespace cachefs;

  {
    std::lock_guard<std::mutex> lk(impl_->ioMu);
    impl_->ioStop = true;
  }
  impl_->ioCv.notify_all();
  if (impl_->ioThread.joinable()) impl_->ioThread.join();

  std::lock_guard<std::mutex> lk(impl_->logMu);
  if (impl_->logFile) {
    syncHandle(impl_->logFile);
    ::fclose(impl_->logFile);
    impl_->logFile = nullptr;
  }
}

std::shared_ptr<HttpCache> HttpCache::open(const RawCacheConfig& cfg) {
  using namespace cachefs;

  if (!cfg.enabled || cfg.directory.empty()) return nullptr;

  std::shared_ptr<HttpCache> cache(new HttpCache());
  CacheCore& core = *cache->impl_;
  core.cfg = cfg;

  std::string base = cfg.directory;
  while (base.size() > 1 && (base.back() == '/' || base.back() == '\\')) {
    base.pop_back();
  }
  core.root = base + "/nitro_http_cache/v1";
  core.entriesDir = core.root + "/e";
  core.indexPath = core.root + "/index.bin";

  // An unusable directory is not an error: HTTP still works, just without a
  // disk behind it. Callers read null as "no caching".
  if (!makeDirs(core.entriesDir)) return nullptr;
  if (!core.loadIndex()) return nullptr;

  core.ioThread = std::thread([&core]() { core.ioLoop(); });
  return cache;
}

std::string HttpCache::keyFor(
    const std::string& method, const std::string& url,
    const std::vector<RawHeader>& requestHeaders) const {
  using namespace cachefs;

  const std::string base = asciiUpper(method) + "\n" + canonicalizeUrl(url);
  const std::string baseHash = hashHex(base);

  std::vector<std::string> vary;
  {
    std::shared_lock<std::shared_mutex> lk(impl_->indexMu);
    auto it = impl_->varyByBase.find(baseHash);
    if (it == impl_->varyByBase.end()) return baseHash;
    vary = it->second;
  }
  if (vary.empty()) return baseHash;

  std::string extended = base;
  for (const std::string& name : vary) {
    extended += "\n";
    extended += name;
    extended += ":";
    extended += headerValue(requestHeaders, name);
  }
  return hashHex(extended);
}

CacheHit HttpCache::lookup(const std::string& key, RawCacheMode mode,
                           const std::string& method,
                           const std::vector<RawHeader>& requestHeaders,
                           bool afterRevalidation) {
  using namespace cachefs;

  CacheHit hit;

  // `missCount` counts lookups that found NOTHING USABLE, and nothing else.
  // Two things are deliberately excluded, both because `CacheStats.hitRate` is
  // derived from `hitCount + missCount` and both would skew it:
  //
  //   * A `Stale` outcome. The entry is about to be revalidated, not
  //     re-fetched, and `revalidationCount` is documented as counting as
  //     "neither hitCount nor missCount".
  //   * The re-read that follows a 304 (`afterRevalidation`). It is the same
  //     request asking the same question a second time, and it SERVES the
  //     stored body — counting it again would put one request in two buckets.
  const auto countMiss = [this, afterRevalidation]() {
    if (!afterRevalidation) impl_->missCount.fetch_add(1);
  };

  const std::string upper = asciiUpper(method);
  if (upper != "GET" && upper != "HEAD") {
    hit.outcome = CacheOutcome::Uncacheable;
    return hit;
  }
  if (mode == RawCacheMode::RAWCACHEMODE_NO_STORE) {
    hit.outcome = CacheOutcome::Uncacheable;
    return hit;
  }
  if (mode == RawCacheMode::RAWCACHEMODE_BYPASS) {
    // Not counted as a miss: the caller never asked the cache anything.
    hit.outcome = CacheOutcome::Miss;
    return hit;
  }

  const std::string safe = safeKey(key);
  {
    std::shared_lock<std::shared_mutex> lk(impl_->indexMu);
    if (impl_->index.find(safe) == impl_->index.end()) {
      lk.unlock();
      countMiss();
      hit.outcome = CacheOutcome::Miss;
      return hit;
    }
  }

  Meta meta;
  if (!impl_->loadMeta(safe, &meta)) {
    impl_->dropEntry(safe);  // indexed but unreadable: reap it
    countMiss();
    hit.outcome = CacheOutcome::Miss;
    return hit;
  }
  if (!variantMatches(meta, requestHeaders)) {
    // The entry is valid, just for a different variant. Leave it alone.
    countMiss();
    hit.outcome = CacheOutcome::Miss;
    return hit;
  }

  hit.statusCode = meta.statusCode;
  hit.headers = meta.headers;
  hit.etag = meta.etag;
  hit.lastModified = meta.lastModified;
  hit.contentLength = meta.bodyBytes;

  const auto attachBody = [this, &safe, &hit]() -> bool {
    const std::string path = impl_->bodyPath(safe);
    if (!readWholeFile(path, &hit.body)) return false;
    // Both are populated: the buffered path takes `body`, the streamed path
    // replays `bodyPath` from disk instead of holding it all in memory.
    hit.bodyPath = path;
    hit.contentLength = static_cast<int64_t>(hit.body.size());
    return true;
  };

  if (mode == RawCacheMode::RAWCACHEMODE_REFRESH) {
    // Force the conditional request even when the entry is still fresh — that
    // is the entire point of the mode.
    hit.outcome = CacheOutcome::Stale;
    if (afterRevalidation) attachBody();
    return hit;
  }

  const int64_t now = wallClockMs();
  const bool fresh = meta.freshnessLifetimeMs >= 0 &&
                     now < meta.storedAtMs + meta.freshnessLifetimeMs;
  if (!fresh) {
    // NOT counted as a miss yet. `CacheStats.revalidationCount` is documented
    // as counting as "neither hitCount nor missCount", and `hitRate` is derived
    // from those two — so a stale entry that still has a validator, and is
    // therefore about to be revalidated rather than re-fetched, must leave both
    // alone. Only the branch below, where nothing usable was found at all,
    // is a real miss.
    const bool hasValidator = !meta.etag.empty() || !meta.lastModified.empty();
    // `onlyIfCached` never returns Stale: Stale means "go revalidate", and this
    // mode must not touch the network at all.
    const bool mayRevalidate =
        mode != RawCacheMode::RAWCACHEMODE_ONLY_IF_CACHED;
    hit.outcome = (hasValidator && mayRevalidate) ? CacheOutcome::Stale
                                                  : CacheOutcome::Miss;
    if (hit.outcome == CacheOutcome::Miss) {
      countMiss();
      return hit;
    }
    // After a 304 the stored body IS the response, so the caller asks for it
    // here rather than paying for a file read on every ordinary stale lookup.
    // Only reachable with `afterRevalidation`, where the counters are frozen by
    // contract, so nothing is counted here.
    if (afterRevalidation && !attachBody()) {
      impl_->dropEntry(safe);
      CacheHit miss;
      miss.outcome = CacheOutcome::Miss;
      return miss;
    }
    return hit;
  }

  if (!attachBody()) {
    impl_->dropEntry(safe);
    countMiss();
    CacheHit miss;
    miss.outcome = CacheOutcome::Miss;
    return miss;
  }
  hit.outcome = CacheOutcome::Fresh;

  {
    std::unique_lock<std::shared_mutex> lk(impl_->indexMu);
    auto it = impl_->index.find(safe);
    if (it != impl_->index.end()) {
      it->second.lastAccessMs = now;
      it->second.hitCount += 1;
    }
  }
  impl_->markTouched(safe);
  if (!afterRevalidation) impl_->hitCount.fetch_add(1);
  return hit;
}

std::unique_ptr<CacheWriter> HttpCache::beginWrite(
    const std::string& key, int64_t statusCode,
    const std::vector<RawHeader>& responseHeaders,
    const std::vector<RawHeader>& requestHeaders, const std::string& method,
    const std::string& url) {
  using namespace cachefs;

  if (!isStorable(statusCode, method, responseHeaders)) return nullptr;

  const std::string upper = asciiUpper(method);
  const std::string base = upper + "\n" + canonicalizeUrl(url);
  const std::string baseHash = hashHex(base);

  // The caller's key predates this response, so a newly announced `Vary` is only
  // visible now. Storing under the extended key is what makes the *next*
  // request's `keyFor` — which will see the recorded `Vary` — land on this entry.
  const std::vector<std::string> vary = varyNames(responseHeaders);
  std::string effectiveKey = baseHash;
  std::vector<RawHeader> varied;
  if (!vary.empty()) {
    std::string extended = base;
    varied.reserve(vary.size());
    for (const std::string& name : vary) {
      const std::string value = headerValue(requestHeaders, name);
      extended += "\n";
      extended += name;
      extended += ":";
      extended += value;
      RawHeader h;
      h.name = name;
      h.value = value;
      varied.push_back(std::move(h));
    }
    effectiveKey = hashHex(extended);
  } else if (isHexKey(key)) {
    effectiveKey = key;
  }

  std::unique_ptr<CacheWriter> writer(new CacheWriter());
  CacheWriter::Impl& w = *writer->impl_;
  w.core = impl_.get();
  w.key = effectiveKey;
  w.baseHash = baseHash;
  w.vary = vary;
  w.maxEntryBytes = impl_->cfg.maxEntryBytes;
  w.tmpPath = impl_->bodyPath(effectiveKey) + ".tmp";

  w.meta.url = url;
  w.meta.method = upper;
  w.meta.statusCode = statusCode;
  w.meta.headers = responseHeaders;
  w.meta.varied = std::move(varied);
  w.meta.etag = headerValue(responseHeaders, "ETag");
  w.meta.lastModified = headerValue(responseHeaders, "Last-Modified");

  w.file = ::fopen(w.tmpPath.c_str(), "wb");
  if (!w.file) return nullptr;
  return writer;
}

void HttpCache::refreshMetadata(
    const std::string& key, const std::vector<RawHeader>& responseHeaders) {
  using namespace cachefs;

  const std::string safe = safeKey(key);
  Meta meta;
  if (!impl_->loadMeta(safe, &meta)) return;

  // RFC 9111 §4.3.4: a 304 updates the stored headers, but `Content-Length` and
  // `Content-Encoding` describe a body the 304 does not carry.
  const auto ignored = [](const RawHeader& h) {
    return asciiEqualIgnoreCase(h.name, "Content-Length") ||
           asciiEqualIgnoreCase(h.name, "Content-Encoding");
  };

  std::vector<std::string> replaced;
  for (const RawHeader& h : responseHeaders) {
    if (ignored(h)) continue;
    const std::string lower = asciiLower(h.name);
    if (std::find(replaced.begin(), replaced.end(), lower) == replaced.end()) {
      replaced.push_back(lower);
    }
  }

  // Every stored header the 304 names is dropped wholesale before the new ones
  // are appended, so a repeated field (Set-Cookie) is replaced as a set rather
  // than accumulating duplicates.
  std::vector<RawHeader> merged;
  merged.reserve(meta.headers.size() + responseHeaders.size());
  for (const RawHeader& h : meta.headers) {
    const std::string lower = asciiLower(h.name);
    if (std::find(replaced.begin(), replaced.end(), lower) != replaced.end()) {
      continue;
    }
    merged.push_back(h);
  }
  for (const RawHeader& h : responseHeaders) {
    if (ignored(h)) continue;
    merged.push_back(h);
  }

  const int64_t now = wallClockMs();
  meta.headers = std::move(merged);
  meta.storedAtMs = now;
  meta.lastAccessMs = now;
  meta.freshnessLifetimeMs = freshnessLifetimeMs(meta.headers, now);

  const std::string etag = headerValue(meta.headers, "ETag");
  if (!etag.empty()) meta.etag = etag;
  const std::string lastModified =
      headerValue(meta.headers, "Last-Modified");
  if (!lastModified.empty()) meta.lastModified = lastModified;

  if (!impl_->storeMeta(safe, meta)) return;

  {
    std::unique_lock<std::shared_mutex> lk(impl_->indexMu);
    auto it = impl_->index.find(safe);
    if (it != impl_->index.end()) it->second.lastAccessMs = now;
  }
  impl_->appendIndexRecord(safe, meta.bodyBytes, now);
  impl_->revalidationCount.fetch_add(1);
}

void HttpCache::clear() {
  using namespace cachefs;

  std::vector<std::string> keys;
  {
    std::unique_lock<std::shared_mutex> lk(impl_->indexMu);
    keys.reserve(impl_->index.size());
    for (const auto& kv : impl_->index) keys.push_back(kv.first);
    impl_->index.clear();
    impl_->varyByBase.clear();
    impl_->sizeBytes = 0;
    (void)impl_->rewriteIndex();
  }
  {
    // Dropped entries have nothing left to flush.
    std::lock_guard<std::mutex> lk(impl_->ioMu);
    impl_->touchDirty.clear();
  }
  for (const std::string& key : keys) {
    removeFile(impl_->metaPath(key));
    removeFile(impl_->bodyPath(key));
  }
}

RawCacheStats HttpCache::stats() const {
  RawCacheStats out;
  {
    std::shared_lock<std::shared_mutex> lk(impl_->indexMu);
    out.entryCount = static_cast<int64_t>(impl_->index.size());
    out.sizeBytes = impl_->sizeBytes;
  }
  out.hitCount = impl_->hitCount.load();
  out.missCount = impl_->missCount.load();
  out.revalidationCount = impl_->revalidationCount.load();
  out.evictionCount = impl_->evictionCount.load();
  return out;
}

bool HttpCache::claimPrefetch(const std::string& key) {
  std::lock_guard<std::mutex> lk(impl_->prefetchMu);
  return impl_->prefetching.insert(cachefs::safeKey(key)).second;
}

void HttpCache::releasePrefetch(const std::string& key) {
  std::lock_guard<std::mutex> lk(impl_->prefetchMu);
  impl_->prefetching.erase(cachefs::safeKey(key));
}

}  // namespace nitrohttp
