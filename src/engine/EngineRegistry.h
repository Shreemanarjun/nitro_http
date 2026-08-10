// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — instance-key routing.
//
// Each `*.native.dart` spec generates its own shared library, so two spec files
// could not share a `curl_multi` pool, a cookie jar or a disk cache without
// fragile cross-dylib symbol wiring on five platforms. There is therefore ONE
// spec class, and role separation rides on the multi-instance factory key:
//
//   "engine"        process-wide singleton — cache config, prefetch, capabilities
//   "c:<clientId>"  one CurlEngine — event loop, pool, cookie jar, TLS config
//   "ws:<socketId>" one WsSession
//
// A `RoleHandle` is what `HybridNitroHttpImpl` holds. Calling a method that
// does not belong to the handle's role throws `std::runtime_error`, which the
// generated bridge converts into a Dart `HybridException` — the right channel,
// because a client-role call on a WebSocket instance is a programming error,
// not a transport failure.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "Common.h"

namespace nitrohttp {

class CurlEngine;
class HttpCache;
class WsSession;

enum class Role { Engine, Client, WebSocket };

class RoleHandle {
 public:
  RoleHandle() = default;

  Role role() const { return role_; }
  int64_t id() const { return id_; }

  /// Throws when this handle is not a client role.
  CurlEngine& engine() const;

  /// Throws when this handle is not a WebSocket role.
  WsSession& socket() const;

  /// Throws when this handle is not the process-wide engine role.
  void requireEngineRole() const;

 private:
  friend class EngineRegistry;
  Role role_ = Role::Engine;
  int64_t id_ = 0;
  std::shared_ptr<CurlEngine> client_;
  std::shared_ptr<WsSession> socket_;
};

class EngineRegistry {
 public:
  /// Parses `key` and creates (or looks up) the backing object. Runs
  /// `curl_global_init` on first use. Throws `std::runtime_error` for a
  /// malformed key.
  static RoleHandle resolve(const std::string& key);

  /// Cache shared by every client, configured through the `engine` role.
  static void configureCache(const RawCacheConfig& cfg);
  static std::shared_ptr<HttpCache> cache();
  static void clearCache();
  static RawCacheStats cacheStats();

  /// Runs a prefetch on a dedicated internal client so a prefetch storm cannot
  /// starve a user client's connection pool.
  static CurlEngine& prefetchEngine();

  /// Hot-restart recovery. The Dart isolate is torn down without cancelling
  /// subscriptions while native threads keep running, so at startup Dart calls
  /// `resetNative()`: drain every engine's inbox with a shutdown op, abort
  /// transfers, join threads, flush cookie jars, free pending blobs, and bump
  /// the generation counter so any straggling emit is dropped.
  static void resetAll();

  /// Incremented by `resetAll`. Emit sites compare against the value captured
  /// when their transfer started and drop the item on mismatch.
  static uint64_t generation();

  /// Sweeps every live client for transfers bound to `tokenId`. The token's own
  /// flag must already be raised — this only reaches the transfers that are not
  /// running curl callbacks and so cannot notice it themselves.
  static void cancelTokenEverywhere(int64_t tokenId);

  /// Drops a client or socket from the registry once its last handle goes away.
  static void forgetClient(int64_t clientId);
  static void forgetSocket(int64_t socketId);
};

}  // namespace nitrohttp
