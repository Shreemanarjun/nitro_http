// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — programmatic access to curl's cookie engine.
//
// Every method here runs on the engine loop thread (the parked handle is bound
// to the same `curl_share` as the transfer handles, and curl's share locking
// covers the jar, not the handle). See CookieBridge.h for why a parked handle
// exists at all.
// ─────────────────────────────────────────────────────────────────────────────
#include "CookieBridge.h"

#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

namespace nitrohttp {

// Everything file-local lives in a NAMED namespace rather than a bare
// anonymous one: the Apple build concatenates every engine source into a single
// translation unit, where internal-linkage names from every file share one
// scope and a generic helper name would collide.
namespace cookiedetail {
namespace {

constexpr char kHttpOnlyPrefix[] = "#HttpOnly_";
constexpr size_t kHttpOnlyPrefixLen = sizeof(kHttpOnlyPrefix) - 1;

/// Netscape jar fields, in file order.
enum CookieField {
  kFieldDomain = 0,
  kFieldIncludeSubdomains,
  kFieldPath,
  kFieldSecure,
  kFieldExpiry,
  kFieldName,
  kFieldValue,
  kFieldCount,
};

/// Splits on tabs, keeping empty fields — a cookie with an empty value is legal
/// and produces a trailing empty field that must survive the split.
std::vector<std::string> splitCookieFields(const std::string& line) {
  std::vector<std::string> fields;
  fields.reserve(kFieldCount);
  size_t at = 0;
  for (;;) {
    const size_t tab = line.find('\t', at);
    if (tab == std::string::npos) {
      fields.push_back(line.substr(at));
      return fields;
    }
    fields.push_back(line.substr(at, tab - at));
    at = tab + 1;
  }
}

bool netscapeBool(const std::string& s) {
  return asciiEqualIgnoreCase(s, "TRUE");
}

}  // namespace
}  // namespace cookiedetail

// ── Lifecycle ────────────────────────────────────────────────────────────────

CookieBridge::CookieBridge(CURLSH* share, std::string jarPath)
    : jarPath_(std::move(jarPath)) {
  ensureCurlGlobalInit();
  parked_ = curl_easy_init();
  if (parked_ == nullptr) return;

  // Binding to the share is what makes this handle a view onto the client's jar
  // instead of a private one; CURL_LOCK_DATA_COOKIE is set up by the engine.
  curl_easy_setopt(parked_, CURLOPT_SHARE, share);

  // An empty string enables the cookie engine with nothing to load — which is
  // exactly what an in-memory jar wants, and is not the same as leaving the
  // option unset (that disables cookies entirely, and CURLINFO_COOKIELIST would
  // come back empty forever).
  curl_easy_setopt(parked_, CURLOPT_COOKIEFILE,
                   jarPath_.empty() ? "" : jarPath_.c_str());
  if (!jarPath_.empty()) {
    curl_easy_setopt(parked_, CURLOPT_COOKIEJAR, jarPath_.c_str());
    // `CURLOPT_COOKIEFILE` is parsed LAZILY, at transfer start. The parked
    // handle never performs a transfer, so without an explicit reload
    // `CURLINFO_COOKIELIST` reports nothing and a fresh client's `getCookies`
    // comes back empty even though the jar on disk is correct. Transfers are
    // unaffected — they load the file themselves — so this bites exactly the
    // read API an app calls on a session-restore screen before its first
    // request. Reloading here also populates the SHARED jar for that request.
    curl_easy_setopt(parked_, CURLOPT_COOKIELIST, "RELOAD");
  }
}

CookieBridge::~CookieBridge() {
  // Writes the jar when CURLOPT_COOKIEJAR is set — the documented persistence
  // point, and the reason the engine keeps this object alive until shutdown.
  if (parked_ != nullptr) curl_easy_cleanup(parked_);
}

void CookieBridge::attach(CURL* easy) const {
  curl_easy_setopt(easy, CURLOPT_COOKIEFILE,
                   jarPath_.empty() ? "" : jarPath_.c_str());
  if (!jarPath_.empty()) {
    curl_easy_setopt(easy, CURLOPT_COOKIEJAR, jarPath_.c_str());
  }
}

// ── Loop-thread operations ───────────────────────────────────────────────────

std::vector<RawCookie> CookieBridge::all() {
  std::vector<RawCookie> cookies;
  if (parked_ == nullptr) return cookies;

  struct curl_slist* list = nullptr;
  if (curl_easy_getinfo(parked_, CURLINFO_COOKIELIST, &list) != CURLE_OK) {
    return cookies;
  }
  for (const struct curl_slist* node = list; node != nullptr;
       node = node->next) {
    if (node->data == nullptr) continue;
    RawCookie cookie;
    if (parseNetscapeCookieLine(node->data, &cookie)) {
      cookies.push_back(std::move(cookie));
    }
  }
  curl_slist_free_all(list);
  return cookies;
}

void CookieBridge::set(const RawCookie& cookie) {
  if (parked_ == nullptr) return;
  const std::string line = cookieToNetscapeLine(cookie);
  curl_easy_setopt(parked_, CURLOPT_COOKIELIST, line.c_str());
}

void CookieBridge::clearAll() {
  if (parked_ != nullptr) curl_easy_setopt(parked_, CURLOPT_COOKIELIST, "ALL");
}

void CookieBridge::clearSession() {
  if (parked_ != nullptr) curl_easy_setopt(parked_, CURLOPT_COOKIELIST, "SESS");
}

void CookieBridge::flush() {
  // A no-op without CURLOPT_COOKIEJAR: curl has nowhere to write. Callers treat
  // flush as advisory, so this stays silent rather than erroring on a
  // deliberately in-memory jar.
  if (parked_ != nullptr && !jarPath_.empty()) {
    curl_easy_setopt(parked_, CURLOPT_COOKIELIST, "FLUSH");
  }
}

// ── Netscape jar format ──────────────────────────────────────────────────────

std::string cookieToNetscapeLine(const RawCookie& c) {
  // Function-local so the directive cannot leak into the next source file
  // of the unity translation unit.
  using namespace cookiedetail;  // NOLINT(build/namespaces)

  // A leading dot is the Netscape format's own way of saying "and subdomains",
  // and curl's tailmatch column must agree with it or the two disagree about
  // which hosts the cookie reaches.
  const bool includeSubdomains = !c.domain.empty() && c.domain[0] == '.';

  // Session cookies are expiry 0. Sub-second precision does not survive the
  // format, and truncating (rather than rounding) can only ever expire a cookie
  // marginally early, never late.
  const int64_t expirySeconds =
      c.expiresEpochMs > 0 ? c.expiresEpochMs / 1000 : 0;

  std::string line;
  line.reserve(kHttpOnlyPrefixLen + c.domain.size() + c.path.size() +
               c.name.size() + c.value.size() + 32);
  if (c.httpOnly) line.append(kHttpOnlyPrefix);
  line.append(c.domain);
  line.push_back('\t');
  line.append(includeSubdomains ? "TRUE" : "FALSE");
  line.push_back('\t');
  line.append(c.path.empty() ? "/" : c.path);
  line.push_back('\t');
  line.append(c.secure ? "TRUE" : "FALSE");
  line.push_back('\t');
  line.append(std::to_string(expirySeconds));
  line.push_back('\t');
  line.append(c.name);
  line.push_back('\t');
  line.append(c.value);
  return line;
}

bool parseNetscapeCookieLine(const std::string& line, RawCookie* out) {
  // Function-local so the directive cannot leak into the next source file
  // of the unity translation unit.
  using namespace cookiedetail;  // NOLINT(build/namespaces)

  if (out == nullptr) return false;

  std::string text = line;
  // Strip the line ending a jar file on disk carries; CURLINFO_COOKIELIST does
  // not, but the same parser serves both.
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
    text.pop_back();
  }
  if (text.empty()) return false;

  bool httpOnly = false;
  if (text.compare(0, kHttpOnlyPrefixLen, kHttpOnlyPrefix) == 0) {
    httpOnly = true;
    text.erase(0, kHttpOnlyPrefixLen);
  } else if (text[0] == '#') {
    return false;  // a real comment, including the jar's own banner
  }

  const std::vector<std::string> fields = splitCookieFields(text);
  // Six fields means a cookie with an empty value written without the trailing
  // tab — accepted, because rejecting it would silently drop a real cookie.
  if (fields.size() < kFieldCount - 1) return false;
  if (fields[kFieldDomain].empty() || fields[kFieldName].empty()) return false;

  const int64_t expirySeconds =
      std::strtoll(fields[kFieldExpiry].c_str(), nullptr, 10);

  out->name = fields[kFieldName];
  out->value =
      fields.size() > kFieldValue ? fields[kFieldValue] : std::string();
  out->domain = fields[kFieldDomain];
  out->path = fields[kFieldPath];
  out->expiresEpochMs = expirySeconds > 0 ? expirySeconds * 1000 : 0;
  out->secure = netscapeBool(fields[kFieldSecure]);
  out->httpOnly = httpOnly;

  // RawCookie carries no tailmatch field because it does not need one: curl
  // writes the Mozilla-style leading dot on exactly the domains whose
  // tailmatch column is TRUE, and strips it again on read, so the dot and the
  // column can never disagree.
  return true;
}

}  // namespace nitrohttp
