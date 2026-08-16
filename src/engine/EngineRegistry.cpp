#include "EngineRegistry.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "CancelRegistry.h"
#include "Common.h"
#include "CurlEngine.h"
#include "DeferredPayloads.h"
#include "HttpCache.h"
#include "WsSession.h"

namespace nitrohttp {
namespace {

/// Reserved client id for the internal prefetch engine. Dart hands out client
/// ids starting at 1 (`Ids.nextClient`), and the key grammar rejects negative
/// ids, so no user client can ever collide with it.
constexpr int64_t kPrefetchClientId = -1;

const char* roleName(Role role) {
  switch (role) {
    case Role::Engine:
      return "engine";
    case Role::Client:
      return "client";
    case Role::WebSocket:
      return "websocket";
  }
  return "unknown";
}

/// The registry map, the socket map, the prefetch engine and the process cache
/// share ONE mutex. Two mutexes would give `resolve` (map → cache) and
/// `configureCache` (cache → map) opposite lock orders, which is a deadlock.
/// None of these operations is hot enough to be worth that risk.
struct State {
  std::mutex mtx;
  std::unordered_map<int64_t, std::shared_ptr<CurlEngine>> clients;
  std::unordered_map<int64_t, std::shared_ptr<WsSession>> sockets;
  std::shared_ptr<CurlEngine> prefetch;
  std::shared_ptr<HttpCache> cache;

  /// Starts at 1 so a captured generation of 0 (a value nobody ever observed)
  /// can never be mistaken for "current".
  std::atomic<uint64_t> generation{1};
};

/// Function-local static: the registry is reachable from a curl loop thread and
/// from Dart, and a namespace-scope object would be subject to static
/// initialisation order across the unity translation unit.
State& state() {
  static State s;
  return s;
}

/// Digits only, no sign, no whitespace, no radix prefix, and the whole
/// substring must be consumed. `strtoll` alone would happily accept `"c: 3"`,
/// `"c:+3"` and `"c:3junk"` for a leading-digit prefix.
bool parseInstanceId(const std::string& text, int64_t* out) {
  if (text.empty() || text.size() > 19) return false;  // 19 digits < INT64_MAX
  uint64_t value = 0;
  for (const char c : text) {
    if (c < '0' || c > '9') return false;
    value = value * 10 + static_cast<uint64_t>(c - '0');
  }
  *out = static_cast<int64_t>(value);
  return true;
}

[[noreturn]] void throwBadKey(const std::string& key) {
  throw std::runtime_error(
      "nitro_http: unrecognised instance key '" + key +
      "'. Valid forms are 'engine' (the process-wide singleton), 'c:<clientId>' "
      "(one HTTP client) and 'ws:<socketId>' (one WebSocket session), where the "
      "id is a non-negative decimal integer.");
}

[[noreturn]] void throwWrongRole(const char* required, const char* keyForm,
                                Role actual, int64_t id) {
  throw std::runtime_error(
      std::string("nitro_http: this method requires a ") + required +
      " instance ('" + keyForm + "'), but the instance was created with role '" +
      roleName(actual) + "' (id " + std::to_string(id) +
      "). This is a programming error in the Dart layer: route the call through "
      "the instance that owns it.");
}

/// Configuration for the internal prefetch engine. Prefetches are speculative
/// background work, so every value here trades throughput for politeness.
RawClientConfig prefetchConfig() {
  RawClientConfig cfg;

  // Let curl negotiate: ALPN gives HTTP/2 where offered, and a prefetch has no
  // reason to insist on a version the origin may not speak.
  cfg.httpVersion = RawHttpVersionPref::RAWHTTPVERSIONPREF_AUTO;

  cfg.connectTimeoutMs = 10000;  // a prefetch that cannot connect in 10 s is
                                 // not going to be warm before the user asks
  cfg.requestTimeoutMs = 60000;  // generous: the result is written to disk, and
                                 // nobody is waiting on the Future
  cfg.idleTimeoutMs = 30000;     // reap the connection rather than hold a slot

  // Prefetching a redirecting URL is the normal case (CDN and locale hops), so
  // follow, but keep the chain short: a prefetch is not worth chasing.
  cfg.followRedirects = true;
  cfg.maxRedirects = 5;

  cfg.enableCompression = true;  // less background bandwidth on cellular
  cfg.enableCache = true;        // storing the response IS the point

  // Never read on this path — a prefetch discards the body rather than streaming
  // it — but left explicit so no field of `cfg` is indeterminate.
  cfg.streamChunkBytes = 0;
  cfg.streamChunkMinContentLength = 1 << 20;
  cfg.streamChunkMaxHoldMs = 25;

  cfg.userAgent = "";        // inherit the engine default
  cfg.altSvcCachePath = "";  // an Alt-Svc cache is per-user-client state
  cfg.defaultHeaders = {};

  // Platform trust, verification on, no pinning: a prefetch has no per-client
  // TLS material of its own and must never be laxer than a user client.
  cfg.tls.verifyCertificates = true;
  cfg.tls.rootCaSource = 0;
  cfg.tls.trustedRootsPem = "";
  cfg.tls.clientCertPem = "";
  cfg.tls.clientKeyPem = "";
  cfg.tls.clientKeyPassword = "";
  cfg.tls.pinnedSpkiSha256 = {};
  cfg.tls.minTlsVersion = 0;
  cfg.tls.maxTlsVersion = 0;
  cfg.tls.sniHostname = "";

  // System proxy: a prefetch on a corporate network must take the same route
  // everything else does, or it will simply fail.
  cfg.proxy.mode = RawProxyMode::RAWPROXYMODE_SYSTEM;
  cfg.proxy.url = "";
  cfg.proxy.username = "";
  cfg.proxy.password = "";
  cfg.proxy.noProxyHosts = "";

  cfg.dns.staticOverrides = {};
  cfg.dns.dohUrl = "";

  // In-memory jar, never persisted: redirect hops that set a session cookie
  // need somewhere to put it, but prefetch state must not leak into (or out of)
  // a user client's jar.
  cfg.cookies.enabled = true;
  cfg.cookies.persistPath = "";

  // Modest pool. The whole reason prefetch gets its own engine is that a
  // prefetch storm must not exhaust a user client's connection slots; giving
  // the prefetcher a large pool would just move the starvation to the network.
  cfg.pool.maxConnections = 4;
  cfg.pool.maxConnectionsPerHost = 2;
  cfg.pool.idleTimeoutMs = 30000;
  cfg.pool.maxLifetimeMs = 0;   // no forced recycling
  cfg.pool.keepAlivePingMs = 0; // no keep-alive probes for background work

  return cfg;
}

}  // namespace

// ── RoleHandle ───────────────────────────────────────────────────────────────

CurlEngine& RoleHandle::engine() const {
  if (role_ != Role::Client || !client_) {
    throwWrongRole("client", "c:<id>", role_, id_);
  }
  return *client_;
}

WsSession& RoleHandle::socket() const {
  if (role_ != Role::WebSocket || !socket_) {
    throwWrongRole("WebSocket", "ws:<id>", role_, id_);
  }
  return *socket_;
}

void RoleHandle::requireEngineRole() const {
  if (role_ != Role::Engine) {
    throwWrongRole("process-wide engine", "engine", role_, id_);
  }
}

// ── EngineRegistry ───────────────────────────────────────────────────────────

RoleHandle EngineRegistry::resolve(const std::string& key) {
  // First instance creation of the process initialises curl. Cheap and
  // `call_once`-guarded, so paying it on every resolve is fine.
  ensureCurlGlobalInit();

  RoleHandle handle;

  if (key == "engine") {
    handle.role_ = Role::Engine;
    handle.id_ = 0;
    return handle;
  }

  int64_t id = 0;
  if (key.rfind("c:", 0) == 0 && parseInstanceId(key.substr(2), &id)) {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    auto it = s.clients.find(id);
    if (it == s.clients.end()) {
      it = s.clients.emplace(id, std::make_shared<CurlEngine>(id)).first;
    }
    // A client created after `configureCache` must still participate in the
    // cache, and re-pushing the same pointer on a repeated resolve is a no-op.
    it->second->setCache(s.cache);
    handle.role_ = Role::Client;
    handle.id_ = id;
    handle.client_ = it->second;
    return handle;
  }

  if (key.rfind("ws:", 0) == 0 && parseInstanceId(key.substr(3), &id)) {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    auto it = s.sockets.find(id);
    if (it == s.sockets.end()) {
      it = s.sockets.emplace(id, std::make_shared<WsSession>(id)).first;
    }
    handle.role_ = Role::WebSocket;
    handle.id_ = id;
    handle.socket_ = it->second;
    return handle;
  }

  throwBadKey(key);
}

void EngineRegistry::configureCache(const RawCacheConfig& cfg) {
  // `open` compacts the index and stats the entry directory. Doing that while
  // holding the registry mutex would stall every concurrent client creation.
  std::shared_ptr<HttpCache> opened = HttpCache::open(cfg);

  std::vector<std::shared_ptr<CurlEngine>> targets;
  {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    s.cache = opened;
    targets.reserve(s.clients.size() + 1);
    for (const auto& entry : s.clients) targets.push_back(entry.second);
    if (s.prefetch) targets.push_back(s.prefetch);
  }

  // Any client that appeared after the swap above read the new cache in
  // `resolve` under the same lock, so this snapshot cannot miss one.
  for (const auto& client : targets) client->setCache(opened);
}

std::shared_ptr<HttpCache> EngineRegistry::cache() {
  State& s = state();
  std::lock_guard<std::mutex> lock(s.mtx);
  return s.cache;
}

void EngineRegistry::clearCache() {
  std::shared_ptr<HttpCache> cache;
  {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    cache = s.cache;
  }
  // No cache configured is not an error: caching is an optimisation, and Dart
  // may clear before it configures.
  if (cache) cache->clear();
}

RawCacheStats EngineRegistry::cacheStats() {
  std::shared_ptr<HttpCache> cache;
  {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    cache = s.cache;
  }
  if (cache) return cache->stats();

  RawCacheStats zero;
  zero.entryCount = 0;
  zero.sizeBytes = 0;
  zero.hitCount = 0;
  zero.missCount = 0;
  zero.revalidationCount = 0;
  zero.evictionCount = 0;
  return zero;
}

CurlEngine& EngineRegistry::prefetchEngine() {
  ensureCurlGlobalInit();

  State& s = state();
  std::lock_guard<std::mutex> lock(s.mtx);
  if (!s.prefetch) {
    s.prefetch = std::make_shared<CurlEngine>(kPrefetchClientId);
    s.prefetch->configure(prefetchConfig());
    s.prefetch->setCache(s.cache);
  }
  // The reference stays valid because the registry owns the engine until
  // `resetAll`, which Dart only calls during startup — before any prefetch can
  // be submitted through this handle.
  return *s.prefetch;
}

void EngineRegistry::resetAll() {
  std::vector<std::shared_ptr<CurlEngine>> clients;
  std::vector<std::shared_ptr<WsSession>> sockets;

  {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);

    clients.reserve(s.clients.size() + 1);
    for (auto& entry : s.clients) clients.push_back(std::move(entry.second));
    if (s.prefetch) clients.push_back(std::move(s.prefetch));
    sockets.reserve(s.sockets.size());
    for (auto& entry : s.sockets) sockets.push_back(std::move(entry.second));

    s.clients.clear();
    s.sockets.clear();
    s.prefetch.reset();

    // Bumped before the joins so a straggling emit from a loop thread that is
    // still winding down already sees the mismatch and drops its item.
    s.generation.fetch_add(1, std::memory_order_release);

    // The cache deliberately survives: an on-disk cache that did not outlive a
    // hot restart would have no reason to exist.
  }

  // Joins happen off-lock. `shutdown` waits for the loop thread, and that
  // thread may reach back into the registry; blocking it while we hold the
  // mutex would deadlock. The objects are already unreachable from the maps, so
  // nothing can resolve them again while they wind down.
  for (const auto& client : clients) client->shutdown();
  for (const auto& socket : sockets) socket->shutdown();

  // The isolate that held views onto any deferred zero-copy payload is gone, so
  // nothing can read them again. This is the one place freeing them outright is
  // sound — everywhere else the terminal ack is the release signal.
  DeferredPayloads::instance().dropEverything();

  // Token ids are allocated by the Dart isolate that just went away, so every
  // entry now describes a token nothing can refer to. Kept until here rather
  // than dropped earlier so the shutdown sweeps above still read real reasons.
  CancelRegistry::instance().clear();
}

void EngineRegistry::cancelTokenEverywhere(int64_t tokenId) {
  if (tokenId == 0) return;

  // Snapshot under the lock, notify outside it: `cancelToken` takes each
  // engine's inbox mutex, and holding the registry mutex across that would
  // order two independent locks and invite a deadlock with client creation.
  std::vector<std::shared_ptr<CurlEngine>> clients;
  {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    clients.reserve(s.clients.size() + 1);
    for (const auto& entry : s.clients) clients.push_back(entry.second);
    // A prefetch can be bound to a token too, and it runs on its own engine.
    if (s.prefetch) clients.push_back(s.prefetch);
  }

  for (const auto& client : clients) client->cancelToken(tokenId);
}

uint64_t EngineRegistry::generation() {
  return state().generation.load(std::memory_order_acquire);
}

void EngineRegistry::forgetClient(int64_t clientId) {
  std::shared_ptr<CurlEngine> client;
  {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    const auto it = s.clients.find(clientId);
    if (it == s.clients.end()) return;  // already forgotten, or never existed
    client = std::move(it->second);
    s.clients.erase(it);
  }
  client->shutdown();
}

void EngineRegistry::forgetSocket(int64_t socketId) {
  std::shared_ptr<WsSession> socket;
  {
    State& s = state();
    std::lock_guard<std::mutex> lock(s.mtx);
    const auto it = s.sockets.find(socketId);
    if (it == s.sockets.end()) return;
    socket = std::move(it->second);
    s.sockets.erase(it);
  }
  socket->shutdown();
}

}  // namespace nitrohttp
