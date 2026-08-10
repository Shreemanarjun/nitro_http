// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — per-client configuration, decoded once and applied per
// transfer.
//
// One `ClientConfig` per `NitroHttpClient`, matching the semantics users expect
// from rhttp and dio: a client owns its proxy, TLS, cookie and pool settings,
// and each client is an independent failure domain.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <curl/curl.h>

#include <string>
#include <vector>

#include "Common.h"

namespace nitrohttp {

class ClientConfig {
 public:
  ClientConfig();

  /// Replaces the whole configuration. Called from the Dart thread before any
  /// request is submitted for this client, and guarded by the engine's mutex
  /// so a reconfigure mid-flight cannot tear a value in half.
  void set(const RawClientConfig& cfg);

  const RawClientConfig& raw() const { return raw_; }

  /// Applies every client-level option to a fresh easy handle. TLS material is
  /// delegated to `CertStore`; this covers version preference, timeouts,
  /// redirects, compression, user agent, proxy, DNS, cookies and pool limits.
  /// Returns a non-ok error only for configuration that cannot be honoured at
  /// all (e.g. an unparseable proxy URL) — never for a merely unsupported
  /// feature, which degrades silently and emits a `notice` event.
  EngineError applyTo(CURL* easy) const;

  /// `CURLOPT_HTTP_VERSION` value for the client preference.
  long curlHttpVersion() const;

  /// Cache-relevant: whether this client participates in the disk cache at all.
  bool cacheEnabled() const { return raw_.enableCache; }

  bool cookiesEnabled() const { return raw_.cookies.enabled; }
  const std::string& cookieJarPath() const { return raw_.cookies.persistPath; }

  const std::string& altSvcPath() const { return raw_.altSvcCachePath; }

  /// Pool limits, applied to the multi handle rather than an easy handle.
  void applyToMulti(CURLM* multi) const;

  /// Default headers, already materialised into curl's `Name: value` form with
  /// the `Name;` trick for deliberately-empty values. Cached so the common path
  /// does not re-render strings per request.
  const std::vector<std::string>& defaultHeaderLines() const {
    return defaultHeaderLines_;
  }

  /// `CURLOPT_RESOLVE` entries, cached as a curl string list owned by this
  /// object. Null when no overrides are configured.
  struct curl_slist* resolveList() const { return resolveList_; }

 private:
  void rebuildCaches();

  RawClientConfig raw_;
  std::vector<std::string> defaultHeaderLines_;
  struct curl_slist* resolveList_ = nullptr;

 public:
  ~ClientConfig();
  ClientConfig(const ClientConfig&) = delete;
  ClientConfig& operator=(const ClientConfig&) = delete;
};

}  // namespace nitrohttp
