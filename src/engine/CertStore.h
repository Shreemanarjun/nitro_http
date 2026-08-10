// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — TLS trust, client certificates and pinning.
//
// A vendored TLS library has no platform trust integration, so this is where
// each OS gets its own strategy. The default (`rootCaSource == platform`) is
// what almost every app should use, because it honours user-installed and
// MDM-deployed roots that no bundled snapshot can know about.
//
//   Apple    `CURLOPT_SSL_CTX_FUNCTION` + a custom verify callback that builds
//            a `SecTrustRef` with an SSL policy and calls
//            `SecTrustEvaluateWithError`. There is no way to export the system
//            trust store as PEM, and `SecTrustCopyAnchorCertificates` is both
//            deprecated and incomplete. When the linked TLS backend is Secure
//            Transport or already platform-integrated, this is a no-op.
//   Windows  `CURLSSLOPT_NATIVE_CA` — curl imports the CryptoAPI ROOT store.
//   Android  Scan `/apex/com.android.conscrypt/cacerts` (API 34+) falling back
//            to `/system/etc/security/cacerts`, normalise to PEM, concatenate
//            once, cache, and supply via `CURLOPT_CAINFO_BLOB`.
//            Do NOT use `CURLOPT_CAPATH` against that directory: the filenames
//            use OpenSSL's *old* subject-hash algorithm, which a modern
//            directory lookup does not match, so verification silently fails.
//   Linux    Probe the conventional bundle paths in order.
//
// Pinning uses `CURLOPT_PINNEDPUBLICKEY` with `sha256//base64;sha256//base64`
// syntax. A mismatch surfaces as `CURLE_SSL_PINNEDPUBKEYNOTMATCH`, mapped to
// `certificatePinMismatch` — deliberately distinct from a generic invalid
// certificate, because the two demand very different responses from an app.
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <curl/curl.h>

#include <string>

#include "Common.h"

namespace nitrohttp {

enum class RootCaSource : int64_t {
  Platform = 0,
  Bundled = 1,
  CustomPem = 2,
  None = 3,
};

class CertStore {
 public:
  /// Applies every TLS-related option to `easy`.
  ///
  /// `pinOverride` is the per-request SPKI pin; when non-empty it replaces the
  /// client's `pinnedSpkiSha256` entirely rather than adding to it, so a
  /// request can pin tighter than its client without inheriting a looser set.
  ///
  /// Returns non-ok only for material this build cannot use at all — malformed
  /// PEM, a pin that is not valid base64, or a TLS version the linked backend
  /// does not know. Unsupported-but-ignorable settings emit a notice instead.
  static EngineError apply(CURL* easy, const RawTlsConfig& tls,
                           const std::string& pinOverride);

  /// Platform trust as a PEM bundle, loaded once and cached. Empty when the
  /// platform is served by a verify callback (Apple) or by curl itself
  /// (Windows native CA) rather than by a bundle.
  static const std::string& platformRootsPem();

  /// Compiled-in Mozilla CA bundle. Serves `rootCaSource == bundled` and acts
  /// as the last resort when platform loading fails.
  static const std::string& bundledRootsPem();

  /// Maps `12`/`13` to the curl TLS version constants; `0` means "backend
  /// default". Returns -1 for an unrecognised value.
  static long curlTlsVersion(int64_t v, bool isMax);

  /// True when this build resolves platform trust through a verify callback
  /// rather than a CA bundle. Exposed for tests and for the notice message.
  static bool usesPlatformVerifyCallback();
};

}  // namespace nitrohttp
