/// Client-level configuration: transport, TLS, proxy, DNS, cookies, pooling and
/// caching.
///
/// Every type here is an immutable, `const`-constructible value with a full
/// `copyWith` and structural equality, so a settings object can live in a
/// top-level `const` and be diffed cheaply. Each field's dartdoc names the wire
/// or engine behaviour it controls — these classes are the only place that
/// mapping is described in Dart.
library;

import 'headers.dart';

// ── Transport ────────────────────────────────────────────────────────────────

/// Which HTTP versions the client may negotiate.
///
/// "Only" variants fail the request rather than falling back, which is what you
/// want when testing a specific protocol path; the plain variants are upgrade
/// preferences with graceful fallback.
enum HttpVersionPref {
  /// Negotiate the best version the server offers: ALPN picks HTTP/2 over TLS,
  /// HTTP/1.1 otherwise, and a cached `Alt-Svc` entry may upgrade to HTTP/3.
  auto,

  /// Force HTTP/1.1. Disables ALPN upgrade and `Alt-Svc` promotion.
  http11Only,

  /// Prefer HTTP/2, falling back to HTTP/1.1 when ALPN does not offer it.
  http2,

  /// Require HTTP/2, including prior-knowledge upgrade on cleartext. Fails if
  /// the server will not speak it.
  http2Only,

  /// Prefer HTTP/3 (QUIC), falling back through HTTP/2 to HTTP/1.1.
  ///
  /// Requires a libcurl built with an HTTP/3 backend; without one the engine
  /// reports the downgrade as a `notice` event and continues.
  http3,

  /// Require HTTP/3. Fails if QUIC is unavailable or unsupported.
  http3Only,
}

/// A TLS protocol version bound.
enum TlsVersion {
  /// TLS 1.2.
  tls12,

  /// TLS 1.3.
  tls13;

  /// The numeric form the engine passes to libcurl's version selectors:
  /// `12` for TLS 1.2, `13` for TLS 1.3.
  int get wireValue => this == tls12 ? 12 : 13;
}

/// Where the client gets the trust anchors it validates server chains against.
enum RootCaSource {
  /// The operating system trust store — the keychain on Apple platforms, the
  /// system CA bundle elsewhere. Honours enterprise and user-installed roots.
  platform,

  /// The Mozilla CA bundle compiled into the plugin. Identical on every
  /// platform, and immune to a device's tampered trust store, but also blind to
  /// legitimately installed corporate roots.
  bundled,

  /// Only the roots in `TlsSettings.trustedRootsPem`.
  custom,

  /// No trust anchors at all. Every chain fails unless
  /// `TlsSettings.verifyCertificates` is `false` or a SPKI pin matches.
  none;

  /// The discriminator the engine reads: `0` platform, `1` bundled, `2` custom,
  /// `3` none.
  int get wireValue => index;
}

/// A PEM-encoded client certificate and its private key, for mutual TLS.
final class ClientCertificate {
  /// Creates a client certificate from PEM text.
  const ClientCertificate({
    required this.certificatePem,
    required this.privateKeyPem,
    this.password,
  });

  /// The certificate chain in PEM form: leaf first, then any intermediates.
  final String certificatePem;

  /// The private key in PEM form (PKCS#1 or PKCS#8).
  final String privateKeyPem;

  /// Passphrase for an encrypted [privateKeyPem]. `null` for an unencrypted key.
  final String? password;

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  ClientCertificate copyWith({
    String? certificatePem,
    String? privateKeyPem,
    String? password,
  }) => ClientCertificate(
    certificatePem: certificatePem ?? this.certificatePem,
    privateKeyPem: privateKeyPem ?? this.privateKeyPem,
    password: password ?? this.password,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientCertificate &&
          other.certificatePem == certificatePem &&
          other.privateKeyPem == privateKeyPem &&
          other.password == password;

  @override
  int get hashCode => Object.hash(certificatePem, privateKeyPem, password);

  /// Redacts the key material — a certificate must never land in a log.
  @override
  String toString() => 'ClientCertificate(<redacted>)';
}

/// TLS behaviour for a client.
final class TlsSettings {
  /// Creates TLS settings. The defaults verify certificates against the
  /// platform trust store with no pinning and no version clamp.
  const TlsSettings({
    this.verifyCertificates = true,
    this.rootCaSource = RootCaSource.platform,
    this.trustedRootsPem,
    this.clientCertificate,
    this.pinnedSpkiSha256 = const <String>[],
    this.minVersion,
    this.maxVersion,
    this.sniHostname,
  });

  /// Disables certificate and hostname verification entirely — any server can
  /// impersonate any host, so this must never reach a shipped build.
  const TlsSettings.insecure() : this(verifyCertificates: false);

  /// Whether the server chain and hostname are verified.
  ///
  /// `false` also disables hostname matching. The engine logs a warning on every
  /// request made with it.
  final bool verifyCertificates;

  /// Which trust anchors verification uses.
  final RootCaSource rootCaSource;

  /// Concatenated PEM certificates used when [rootCaSource] is
  /// [RootCaSource.custom]. Ignored otherwise.
  final String? trustedRootsPem;

  /// Certificate presented when a server requests client authentication.
  /// `null` disables mutual TLS.
  final ClientCertificate? clientCertificate;

  /// Base64 SHA-256 hashes of accepted server SPKIs, in libcurl's
  /// `sha256//<base64>` pin form without the prefix.
  ///
  /// Empty disables pinning. When non-empty the chain must both verify (unless
  /// [verifyCertificates] is `false`) *and* present a public key hashing to one
  /// of these; a mismatch fails with `NitroHttpCertificateException`.
  final List<String> pinnedSpkiSha256;

  /// Lowest acceptable TLS version. `null` leaves the libcurl default (TLS 1.2
  /// on every backend we ship against).
  final TlsVersion? minVersion;

  /// Highest acceptable TLS version. `null` means no upper clamp.
  final TlsVersion? maxVersion;

  /// Overrides the SNI name and the hostname that certificates are matched
  /// against. `null` derives both from the request URL.
  ///
  /// Used to reach a host by IP while still validating its certificate.
  final String? sniHostname;

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  TlsSettings copyWith({
    bool? verifyCertificates,
    RootCaSource? rootCaSource,
    String? trustedRootsPem,
    ClientCertificate? clientCertificate,
    List<String>? pinnedSpkiSha256,
    TlsVersion? minVersion,
    TlsVersion? maxVersion,
    String? sniHostname,
  }) => TlsSettings(
    verifyCertificates: verifyCertificates ?? this.verifyCertificates,
    rootCaSource: rootCaSource ?? this.rootCaSource,
    trustedRootsPem: trustedRootsPem ?? this.trustedRootsPem,
    clientCertificate: clientCertificate ?? this.clientCertificate,
    pinnedSpkiSha256: pinnedSpkiSha256 ?? this.pinnedSpkiSha256,
    minVersion: minVersion ?? this.minVersion,
    maxVersion: maxVersion ?? this.maxVersion,
    sniHostname: sniHostname ?? this.sniHostname,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TlsSettings &&
          other.verifyCertificates == verifyCertificates &&
          other.rootCaSource == rootCaSource &&
          other.trustedRootsPem == trustedRootsPem &&
          other.clientCertificate == clientCertificate &&
          _listEquals(other.pinnedSpkiSha256, pinnedSpkiSha256) &&
          other.minVersion == minVersion &&
          other.maxVersion == maxVersion &&
          other.sniHostname == sniHostname;

  @override
  int get hashCode => Object.hash(
    verifyCertificates,
    rootCaSource,
    trustedRootsPem,
    clientCertificate,
    Object.hashAll(pinnedSpkiSha256),
    minVersion,
    maxVersion,
    sniHostname,
  );

  @override
  String toString() =>
      'TlsSettings(verify: $verifyCertificates, roots: ${rootCaSource.name}, '
      'pins: ${pinnedSpkiSha256.length}, '
      'mTLS: ${clientCertificate != null})';
}

// ── Proxy ────────────────────────────────────────────────────────────────────

/// Protocol of a manually configured proxy.
enum ProxyKind {
  /// An HTTP proxy: `CONNECT` for https targets, absolute-form requests for
  /// http ones.
  http,

  /// A SOCKS5 proxy that resolves hostnames locally, then connects by IP.
  socks5,

  /// A SOCKS5 proxy that forwards the hostname for the proxy to resolve, so DNS
  /// does not leak to the local resolver.
  socks5Hostname,
}

/// How the client reaches the network.
///
/// Sealed: exactly [SystemProxySettings], [NoProxySettings] and
/// [ManualProxySettings].
sealed class ProxySettings {
  /// Const base constructor for the variants below.
  const ProxySettings();

  /// Honour the platform proxy configuration and the `http_proxy` /
  /// `https_proxy` / `no_proxy` environment variables. The default.
  const factory ProxySettings.system() = SystemProxySettings;

  /// Ignore all proxy configuration and connect directly.
  const factory ProxySettings.noProxy() = NoProxySettings;

  /// Route through an HTTP proxy at [url] (`host:port`, optionally scheme
  /// prefixed).
  ///
  /// [noProxy] is a comma-separated list of host patterns that bypass the
  /// proxy, in libcurl's `CURLOPT_NOPROXY` syntax.
  const factory ProxySettings.http(
    String url, {
    String? username,
    String? password,
    String? noProxy,
  }) = ManualProxySettings.http;

  /// Route through a SOCKS5 proxy at [url], resolving hostnames locally.
  const factory ProxySettings.socks5(
    String url, {
    String? username,
    String? password,
    String? noProxy,
  }) = ManualProxySettings.socks5;

  /// Route through a SOCKS5 proxy at [url], letting the proxy resolve
  /// hostnames.
  const factory ProxySettings.socks5Hostname(
    String url, {
    String? username,
    String? password,
    String? noProxy,
  }) = ManualProxySettings.socks5Hostname;
}

/// Use the platform's proxy configuration. See [ProxySettings.system].
final class SystemProxySettings extends ProxySettings {
  /// Creates the system-proxy variant.
  const SystemProxySettings();

  @override
  bool operator ==(Object other) => other is SystemProxySettings;

  @override
  int get hashCode => (SystemProxySettings).hashCode;

  @override
  String toString() => 'ProxySettings.system()';
}

/// Bypass every proxy. See [ProxySettings.noProxy].
final class NoProxySettings extends ProxySettings {
  /// Creates the direct-connection variant.
  const NoProxySettings();

  @override
  bool operator ==(Object other) => other is NoProxySettings;

  @override
  int get hashCode => (NoProxySettings).hashCode;

  @override
  String toString() => 'ProxySettings.noProxy()';
}

/// An explicitly configured proxy endpoint.
final class ManualProxySettings extends ProxySettings {
  /// Creates a proxy of an arbitrary [mode].
  const ManualProxySettings(
    this.mode,
    this.url, {
    this.username,
    this.password,
    this.noProxy,
  });

  /// Creates an HTTP proxy. See [ProxySettings.http].
  const ManualProxySettings.http(
    this.url, {
    this.username,
    this.password,
    this.noProxy,
  }) : mode = ProxyKind.http;

  /// Creates a locally-resolving SOCKS5 proxy. See [ProxySettings.socks5].
  const ManualProxySettings.socks5(
    this.url, {
    this.username,
    this.password,
    this.noProxy,
  }) : mode = ProxyKind.socks5;

  /// Creates a remotely-resolving SOCKS5 proxy.
  /// See [ProxySettings.socks5Hostname].
  const ManualProxySettings.socks5Hostname(
    this.url, {
    this.username,
    this.password,
    this.noProxy,
  }) : mode = ProxyKind.socks5Hostname;

  /// Proxy protocol.
  final ProxyKind mode;

  /// Proxy endpoint as `host:port`, optionally scheme-prefixed. A missing port
  /// falls back to libcurl's default for [mode].
  final String url;

  /// Proxy username. `null` for an unauthenticated proxy.
  final String? username;

  /// Proxy password, paired with [username].
  final String? password;

  /// Comma-separated host patterns that bypass this proxy
  /// (`CURLOPT_NOPROXY` syntax, e.g. `localhost,.internal`).
  final String? noProxy;

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  ManualProxySettings copyWith({
    ProxyKind? mode,
    String? url,
    String? username,
    String? password,
    String? noProxy,
  }) => ManualProxySettings(
    mode ?? this.mode,
    url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    noProxy: noProxy ?? this.noProxy,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManualProxySettings &&
          other.mode == mode &&
          other.url == url &&
          other.username == username &&
          other.password == password &&
          other.noProxy == noProxy;

  @override
  int get hashCode => Object.hash(mode, url, username, password, noProxy);

  /// Redacts credentials.
  @override
  String toString() =>
      'ManualProxySettings(${mode.name}, $url'
      '${username == null ? '' : ', auth: <redacted>'}'
      '${noProxy == null ? '' : ', noProxy: $noProxy'})';
}

// ── DNS ──────────────────────────────────────────────────────────────────────

/// How hostnames are resolved.
///
/// Sealed: exactly [SystemDnsSettings], [StaticDnsSettings] and
/// [DohDnsSettings].
sealed class DnsSettings {
  /// Const base constructor for the variants below.
  const DnsSettings();

  /// Use the platform resolver. The default.
  const factory DnsSettings.system() = SystemDnsSettings;

  /// Pre-seed the resolver cache: every host in [overrides] resolves to the
  /// listed addresses without a DNS query.
  ///
  /// Entries apply to [port] only, because libcurl's `CURLOPT_RESOLVE` is keyed
  /// by `host:port`.
  const factory DnsSettings.static(
    Map<String, List<String>> overrides, {
    int port,
  }) = StaticDnsSettings;

  /// Resolve through a DNS-over-HTTPS endpoint at [url].
  const factory DnsSettings.doh(String url) = DohDnsSettings;

  /// Renders the `host:port:ip1,ip2` strings libcurl's `CURLOPT_RESOLVE`
  /// expects. Empty for every variant except [StaticDnsSettings].
  List<String> toResolveEntries();
}

/// Use the platform resolver. See [DnsSettings.system].
final class SystemDnsSettings extends DnsSettings {
  /// Creates the system-resolver variant.
  const SystemDnsSettings();

  @override
  List<String> toResolveEntries() => const <String>[];

  @override
  bool operator ==(Object other) => other is SystemDnsSettings;

  @override
  int get hashCode => (SystemDnsSettings).hashCode;

  @override
  String toString() => 'DnsSettings.system()';
}

/// Hard-coded host-to-address overrides. See [DnsSettings.static].
final class StaticDnsSettings extends DnsSettings {
  /// Creates static overrides for [port] (443 by default).
  const StaticDnsSettings(this.overrides, {this.port = 443});

  /// Hostname to literal addresses. IPv4 and IPv6 literals may be mixed; the
  /// engine tries them in order.
  final Map<String, List<String>> overrides;

  /// The port these overrides apply to. Requests to any other port on the same
  /// host resolve normally.
  final int port;

  /// Renders one `host:port:ip1,ip2` entry per host, skipping hosts with no
  /// addresses — an empty address list would tell libcurl to *block* the host
  /// rather than redirect it.
  @override
  List<String> toResolveEntries() => <String>[
    for (final entry in overrides.entries)
      if (entry.value.isNotEmpty) '${entry.key}:$port:${entry.value.join(',')}',
  ];

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  StaticDnsSettings copyWith({
    Map<String, List<String>>? overrides,
    int? port,
  }) => StaticDnsSettings(overrides ?? this.overrides, port: port ?? this.port);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StaticDnsSettings &&
          other.port == port &&
          _listEquals(other.toResolveEntries(), toResolveEntries());

  @override
  int get hashCode => Object.hash(port, Object.hashAll(toResolveEntries()));

  @override
  String toString() => 'DnsSettings.static(${toResolveEntries()})';
}

/// DNS-over-HTTPS. See [DnsSettings.doh].
final class DohDnsSettings extends DnsSettings {
  /// Creates a DoH resolver pointed at [url].
  const DohDnsSettings(this.url);

  /// The DoH endpoint, e.g. `https://cloudflare-dns.com/dns-query`.
  ///
  /// Use an endpoint addressable without DNS, or one the platform resolver can
  /// already reach, otherwise the first lookup bootstraps through the system
  /// resolver anyway.
  final String url;

  @override
  List<String> toResolveEntries() => const <String>[];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DohDnsSettings && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'DnsSettings.doh($url)';
}

// ── Cookies ──────────────────────────────────────────────────────────────────

/// Cookie handling for a client.
final class CookieSettings {
  /// Creates cookie settings. By default cookies are stored in memory for the
  /// lifetime of the client.
  const CookieSettings({this.storeCookies = true, this.persistPath});

  /// Whether the engine keeps a cookie jar at all.
  ///
  /// `false` neither stores `Set-Cookie` nor sends a `Cookie:` header the
  /// caller did not write itself.
  final bool storeCookies;

  /// Path of a Netscape-format cookie file to load at startup and flush to on
  /// shutdown. `null` keeps the jar in memory only.
  ///
  /// The file holds session credentials in plain text; put it somewhere the
  /// platform protects.
  final String? persistPath;

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  CookieSettings copyWith({bool? storeCookies, String? persistPath}) =>
      CookieSettings(
        storeCookies: storeCookies ?? this.storeCookies,
        persistPath: persistPath ?? this.persistPath,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CookieSettings &&
          other.storeCookies == storeCookies &&
          other.persistPath == persistPath;

  @override
  int get hashCode => Object.hash(storeCookies, persistPath);

  @override
  String toString() =>
      'CookieSettings(store: $storeCookies, persistent: ${persistPath != null})';
}

// ── Redirects ────────────────────────────────────────────────────────────────

/// Redirect-following policy.
///
/// Sealed: exactly [FollowRedirects], [LimitedRedirects] and [NoRedirects].
sealed class RedirectSettings {
  /// Const base constructor for the variants below.
  const RedirectSettings();

  /// Follow redirects up to a sane default depth of 30.
  const factory RedirectSettings.follow() = FollowRedirects;

  /// Follow at most [max] redirects, failing with
  /// `NitroHttpRedirectException` beyond that.
  const factory RedirectSettings.limited(int max) = LimitedRedirects;

  /// Never follow a redirect; return the 3xx response as-is.
  const factory RedirectSettings.none() = NoRedirects;

  /// Whether redirects are followed at all.
  bool get follow;

  /// Maximum redirect hops. Meaningless when [follow] is `false`, where it
  /// reports `0`.
  int get maxRedirects;
}

/// Follow redirects with the default limit. See [RedirectSettings.follow].
final class FollowRedirects extends RedirectSettings {
  /// Creates the default follow policy.
  const FollowRedirects();

  @override
  bool get follow => true;

  @override
  int get maxRedirects => 30;

  @override
  bool operator ==(Object other) => other is FollowRedirects;

  @override
  int get hashCode => (FollowRedirects).hashCode;

  @override
  String toString() => 'RedirectSettings.follow()';
}

/// Follow redirects up to an explicit limit. See [RedirectSettings.limited].
final class LimitedRedirects extends RedirectSettings {
  /// Creates a policy allowing at most [maxRedirects] hops.
  const LimitedRedirects(this.maxRedirects);

  @override
  final int maxRedirects;

  @override
  bool get follow => maxRedirects > 0;

  @override
  bool operator ==(Object other) =>
      other is LimitedRedirects && other.maxRedirects == maxRedirects;

  @override
  int get hashCode => Object.hash(LimitedRedirects, maxRedirects);

  @override
  String toString() => 'RedirectSettings.limited($maxRedirects)';
}

/// Never follow redirects. See [RedirectSettings.none].
final class NoRedirects extends RedirectSettings {
  /// Creates the no-follow policy.
  const NoRedirects();

  @override
  bool get follow => false;

  @override
  int get maxRedirects => 0;

  @override
  bool operator ==(Object other) => other is NoRedirects;

  @override
  int get hashCode => (NoRedirects).hashCode;

  @override
  String toString() => 'RedirectSettings.none()';
}

// ── Pool ─────────────────────────────────────────────────────────────────────

/// Connection-pool limits shared by every request on a client.
final class PoolSettings {
  /// Creates pool settings with the engine defaults documented on each field.
  const PoolSettings({
    this.maxConnections = 64,
    this.maxConnectionsPerHost = 6,
    this.idleTimeout = const Duration(seconds: 90),
    this.maxLifetime = const Duration(minutes: 10),
    this.keepAlivePingInterval,
  });

  /// Total pooled connections kept alive across all hosts. Defaults to 64.
  ///
  /// The pool evicts the least recently used connection past this point; it
  /// does not throttle new requests.
  final int maxConnections;

  /// Simultaneous connections to one origin. Defaults to 6, matching browser
  /// behaviour for HTTP/1.1. HTTP/2 and HTTP/3 multiplex over one connection
  /// and rarely reach this.
  final int maxConnectionsPerHost;

  /// How long an unused connection stays pooled. Defaults to 90 seconds — below
  /// the 60–120 s idle window most origins and load balancers enforce, so we
  /// close first rather than racing a server-side FIN.
  final Duration idleTimeout;

  /// Hard age limit for a pooled connection regardless of use. Defaults to 10
  /// minutes, which bounds how long a request can keep riding a stale DNS
  /// result or an about-to-be-drained backend.
  final Duration maxLifetime;

  /// HTTP/2 `PING` interval on idle multiplexed connections. `null` (the
  /// default) disables pings.
  ///
  /// Pings detect a silently dropped connection before a request commits to it,
  /// at the cost of periodic radio wakeups on mobile.
  final Duration? keepAlivePingInterval;

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  PoolSettings copyWith({
    int? maxConnections,
    int? maxConnectionsPerHost,
    Duration? idleTimeout,
    Duration? maxLifetime,
    Duration? keepAlivePingInterval,
  }) => PoolSettings(
    maxConnections: maxConnections ?? this.maxConnections,
    maxConnectionsPerHost: maxConnectionsPerHost ?? this.maxConnectionsPerHost,
    idleTimeout: idleTimeout ?? this.idleTimeout,
    maxLifetime: maxLifetime ?? this.maxLifetime,
    keepAlivePingInterval: keepAlivePingInterval ?? this.keepAlivePingInterval,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PoolSettings &&
          other.maxConnections == maxConnections &&
          other.maxConnectionsPerHost == maxConnectionsPerHost &&
          other.idleTimeout == idleTimeout &&
          other.maxLifetime == maxLifetime &&
          other.keepAlivePingInterval == keepAlivePingInterval;

  @override
  int get hashCode => Object.hash(
    maxConnections,
    maxConnectionsPerHost,
    idleTimeout,
    maxLifetime,
    keepAlivePingInterval,
  );

  @override
  String toString() =>
      'PoolSettings(max: $maxConnections, perHost: $maxConnectionsPerHost, '
      'idle: $idleTimeout, lifetime: $maxLifetime, '
      'ping: $keepAlivePingInterval)';
}

// ── Cache ────────────────────────────────────────────────────────────────────

/// Per-client participation in the shared disk cache.
///
/// The cache *directory* and size budget are process-wide and configured once
/// through `HttpCacheConfig`; a client only chooses whether to use it.
final class CacheSettings {
  /// Creates cache settings. Caching is opt-in, so [enabled] defaults to
  /// `false`.
  const CacheSettings({this.enabled = false});

  /// Whether this client reads from and writes to the shared cache.
  ///
  /// Requires the process-wide store to have been configured; without it every
  /// request behaves as `CacheMode.noStore`.
  final bool enabled;

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  CacheSettings copyWith({bool? enabled}) =>
      CacheSettings(enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheSettings && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;

  @override
  String toString() => 'CacheSettings(enabled: $enabled)';
}

// ── Client ───────────────────────────────────────────────────────────────────

/// Everything a client is configured with.
///
/// `const ClientSettings()` is a usable default: no base URL, no timeouts
/// beyond libcurl's own, negotiated HTTP version, verified TLS against the
/// platform trust store, system proxy and resolver, in-memory cookies, and
/// non-2xx responses raised as exceptions.
/// How a streamed response body is batched before it crosses into Dart.
///
/// libcurl hands the engine 16 KiB at a time. Passing each one straight through
/// costs a chunk struct, a zero-copy proxy with a finalizer, a credit and a
/// `StreamController.add` — 4.81 us measured, which over a 32 MiB body is 2050
/// crossings and 9.9 ms, 7.4 % of the transfer. Batching them into larger chunks
/// removed most of that and took a 32 MiB download from last place to first
/// against `dart:io`, `dio`, `package:http` and `rhttp`.
///
/// The cost of batching is latency: bytes wait for the chunk to fill. That is
/// free on a bulk download and unacceptable on a live stream, which is why the
/// default decides per response rather than per client.
final class StreamChunkSettings {
  /// Sizes each chunk from the response. **The default; prefer it.**
  ///
  /// A body smaller than [minContentLength], one with no declared length, and
  /// one that is content-decoded (its inflated size is unknown until the last
  /// byte) all stream as they arrive — so server-sent events and long polls keep
  /// their latency without anyone configuring anything. Above that the engine
  /// batches to 128 KiB, which measured fastest at every body size from 8 MiB to
  /// 256 MiB (`example/integration_test/chunk_ladder_test.dart`). Notably the
  /// curve is not monotonic — 256 KiB was slower than not batching at all — so
  /// raising this with [StreamChunkSettings.fixed] is a measurement, not a dial.
  ///
  /// [maxHold] bounds the downside of guessing wrong. The ladder assumes a large
  /// body also arrives quickly, which is false on a slow link, so a part-full
  /// chunk older than this is emitted anyway.
  const StreamChunkSettings.adaptive({
    this.minContentLength = 1024 * 1024,
    this.maxHold = const Duration(milliseconds: 25),
  }) : bytes = 0;

  /// Never batch: every block libcurl produces crosses immediately.
  ///
  /// The lowest-latency option and the slowest for bulk transfer. Worth setting
  /// explicitly for a client that only ever consumes live streams, where the
  /// adaptive default would still batch a long response that happens to declare
  /// its length.
  const StreamChunkSettings.immediate()
    : bytes = -1,
      minContentLength = 0,
      maxHold = Duration.zero;

  /// Batch to exactly [bytes], for bodies of at least [minContentLength].
  ///
  /// For when the size heuristic reads a workload wrongly — many 200 KiB bodies
  /// that the ladder leaves unbatched, or a memory budget that cannot afford the
  /// 512 KiB step. Note each credit stands for one chunk, so a larger size also
  /// multiplies what the 64-credit window keeps in flight.
  const StreamChunkSettings.fixed(
    this.bytes, {
    this.minContentLength = 1024 * 1024,
    this.maxHold = const Duration(milliseconds: 25),
  }) : assert(bytes > 0, 'use StreamChunkSettings.immediate() to disable');

  /// Target chunk size: `0` adaptive, `-1` immediate, `>0` that exact size.
  final int bytes;

  /// Smallest declared body that batches at all.
  final int minContentLength;

  /// Longest a part-full chunk is held before being emitted anyway.
  final Duration maxHold;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamChunkSettings &&
          other.bytes == bytes &&
          other.minContentLength == minContentLength &&
          other.maxHold == maxHold;

  @override
  int get hashCode => Object.hash(bytes, minContentLength, maxHold);

  @override
  String toString() => switch (bytes) {
    -1 => 'StreamChunkSettings.immediate()',
    0 => 'StreamChunkSettings.adaptive(minContentLength: $minContentLength, '
        'maxHold: $maxHold)',
    _ => 'StreamChunkSettings.fixed($bytes, '
        'minContentLength: $minContentLength, maxHold: $maxHold)',
  };
}

final class ClientSettings {
  /// Creates client settings; every argument has a working default.
  const ClientSettings({
    this.baseUrl,
    this.timeout,
    this.connectTimeout,
    this.idleTimeout,
    this.httpVersionPref = HttpVersionPref.auto,
    this.headers,
    this.userAgent,
    this.redirectSettings = const RedirectSettings.follow(),
    this.throwOnStatusCode = true,
    this.enableCompression = true,
    this.tlsSettings = const TlsSettings(),
    this.proxySettings = const ProxySettings.system(),
    this.dnsSettings = const DnsSettings.system(),
    this.cookieSettings = const CookieSettings(),
    this.poolSettings = const PoolSettings(),
    this.cacheSettings = const CacheSettings(),
    this.altSvcCachePath,
    this.streamChunks = const StreamChunkSettings.adaptive(),
  });

  /// Prefix that relative request paths resolve against, e.g.
  /// `https://api.example.com/v1`. See [resolve] for the joining rules.
  final String? baseUrl;

  /// Wall-clock budget for a whole request, including redirects, retries inside
  /// the engine and body transfer. `null` means unlimited.
  final Duration? timeout;

  /// Budget for DNS, TCP and TLS to complete. `null` uses libcurl's default.
  ///
  /// Counted separately from [timeout], which continues to run during connect.
  final Duration? connectTimeout;

  /// Abort a transfer that moves no bytes for this long. `null` disables the
  /// check.
  ///
  /// This is the only timeout that distinguishes a slow download from a wedged
  /// one, so prefer it over a small [timeout] for large bodies.
  final Duration? idleTimeout;

  /// Which HTTP versions may be negotiated.
  final HttpVersionPref httpVersionPref;

  /// Headers merged into every request. Per-request headers with the same name
  /// replace these. `null` means none.
  final HttpHeaders? headers;

  /// Value of the `User-Agent` header. `null` sends the engine's default.
  ///
  /// A `User-Agent` in [headers] takes precedence over this.
  final String? userAgent;

  /// Redirect-following policy.
  final RedirectSettings redirectSettings;

  /// Whether a non-2xx response throws `NitroHttpStatusCodeException` instead of
  /// returning normally. Defaults to `true`.
  final bool throwOnStatusCode;

  /// Advertises `Accept-Encoding` with exactly the codings the engine can
  /// decode — always gzip and deflate, plus brotli and zstd when this build is
  /// linked against them, which [NitroHttp.supportsBrotli] and
  /// [NitroHttp.supportsZstd] report. Defaults to `true`.
  ///
  /// Turning it off omits `Accept-Encoding`. It does not turn decoding off: a
  /// server that compresses anyway, or a hand-written `Accept-Encoding` request
  /// header, is still decoded. A coding the engine does not recognise is always
  /// passed through byte for byte, with its `Content-Encoding` intact.
  final bool enableCompression;

  /// TLS behaviour.
  final TlsSettings tlsSettings;

  /// Proxy configuration.
  final ProxySettings proxySettings;

  /// Name resolution configuration.
  final DnsSettings dnsSettings;

  /// Cookie jar configuration.
  final CookieSettings cookieSettings;

  /// Connection-pool limits.
  final PoolSettings poolSettings;

  /// Participation in the shared disk cache.
  final CacheSettings cacheSettings;

  /// Path of the file caching `Alt-Svc` advertisements, which is how a server
  /// tells us it also speaks HTTP/3. `null` disables the cache, so HTTP/3 is
  /// only reachable by requesting it explicitly through [httpVersionPref].
  final String? altSvcCachePath;

  /// How streamed response bodies are batched before crossing into Dart.
  ///
  /// Defaults to [StreamChunkSettings.adaptive], which sizes itself from the
  /// response and needs no tuning. Override it only for a workload the size
  /// heuristic reads wrongly — see that class for when that happens.
  final StreamChunkSettings streamChunks;

  /// Resolves [pathOrUrl] against [baseUrl] and applies [query].
  ///
  /// An absolute input — one with a scheme, or a protocol-relative
  /// `//host/path` — wins outright and [baseUrl] is ignored. Otherwise the two
  /// are joined with exactly one `/` between them, whether or not the base ends
  /// in a slash and whether or not the path starts with one. Unlike
  /// [Uri.resolve], a leading `/` does *not* discard the base's path: with a
  /// base of `https://api.example.com/v1`, both `users` and `/users` yield
  /// `https://api.example.com/v1/users`.
  ///
  /// [query] is merged over any query already present in [pathOrUrl]. A
  /// `List` (or any `Iterable`) value becomes repeated keys; a `null` value
  /// removes the key; anything else is stringified.
  Uri resolve(String pathOrUrl, {Map<String, dynamic>? query}) {
    final base = _join(pathOrUrl);
    if (query == null || query.isEmpty) return base;

    final merged = <String, List<String>>{...base.queryParametersAll};
    for (final entry in query.entries) {
      final value = entry.value;
      if (value == null) {
        merged.remove(entry.key);
      } else if (value is Iterable) {
        final values = <String>[
          for (final item in value)
            if (item != null) '$item',
        ];
        if (values.isEmpty) {
          merged.remove(entry.key);
        } else {
          merged[entry.key] = values;
        }
      } else {
        merged[entry.key] = <String>['$value'];
      }
    }

    if (merged.isEmpty) return _withoutQuery(base);
    return base.replace(queryParameters: merged);
  }

  Uri _join(String pathOrUrl) {
    final parsed = Uri.parse(pathOrUrl);
    if (parsed.hasScheme || parsed.hasAuthority) return parsed;

    final base = baseUrl;
    if (base == null || base.isEmpty) return parsed;

    final left = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    var right = pathOrUrl;
    while (right.startsWith('/')) {
      right = right.substring(1);
    }
    return Uri.parse(right.isEmpty ? left : '$left/$right');
  }

  /// Returns a copy with the given fields replaced. `null` keeps the current
  /// value.
  ClientSettings copyWith({
    String? baseUrl,
    Duration? timeout,
    Duration? connectTimeout,
    Duration? idleTimeout,
    HttpVersionPref? httpVersionPref,
    HttpHeaders? headers,
    String? userAgent,
    RedirectSettings? redirectSettings,
    bool? throwOnStatusCode,
    bool? enableCompression,
    TlsSettings? tlsSettings,
    ProxySettings? proxySettings,
    DnsSettings? dnsSettings,
    CookieSettings? cookieSettings,
    PoolSettings? poolSettings,
    CacheSettings? cacheSettings,
    String? altSvcCachePath,
    StreamChunkSettings? streamChunks,
  }) => ClientSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    timeout: timeout ?? this.timeout,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    idleTimeout: idleTimeout ?? this.idleTimeout,
    httpVersionPref: httpVersionPref ?? this.httpVersionPref,
    headers: headers ?? this.headers,
    userAgent: userAgent ?? this.userAgent,
    redirectSettings: redirectSettings ?? this.redirectSettings,
    throwOnStatusCode: throwOnStatusCode ?? this.throwOnStatusCode,
    enableCompression: enableCompression ?? this.enableCompression,
    tlsSettings: tlsSettings ?? this.tlsSettings,
    proxySettings: proxySettings ?? this.proxySettings,
    dnsSettings: dnsSettings ?? this.dnsSettings,
    cookieSettings: cookieSettings ?? this.cookieSettings,
    poolSettings: poolSettings ?? this.poolSettings,
    cacheSettings: cacheSettings ?? this.cacheSettings,
    altSvcCachePath: altSvcCachePath ?? this.altSvcCachePath,
    streamChunks: streamChunks ?? this.streamChunks,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientSettings &&
          other.baseUrl == baseUrl &&
          other.timeout == timeout &&
          other.connectTimeout == connectTimeout &&
          other.idleTimeout == idleTimeout &&
          other.httpVersionPref == httpVersionPref &&
          _headersEqual(other.headers, headers) &&
          other.userAgent == userAgent &&
          other.redirectSettings == redirectSettings &&
          other.throwOnStatusCode == throwOnStatusCode &&
          other.enableCompression == enableCompression &&
          other.tlsSettings == tlsSettings &&
          other.proxySettings == proxySettings &&
          other.dnsSettings == dnsSettings &&
          other.cookieSettings == cookieSettings &&
          other.poolSettings == poolSettings &&
          other.cacheSettings == cacheSettings &&
          other.altSvcCachePath == altSvcCachePath &&
          other.streamChunks == streamChunks;

  @override
  int get hashCode => Object.hash(
    baseUrl,
    timeout,
    connectTimeout,
    idleTimeout,
    httpVersionPref,
    // Headers are a mutable multimap; hashing their length keeps `hashCode`
    // consistent with `==` without walking the map on every lookup.
    headers?.length,
    userAgent,
    redirectSettings,
    throwOnStatusCode,
    enableCompression,
    tlsSettings,
    proxySettings,
    dnsSettings,
    cookieSettings,
    poolSettings,
    Object.hash(cacheSettings, altSvcCachePath, streamChunks),
  );

  @override
  String toString() =>
      'ClientSettings(baseUrl: $baseUrl, timeout: $timeout, '
      'connectTimeout: $connectTimeout, idleTimeout: $idleTimeout, '
      'httpVersionPref: ${httpVersionPref.name}, '
      'redirects: $redirectSettings, throwOnStatusCode: $throwOnStatusCode, '
      'compression: $enableCompression, tls: $tlsSettings, '
      'proxy: $proxySettings, dns: $dnsSettings, cookies: $cookieSettings, '
      'pool: $poolSettings, cache: $cacheSettings, '
      'altSvcCachePath: $altSvcCachePath, streamChunks: $streamChunks)';
}

Uri _withoutQuery(Uri uri) => uri.hasQuery
    ? Uri(
        scheme: uri.hasScheme ? uri.scheme : null,
        userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
        host: uri.hasAuthority ? uri.host : null,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
        fragment: uri.hasFragment ? uri.fragment : null,
      )
    : uri;

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _headersEqual(HttpHeaders? a, HttpHeaders? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  final left = a.entries.iterator;
  final right = b.entries.iterator;
  while (left.moveNext() && right.moveNext()) {
    if (left.current != right.current) return false;
  }
  return true;
}
