/// Translation between the hand-written public API and the `Raw*` wire types.
///
/// This file and `request_runner.dart` are the only two places in the package
/// that import the generated spec. Everything above them speaks in
/// `ClientSettings` / `HttpRequest` / `HttpResponse`; everything below speaks in
/// records with sentinel conventions.
///
/// The `RawErrorKind` → exception table at the bottom is an exhaustive `switch`
/// on purpose: adding a case to the enum becomes a compile error here rather
/// than a silent `NitroHttpUnknownException` at runtime.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../api/body.dart';
import '../api/cache.dart';
import '../api/cookies.dart';
import '../api/exceptions.dart';
import '../api/headers.dart';
import '../api/request.dart';
import '../api/response.dart';
import '../api/settings.dart';
import '../nitro_http.native.dart';

// ── Settings → RawClientConfig ───────────────────────────────────────────────

/// Sentinel meaning "no value"; the engine treats 0 as "use the curl default"
/// for timeouts and "unlimited" for the total-request timeout.
int _ms(Duration? d) => d == null ? 0 : d.inMilliseconds;

RawTlsConfig toRawTls(TlsSettings tls) {
  final cert = tls.clientCertificate;
  return RawTlsConfig(
    verifyCertificates: tls.verifyCertificates,
    rootCaSource: switch (tls.rootCaSource) {
      RootCaSource.platform => 0,
      RootCaSource.bundled => 1,
      RootCaSource.custom => 2,
      RootCaSource.none => 3,
    },
    trustedRootsPem: tls.trustedRootsPem ?? '',
    clientCertPem: cert?.certificatePem ?? '',
    clientKeyPem: cert?.privateKeyPem ?? '',
    clientKeyPassword: cert?.password ?? '',
    pinnedSpkiSha256: List<String>.unmodifiable(tls.pinnedSpkiSha256),
    minTlsVersion: tls.minVersion?.wireValue ?? 0,
    maxTlsVersion: tls.maxVersion?.wireValue ?? 0,
    sniHostname: tls.sniHostname ?? '',
  );
}

RawProxyConfig toRawProxy(ProxySettings proxy) {
  return switch (proxy) {
    SystemProxySettings() => const RawProxyConfig(
      mode: RawProxyMode.system,
      url: '',
      username: '',
      password: '',
      noProxyHosts: '',
    ),
    NoProxySettings() => const RawProxyConfig(
      mode: RawProxyMode.none,
      url: '',
      username: '',
      password: '',
      noProxyHosts: '',
    ),
    ManualProxySettings(
      :final mode,
      :final url,
      :final username,
      :final password,
      :final noProxy,
    ) =>
      RawProxyConfig(
        mode: switch (mode) {
          ProxyKind.http => RawProxyMode.http,
          ProxyKind.socks5 => RawProxyMode.socks5,
          ProxyKind.socks5Hostname => RawProxyMode.socks5Hostname,
        },
        url: url,
        username: username ?? '',
        password: password ?? '',
        noProxyHosts: noProxy ?? '',
      ),
  };
}

RawDnsConfig toRawDns(DnsSettings dns) {
  return switch (dns) {
    SystemDnsSettings() => const RawDnsConfig(
      staticOverrides: <String>[],
      dohUrl: '',
    ),
    StaticDnsSettings() => RawDnsConfig(
      staticOverrides: dns.toResolveEntries(),
      dohUrl: '',
    ),
    DohDnsSettings(:final url) => RawDnsConfig(
      staticOverrides: const <String>[],
      dohUrl: url,
    ),
  };
}

RawClientConfig toRawClientConfig(ClientSettings s) {
  final headers = <RawHeader>[
    for (final (name, value) in s.headers?.entries ?? const <(String, String)>[])
      RawHeader(name: name, value: value),
  ];
  final pool = s.poolSettings;
  return RawClientConfig(
    httpVersion: switch (s.httpVersionPref) {
      HttpVersionPref.auto => RawHttpVersionPref.auto,
      HttpVersionPref.http11Only => RawHttpVersionPref.http11Only,
      HttpVersionPref.http2 => RawHttpVersionPref.http2,
      HttpVersionPref.http2Only => RawHttpVersionPref.http2Only,
      HttpVersionPref.http3 => RawHttpVersionPref.http3,
      HttpVersionPref.http3Only => RawHttpVersionPref.http3Only,
    },
    connectTimeoutMs: _ms(s.connectTimeout),
    requestTimeoutMs: _ms(s.timeout),
    idleTimeoutMs: _ms(s.idleTimeout),
    followRedirects: s.redirectSettings.follow,
    maxRedirects: s.redirectSettings.maxRedirects,
    enableCompression: s.enableCompression,
    enableCache: s.cacheSettings.enabled,
    userAgent: s.userAgent ?? defaultUserAgent,
    altSvcCachePath: s.altSvcCachePath ?? '',
    streamChunkBytes: s.streamChunks.bytes,
    streamChunkMinContentLength: s.streamChunks.minContentLength,
    streamChunkMaxHoldMs: s.streamChunks.maxHold.inMilliseconds,
    defaultHeaders: headers,
    tls: toRawTls(s.tlsSettings),
    proxy: toRawProxy(s.proxySettings),
    dns: toRawDns(s.dnsSettings),
    cookies: RawCookieConfig(
      enabled: s.cookieSettings.storeCookies,
      persistPath: s.cookieSettings.persistPath ?? '',
    ),
    pool: RawPoolConfig(
      maxConnections: pool.maxConnections,
      maxConnectionsPerHost: pool.maxConnectionsPerHost,
      idleTimeoutMs: pool.idleTimeout.inMilliseconds,
      maxLifetimeMs: pool.maxLifetime.inMilliseconds,
      keepAlivePingMs: pool.keepAlivePingInterval?.inMilliseconds ?? 0,
    ),
  );
}

/// Sent unless the caller overrides it. Naming the engine makes server-side
/// debugging of a native-transport client dramatically easier.
const String defaultUserAgent = 'nitro_http/0.0.1';

RawCacheConfig toRawCacheConfig(HttpCacheConfig c) => RawCacheConfig(
  enabled: c.enabled,
  directory: c.directory,
  maxSizeBytes: c.maxSizeBytes,
  maxEntryBytes: c.maxEntryBytes,
);

CacheStats fromRawCacheStats(RawCacheStats s) => CacheStats(
  entryCount: s.entryCount,
  sizeBytes: s.sizeBytes,
  hitCount: s.hitCount,
  missCount: s.missCount,
  revalidationCount: s.revalidationCount,
  evictionCount: s.evictionCount,
);

// ── Cookies ──────────────────────────────────────────────────────────────────

Cookie fromRawCookie(RawCookie c) => Cookie(
  name: c.name,
  value: c.value,
  domain: c.domain,
  path: c.path,
  expires: c.expiresEpochMs == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(c.expiresEpochMs),
  secure: c.secure,
  httpOnly: c.httpOnly,
);

RawCookie toRawCookie(Cookie c) => RawCookie(
  name: c.name,
  value: c.value,
  domain: c.domain,
  path: c.path.isEmpty ? '/' : c.path,
  expiresEpochMs: c.expires?.millisecondsSinceEpoch ?? 0,
  secure: c.secure,
  httpOnly: c.httpOnly,
);

// ── Request → RawRequest ─────────────────────────────────────────────────────

/// The `-1` sentinel every per-request numeric option uses to mean
/// "inherit from the client".
const int kInherit = -1;

RawMethod toRawMethod(HttpMethod m) => switch (m) {
  HttpMethod.get => RawMethod.get,
  HttpMethod.head => RawMethod.head,
  HttpMethod.post => RawMethod.post,
  HttpMethod.put => RawMethod.put,
  HttpMethod.delete => RawMethod.delete,
  HttpMethod.patch => RawMethod.patch,
  HttpMethod.options => RawMethod.options,
  HttpMethod.trace => RawMethod.trace,
  HttpMethod.custom => RawMethod.custom,
};

RawCacheMode toRawCacheMode(CacheMode? m) => switch (m) {
  null || CacheMode.normal => RawCacheMode.normal,
  CacheMode.noStore => RawCacheMode.noStore,
  CacheMode.bypass => RawCacheMode.bypass,
  CacheMode.onlyIfCached => RawCacheMode.onlyIfCached,
  CacheMode.refresh => RawCacheMode.refresh,
};

RawRequestOptions toRawOptions(
  RequestOptions o, {
  required bool reportProgress,
  required int uploadContentLength,
  int cancelTokenId = 0,
}) {
  return RawRequestOptions(
    connectTimeoutMs: o.connectTimeout?.inMilliseconds ?? kInherit,
    requestTimeoutMs: o.timeout?.inMilliseconds ?? kInherit,
    followRedirects: switch (o.followRedirects) {
      null => kInherit,
      true => 1,
      false => 0,
    },
    maxRedirects: o.maxRedirects ?? kInherit,
    cacheMode: toRawCacheMode(o.cacheMode),
    reportProgress: reportProgress,
    wantTimings: o.wantTimings ?? true,
    uploadContentLength: uploadContentLength,
    pinnedSpkiOverride: o.pinnedSpkiSha256 ?? '',
    cancelTokenId: cancelTokenId,
  );
}

/// The wire form of a request body, plus the bytes that accompany it.
///
/// `bodyKind` is a discriminator rather than a nullable `Uint8List` because
/// Nitro cannot carry `TypedData?` across the boundary (it is two FFI
/// parameters, and nullability would need a third).
class EncodedBody {
  EncodedBody({
    required this.kind,
    required this.bytes,
    this.filePath = '',
    this.stream,
    this.contentLength,
    this.contentType,
  });

  final RawBodyKind kind;
  final Uint8List bytes;
  final String filePath;
  final Stream<List<int>>? stream;
  final int? contentLength;
  final String? contentType;

  static final EncodedBody none = EncodedBody(
    kind: RawBodyKind.none,
    bytes: Uint8List(0),
  );
}

/// Renders a public [HttpBody] into its wire form.
///
/// Multipart is composed here in Dart, not natively: composing it as a lazy
/// stream means a file part is read from disk in chunks instead of being
/// materialised, which is the whole reason `HttpBody.file` and multipart-with-
/// files do not blow up on a 500 MB attachment.
Future<EncodedBody> encodeBody(HttpBody? body) async {
  switch (body) {
    case null:
      return EncodedBody.none;

    case HttpTextBody(:final text, :final contentType):
      final bytes = Uint8List.fromList(utf8.encode(text));
      return EncodedBody(
        kind: RawBodyKind.bytes,
        bytes: bytes,
        contentLength: bytes.length,
        contentType: contentType ?? body.defaultContentType,
      );

    case HttpJsonBody(:final json):
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      return EncodedBody(
        kind: RawBodyKind.bytes,
        bytes: bytes,
        contentLength: bytes.length,
        contentType: body.defaultContentType,
      );

    case HttpBytesBody(:final bytes, :final contentType):
      return EncodedBody(
        kind: RawBodyKind.bytes,
        bytes: bytes,
        contentLength: bytes.length,
        contentType: contentType ?? body.defaultContentType,
      );

    case HttpFormBody(:final fields):
      final bytes = Uint8List.fromList(utf8.encode(encodeFormFields(fields)));
      return EncodedBody(
        kind: RawBodyKind.bytes,
        bytes: bytes,
        contentLength: bytes.length,
        contentType: body.defaultContentType,
      );

    case HttpMultipartBody(:final parts, :final boundary):
      final b = boundary ?? generateMultipartBoundary();
      final length = await multipartContentLength(parts, b);
      return EncodedBody(
        kind: RawBodyKind.streamed,
        bytes: Uint8List(0),
        stream: composeMultipart(parts, b),
        contentLength: length,
        contentType: 'multipart/form-data; boundary=$b',
      );

    case HttpStreamBody(:final stream, :final contentLength, :final contentType):
      return EncodedBody(
        kind: RawBodyKind.streamed,
        bytes: Uint8List(0),
        stream: stream,
        contentLength: contentLength,
        contentType: contentType,
      );

    case HttpFileBody(:final path, :final contentType):
      // The path goes to native and curl reads the file directly, so a large
      // upload never allocates a Dart buffer.
      return EncodedBody(
        kind: RawBodyKind.filePath,
        bytes: Uint8List(0),
        filePath: path,
        contentType: contentType ?? guessContentTypeFromPath(path),
      );
  }
}

/// Builds the wire request. [headers] must already include any content type and
/// length the body implies, so the engine never has to guess.
RawRequest toRawRequest({
  required int requestId,
  required HttpRequest request,
  required HttpHeaders headers,
  required EncodedBody body,
  required bool reportProgress,
}) {
  return RawRequest(
    requestId: requestId,
    method: toRawMethod(request.method),
    customMethod: request.method == HttpMethod.custom
        ? (request.customMethod ?? '')
        : '',
    url: request.url.toString(),
    headers: <RawHeader>[
      for (final (name, value) in headers.entries)
        RawHeader(name: name, value: value),
    ],
    bodyKind: body.kind,
    bodyFilePath: body.filePath,
    options: toRawOptions(
      request.options,
      reportProgress: reportProgress,
      uploadContentLength: body.contentLength ?? kInherit,
      // Travels with the request so the engine can refuse it before opening a
      // socket if the token was cancelled while this call was in flight.
      cancelTokenId: request.cancelToken?.nativeId ?? 0,
    ),
  );
}

// ── RawResponse → public response ────────────────────────────────────────────

HttpVersion fromRawVersion(RawHttpVersion v) => switch (v) {
  RawHttpVersion.unknown => HttpVersion.unknown,
  RawHttpVersion.http10 => HttpVersion.http10,
  RawHttpVersion.http11 => HttpVersion.http11,
  RawHttpVersion.http2 => HttpVersion.http2,
  RawHttpVersion.http3 => HttpVersion.http3,
};

HttpHeaders fromRawHeaders(List<RawHeader> headers) {
  final h = HttpHeaders();
  for (final raw in headers) {
    h.add(raw.name, raw.value);
  }
  return h;
}

Duration _dur(double ms) =>
    Duration(microseconds: (ms * 1000).isFinite ? (ms * 1000).round() : 0);

HttpTimings fromRawTimings(RawTimings t) => HttpTimings(
  queue: _dur(t.queueMs),
  dns: _dur(t.dnsMs),
  connect: _dur(t.connectMs),
  tls: _dur(t.tlsMs),
  firstByte: _dur(t.firstByteMs),
  redirect: _dur(t.redirectMs),
  total: _dur(t.totalMs),
);

/// Parsed URL of the final hop. Falls back to the request URL when the engine
/// reported something unparseable, because a response object with a broken
/// `finalUrl` is worse than a slightly stale one.
Uri _finalUri(String finalUrl, Uri fallback) {
  if (finalUrl.isEmpty) return fallback;
  return Uri.tryParse(finalUrl) ?? fallback;
}

/// Shared metadata every concrete response carries.
ResponseMetadata metadataFrom({
  required HttpRequest request,
  required int statusCode,
  required String reasonPhrase,
  required RawHttpVersion version,
  required List<RawHeader> headers,
  required String finalUrl,
  required int redirectCount,
  required bool fromCache,
  required bool revalidated,
  required String primaryIp,
  required int primaryPort,
  required RawTimings timings,
}) {
  return ResponseMetadata(
    request: request,
    statusCode: statusCode,
    reasonPhrase: reasonPhrase,
    version: fromRawVersion(version),
    headers: fromRawHeaders(headers),
    finalUrl: _finalUri(finalUrl, request.url),
    redirectCount: redirectCount,
    fromCache: fromCache,
    revalidated: revalidated,
    primaryIp: primaryIp,
    primaryPort: primaryPort,
    timings: fromRawTimings(timings),
  );
}

// ── RawErrorKind → exception ─────────────────────────────────────────────────

/// Maps a transport failure onto the typed exception hierarchy.
///
/// Exhaustive by construction: `RawErrorKind.none` is a programming error here
/// (the caller must check `errorKind` first), and every other case maps to
/// exactly one exception type or one field on it.
NitroHttpException mapError({
  required RawErrorKind kind,
  required String message,
  required int engineErrorCode,
  HttpRequest? request,
}) {
  return switch (kind) {
    RawErrorKind.none => throw StateError(
      'mapError called with RawErrorKind.none — the caller must treat '
      'errorKind == none as success',
    ),
    // The engine knows only that the transfer was aborted; the human-readable
    // "why" lives on the token the caller cancelled. `NitroHttpCancelException.
    // reason` is documented as exactly that, so read it back here. Null for a
    // `cancelAll()` or a disposal, which have no token and no reason.
    RawErrorKind.cancelled => NitroHttpCancelException(
      reason: request?.cancelToken?.reason,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.timeoutConnect => NitroHttpTimeoutException(
      stage: TimeoutStage.connect,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.timeoutRequest => NitroHttpTimeoutException(
      stage: TimeoutStage.request,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.timeoutIdle => NitroHttpTimeoutException(
      stage: TimeoutStage.idle,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.dnsFailure => NitroHttpConnectionException(
      failure: ConnectionFailure.dns,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.connectionRefused => NitroHttpConnectionException(
      failure: ConnectionFailure.refused,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.connectionReset => NitroHttpConnectionException(
      failure: ConnectionFailure.reset,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.connectionFailed => NitroHttpConnectionException(
      failure: ConnectionFailure.failed,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.proxyFailure => NitroHttpConnectionException(
      failure: ConnectionFailure.proxy,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.unsupportedScheme => NitroHttpConnectionException(
      failure: ConnectionFailure.unsupportedScheme,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.sendFailure => NitroHttpConnectionException(
      failure: ConnectionFailure.send,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.receiveFailure => NitroHttpConnectionException(
      failure: ConnectionFailure.receive,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.tlsHandshake => NitroHttpCertificateException(
      isPinMismatch: false,
      isClientAuthFailure: false,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.certificateInvalid => NitroHttpCertificateException(
      isPinMismatch: false,
      isClientAuthFailure: false,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.certificatePinMismatch => NitroHttpCertificateException(
      isPinMismatch: true,
      isClientAuthFailure: false,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.certificateClientAuth => NitroHttpCertificateException(
      isPinMismatch: false,
      isClientAuthFailure: true,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.tooManyRedirects => NitroHttpRedirectException(
      redirectCount: engineErrorCode,
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.protocolError => NitroHttpProtocolException(
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.decompressionFailure => NitroHttpDecodingException(
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.cacheMiss => NitroHttpCacheMissException(
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
    RawErrorKind.io ||
    RawErrorKind.engineError ||
    RawErrorKind.badRequest ||
    RawErrorKind.unknown => NitroHttpUnknownException(
      request: request,
      engineMessage: message,
      engineErrorCode: engineErrorCode,
    ),
  };
}
