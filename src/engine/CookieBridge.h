// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — programmatic access to curl's cookie engine.
//
// Reading and writing the jar needs an easy handle that is bound to the
// client's `curl_share` but NOT attached to a transfer. Each engine therefore
// keeps one parked handle, and every cookie operation runs as an inbox op on
// the loop thread — the same rule that governs every other handle in the
// engine.
//
// `getCookies` returns the whole jar and lets Dart filter by domain and path.
// That is deliberate: rebinding the parked handle's URL to filter natively
// would be more code for a jar that is measured in kilobytes, and the Dart side
// already has to parse domain-match rules for its own `CookieJar` API.
//
// KNOWN GAP: without libpsl there is no public-suffix validation, so curl's own
// domain checks are the only guard against an overly broad `Set-Cookie`. This
// is documented in the README rather than silently accepted.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <curl/curl.h>

#include <string>
#include <vector>

#include "Common.h"

namespace nitrohttp {

class CookieBridge {
 public:
  /// `share` must already carry `CURL_LOCK_DATA_COOKIE`. `jarPath` may be empty
  /// for an in-memory-only jar.
  CookieBridge(CURLSH* share, std::string jarPath);
  ~CookieBridge();

  CookieBridge(const CookieBridge&) = delete;
  CookieBridge& operator=(const CookieBridge&) = delete;

  /// Enables the cookie engine on a transfer handle and, when a jar path is
  /// configured, points it at the file. Called for every easy handle.
  void attach(CURL* easy) const;

  // ── Loop-thread only ───────────────────────────────────────────────────────

  /// The full jar, parsed from `CURLINFO_COOKIELIST`'s Netscape lines.
  std::vector<RawCookie> all();

  /// Accepts either a Netscape line or `Set-Cookie: …` syntax; this renders the
  /// record as the former, which round-trips expiry and the host-only flag
  /// exactly.
  void set(const RawCookie& cookie);

  void clearAll();      ///< magic "ALL"
  void clearSession();  ///< magic "SESS"
  void flush();         ///< magic "FLUSH" — persist now

 private:
  CURL* parked_ = nullptr;
  std::string jarPath_;
};

/// Renders a cookie as a Netscape jar line:
/// `domain \t includeSubdomains \t path \t secure \t expiry \t name \t value`
/// with the `#HttpOnly_` domain prefix curl uses for HttpOnly entries.
std::string cookieToNetscapeLine(const RawCookie& c);

/// Parses one Netscape jar line. Returns false for comments, blanks and
/// malformed lines. Understands curl's `#HttpOnly_` prefix.
bool parseNetscapeCookieLine(const std::string& line, RawCookie* out);

}  // namespace nitrohttp
