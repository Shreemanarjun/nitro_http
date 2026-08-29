// ─────────────────────────────────────────────────────────────────────────────
// nitro_http — Nitro bridge surface (transport types only).
//
// Nothing in this file is exported from `package:nitro_http`. Every type is
// `Raw*`-prefixed and belongs to the wire, not to users; the hand-written
// public API in `lib/src/api/` is the only supported surface.
//
// THREE INVARIANTS LIVE HERE. Breaking any of them produces data corruption
// that only shows up under concurrency.
//
// 1. STREAMS ARE MODULE-GLOBAL BROADCAST, NOT PER-INSTANCE.
//    The generated C++ bridge keeps a file-level static port registry per
//    stream *name* and ignores the instance id when registering. Therefore
//    `chunks`, `events` and `wsFrames` must have EXACTLY ONE internal
//    subscriber each, held by `RequestRunner`, which demultiplexes on the
//    `requestId` / `socketId` tag. A second subscription anywhere duplicates
//    delivery and double-frees zero-copy payloads.
//
// 2. ERRORS RIDE INSIDE THE RESULT RECORD, NOT AS EXCEPTIONS.
//    `@NitroResult` cannot combine with `@nitroNativeAsync` (validator E015),
//    and the bare native-async failure path can only post `kNull`. So every
//    response record opens with an error envelope — `errorKind`,
//    `errorMessage`, `engineErrorCode`. `errorKind == none` means the transfer
//    completed; a 500 response is a *success* at this layer. `HybridException`
//    is reserved for programming errors (bad instance key, malformed blob).
//
// 3. PARAMETER MEMORY DIES WHEN THE CALL RETURNS.
//    Nitro releases the parameter arena as soon as the registering call
//    returns. `sendBuffered`, `startStreamed`, `feedUploadChunk` and `wsSend`
//    MUST deep-copy the request blob and body bytes synchronously.
//
// There are no callbacks in this spec, on purpose: function-typed parameters
// are backed by one `NativeCallable` slot per (method, parameter), so two
// concurrent requests would clobber each other's callback. Progress and
// upload-drain notifications travel on the `events` stream instead.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:nitro/nitro.dart';

import 'nitro_http.platform.g.dart';

part 'nitro_http.g.dart';

// ── Enumerations ─────────────────────────────────────────────────────────────

@HybridEnum()
enum RawMethod { get, head, post, put, delete, patch, options, trace, custom }

/// What the caller *asks* for.
@HybridEnum()
enum RawHttpVersionPref {
  auto,
  http11Only,
  http2,
  http2Only,
  http3,
  http3Only,
}

/// What was actually negotiated.
@HybridEnum()
enum RawHttpVersion { unknown, http10, http11, http2, http3 }

/// Deliberately fine-grained: each case maps to exactly one Dart exception type
/// or one field on it, so the mapping table in `raw_mapping.dart` is total and
/// exhaustively testable. `timeoutIdle` is distinct from `timeoutRequest`
/// because someone debugging a hung streamed response needs to know which one
/// fired.
@HybridEnum()
enum RawErrorKind {
  none,
  cancelled,
  timeoutConnect,
  timeoutRequest,
  timeoutIdle,
  dnsFailure,
  connectionRefused,
  connectionReset,
  connectionFailed,
  tlsHandshake,
  certificateInvalid,
  certificatePinMismatch,
  certificateClientAuth,
  tooManyRedirects,
  proxyFailure,
  protocolError,
  unsupportedScheme,
  sendFailure,
  receiveFailure,
  decompressionFailure,
  responseTooLarge,
  io,
  cacheMiss,
  engineError,
  badRequest,
  unknown,
}

@HybridEnum()
enum RawProxyMode { system, none, http, socks5, socks5Hostname }

@HybridEnum()
enum RawCacheMode { normal, noStore, bypass, onlyIfCached, refresh }

@HybridEnum()
enum RawBodyKind { none, bytes, filePath, streamed }

@HybridEnum()
enum RawChunkKind { data, done, error }

@HybridEnum()
enum RawEventKind { downloadProgress, uploadProgress, uploadDrain, notice }

// ── Configuration records ────────────────────────────────────────────────────
//
// Fields are non-nullable with sentinel conventions (`-1` = inherit from the
// client, `''` = unset). A nullable primitive inside a record costs a tag byte
// and an extra branch in the C++ reader, for no benefit at this layer.

/// Headers travel as an ordered list of pairs, never a `Map`. A map would lose
/// duplicates (`Set-Cookie`) and ordering, and `Map<String, T>` falls back to
/// JSON on the bridge whereas a record list uses the binary codec.
@HybridRecord()
class RawHeader {
  final String name;
  final String value;
  const RawHeader({required this.name, required this.value});
}

@HybridRecord()
class RawTlsConfig {
  /// `false` is dev-only; the engine logs a warning on every request.
  final bool verifyCertificates;

  /// 0 platform trust · 1 bundled Mozilla roots · 2 custom PEM · 3 none.
  final int rootCaSource;

  /// PEM bundle used when [rootCaSource] == 2.
  final String trustedRootsPem;

  /// mTLS material. `''` = no client certificate.
  final String clientCertPem;
  final String clientKeyPem;
  final String clientKeyPassword;

  /// Base64 SPKI SHA-256 hashes. Empty = no pinning.
  final List<String> pinnedSpkiSha256;

  /// 0 = engine default, 12 = TLS 1.2, 13 = TLS 1.3.
  final int minTlsVersion;
  final int maxTlsVersion;

  /// `''` = derive from the URL.
  final String sniHostname;

  const RawTlsConfig({
    this.verifyCertificates = true,
    this.rootCaSource = 0,
    this.trustedRootsPem = '',
    this.clientCertPem = '',
    this.clientKeyPem = '',
    this.clientKeyPassword = '',
    this.pinnedSpkiSha256 = const <String>[],
    this.minTlsVersion = 0,
    this.maxTlsVersion = 0,
    this.sniHostname = '',
  });
}

@HybridRecord()
class RawProxyConfig {
  final RawProxyMode mode;

  /// `host:port`, optionally scheme-prefixed.
  final String url;
  final String username;
  final String password;

  /// Comma-separated host patterns bypassing the proxy.
  final String noProxyHosts;

  const RawProxyConfig({
    this.mode = RawProxyMode.system,
    this.url = '',
    this.username = '',
    this.password = '',
    this.noProxyHosts = '',
  });
}

@HybridRecord()
class RawDnsConfig {
  /// `"host:port:ip1,ip2"` entries fed to `CURLOPT_RESOLVE`.
  final List<String> staticOverrides;

  /// DNS-over-HTTPS endpoint. `''` = system resolver.
  final String dohUrl;

  const RawDnsConfig({
    this.staticOverrides = const <String>[],
    this.dohUrl = '',
  });
}

@HybridRecord()
class RawCookieConfig {
  final bool enabled;

  /// Netscape jar path. `''` = in-memory only.
  final String persistPath;

  const RawCookieConfig({this.enabled = true, this.persistPath = ''});
}

@HybridRecord()
class RawPoolConfig {
  final int maxConnections;
  final int maxConnectionsPerHost;
  final int idleTimeoutMs;
  final int maxLifetimeMs;

  /// HTTP/2 keep-alive ping interval. 0 = off.
  final int keepAlivePingMs;

  const RawPoolConfig({
    this.maxConnections = 0,
    this.maxConnectionsPerHost = 0,
    this.idleTimeoutMs = 0,
    this.maxLifetimeMs = 0,
    this.keepAlivePingMs = 0,
  });
}

@HybridRecord()
class RawClientConfig {
  final RawHttpVersionPref httpVersion;

  /// 0 = engine default.
  final int connectTimeoutMs;

  /// 0 = no total-request timeout.
  final int requestTimeoutMs;

  /// Abort a transfer that goes quiet for this long. 0 = off.
  ///
  /// A real no-byte-for-N-ms deadline enforced by the engine's own event loop,
  /// NOT curl's `CURLOPT_LOW_SPEED_LIMIT`. A rate floor averages over a rolling
  /// window, so a body that delivers a large chunk and then stalls for ten
  /// seconds keeps a healthy average and is never aborted; `LOW_SPEED_TIME` is
  /// also whole seconds, which silently rounds a sub-second budget away. The
  /// clock is armed by the first response header, so a slow connect stays
  /// charged to the connect budget, and it pauses while either direction is
  /// paused for flow control — a consumer that stopped granting credit is not a
  /// peer that went quiet.
  final int idleTimeoutMs;

  final bool followRedirects;
  final int maxRedirects;

  /// Advertise and transparently decode gzip / brotli / zstd.
  final bool enableCompression;
  final bool enableCache;

  final String userAgent;

  /// Alt-Svc cache used for HTTP/3 discovery. `''` = disabled.
  final String altSvcCachePath;

  /// Target size, in bytes, of a streamed response chunk.
  /// `0` = adapt to the body size, `-1` = never batch, `>0` = that exact size.
  ///
  /// curl hands the engine 16 KiB at a time, and emitting each one costs a chunk
  /// struct, a zero-copy proxy with a finalizer, a credit and a `controller.add`
  /// — measured at 4.81 us. Over a 32 MiB body that is 2050 emits and 9.9 ms,
  /// 7.4 % of the transfer. Batching them into 64 KiB cut it to 1.8-2.9 ms and
  /// took the download from last place to first.
  ///
  /// `-1` is what a latency-sensitive stream wants: server-sent events or a long
  /// poll must never have a byte held back waiting for more that may be seconds
  /// away.
  final int streamChunkBytes;

  /// Smallest `Content-Length` that opts into batching. `0` = engine default.
  ///
  /// Below it a response streams as it arrives, so the guarantee above holds for
  /// anything short or of unknown length without the caller configuring
  /// anything. A decoded body never batches regardless: its inflated size is
  /// unknown until the last byte.
  final int streamChunkMinContentLength;

  /// Longest a batched chunk may be held waiting to fill. `0` = engine default.
  ///
  /// The size ladder assumes a large body also arrives quickly, which is true on
  /// a fast link and false on a slow one — a 100 MiB download over a bad mobile
  /// connection would otherwise sit on a half-full 512 KiB buffer for seconds.
  /// The engine flushes anything older than this regardless of how full it is, so
  /// batching can never convert a throughput win into a latency regression.
  final int streamChunkMaxHoldMs;

  /// Refuse a response body larger than this, in bytes. `0` = no ceiling.
  ///
  /// The content-decoding ceiling only bounds what a *compressed* body inflates
  /// to; an uncompressed one has no limit at all without this. A caller that
  /// knows its API never returns more than a few MiB can say so and have a
  /// runaway response fail instead of filling memory.
  final int maxResponseBytes;

  /// HSTS cache file. `''` = disabled.
  ///
  /// Same shape as [altSvcCachePath]: a file the engine reads at start and
  /// writes back, so a host that said "HTTPS only" is still remembered next
  /// launch and an `http://` URL for it never leaves the device in the clear.
  final String hstsCachePath;

  /// Unix domain socket to send every request over. `''` = ordinary TCP.
  ///
  /// The URL still carries the host, which becomes the `Host` header — the
  /// socket replaces only the transport, which is how a local daemon expects
  /// to be addressed.
  final String unixSocketPath;

  /// Local network interface, IP or host name to bind outgoing connections to.
  /// `''` = let the OS choose.
  final String networkInterface;

  final List<RawHeader> defaultHeaders;
  final RawTlsConfig tls;
  final RawProxyConfig proxy;
  final RawDnsConfig dns;
  final RawCookieConfig cookies;
  final RawPoolConfig pool;

  const RawClientConfig({
    required this.httpVersion,
    required this.connectTimeoutMs,
    required this.requestTimeoutMs,
    required this.idleTimeoutMs,
    required this.followRedirects,
    required this.maxRedirects,
    required this.enableCompression,
    required this.enableCache,
    this.userAgent = '',
    this.altSvcCachePath = '',
    required this.streamChunkBytes,
    required this.streamChunkMinContentLength,
    required this.streamChunkMaxHoldMs,
    this.maxResponseBytes = 0,
    this.hstsCachePath = '',
    this.unixSocketPath = '',
    this.networkInterface = '',
    this.defaultHeaders = const <RawHeader>[],
    this.tls = const RawTlsConfig(),
    this.proxy = const RawProxyConfig(),
    this.dns = const RawDnsConfig(),
    this.cookies = const RawCookieConfig(),
    this.pool = const RawPoolConfig(),
  });
}

// ── Request and response records ─────────────────────────────────────────────

@HybridRecord()
class RawRequestOptions {
  /// `-1` inherits the client setting.
  final int connectTimeoutMs;
  final int requestTimeoutMs;

  /// `-1` inherit · 0 no · 1 yes.
  final int followRedirects;
  final int maxRedirects;

  final RawCacheMode cacheMode;

  /// Emit `downloadProgress` / `uploadProgress` events for this transfer.
  final bool reportProgress;
  final bool wantTimings;

  /// `-1` = unknown, forcing `Transfer-Encoding: chunked`.
  final int uploadContentLength;

  /// Per-request SPKI pin overriding the client's. `''` = client default.
  final String pinnedSpkiOverride;

  /// Binds this transfer to a native cancellation token. `0` = none.
  ///
  /// The engine resolves the id to a shared, atomically-readable flag that
  /// outlives any one request, which buys two things Dart-side fan-out cannot:
  /// a transfer submitted *after* the token was cancelled never opens a socket,
  /// and cancelling N bound transfers is one call instead of N.
  final int cancelTokenId;

  const RawRequestOptions({
    this.connectTimeoutMs = -1,
    this.requestTimeoutMs = -1,
    this.followRedirects = -1,
    this.maxRedirects = -1,
    this.cacheMode = RawCacheMode.normal,
    this.reportProgress = false,
    this.wantTimings = false,
    this.uploadContentLength = -1,
    this.pinnedSpkiOverride = '',
    this.cancelTokenId = 0,
  });
}

@HybridRecord()
class RawRequest {
  /// Dart-side monotonic id. The key for cancellation, credits and events.
  final int requestId;

  final RawMethod method;

  /// Used when [method] == [RawMethod.custom].
  final String customMethod;

  /// Absolute URL. Dart has already resolved `baseUrl` and the query string.
  final String url;

  final List<RawHeader> headers;
  final RawBodyKind bodyKind;

  /// Used when [bodyKind] == [RawBodyKind.filePath]; curl reads it directly, so
  /// a 500 MB upload never allocates a Dart buffer.
  final String bodyFilePath;

  /// Write the response body to this path instead of delivering it. `''` =
  /// deliver it as bytes or chunks.
  ///
  /// The point is that the bytes never enter the Dart heap: a multi-gigabyte
  /// download costs the engine a `FILE*` and the caller a path.
  final String responseFilePath;

  final RawRequestOptions options;

  const RawRequest({
    required this.requestId,
    this.method = RawMethod.get,
    this.customMethod = '',
    required this.url,
    this.headers = const <RawHeader>[],
    this.bodyKind = RawBodyKind.none,
    this.bodyFilePath = '',
    this.responseFilePath = '',
    this.options = const RawRequestOptions(),
  });
}

@HybridRecord()
class RawTimings {
  final double queueMs;
  final double dnsMs;
  final double connectMs;
  final double tlsMs;
  final double firstByteMs;
  final double redirectMs;
  final double totalMs;

  const RawTimings({
    this.queueMs = 0,
    this.dnsMs = 0,
    this.connectMs = 0,
    this.tlsMs = 0,
    this.firstByteMs = 0,
    this.redirectMs = 0,
    this.totalMs = 0,
  });
}

@HybridRecord()
class RawResponse {
  // Error envelope first — a partially decoded record still yields the failure.
  final int requestId;
  final RawErrorKind errorKind;
  final String errorMessage;

  /// Raw CURLcode, for diagnostics only.
  final int engineErrorCode;

  // Success payload.
  final int statusCode;

  /// The status line's reason phrase, verbatim. Empty when the server sent none
  /// (HTTP/2 and HTTP/3 have no reason phrase at all). Carried on the wire rather
  /// than derived from [statusCode] because a server is free to send a custom
  /// one, and `package:http`'s conformance suite checks exactly that.
  final String reasonPhrase;

  final RawHttpVersion version;
  final String finalUrl;
  final int redirectCount;
  final List<RawHeader> headers;

  /// Already decompressed. Empty when [errorKind] != none.
  final Uint8List body;

  final bool fromCache;
  final bool revalidated;
  final String primaryIp;
  final int primaryPort;
  final RawTimings timings;

  const RawResponse({
    required this.requestId,
    this.errorKind = RawErrorKind.none,
    this.errorMessage = '',
    this.engineErrorCode = 0,
    this.statusCode = 0,
    this.reasonPhrase = '',
    this.version = RawHttpVersion.unknown,
    this.finalUrl = '',
    this.redirectCount = 0,
    this.headers = const <RawHeader>[],
    required this.body,
    this.fromCache = false,
    this.revalidated = false,
    this.primaryIp = '',
    this.primaryPort = 0,
    this.timings = const RawTimings(),
  });
}

/// The streamed path's head: [RawResponse] minus the body.
@HybridRecord()
class RawResponseHead {
  final int requestId;
  final RawErrorKind errorKind;
  final String errorMessage;
  final int engineErrorCode;
  final int statusCode;
  final String reasonPhrase;
  final RawHttpVersion version;
  final String finalUrl;
  final int redirectCount;
  final List<RawHeader> headers;
  final bool fromCache;

  /// `-1` when the server did not declare one.
  final int contentLength;

  final String primaryIp;
  final int primaryPort;
  final RawTimings timings;

  const RawResponseHead({
    required this.requestId,
    this.errorKind = RawErrorKind.none,
    this.errorMessage = '',
    this.engineErrorCode = 0,
    this.statusCode = 0,
    this.reasonPhrase = '',
    this.version = RawHttpVersion.unknown,
    this.finalUrl = '',
    this.redirectCount = 0,
    this.headers = const <RawHeader>[],
    this.fromCache = false,
    this.contentLength = -1,
    this.primaryIp = '',
    this.primaryPort = 0,
    this.timings = const RawTimings(),
  });
}

@HybridRecord()
class RawEvent {
  final int requestId;
  final RawEventKind kind;

  /// progress: bytes transferred · drain: bytes still buffered.
  final int a;

  /// progress: total bytes, `-1` when unknown.
  final int b;

  /// [RawEventKind.notice] only; `''` otherwise.
  final String message;

  const RawEvent({
    required this.requestId,
    required this.kind,
    required this.a,
    required this.b,
    required this.message,
  });
}

// ── Cookie, cache and WebSocket records ──────────────────────────────────────

@HybridRecord()
class RawCookie {
  final String name;
  final String value;
  final String domain;
  final String path;

  /// 0 = session cookie.
  final int expiresEpochMs;

  final bool secure;
  final bool httpOnly;

  const RawCookie({
    required this.name,
    required this.value,
    this.domain = '',
    this.path = '',
    this.expiresEpochMs = 0,
    this.secure = false,
    this.httpOnly = false,
  });
}

@HybridRecord()
class RawCacheConfig {
  final bool enabled;
  final String directory;
  final int maxSizeBytes;
  final int maxEntryBytes;

  const RawCacheConfig({
    this.enabled = true,
    required this.directory,
    this.maxSizeBytes = 0,
    this.maxEntryBytes = 0,
  });
}

@HybridRecord()
class RawCacheStats {
  final int entryCount;
  final int sizeBytes;
  final int hitCount;
  final int missCount;
  final int revalidationCount;
  final int evictionCount;

  const RawCacheStats({
    this.entryCount = 0,
    this.sizeBytes = 0,
    this.hitCount = 0,
    this.missCount = 0,
    this.revalidationCount = 0,
    this.evictionCount = 0,
  });
}

@HybridRecord()
class RawWsConfig {
  final int socketId;

  /// `ws://` or `wss://`.
  final String url;
  final List<String> protocols;
  final List<RawHeader> headers;

  /// Automatic ping interval. 0 = off.
  final int pingIntervalMs;
  final int maxFrameBytes;
  final int connectTimeoutMs;

  /// TLS for a `wss://` socket.
  ///
  /// Without this the engine had no choice but to hardcode its defaults —
  /// verification on, platform roots — so a WebSocket could not use custom
  /// roots, SPKI pinning, mTLS or a version clamp, even though the same client
  /// applied all of them to its HTTP requests. Ignored for `ws://`.
  final RawTlsConfig tls;

  const RawWsConfig({
    required this.socketId,
    required this.url,
    this.protocols = const <String>[],
    this.headers = const <RawHeader>[],
    this.pingIntervalMs = 0,
    this.maxFrameBytes = 0,
    this.connectTimeoutMs = 0,
    this.tls = const RawTlsConfig(),
  });
}

@HybridRecord()
class RawWsHandshake {
  final int socketId;
  final RawErrorKind errorKind;
  final String errorMessage;
  final int engineErrorCode;
  final int statusCode;
  final String negotiatedProtocol;
  final List<RawHeader> responseHeaders;

  const RawWsHandshake({
    required this.socketId,
    this.errorKind = RawErrorKind.none,
    this.errorMessage = '',
    this.engineErrorCode = 0,
    this.statusCode = 0,
    this.negotiatedProtocol = '',
    this.responseHeaders = const <RawHeader>[],
  });
}

// ── Zero-copy stream structs ─────────────────────────────────────────────────
//
// The hot path: potentially thousands per second. They carry NO String fields —
// each would cost a `strdup` per emit — so error text rides in the byte payload
// with a discriminating `kind`.

@HybridStruct(zeroCopy: ['bytes'])
class RawChunk {
  /// data: body bytes · done: trailer block · error: UTF-8 message.
  final Uint8List bytes;
  final int requestId;

  /// [RawChunkKind] index.
  final int kind;

  /// error: [RawErrorKind] index · done: 0.
  final int aux;

  const RawChunk({
    required this.bytes,
    required this.requestId,
    required this.kind,
    required this.aux,
  });
}

@HybridStruct(zeroCopy: ['payload'])
class RawWsFrame {
  /// text/binary payload · close: 2-byte code followed by a UTF-8 reason.
  final Uint8List payload;
  final int socketId;

  /// 1 text · 2 binary · 8 close · 9 ping · 10 pong · 255 transport error.
  final int opcode;

  /// bit0 = fin.
  final int flags;

  const RawWsFrame({
    required this.payload,
    required this.socketId,
    required this.opcode,
    required this.flags,
  });
}

// ── The module ───────────────────────────────────────────────────────────────
//
// ONE spec class, because each `*.native.dart` spec produces its own shared
// library — two spec files could not share a `curl_multi` pool, a cookie jar or
// a disk cache without cross-dylib symbol wiring on five platforms. Role
// separation therefore rides on the multi-instance factory key:
//
//   'engine'      process-wide singleton: cache config, prefetch, capabilities
//   'c:<id>'      one CurlEngine: event loop, pool, cookie jar, TLS config
//   'ws:<id>'     one WebSocket session
//
// `cSymbolPrefix` pins the C namespace to `nitro_http_` even though the class
// is `NitroHttpNative`, so the public API is free to use the name `NitroHttp`.

@NitroModule(
  ios: AppleNativeImpl.cpp,
  macos: AppleNativeImpl.cpp,
  android: AndroidNativeImpl.cpp,
  // Generic `NativeImpl.cpp` (not the platform-specific markers) keeps Windows
  // and Linux sharing the single `src/HybridNitroHttp.cpp` translation unit
  // rather than each getting its own copy to drift apart.
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
  // Declared so the generator splits the FFI types out of the shared bridge:
  // `dart:ffi` in any transitively imported library fails a web compile, even
  // though the browser never loads this module. `executor_web.dart` serves web
  // through `fetch` and never touches the WASM bridge.
  web: WebNativeImpl.wasm,
  cSymbolPrefix: 'nitro_http',
  lib: 'nitro_http',
)
abstract class NitroHttpNative extends HybridObject {
  /// Process-wide singleton: cache configuration, prefetch, capability queries.
  static final NitroHttpNative engine = createNitroHttpNativeInstance('engine');

  /// Role-typed instance. Keys: `engine` | `c:<clientId>` | `ws:<socketId>`.
  static NitroHttpNative forKey(String key) =>
      createNitroHttpNativeInstance(key);

  // ── Capabilities (valid on any instance) ───────────────────────────────────

  /// e.g. `libcurl/8.21.0 OpenSSL/3.5.0 nghttp2/1.70.0 ngtcp2/1.25.0`.
  String engineVersion();

  bool supportsHttp3();
  bool supportsWebSockets();
  bool supportsBrotli();
  bool supportsZstd();

  /// Hot-restart recovery: abort every transfer, join every thread, flush jars.
  /// The Dart layer calls this once at startup, before creating any client.
  void resetNative();

  // ── Client role: 'c:<clientId>' ────────────────────────────────────────────

  /// Synchronous by design — there is no reason to make users `await` a client
  /// constructor when configuration is a sub-microsecond FFI call.
  void configureClient(RawClientConfig config);

  @nitroNativeAsync
  Future<RawResponse> sendBuffered(RawRequest request, @zeroCopy Uint8List body);

  /// [sendBuffered] with its completion batched through a [NitroCoalescer].
  ///
  /// Same transfer, same result — only the delivery differs. `sendBuffered`
  /// posts its own result over its own `ReceivePort`, so 64 requests finishing
  /// together wake the isolate 64 times; the measured floor for one such round
  /// trip is 37 us and it is 74 % of everything this client spends outside curl
  /// (`handoff_cost_test`). Here the engine buffers completions and posts each
  /// drained batch as ONE `kArray`, so a burst shares one wake.
  ///
  /// Sync, not `@nitroNativeAsync`: it returns the instant the request is
  /// queued. The result arrives later on [dartPort], addressed by [callId].
  ///
  /// A coalescer carries `int64` values only, so the value posted back is the
  /// ADDRESS of the encoded `RawResponse` blob. That costs nothing extra — the
  /// non-coalesced path already posts exactly this pointer as an int64 — but it
  /// does move ownership: **Dart must decode the blob and free it**, which
  /// `RequestRunner` does. Native does not free it after posting.
  ///
  /// Buffered responses only. Streamed transfers already deliver their body over
  /// the module-global `chunks` stream, which is one subscriber and therefore
  /// already coalesced by construction.
  void sendBufferedCoalesced(
    int callId,
    RawRequest request,
    @zeroCopy Uint8List body,
    int dartPort,
  );

  /// Frees a record blob whose address arrived over a coalesced batch.
  ///
  /// The non-coalesced path never needs this: the generated `unpack` owns the
  /// pointer and calls the module's `nitro_free` itself. A coalesced completion
  /// hands Dart a bare integer instead, so the release has to be explicit — and
  /// it has to run through the engine's own C runtime. `package:ffi`'s
  /// `malloc.free` is NOT interchangeable with the allocator the plugin's binary
  /// used, which is precisely the mismatch that makes Windows abort.
  ///
  /// Idempotent only against zero. Passing an address twice is a double free.
  void releaseRecord(int address);

  @nitroNativeAsync
  Future<RawResponseHead> startStreamed(
    RawRequest request,
    @zeroCopy Uint8List body,
  );

  void cancel(int requestId);
  void cancelAll();

  /// Cancels every transfer bound to [tokenId], on every client, and marks the
  /// token so a transfer submitted later is refused before it opens a socket.
  ///
  /// The flag is raised on the calling thread before any engine is notified, so
  /// an in-flight transfer aborts at its next curl callback rather than waiting
  /// for a loop turn. The per-engine notification that follows exists for
  /// transfers that are paused or idle and therefore running no callbacks.
  ///
  /// Idempotent: the first [reason] is the one reported. Cancelling a token
  /// that has no transfers bound is legal and is how a pre-emptive cancel works.
  void cancelToken(int tokenId, String reason);

  /// Drops [tokenId] from the native registry.
  ///
  /// Purely a memory concern — a token already bound to a transfer keeps its
  /// state alive through that transfer's own reference, so releasing early can
  /// never resurrect a cancelled transfer. Omitting the call leaks one small
  /// entry per token, which is why Dart releases from a `Finalizer`.
  void releaseCancelToken(int tokenId);

  /// Download flow control **and** payload release, in one sub-microsecond call.
  ///
  /// [chunkCount] additional chunks may be emitted for [requestId]; at zero
  /// native returns `CURL_WRITEFUNC_PAUSE`, which closes the TCP window — real
  /// backpressure rather than a Dart-side buffer.
  ///
  /// [ackedChunks] is the cumulative number of chunks the runner has copied out
  /// of native memory for this request. It exists because
  /// `nitro_http_release_RawChunk` frees only the struct shell: the zero-copy
  /// payload stays native-owned with no other completion signal. Native frees
  /// every payload with sequence `< ackedChunks`, so the ack is what makes the
  /// zero-copy path leak-free *and* use-after-free-free. Passing a value the
  /// runner has not actually copied is memory corruption.
  void grantCredit(int requestId, int chunkCount, int ackedChunks);

  /// Upload flow control. Returns the bytes currently buffered in the native
  /// ring, so the runner can pause its Dart source above a high-water mark.
  int feedUploadChunk(int requestId, @zeroCopy Uint8List chunk);

  void finishUpload(int requestId);

  /// Aborts a streamed upload with an error instead of a clean EOF.
  void failUpload(int requestId, String message);

  // Cookies. `getCookies` returns the whole jar; Dart filters by domain/path.
  List<RawCookie> getCookies(String url);
  void setCookie(RawCookie cookie);
  void clearCookies();
  void flushCookies();

  // ── Engine role: 'engine' ──────────────────────────────────────────────────

  void configureCache(RawCacheConfig config);

  /// Fetches, populates the cache, and returns the response with an empty body.
  /// Identical in-flight prefetches are deduplicated by cache key.
  @nitroNativeAsync
  Future<RawResponse> prefetch(RawRequest request);

  void clearCache();
  RawCacheStats cacheStats();

  // ── WebSocket role: 'ws:<socketId>' ───────────────────────────────────────

  @nitroNativeAsync
  Future<RawWsHandshake> wsConnect(RawWsConfig config);

  /// Returns the bytes still queued for transmission.
  int wsSend(int opcode, @zeroCopy Uint8List payload);

  void wsClose(int code, String reason);
  /// Frame flow control and payload release — [ackedFrames] carries the same
  /// meaning as `grantCredit`'s `ackedChunks`.
  void wsGrantCredit(int frameCount, int ackedFrames);

  // ── Module-global streams — EXACTLY ONE internal subscriber each ───────────
  //
  // See invariant 1 in the file header. `Backpressure.block` is forbidden here:
  // it blocks the emitting thread, which is the `curl_multi` event loop, and
  // would stall every other in-flight request on that client. `bufferDrop`
  // provably never drops a body byte because per-request credits (<= 32) stay
  // below the ring size (64) and native never emits beyond its credit.

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<RawChunk> get chunks;

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<RawEvent> get events;

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<RawWsFrame> get wsFrames;
}
