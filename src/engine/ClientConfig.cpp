// ─────────────────────────────────────────────────────────────────────────────
// nitro_http engine — ClientConfig implementation.
//
// A note on feature guards. Every `CURLOPT_*` name is an ENUM CONSTANT produced
// by curl.h's `CURLOPT(na, t, nu)` macro, which is `#undef`ed at the end of the
// header. `#ifdef CURLOPT_ALTSVC` is therefore *always false*, which would
// silently disable the feature on every build. Optional options are guarded by
// `LIBCURL_VERSION_NUM` instead, and optional *capabilities* (HTTP/3, alt-svc)
// are probed at runtime through `curl_version_info`, never at compile time.
// ─────────────────────────────────────────────────────────────────────────────

#include "ClientConfig.h"

#include <string>
#include <vector>

#include "Wire.h"

namespace nitrohttp {
namespace {

/// Milliseconds per second, for the several options curl exposes in seconds.
constexpr int64_t kMsPerSecond = 1000;

/// `CURLOPT_ALTSVC` / `CURLOPT_ALTSVC_CTRL` — 7.64.1.
#define NITRO_HTTP_HAS_ALTSVC (LIBCURL_VERSION_NUM >= 0x074001)
/// `CURLOPT_MAXAGE_CONN` — 7.65.0.
#define NITRO_HTTP_HAS_MAXAGE_CONN (LIBCURL_VERSION_NUM >= 0x074100)
/// `CURL_HTTP_VERSION_3` — 7.66.0.
#define NITRO_HTTP_HAS_H3_ENUM (LIBCURL_VERSION_NUM >= 0x074200)
/// `CURLOPT_MAXLIFETIME_CONN` — 7.80.0.
#define NITRO_HTTP_HAS_MAXLIFETIME_CONN (LIBCURL_VERSION_NUM >= 0x075000)
/// `CURL_HTTP_VERSION_3ONLY` — 7.88.0.
#define NITRO_HTTP_HAS_H3ONLY_ENUM (LIBCURL_VERSION_NUM >= 0x075800)
/// `CURLOPT_DOH_URL` — 7.62.0.
#define NITRO_HTTP_HAS_DOH (LIBCURL_VERSION_NUM >= 0x073e00)

/// Whole seconds, rounded up, with a floor of one — curl's second-granularity
/// options must never round a positive millisecond budget down to "disabled".
long msToSecondsAtLeastOne(int64_t ms) {
  const int64_t seconds = (ms + kMsPerSecond - 1) / kMsPerSecond;
  return static_cast<long>(seconds < 1 ? 1 : seconds);
}

/// A client-level degradation the app should know about but which must not fail
/// the request. Emitted once per `set()` rather than per transfer, with
/// `requestId == 0` because it belongs to the client, not to any one request.
void emitClientNotice(const std::string& message) {
  if (!streamSink().event) return;
  RawEvent ev{};
  ev.requestId = 0;
  ev.kind = RawEventKind::RAWEVENTKIND_NOTICE;
  ev.a = 0;
  ev.b = 0;
  ev.message = message;
  streamSink().event(wire::encodeEvent(ev).toBuffer());
}

bool proxyModeNeedsUrl(RawProxyMode mode) {
  return mode == RawProxyMode::RAWPROXYMODE_HTTP ||
         mode == RawProxyMode::RAWPROXYMODE_SOCKS5 ||
         mode == RawProxyMode::RAWPROXYMODE_SOCKS5_HOSTNAME;
}

/// True when `list` already holds exactly `entries`, in order. Used to avoid
/// freeing a `CURLOPT_RESOLVE` list that in-flight handles still point at when
/// a reconfigure did not actually change the DNS overrides.
bool resolveListMatches(const struct curl_slist* list,
                        const std::vector<std::string>& entries) {
  for (const std::string& entry : entries) {
    if (entry.empty()) continue;
    if (list == nullptr || list->data == nullptr || entry != list->data) {
      return false;
    }
    list = list->next;
  }
  return list == nullptr;
}

}  // namespace

ClientConfig::ClientConfig() {
  // `RawClientConfig` is a plain aggregate: its scalars are uninitialised until
  // Dart configures the client, and a request may legitimately arrive first.
  raw_.httpVersion = RawHttpVersionPref::RAWHTTPVERSIONPREF_AUTO;
  raw_.connectTimeoutMs = 10000;
  raw_.requestTimeoutMs = 0;
  raw_.idleTimeoutMs = 0;
  raw_.followRedirects = true;
  raw_.maxRedirects = 20;
  raw_.enableCompression = true;
  raw_.enableCache = false;

  raw_.tls.verifyCertificates = true;
  raw_.tls.rootCaSource = 0;  // platform
  raw_.tls.minTlsVersion = 0;
  raw_.tls.maxTlsVersion = 0;

  raw_.proxy.mode = RawProxyMode::RAWPROXYMODE_SYSTEM;

  raw_.cookies.enabled = false;

  raw_.pool.maxConnections = 0;
  raw_.pool.maxConnectionsPerHost = 0;
  raw_.pool.idleTimeoutMs = 0;
  raw_.pool.maxLifetimeMs = 0;
  raw_.pool.keepAlivePingMs = 0;

  // Chunk batching. These carry Dart's `StreamChunkSettings.adaptive()` values
  // because zero is a real setting here — "batch every response, whatever its
  // size" — and so cannot double as "unset" at the point it is read.
  raw_.streamChunkBytes = 0;                     // adaptive
  raw_.streamChunkMinContentLength = 1 << 20;    // 1 MiB
  raw_.streamChunkMaxHoldMs = 25;
}

ClientConfig::~ClientConfig() {
  if (resolveList_ != nullptr) {
    curl_slist_free_all(resolveList_);
    resolveList_ = nullptr;
  }
}

void ClientConfig::set(const RawClientConfig& cfg) {
  raw_ = cfg;
  rebuildCaches();

  const bool wantsHttp3 =
      raw_.httpVersion == RawHttpVersionPref::RAWHTTPVERSIONPREF_HTTP3 ||
      raw_.httpVersion == RawHttpVersionPref::RAWHTTPVERSIONPREF_HTTP3_ONLY;
  if (wantsHttp3 && !hasHttp3()) {
    emitClientNotice(
        "HTTP/3 was requested but this build of libcurl has no QUIC backend; "
        "falling back to HTTP/2");
  }
#if !NITRO_HTTP_HAS_DOH
  if (!raw_.dns.dohUrl.empty()) {
    emitClientNotice(
        "DNS-over-HTTPS was requested but this libcurl predates CURLOPT_DOH_URL; "
        "using the system resolver");
  }
#endif
#if !NITRO_HTTP_HAS_ALTSVC
  if (!raw_.altSvcCachePath.empty()) {
    emitClientNotice(
        "an Alt-Svc cache path was configured but this libcurl predates "
        "CURLOPT_ALTSVC; HTTP/3 discovery is disabled");
  }
#endif
}

void ClientConfig::rebuildCaches() {
  defaultHeaderLines_.clear();
  defaultHeaderLines_.reserve(raw_.defaultHeaders.size());
  for (const RawHeader& header : raw_.defaultHeaders) {
    if (header.name.empty()) continue;
    // `Name;` is curl's syntax for "send this header with an empty value".
    // Plain `Name:` would *remove* the header instead, which silently drops a
    // deliberately-empty default.
    defaultHeaderLines_.push_back(header.value.empty()
                                      ? header.name + ";"
                                      : header.name + ": " + header.value);
  }

  // `CURLOPT_RESOLVE` does not copy the list — an in-flight easy handle holds
  // this exact pointer. Freeing and rebuilding it would hand curl dangling
  // memory, so a reconfigure that leaves the overrides alone keeps the list
  // alive, and one that genuinely changes them only affects later transfers.
  if (resolveListMatches(resolveList_, raw_.dns.staticOverrides)) return;
  if (resolveList_ != nullptr) {
    curl_slist_free_all(resolveList_);
    resolveList_ = nullptr;
  }
  for (const std::string& entry : raw_.dns.staticOverrides) {
    if (entry.empty()) continue;
    struct curl_slist* grown = curl_slist_append(resolveList_, entry.c_str());
    if (grown == nullptr) break;  // allocation failure: keep what we have
    resolveList_ = grown;
  }
}

long ClientConfig::curlHttpVersion() const {
  switch (raw_.httpVersion) {
    case RawHttpVersionPref::RAWHTTPVERSIONPREF_HTTP11_ONLY:
      return CURL_HTTP_VERSION_1_1;
    case RawHttpVersionPref::RAWHTTPVERSIONPREF_HTTP2:
      return CURL_HTTP_VERSION_2TLS;
    case RawHttpVersionPref::RAWHTTPVERSIONPREF_HTTP2_ONLY:
      return CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE;
    case RawHttpVersionPref::RAWHTTPVERSIONPREF_HTTP3:
#if NITRO_HTTP_HAS_H3_ENUM
      if (hasHttp3()) return CURL_HTTP_VERSION_3;
#endif
      return CURL_HTTP_VERSION_2TLS;
    case RawHttpVersionPref::RAWHTTPVERSIONPREF_HTTP3_ONLY:
#if NITRO_HTTP_HAS_H3ONLY_ENUM
      if (hasHttp3()) return CURL_HTTP_VERSION_3ONLY;
#endif
#if NITRO_HTTP_HAS_H3_ENUM
      if (hasHttp3()) return CURL_HTTP_VERSION_3;
#endif
      return CURL_HTTP_VERSION_2TLS;
    case RawHttpVersionPref::RAWHTTPVERSIONPREF_AUTO:
      break;
  }
  // `2TLS` negotiates h2 over ALPN and stays on 1.1 for cleartext, which is the
  // only preference that is never wrong.
  return CURL_HTTP_VERSION_2TLS;
}

EngineError ClientConfig::applyTo(CURL* easy) const {
  if (easy == nullptr) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_ENGINE_ERROR,
                             "applyTo called with a null easy handle");
  }

  curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, curlHttpVersion());

  curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS,
                   static_cast<long>(raw_.connectTimeoutMs > 0
                                         ? raw_.connectTimeoutMs
                                         : 0));
  // 0 means "no overall deadline", which is what a long download needs.
  curl_easy_setopt(
      easy, CURLOPT_TIMEOUT_MS,
      static_cast<long>(raw_.requestTimeoutMs > 0 ? raw_.requestTimeoutMs : 0));

  // `idleTimeoutMs` is DELIBERATELY not mapped to `CURLOPT_LOW_SPEED_LIMIT` /
  // `CURLOPT_LOW_SPEED_TIME`. Those compare an AVERAGE rate over a rolling
  // window against a floor, which is a different predicate from "no byte for N
  // ms": a body that delivers 16 KiB and then stalls for five seconds still
  // averages kilobytes per second and is never aborted. Their resolution is
  // also whole seconds, so a sub-second budget could not be expressed at all.
  // `RequestTask::idleBudgetRemainingMs` owns the deadline instead, and the
  // engine loop polices it.

  curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, raw_.followRedirects ? 1L : 0L);
  curl_easy_setopt(easy, CURLOPT_MAXREDIRS,
                   static_cast<long>(raw_.maxRedirects >= 0 ? raw_.maxRedirects
                                                            : -1));

  // Content decoding is the ENGINE's job, not curl's.
  //
  // The obvious spelling, `CURLOPT_ACCEPT_ENCODING ""`, is wrong twice over.
  // It advertises whatever the LOCAL libcurl was built to inflate, so the
  // vendored Android/iOS slices offer four codings and a macOS system curl
  // offers two — one plugin, two behaviours. Worse, it also makes curl abort
  // the whole transfer with `CURLE_BAD_CONTENT_ENCODING` when a server answers
  // with a coding curl does not know, where `dart:io`, `cupertino_http` and the
  // `package:http` conformance suite all require the body to pass through
  // untouched. curl has no option for "decode what you know, pass the rest
  // through": `Curl_build_unencoding_stack` runs before our HEADERFUNCTION sees
  // the header, so the choice cannot be deferred.
  //
  // So: advertise exactly the set `ContentDecoder` can inflate, and inflate it
  // ourselves in `RequestTask`.
  curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING,
                   raw_.enableCompression ? acceptEncodingHeader().c_str()
                                          : nullptr);
  // Unconditional, and not tied to `enableCompression`: a server may send a
  // `Content-Encoding` nobody asked for, and the engine still has to be the one
  // that decides what happens to it.
  curl_easy_setopt(easy, CURLOPT_HTTP_CONTENT_DECODING, 0L);

  if (!raw_.userAgent.empty()) {
    curl_easy_setopt(easy, CURLOPT_USERAGENT, raw_.userAgent.c_str());
  }

  // Mandatory, not an optimisation: curl's signal-based DNS timeout uses
  // `alarm()` + `siglongjmp`, which is not thread-safe and will corrupt an
  // engine that runs transfers off the main thread.
  curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);

  // Deliberately NOT set either: `CURLOPT_UPLOAD_BUFFERSIZE`, the SEND buffer.
  //
  // curl's docs say a larger upload buffer can be "a huge performance benefit",
  // and the reasoning transfers cleanly on paper: the 64 KiB default costs 128
  // read callbacks and 128 socket writes per 8 MiB body, each callback taking
  // `BodyPipe`'s mutex, which curl's own performance guide warns against doing
  // in a callback at all. 256 KiB quarters all three counts.
  //
  // Measured, it does nothing. Two 10-run sets through tool/bench-macos.sh,
  // same machine, same binary except this option, 8 MiB streamed upload:
  //
  //     64 KiB (default)   nitro_http 106.90 ms   package:http 104.09 ms
  //     256 KiB            nitro_http 107.07 ms   package:http 104.11 ms
  //
  // The control moved 0.02 ms, so the machine was steady and that really is a
  // null rather than noise covering an effect. It fits what the ring itself
  // measures: its cost is 0.47-0.85 ms per 8 MiB whatever the pull size, so it
  // is bound by copying bytes, not by how often it is asked for them.
  //
  // Caveat worth keeping, because it is the reason not to treat this as closed:
  // that was loopback on an M1, where a socket write is nearly free. curl's
  // "some setups" are presumably ones where it is not — a real network, or a
  // slower phone. Re-test on Android before concluding it never helps.

  // Deliberately NOT set: `CURLOPT_BUFFERSIZE`, the RECEIVE buffer.
  // Tried three times on a 32 MiB streamed download, and it loses every time:
  //
  //   16 KiB (curl's default)               147 ms
  //   64 KiB, credit window cut to 16       157 ms
  //   256 KiB, credit window cut to 4       176 ms
  //
  // That measurement is about DOWNLOADS specifically: the window is denominated
  // in chunks, so a bigger receive buffer has to be paid for with fewer credits
  // to keep the same ~1 MiB of memory in flight — and the
  // engine would rather have many small chunks it can hand over as they arrive
  // than few large ones it has to fill before Dart sees anything. Fewer, larger
  // crossings buy nothing because the cost here is per byte, not per chunk (a
  // 32 MiB body costs 2.3 ms of Dart-side copying in total). Left at curl's
  // default; see `kInitialCredits` for the other half of this measurement.
  // Wait for an existing connection to reveal whether it can multiplex, rather
  // than opening a second one the moment a request arrives.
  //
  // `CURLMOPT_PIPELINING` alone only permits multiplexing; without this, curl
  // still fans concurrent requests out to new connections because it does not
  // yet know the first will negotiate h2. Measured over 73 transfers to an h2
  // origin, 12 concurrent per round on a cold pool:
  //
  //   off: 37 new connections     on: 7 new connections
  //
  // Batch latency did not move (82 ms vs 80 ms median) — on a fast link with
  // session resumption an extra handshake is cheap — so this is a resource win,
  // not a speed one: five times fewer TLS handshakes, sockets and server-side
  // connections, which is worth most where a handshake costs an RTT and CPU.
  // HTTP/1.1 was checked for the obvious regression (waiting cannot help where
  // nothing multiplexes) and does not pay for it: 40 ms median either way.
  curl_easy_setopt(easy, CURLOPT_PIPEWAIT, 1L);

  curl_easy_setopt(easy, CURLOPT_TCP_KEEPALIVE, 1L);
  if (raw_.pool.keepAlivePingMs > 0) {
    const long seconds = msToSecondsAtLeastOne(raw_.pool.keepAlivePingMs);
    curl_easy_setopt(easy, CURLOPT_TCP_KEEPIDLE, seconds);
    curl_easy_setopt(easy, CURLOPT_TCP_KEEPINTVL, seconds);
  }

  // Keep `//` and `..` in the path exactly as the caller wrote them; signed
  // URLs break when curl "normalises" them.
  curl_easy_setopt(easy, CURLOPT_PATH_AS_IS, 0L);

  // Without this, a CONNECT tunnel's own 200 response is fed to our header
  // callback and shows up as a bogus status line.
  curl_easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);

#if NITRO_HTTP_HAS_ALTSVC
  if (!raw_.altSvcCachePath.empty()) {
    // Optional feature: a curl without alt-svc answers CURLE_NOT_BUILT_IN and
    // the client simply never discovers h3. Not an error.
    if (curl_easy_setopt(easy, CURLOPT_ALTSVC, raw_.altSvcCachePath.c_str()) ==
        CURLE_OK) {
      long ctrl = CURLALTSVC_H1 | CURLALTSVC_H2;
      if (hasHttp3()) ctrl |= CURLALTSVC_H3;
      curl_easy_setopt(easy, CURLOPT_ALTSVC_CTRL, ctrl);
    }
  }
#endif

#if NITRO_HTTP_HAS_MAXAGE_CONN
  if (raw_.pool.idleTimeoutMs > 0) {
    curl_easy_setopt(easy, CURLOPT_MAXAGE_CONN,
                     msToSecondsAtLeastOne(raw_.pool.idleTimeoutMs));
  }
#endif
#if NITRO_HTTP_HAS_MAXLIFETIME_CONN
  if (raw_.pool.maxLifetimeMs > 0) {
    curl_easy_setopt(easy, CURLOPT_MAXLIFETIME_CONN,
                     msToSecondsAtLeastOne(raw_.pool.maxLifetimeMs));
  }
#endif

  const RawProxyConfig& proxy = raw_.proxy;
  if (proxyModeNeedsUrl(proxy.mode) && proxy.url.empty()) {
    return EngineError::make(RawErrorKind::RAWERRORKIND_BAD_REQUEST,
                             "proxy mode requires a proxy URL");
  }
  switch (proxy.mode) {
    case RawProxyMode::RAWPROXYMODE_SYSTEM:
      // Leave curl's `http_proxy` / `ALL_PROXY` environment handling alone.
      break;
    case RawProxyMode::RAWPROXYMODE_NONE:
      // An empty proxy overrides the environment, which a null pointer does not.
      curl_easy_setopt(easy, CURLOPT_PROXY, "");
      break;
    case RawProxyMode::RAWPROXYMODE_HTTP:
    case RawProxyMode::RAWPROXYMODE_SOCKS5:
    case RawProxyMode::RAWPROXYMODE_SOCKS5_HOSTNAME: {
      curl_easy_setopt(easy, CURLOPT_PROXY, proxy.url.c_str());
      long type = CURLPROXY_HTTP;
      if (proxy.mode == RawProxyMode::RAWPROXYMODE_SOCKS5) {
        type = CURLPROXY_SOCKS5;
      } else if (proxy.mode == RawProxyMode::RAWPROXYMODE_SOCKS5_HOSTNAME) {
        // Resolve the target host at the proxy — the whole point of using a
        // SOCKS proxy for privacy.
        type = CURLPROXY_SOCKS5_HOSTNAME;
      }
      curl_easy_setopt(easy, CURLOPT_PROXYTYPE, type);
      if (!proxy.username.empty() || !proxy.password.empty()) {
        const std::string credentials = proxy.username + ":" + proxy.password;
        curl_easy_setopt(easy, CURLOPT_PROXYUSERPWD, credentials.c_str());
      }
      break;
    }
  }
  if (!proxy.noProxyHosts.empty()) {
    curl_easy_setopt(easy, CURLOPT_NOPROXY, proxy.noProxyHosts.c_str());
  }

#if NITRO_HTTP_HAS_DOH
  if (!raw_.dns.dohUrl.empty()) {
    curl_easy_setopt(easy, CURLOPT_DOH_URL, raw_.dns.dohUrl.c_str());
  }
#endif

  if (resolveList_ != nullptr) {
    curl_easy_setopt(easy, CURLOPT_RESOLVE, resolveList_);
  }

  return EngineError::none();
}

void ClientConfig::applyToMulti(CURLM* multi) const {
  if (multi == nullptr) return;

  const RawPoolConfig& pool = raw_.pool;
  const long total =
      static_cast<long>(pool.maxConnections > 0 ? pool.maxConnections : 0);
  curl_multi_setopt(multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, total);
  curl_multi_setopt(
      multi, CURLMOPT_MAX_HOST_CONNECTIONS,
      static_cast<long>(pool.maxConnectionsPerHost > 0
                            ? pool.maxConnectionsPerHost
                            : 0));
  // Size of the idle-connection cache, distinct from the in-use ceiling above.
  curl_multi_setopt(multi, CURLMOPT_MAXCONNECTS, total);

  // HTTP/2 multiplexing. HTTP/1 pipelining was removed from curl years ago, so
  // this bit only ever means "reuse one h2 connection for concurrent streams".
  curl_multi_setopt(multi, CURLMOPT_PIPELINING,
                    static_cast<long>(CURLPIPE_MULTIPLEX));
}

}  // namespace nitrohttp
