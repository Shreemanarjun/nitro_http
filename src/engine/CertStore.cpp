// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — TLS trust, client certificates and pinning.
//
// Every decision here is per-platform because trust *is* per-platform; see
// CertStore.h for the strategy table. This file only applies options and never
// opens a socket, so it is exercised by handing it a fresh easy handle and
// asserting on the returned `EngineError` and the notices it emits.
// ─────────────────────────────────────────────────────────────────────────────
#include "CertStore.h"

#include <cctype>
#include <mutex>
#include <string>
#include <vector>

#include "Wire.h"

// Only the bundle-scanning platforms need filesystem access; keeping the
// includes with the code they serve means an Apple build compiles neither.
#if defined(__ANDROID__) || defined(__linux__)
#define NITRO_HTTP_SCANS_TRUST_FILES 1
#else
#define NITRO_HTTP_SCANS_TRUST_FILES 0
#endif

#if NITRO_HTTP_SCANS_TRUST_FILES
#include <fstream>
#include <sstream>
#endif

#if defined(__ANDROID__)
#include <dirent.h>
#endif

namespace nitrohttp {

// Everything file-local lives in a NAMED namespace rather than a bare
// anonymous one: the Apple build concatenates every engine source into a single
// translation unit, where internal-linkage names from every file share one
// scope and a generic helper name would collide.
namespace certdetail {
namespace {

constexpr char kPemCertBegin[] = "-----BEGIN CERTIFICATE-----";

/// Fans a notice out to Dart on the module-global event stream. `requestId` is
/// 0 because a trust decision belongs to a client, not to one transfer; the
/// Dart runner routes id 0 to the client-level listener.
void emitTlsNotice(const std::string& message) {
  const StreamSink& sink = streamSink();
  if (!sink.event) return;  // no Dart attached yet (or a unit-test harness)

  RawEvent ev;
  ev.requestId = 0;
  ev.kind = RawEventKind::RAWEVENTKIND_NOTICE;
  ev.a = 0;
  ev.b = 0;
  ev.message = message;
  sink.event(wire::encodeEvent(ev).toBuffer());
}

/// Notices below are one-shot: `apply` runs per request, and a client with
/// verification disabled would otherwise emit one event per request forever,
/// which is both useless and a measurable cost in a hot loop.
void warnOnce(std::once_flag& flag, const char* message) {
  std::call_once(flag, [message] { emitTlsNotice(message); });
}

bool pemHasCertificate(const std::string& pem) {
  return pem.find(kPemCertBegin) != std::string::npos;
}

/// A PEM private key in any of the spellings curl's backends accept: PKCS#8
/// (`PRIVATE KEY`), encrypted PKCS#8, and the legacy `RSA`/`EC`/`DSA` forms —
/// all of which end in the same two words.
bool pemHasPrivateKey(const std::string& pem) {
  size_t at = pem.find("-----BEGIN ");
  while (at != std::string::npos) {
    const size_t eol = pem.find("-----", at + 11);
    if (eol == std::string::npos) return false;
    const std::string label = pem.substr(at + 11, eol - (at + 11));
    if (label.size() >= 11 &&
        label.compare(label.size() - 11, 11, "PRIVATE KEY") == 0) {
      return true;
    }
    at = pem.find("-----BEGIN ", eol);
  }
  return false;
}

#if NITRO_HTTP_SCANS_TRUST_FILES

constexpr char kPemCertEnd[] = "-----END CERTIFICATE-----";

/// Appends only the `BEGIN`…`END CERTIFICATE` blocks of `text` to `out`.
/// Platform trust files carry human-readable subject descriptions, Android's
/// carry a trailing metadata block, and a TLS backend that meets either one
/// mid-parse is entitled to reject the whole bundle.
void appendPemCertificates(const std::string& text, std::string* out) {
  size_t at = 0;
  for (;;) {
    const size_t begin = text.find(kPemCertBegin, at);
    if (begin == std::string::npos) return;
    const size_t end = text.find(kPemCertEnd, begin);
    if (end == std::string::npos) return;
    const size_t stop = end + sizeof(kPemCertEnd) - 1;
    out->append(text, begin, stop - begin);
    out->push_back('\n');
    at = stop;
  }
}

bool readTrustFile(const std::string& path, std::string* out) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;
  std::ostringstream buf;
  buf << in.rdbuf();
  *out = buf.str();
  return !out->empty();
}

#endif  // NITRO_HTTP_SCANS_TRUST_FILES

/// Installs a CA bundle. `ownedByProcess` selects `CURL_BLOB_NOCOPY` for the
/// function-local statics that outlive every handle — the bundle is ~180 KB and
/// copying it per request is pure waste. Returns false when this libcurl has no
/// blob support at all, in which case the caller degrades to curl's default
/// trust rather than failing the request.
bool setCaBundleBlob(CURL* easy, const std::string& pem, bool ownedByProcess) {
#if LIBCURL_VERSION_NUM >= 0x074D00  // 7.77.0
  struct curl_blob blob;
  blob.data = const_cast<char*>(pem.data());
  blob.len = pem.size();
  blob.flags = ownedByProcess ? CURL_BLOB_NOCOPY : CURL_BLOB_COPY;
  return curl_easy_setopt(easy, CURLOPT_CAINFO_BLOB, &blob) == CURLE_OK;
#else
  (void)easy;
  (void)pem;
  (void)ownedByProcess;
  return false;
#endif
}

/// One SPKI pin, normalised to the `sha256//<canonical base64>` form curl
/// parses. Accepts a bare hash, `sha256/…` and `sha256//…` so a value copied
/// out of another HTTP client's config works unchanged. Re-encodes from the
/// decoded bytes so unpadded input still yields the padded base64 curl's
/// decoder requires.
bool normalizeSpkiPin(const std::string& raw, std::string* out) {
  std::string value = trimAsciiSpace(raw);
  if (value.rfind("sha256//", 0) == 0) {
    value.erase(0, 8);
  } else if (value.rfind("sha256/", 0) == 0) {
    value.erase(0, 7);
  }
  value = trimAsciiSpace(value);
  if (value.empty()) return false;

  std::vector<uint8_t> decoded;
  if (!base64Decode(value, &decoded) || decoded.size() != 32) return false;

  *out = "sha256//" + base64Encode(decoded.data(), decoded.size());
  return true;
}

/// Splits a `;`-separated pin list and normalises each entry. Empty entries are
/// dropped (a trailing `;` is not an error); an undecodable one fails the whole
/// request, because silently ignoring a pin the caller asked for would turn a
/// pinning failure into a successful unpinned connection.
bool buildPinnedKeyString(const std::vector<std::string>& entries,
                          std::string* out) {
  std::string joined;
  for (const std::string& entry : entries) {
    if (trimAsciiSpace(entry).empty()) continue;
    std::string one;
    if (!normalizeSpkiPin(entry, &one)) return false;
    if (!joined.empty()) joined.push_back(';');
    joined += one;
  }
  *out = std::move(joined);
  return true;
}

std::vector<std::string> splitPinList(const std::string& s) {
  std::vector<std::string> parts;
  size_t at = 0;
  for (;;) {
    const size_t sep = s.find(';', at);
    parts.push_back(s.substr(at, sep == std::string::npos ? sep : sep - at));
    if (sep == std::string::npos) return parts;
    at = sep + 1;
  }
}

bool backendHasSsl() {
  const curl_version_info_data* info = curl_version_info(CURLVERSION_NOW);
  return info != nullptr && (info->features & CURL_VERSION_SSL) != 0;
}

// Whether the linked TLS backend resolves trust through the Keychain itself.
// Apple's own libcurl does, being built against Secure Transport; a vendored
// build against BoringSSL does not, and has no compiled-in CA bundle either, so
// supplying nothing would leave it trusting nothing.
//
// Asked of curl at runtime rather than inferred from the platform: one binary
// can be linked either way.
bool backendResolvesAppleTrust() {
  const curl_version_info_data* info = curl_version_info(CURLVERSION_NOW);
  if (info == nullptr || info->ssl_version == nullptr) return false;
  std::string name(info->ssl_version);
  for (char& c : name) c = static_cast<char>(std::tolower(c));
  // curl spells it "SecureTransport"; older builds used "AppleTLS"/"darwinssl".
  return name.find("securetransport") != std::string::npos ||
         name.find("secure transport") != std::string::npos ||
         name.find("appletls") != std::string::npos ||
         name.find("darwinssl") != std::string::npos;
}

std::once_flag g_warnVerifyDisabled;
std::once_flag g_warnTrustNone;
std::once_flag g_warnNoBlobSupport;
std::once_flag g_warnEmptyBundle;
std::once_flag g_warnAppleKeychainUnavailable;
#if NITRO_HTTP_SCANS_TRUST_FILES
std::once_flag g_warnNoPlatformRoots;
#endif
std::once_flag g_warnSniOverride;
std::once_flag g_warnNoTls;

}  // namespace
}  // namespace certdetail

// ── Platform trust ───────────────────────────────────────────────────────────

const std::string& CertStore::platformRootsPem() {
  // Function-local so the directive cannot leak into the next source file
  // of the unity translation unit.
  using namespace certdetail;  // NOLINT(build/namespaces)

  // Built once: on Android this walks a directory of ~150 files, which is far
  // too much syscall traffic to repeat per request.
  static const std::string kRoots = [] {
    std::string pem;

#if defined(__ANDROID__)
    // Conscrypt's apex store (Android 14+) takes precedence over the system
    // store; on older releases only the latter exists.
    //
    // CURLOPT_CAPATH against these directories does NOT work: the filenames are
    // OpenSSL *old* subject-hash values (`c8750f0d.0`), and a modern backend
    // computes the new hash when it looks a subject up. Every lookup misses, so
    // verification fails with "unable to get local issuer certificate" while
    // the directory sits there fully populated. Concatenating to one blob
    // sidesteps the hash question entirely.
    static const char* const kDirs[] = {
        "/apex/com.android.conscrypt/cacerts",
        "/system/etc/security/cacerts",
    };
    for (const char* dir : kDirs) {
      DIR* d = ::opendir(dir);
      if (d == nullptr) continue;
      std::string path;
      while (const struct dirent* ent = ::readdir(d)) {
        if (ent->d_name[0] == '.') continue;
        path.assign(dir);
        path.push_back('/');
        path.append(ent->d_name);
        std::string text;
        // Each file is a PEM certificate followed by a human-readable dump;
        // only the armoured block is kept.
        if (readTrustFile(path, &text)) appendPemCertificates(text, &pem);
      }
      ::closedir(d);
      if (!pem.empty()) break;
    }
#elif defined(__linux__)
    static const char* const kBundles[] = {
        "/etc/ssl/certs/ca-certificates.crt",  // Debian, Ubuntu, Alpine
        "/etc/pki/tls/certs/ca-bundle.crt",    // Fedora, RHEL
        "/etc/ssl/ca-bundle.pem",              // openSUSE
        "/etc/ssl/cert.pem",                   // musl, older layouts
    };
    for (const char* path : kBundles) {
      std::string text;
      // A missing file simply fails to open, so no separate existence check.
      if (readTrustFile(path, &text)) {
        appendPemCertificates(text, &pem);
        if (!pem.empty()) break;
      }
    }
#endif
    // Apple and Windows deliberately fall through empty: there is no PEM view
    // of the Keychain or of the CryptoAPI ROOT store, and both are served by
    // the linked backend (`usesPlatformVerifyCallback`) or by
    // CURLSSLOPT_NATIVE_CA instead.
    return pem;
  }();

  return kRoots;
}

const std::string& CertStore::bundledRootsPem() {
  static const std::string kBundle = [] {
    static const char* const kChunks[] = {
#include "mozilla_roots.inc"
    };
    // One pass to size, one to fill: the bundle is ~180 KB and reallocating
    // through six chunk appends would copy most of it twice.
    size_t total = 0;
    for (const char* chunk : kChunks) {
      total += std::string::traits_type::length(chunk);
    }

    std::string pem;
    pem.reserve(total);
    for (const char* chunk : kChunks) pem.append(chunk);
    return pem;
  }();

  return kBundle;
}

bool CertStore::usesPlatformVerifyCallback() {
#if defined(__APPLE__)
  // Overriding CAINFO against Secure Transport would *narrow* trust, so
  // nothing is installed there; see backendResolvesAppleTrust().
  return certdetail::backendResolvesAppleTrust();
#else
  return false;
#endif
}

// ── TLS versions ─────────────────────────────────────────────────────────────

long CertStore::curlTlsVersion(int64_t v, bool isMax) {
  if (isMax) {
    switch (v) {
      case 0:
        return CURL_SSLVERSION_MAX_DEFAULT;
      case 12:
        return CURL_SSLVERSION_MAX_TLSv1_2;
      case 13:
        return CURL_SSLVERSION_MAX_TLSv1_3;
      default:
        return -1;
    }
  }
  switch (v) {
    case 0:
      return CURL_SSLVERSION_DEFAULT;
    case 12:
      return CURL_SSLVERSION_TLSv1_2;
    case 13:
      return CURL_SSLVERSION_TLSv1_3;
    default:
      return -1;
  }
}

// ── Apply ────────────────────────────────────────────────────────────────────

EngineError CertStore::apply(CURL* easy, const RawTlsConfig& tls,
                             const std::string& pinOverride) {
  // Function-local so the directive cannot leak into the next source file
  // of the unity translation unit.
  using namespace certdetail;  // NOLINT(build/namespaces)

  const bool wantsTls = tls.verifyCertificates || !tls.clientCertPem.empty() ||
                        !tls.pinnedSpkiSha256.empty() || !pinOverride.empty();
  if (wantsTls && !backendHasSsl()) {
    warnOnce(g_warnNoTls,
             "nitro_http: this libcurl was built without TLS support; https "
             "requests will fail");
  }

  curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER,
                   tls.verifyCertificates ? 1L : 0L);
  curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST,
                   tls.verifyCertificates ? 2L : 0L);
  if (!tls.verifyCertificates) {
    warnOnce(g_warnVerifyDisabled,
             "nitro_http: certificate verification is DISABLED on this client. "
             "Every https connection is trivially interceptable — never ship "
             "this configuration.");
  }

  switch (static_cast<RootCaSource>(tls.rootCaSource)) {
    case RootCaSource::Platform: {
#if defined(_WIN32)
#ifdef CURLSSLOPT_NATIVE_CA
      // curl imports the CryptoAPI ROOT store itself; crypt32 is linked.
      curl_easy_setopt(easy, CURLOPT_SSL_OPTIONS,
                       static_cast<long>(CURLSSLOPT_NATIVE_CA));
#else
      if (!setCaBundleBlob(easy, bundledRootsPem(), true)) {
        warnOnce(
            g_warnNoBlobSupport,
            "nitro_http: this libcurl supports neither CURLSSLOPT_NATIVE_CA "
            "nor CURLOPT_CAINFO_BLOB; falling back to its compiled-in trust "
            "store");
      }
#endif
#elif defined(__ANDROID__) || defined(__linux__)
      // Both branches hand curl a process-lifetime static, hence NOCOPY.
      const std::string& platform = platformRootsPem();
      const std::string& roots =
          platform.empty() ? bundledRootsPem() : platform;
      if (platform.empty()) {
        warnOnce(
            g_warnNoPlatformRoots,
            "nitro_http: no platform CA store found; using the compiled-in "
            "Mozilla bundle, which cannot see user-installed or MDM-deployed "
            "roots");
      }
      if (roots.empty()) {
        warnOnce(g_warnEmptyBundle,
                 "nitro_http: no CA roots available from the platform or the "
                 "compiled-in bundle; falling back to this libcurl's own trust "
                 "store");
      } else if (!setCaBundleBlob(easy, roots, true)) {
        warnOnce(g_warnNoBlobSupport,
                 "nitro_http: this libcurl predates CURLOPT_CAINFO_BLOB; "
                 "falling back to its compiled-in trust store");
      }
#elif defined(__APPLE__)
      // Nothing to install only when the backend reads the Keychain itself;
      // otherwise the compiled-in bundle is the trust store.
      if (!usesPlatformVerifyCallback()) {
        const std::string& roots = bundledRootsPem();
        if (roots.empty()) {
          warnOnce(g_warnEmptyBundle,
                   "nitro_http: no CA roots available from the compiled-in "
                   "bundle (run tool/gen_mozilla_roots.sh); HTTPS will fail");
        } else if (!setCaBundleBlob(easy, roots, true)) {
          warnOnce(g_warnNoBlobSupport,
                   "nitro_http: this libcurl predates CURLOPT_CAINFO_BLOB; "
                   "falling back to its compiled-in trust store");
        } else {
          // The bundle is Mozilla's root list, so a root added to the Keychain
          // by a user or MDM profile is not trusted.
          warnOnce(g_warnAppleKeychainUnavailable,
                   "nitro_http: the linked TLS backend cannot read the Apple "
                   "Keychain, so RootCaSource.platform is served by the "
                   "compiled-in Mozilla bundle; user- or MDM-installed roots "
                   "are not trusted. Pass RootCaSource.custom with your own "
                   "PEM if you need them.");
        }
      }
#else
      // Unknown platform: the compiled-in bundle is the only thing we know is
      // there. Trust that cannot see user-installed roots beats no trust.
      if (!setCaBundleBlob(easy, bundledRootsPem(), true)) {
        warnOnce(g_warnNoBlobSupport,
                 "nitro_http: this libcurl predates CURLOPT_CAINFO_BLOB; "
                 "falling back to its compiled-in trust store");
      }
#endif
      break;
    }

    case RootCaSource::Bundled: {
      const std::string& roots = bundledRootsPem();
      if (roots.empty()) {
        // An empty mozilla_roots.inc degrades to whatever curl trusts by
        // default. Refusing every request would be worse, and inventing roots
        // would be dangerous; a notice is the honest middle.
        warnOnce(g_warnEmptyBundle,
                 "nitro_http: the compiled-in CA bundle is empty (run "
                 "tool/gen_mozilla_roots.sh); falling back to this libcurl's "
                 "own trust store");
      } else if (!setCaBundleBlob(easy, roots, true)) {
        warnOnce(g_warnNoBlobSupport,
                 "nitro_http: this libcurl predates CURLOPT_CAINFO_BLOB; the "
                 "compiled-in CA bundle cannot be installed");
      }
      break;
    }

    case RootCaSource::CustomPem: {
      if (!pemHasCertificate(tls.trustedRootsPem)) {
        return EngineError::make(
            RawErrorKind::RAWERRORKIND_BAD_REQUEST,
            "trustedRootsPem contains no PEM certificate block");
      }
      // COPY: the config this string lives in can be replaced while the handle
      // is still in flight.
      if (!setCaBundleBlob(easy, tls.trustedRootsPem, false)) {
        return EngineError::make(
            RawErrorKind::RAWERRORKIND_BAD_REQUEST,
            "this libcurl predates CURLOPT_CAINFO_BLOB, so a custom PEM trust "
            "store cannot be installed");
      }
      break;
    }

    case RootCaSource::None: {
      // `none` means "no trust anchors", which the API documents as every chain
      // FAILING unless a pin matches. Clearing VERIFYPEER on its own is the
      // exact inverse — every chain succeeds — so without a pin this refuses
      // rather than silently handing back the least safe mode to someone who
      // picked what reads like the strictest one. With a pin it is the intended
      // pin-only mode: curl still enforces CURLOPT_PINNEDPUBLICKEY.
      if (tls.pinnedSpkiSha256.empty() && pinOverride.empty()) {
        return EngineError::make(
            RawErrorKind::RAWERRORKIND_BAD_REQUEST,
            "rootCaSource 'none' removes every trust anchor, so it is only "
            "usable with pinnedSpkiSha256; use TlsSettings.insecure() if you "
            "really want to skip verification");
      }
      curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 0L);
      warnOnce(g_warnTrustNone,
               "nitro_http: rootCaSource is 'none', so the SPKI pin is the only "
               "thing authenticating this connection");
      break;
    }

    default:
      return EngineError::make(RawErrorKind::RAWERRORKIND_BAD_REQUEST,
                               "unknown rootCaSource " +
                                   std::to_string(tls.rootCaSource));
  }

  // ── mTLS ───────────────────────────────────────────────────────────────────

  if (tls.clientCertPem.empty() && !tls.clientKeyPem.empty()) {
    return EngineError::make(
        RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH,
        "a client private key was supplied without a client certificate");
  }
  if (!tls.clientCertPem.empty()) {
#if LIBCURL_VERSION_NUM >= 0x074700  // 7.71.0
    if (!pemHasCertificate(tls.clientCertPem)) {
      return EngineError::make(
          RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH,
          "clientCertPem contains no PEM certificate block");
    }
    // A single PEM holding both cert and key is the common export shape, so an
    // empty clientKeyPem is only an error when the certificate has no key
    // inside it.
    const bool keyInCert =
        tls.clientKeyPem.empty() && pemHasPrivateKey(tls.clientCertPem);
    if (tls.clientKeyPem.empty() && !keyInCert) {
      return EngineError::make(
          RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH,
          "clientCertPem carries no private key and clientKeyPem is empty");
    }
    if (!tls.clientKeyPem.empty() && !pemHasPrivateKey(tls.clientKeyPem)) {
      return EngineError::make(
          RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH,
          "clientKeyPem contains no PEM private key block");
    }

    struct curl_blob certBlob;
    certBlob.data = const_cast<char*>(tls.clientCertPem.data());
    certBlob.len = tls.clientCertPem.size();
    certBlob.flags = CURL_BLOB_COPY;
    if (curl_easy_setopt(easy, CURLOPT_SSLCERT_BLOB, &certBlob) != CURLE_OK) {
      return EngineError::make(
          RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH,
          "this TLS backend does not support in-memory client certificates");
    }
    curl_easy_setopt(easy, CURLOPT_SSLCERTTYPE, "PEM");

    if (!tls.clientKeyPem.empty()) {
      struct curl_blob keyBlob;
      keyBlob.data = const_cast<char*>(tls.clientKeyPem.data());
      keyBlob.len = tls.clientKeyPem.size();
      keyBlob.flags = CURL_BLOB_COPY;
      if (curl_easy_setopt(easy, CURLOPT_SSLKEY_BLOB, &keyBlob) != CURLE_OK) {
        return EngineError::make(
            RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH,
            "this TLS backend does not support in-memory private keys");
      }
      curl_easy_setopt(easy, CURLOPT_SSLKEYTYPE, "PEM");
    }
    if (!tls.clientKeyPassword.empty()) {
      curl_easy_setopt(easy, CURLOPT_KEYPASSWD, tls.clientKeyPassword.c_str());
    }
#else
    return EngineError::make(
        RawErrorKind::RAWERRORKIND_CERTIFICATE_CLIENT_AUTH,
        "this libcurl predates CURLOPT_SSLCERT_BLOB, so mTLS material can only "
        "be supplied as a file, which this plugin deliberately does not do");
#endif
  }

  // ── Pinning ────────────────────────────────────────────────────────────────

  // A per-request pin REPLACES the client's set rather than adding to it, so a
  // request can pin tighter than its client without inheriting a looser list.
  std::string pins;
  const bool pinsOk =
      pinOverride.empty()
          ? buildPinnedKeyString(tls.pinnedSpkiSha256, &pins)
          : buildPinnedKeyString(splitPinList(pinOverride), &pins);
  if (!pinsOk) {
    return EngineError::make(
        RawErrorKind::RAWERRORKIND_BAD_REQUEST,
        "SPKI pin is not base64 of exactly 32 bytes (sha256 digest)");
  }
  if (!pins.empty()) {
    curl_easy_setopt(easy, CURLOPT_PINNEDPUBLICKEY, pins.c_str());
  }

  // ── Protocol versions ──────────────────────────────────────────────────────

  const long minVersion = curlTlsVersion(tls.minTlsVersion, false);
  const long maxVersion = curlTlsVersion(tls.maxTlsVersion, true);
  if (minVersion < 0 || maxVersion < 0) {
    return EngineError::make(
        RawErrorKind::RAWERRORKIND_BAD_REQUEST,
        "unsupported TLS version bounds: min=" +
            std::to_string(tls.minTlsVersion) +
            " max=" + std::to_string(tls.maxTlsVersion) + " (0, 12 or 13)");
  }
  if (tls.minTlsVersion != 0 && tls.maxTlsVersion != 0 &&
      tls.minTlsVersion > tls.maxTlsVersion) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_BAD_REQUEST,
                             "minTlsVersion is above maxTlsVersion");
  }
  // curl packs the ceiling into the high half of the same option value, so the
  // two bounds are one setopt, not two.
  if (minVersion != CURL_SSLVERSION_DEFAULT ||
      maxVersion != CURL_SSLVERSION_MAX_DEFAULT) {
    curl_easy_setopt(easy, CURLOPT_SSLVERSION, minVersion | maxVersion);
  }

  // ── SNI override ───────────────────────────────────────────────────────────

  if (!tls.sniHostname.empty()) {
    // Not applied, and deliberately not faked. libcurl derives the SNI name
    // from the connect host, so overriding it means connecting to the URL's
    // host while presenting a different name — which is exactly
    // CURLOPT_CONNECT_TO / CURLOPT_RESOLVE territory (rewrite the URL host to
    // the SNI name and pin the connection to the real address). That has to be
    // decided where the URL and the DNS overrides are built, not here, and
    // silently ignoring it would leave callers believing they had domain
    // fronting when they did not.
    warnOnce(g_warnSniOverride,
             "nitro_http: sniHostname is not applied. A per-request SNI "
             "override requires CURLOPT_CONNECT_TO — set the URL host to the "
             "SNI name and add a connect-to/resolve entry for the real "
             "endpoint instead.");
  }

  return EngineError::none();
}

}  // namespace nitrohttp

// The Apple build concatenates every engine source into one translation unit,
// so a file-local macro must not survive this file.
#undef NITRO_HTTP_SCANS_TRUST_FILES
