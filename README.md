<!--
  This README is for people USING the library. Keep it example-led and short.
  Deep material — TLS/proxy/DNS detail, the native build, the full benchmark
  record — belongs in doc/ADVANCED.md.
-->

<p align="center">
  <img alt="nitro_http" width="420"
       src="https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/nitro_http/logo.png">
</p>
<p align="center">
  A fast HTTP client for Flutter. One C++ engine, five platforms, and the same
  behaviour on all of them.
</p>

<p align="center">
  Built with <a href="https://nitro.shreeman.dev/"><b>Nitro for Flutter</b></a>
  — the FFI bridge that makes the C++ call cheap enough to be worth making.
</p>

<p align="center">
  <a href="https://pub.dev/packages/nitro_http"><img alt="pub version" src="https://img.shields.io/pub/v/nitro_http.svg"></a>
  <a href="https://pub.dev/packages/nitro_http/score"><img alt="pub points" src="https://img.shields.io/pub/points/nitro_http"></a>
  <a href="https://github.com/Shreemanarjun/nitro_http/actions/workflows/ci.yml"><img alt="ci" src="https://github.com/Shreemanarjun/nitro_http/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="license: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

```dart
import 'package:nitro_http/nitro_http.dart';

final res = await fetch('https://api.example.com/users/42');

print(res.bodyToJson());   // parsed JSON, decoded with the response's charset
print(res.version.label);  // HTTP/3 — negotiated for you, not configured
```

Every request goes to a **libcurl engine written in C++**, called straight over
FFI — no platform channel, and no second implementation to disagree with the
first.

|  |  |
|---|---|
| **Protocols** | HTTP/1.1 · HTTP/2 · HTTP/3 (QUIC) · WebSockets |
| **Transfers** | streaming both ways · upload &amp; download progress · cancellation · per-request timings · resumable via byte ranges |
| **Security** | TLS 1.2/1.3 · SPKI pinning, per client or per request · mTLS · custom roots · DNS-over-HTTPS |
| **Caching** | RFC 9111 subset — `Cache-Control`, `ETag`, `Last-Modified`, 304 revalidation · prefetch |
| **Plumbing** | interceptors · request logging · retry with backoff · cookie jar · HTTP and SOCKS5 proxies · connection pool |
| **Platforms** | iOS · Android · macOS · Windows · Linux |

One engine means proxies, pinning, redirects, timeouts and cookies behave
identically on all five. There is no "works differently on Android".

## Why you might want it

- **Fast in the shape a real screen loads.** Small and large requests
  interleaved — fastest in **9 runs out of 9 on every platform measured**, and
  **1.75x** the requests per second of the next-best client on Android.
  [See the charts](#how-fast-is-it).
- **Features `dart:io` cannot reach.** HTTP/3, TLS pinning, mTLS,
  DNS-over-HTTPS, a disk cache and transfer timings. `package:http`, `dio` and
  `retrofit` all sit on `dart:io`'s socket layer, which has no knobs for these —
  this package owns its transport, so that is where they live.
- **One engine, one behaviour.** Nothing to rediscover per platform once you are
  in production.
- **Drop-in adapters.** Already on `package:http` or `dio`? Change one line and
  keep every call site.
- **Honest about limits.** No web, HTTP/1.1-only WebSockets, ~3–4.8 MB per ABI.
  All of it in [Limitations](#limitations), not buried.

## How fast is it

Release builds on real hardware, against `dart:io`, `package:http`, `dio` and
`rhttp` — all five hitting the same in-process server in the same run.

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/nitro_http/bench-android-dark.svg">
    <img alt="Android on a OnePlus 11 (Snapdragon 8 Gen 2, 16 GB, Android 16): nitro_http is fastest in all five scenarios — small GET 0.5 ms, 64 concurrent GETs 19 ms, 32 MiB download 209 ms, 8 MiB upload 227 ms, mixed workload 2.87 ms — winning 9 of 9 runs on concurrency, download and mixed." src="https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/nitro_http/bench-android-light.svg" width="100%">
  </picture>
</p>

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/nitro_http/bench-ios-dark.svg">
    <img alt="iOS on an iPhone 12 (A14 Bionic, 4 GB, iOS 26.6): nitro_http wins 64 concurrent GETs at 4.22 ms and the mixed workload at 1.17 ms in 9 of 9 runs, ties rhttp on a 32 MiB download at 135 ms, and trails package:http by 2.7 % on an 8 MiB upload." src="https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/nitro_http/bench-ios-light.svg" width="100%">
  </picture>
</p>

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/nitro_http/bench-macos-dark.svg">
    <img alt="macOS on an Apple M1 Pro (16 GB, macOS 26.4): nitro_http wins the mixed workload in 9 of 9 runs at 0.81 ms, ties rhttp on concurrency, and trails dart:io by 0.01 ms on a single small GET." src="https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/nitro_http/bench-macos-light.svg" width="100%">
  </picture>
</p>

Each panel's "wins N/9" note is what separates a result from a coin flip — bar
length cannot show it. Where it loses, why, and how to reproduce any of this:
**[the full benchmark record](doc/ADVANCED.md#benchmarks)**.

## Setup

```sh
flutter pub add nitro_http
```

Requires Dart `^3.12.2` and Flutter `>=3.3.0`. There is no manual step: the
native engine is fetched as a checksum-pinned prebuilt the first time you build.

**What the first build does.** It downloads the slice for each ABI you are
building — about 12 MB for a three-ABI Android APK — and compiles the engine,
which adds roughly 11 seconds over a plain Flutter app. Everything lands in a
per-machine cache (`~/.cache/nitro_http`, `%LOCALAPPDATA%` on Windows) keyed by
the dependency release, so later projects and package upgrades reuse it and
`flutter clean` does not throw it away.

**Platform support**

| Platform | Requirement | Anything to do? |
|---|---|---|
| Android | minSdk 24 · arm64-v8a, armeabi-v7a, x86_64 | No |
| iOS | 13.0+, device and simulator | No |
| macOS | 10.15+ | **Yes — one entitlement, below** |
| Windows | x64 | No |
| Linux | x64, arm64 | No |
| Web | — | Not supported, and never will be |

### macOS: the one required step

A sandboxed macOS app needs the network-client entitlement or **every request
fails with "connection refused"**. `flutter create` does not add it, so a new
app will hit this:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

Add it to both `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`.

### Web

There is no web build because the whole client *is* native code. Use
`package:http`'s `BrowserClient` behind `kIsWeb`.

### Check the install

The engine reports what it was actually linked against, which is the quickest
way to confirm a build picked up the vendored slice rather than a system
libcurl:

```dart
print(NitroHttp.engineVersion);      // libcurl/8.21.0 BoringSSL … ngtcp2/1.25.0
print(NitroHttp.supportsHttp3);      // true with the shipped slice
print(NitroHttp.supportsBrotli);
print(NitroHttp.supportsZstd);
```

`supportsHttp3 == false` on a platform that should have it means the build fell
back to a system libcurl — worth catching early, because nothing else about it
looks wrong.

### Building offline

Point `NITRO_HTTP_DEPS_DIR` at a directory of prebuilt slices and nothing
touches the network:

```sh
NITRO_HTTP_DEPS_DIR=/path/to/slices flutter build apk --release
```

Build those slices yourself with `dart run nitro_http:build_curl` — see
[doc/ADVANCED.md](doc/ADVANCED.md#native-dependencies). You only need this for
air-gapped or corporate-proxy machines; a normal build downloads them itself.

## Quick start

```dart
import 'package:nitro_http/nitro_http.dart';

final client = NitroHttpClient(
  settings: const ClientSettings(
    baseUrl: 'https://api.example.com',
    userAgent: 'my_app/1.0',
  ),
);

// GET some JSON
final user = await client.get('/users/42');
print((user.bodyToJson() as Map)['name']);

// POST some JSON
final created = await client.post('/users', body: HttpBody.json({'name': 'Ada'}));
print(created.statusCode); // 201

client.dispose(); // closes pooled connections
```

One client per API is the intended shape: it owns the connection pool, the cookie
jar and the cache, so reusing it is what makes the second request fast.

## Features

Grouped by what you are trying to do. Every snippet below that calls this
library is compiled and run by
[`test/readme_examples_test.dart`](test/readme_examples_test.dart), so an API
change breaks that test before it can break a reader.

- [The default client](#the-default-client)
- [Making requests](#making-requests)
- [Sending a body](#sending-a-body)
- [Reading a response](#reading-a-response)
- [Errors](#errors)
- [Streaming](#streaming)
- [Progress and timings](#progress-and-timings)
- [Cancelling](#cancelling)
- [Timeouts](#timeouts)
- [Retries](#retries)
- [Interceptors](#interceptors)
- [Cookies](#cookies)
- [Caching and prefetch](#caching-and-prefetch)
- [TLS and certificates](#tls-and-certificates)
- [Proxies and DNS](#proxies-and-dns)
- [HTTP versions and the connection pool](#http-versions-and-the-connection-pool)
- [WebSockets](#websockets)
- [Using it with package:http or dio](#using-it-with-packagehttp-or-dio)
- [Engine capabilities and hot restart](#engine-capabilities-and-hot-restart)

---

### The default client

`fetch()` and every `NitroHttp.*` verb share one lazily created client. Configure
it once at startup and they all pick it up:

```dart
NitroHttp.init(
  const ClientSettings(
    baseUrl: 'https://api.example.com',
    userAgent: 'my_app/1.0',
  ),
  interceptors: [RetryInterceptor(maxRetries: 3)],
);

final user = await NitroHttp.get('/users/42');    // baseUrl applies
final posted = await NitroHttp.post('/users', body: HttpBody.json({'name': 'Ada'}));
```

Calling `init` again replaces the client and **disposes the previous one**, which
cancels anything still in flight on it. Call it during startup, not per screen.

Large bodies have a one-liner too, so you do not need a client just to stream a
download:

```dart
final report = await NitroHttp.getStream('/reports/2026.csv');
await for (final chunk in report.body) {
  // chunk is a List<int>, delivered as it arrives
}
```

`NitroHttp` also carries the process-wide pieces — `configureCache`, `prefetch`,
`cacheStats`, and the capability getters in
[Engine capabilities](#engine-capabilities-and-hot-restart).

One caveat worth stating: the default client is global. For anything beyond a
single API, construct a `NitroHttpClient` per API instead — see
[Quick start](#quick-start) — because a client owns the connection pool, the
cookie jar and the cache, and sharing one across unrelated hosts shares all
three.

### Making requests

Every verb has a method, and `options_` is spelled with a trailing underscore
because `options` is a Dart keyword in that position:

```dart
await client.get('/users');
await client.head('/users');
await client.post('/users', body: HttpBody.json({'name': 'Ada'}));
await client.put('/users/1', body: HttpBody.json({'name': 'Ada'}));
await client.patch('/users/1', body: HttpBody.json({'name': 'Grace'}));
await client.delete('/users/1');
await client.options_('/users');
await client.trace('/users');
```

Anything else — including verbs nobody has standardised — goes through `request`:

```dart
await client.requestText(HttpMethod.custom, '/graph', customMethod: 'PURGE');
```

Query parameters and headers are per call. `HttpHeaders` is case-insensitive, and
a header you set replaces the client default of the same name rather than
appending to it:

```dart
final res = await client.get(
  '/search',
  query: {'q': 'flutter', 'limit': '20'},
  headers: HttpHeaders.fromMap({'Authorization': 'Bearer $token'}),
);
```

### Sending a body

Seven shapes, and the last three never load the payload into the Dart heap:

```dart
// UTF-8 text.
HttpBody.text('hello', contentType: 'text/plain; charset=utf-8');

// jsonEncode-ed, with application/json; charset=utf-8.
HttpBody.json({'name': 'Ada', 'roles': ['admin']});

// Raw bytes.
HttpBody.bytes(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]));

// application/x-www-form-urlencoded.
HttpBody.form({'grant_type': 'refresh_token', 'token': token});

// multipart/form-data; file parts stream off disk, never through the Dart heap.
HttpBody.multipart([
  MultipartItem.text('caption', 'Sunset'),
  MultipartItem.file('photo', '/tmp/sunset.jpg', contentType: 'image/jpeg'),
]);

// A Dart stream, chunked when the length is unknown.
HttpBody.stream(source, contentLength: 4096);

// A path handed straight to the engine.
HttpBody.file('/tmp/backup.zip');
```

### Reading a response

```dart
res.statusCode;              // 200
res.body;                    // String, decoded using the response charset
res.bodyBytes;               // Uint8List
res.bodyToJson();            // parsed JSON
res.headers['etag'];         // case-insensitive lookup
res.isSuccess;               // 2xx
```

`body` is decoded lazily and cached, so reading only `statusCode` never pays to
decode a megabyte of text. `bodyToJson()` is `jsonDecode` with one difference
that matters: malformed JSON throws `NitroHttpDecodingException`, not a bare
`FormatException`, so a single `on NitroHttpException` clause still catches
everything this package can fail with.

Responses are a sealed family, so a `switch` over them is checked for
completeness — add a response kind and the compiler finds every place that needs
updating:

```dart
String describe(HttpResponse res) => switch (res) {
  HttpTextResponse(:final body) => 'text: ${body.length} chars',
  HttpBytesResponse(:final bodyBytes) => 'bytes: ${bodyBytes.length}',
  HttpStreamResponse(:final contentLength) => 'stream: ${contentLength ?? -1}',
};
```

There is more on the response than the body. `fromCache` and `revalidated` tell
you whether the network was touched at all:

```dart
final res = await client.get('/users');
print(res.version.label);        // HTTP/2
print(res.reasonPhrase);         // OK — '' over HTTP/2 and HTTP/3, which dropped it
print(res.finalUrl);
print(res.redirectCount);
print(res.primaryIp);
print(res.fromCache);
print(res.headers.getAll('set-cookie'));
```

### Errors

Every failure is a `NitroHttpException` subtype, and the family is sealed — so you
can switch exhaustively instead of matching on message strings:

```dart
try {
  await client.get('/users');
} on NitroHttpException catch (e) {
  final detail = switch (e) {
    NitroHttpTimeoutException(:final stage) => 'timeout at ${stage.name}',
    NitroHttpCancelException(:final reason) => 'cancelled: ${reason ?? ''}',
    NitroHttpStatusCodeException(:final statusCode) => 'status $statusCode',
    NitroHttpCertificateException(:final isPinMismatch) =>
      isPinMismatch ? 'pin mismatch' : 'bad certificate',
    NitroHttpTlsException() => 'no shared TLS version or cipher',
    NitroHttpConfigurationException() => 'these settings cannot be satisfied',
    NitroHttpConnectionException(:final failure) => 'connection ${failure.name}',
    NitroHttpRedirectException(:final redirectCount) => '$redirectCount hops',
    NitroHttpProtocolException() => 'protocol error',
    NitroHttpDecodingException() => 'undecodable body',
    NitroHttpCacheMissException() => 'nothing cached',
    NitroHttpDisposedException() => 'client disposed',
    NitroHttpUnknownException(:final engineErrorCode) => 'CURLcode $engineErrorCode',
  };
  print(detail);
}
```

A 4xx or 5xx is **returned, not thrown**, so check `res.statusCode`. Set
`throwOnStatusCode: true` in `ClientSettings` if you would rather have it thrown.

Three of these are easy to confuse, and the distinction is deliberate:

| | means | retryable |
|---|---|---|
| `NitroHttpCertificateException` | the chain was judged and rejected — untrusted, expired, or not matching a pin | no |
| `NitroHttpTlsException` | the handshake never got that far: no shared protocol version or cipher | no |
| `NitroHttpConfigurationException` | the engine refused the settings before opening a socket | no — fix the settings |

### Streaming

Downloads stream with real backpressure: the engine stops reading the socket when
you stop consuming, so a slow consumer slows the network instead of filling
memory.

```dart
final res = await client.requestStream(HttpMethod.get, '/dataset.ndjson');

await for (final chunk in res.body) {
  sink.add(chunk);              // a slow consumer stalls the socket, not the heap
}
```

Uploads stream the same way, from any Dart stream:

```dart
await client.post(
  '/ingest',
  body: HttpBody.stream(source, contentLength: totalBytes),
);
```

And a file goes straight from disk to the socket, with the engine doing the
reading — a 2 GB upload costs a few KB of Dart memory:

```dart
await client.put('/backups/nightly.zip', body: HttpBody.file('/var/tmp/nightly.zip'));
```

### Progress and timings

Both directions, on any request:

```dart
await client.post(
  '/upload',
  body: HttpBody.file('/tmp/video.mp4'),
  onSendProgress: (sent, total) => print('$sent / ${total ?? -1}'),
  onReceiveProgress: (received, total) => print('down $received'),
);
```

Phase timings are on by default and cost nothing measurable. No other Dart client
reports these, because they come from inside the engine:

```dart
final res = await client.get('/ping');
print(res.timings.dns);
print(res.timings.tls);
print(res.timings.firstByte);
print(res.timings.total);
```

### Cancelling

Make a `CancelToken`, pass it to the requests it should control, and cancel it.
The reason you give comes back on the exception:

```dart
final token = CancelToken();
Timer(const Duration(seconds: 2), () => token.cancel('user navigated away'));

try {
  await client.get('/slow', cancelToken: token);
} on NitroHttpCancelException catch (e) {
  print(e.reason);              // user navigated away
}
```

**One token, any number of requests.** Give the same token to everything a
screen loads and one `cancel()` stops all of it — useful in `dispose()`:

```dart
final screen = CancelToken();

final results = await Future.wait([
  client.get('/profile', cancelToken: screen),
  client.get('/feed', cancelToken: screen),
  client.get('/notifications', cancelToken: screen),
]);
```

```dart
@override
void dispose() {
  screen.cancel('screen closed');
  super.dispose();
}
```

**Cancelling early keeps the request off the network entirely.** The token lives
in the engine, not in Dart, so a request bound to a token that is already
cancelled is refused before a socket is opened — it never reaches your server:

```dart
final token = CancelToken()..cancel('never mind');

try {
  await client.get('/expensive', cancelToken: token);
} on NitroHttpCancelException {
  // Fails straight away: no socket was opened and the server saw nothing.
}
```

Cancelling is safe to do at any point: twice, after the request already
finished, or on a token nothing is using. The first `cancel()` wins and the rest
are no-ops.

### Timeouts

Three separate deadlines, because "it timed out" is three different problems:

```dart
const ClientSettings(
  connectTimeout: Duration(seconds: 10),   // DNS + TCP + TLS
  timeout: Duration(seconds: 30),          // the whole request
  idleTimeout: Duration(seconds: 90),      // aborts a transfer that goes quiet
);
```

### Retries

```dart
final client = NitroHttpClient(
  interceptors: [
    RetryInterceptor(
      maxRetries: 4,
      baseDelay: const Duration(milliseconds: 250),
      maxDelay: const Duration(seconds: 10),
      respectRetryAfter: true,
    ),
  ],
);
```

It retries only what is safe to retry — connection failures, timeouts, 429 and
5xx — with exponential backoff and jitter, and it honours `Retry-After`.

### Interceptors

An interceptor sits between your call and the engine. It can rewrite the request
on the way out, the response on the way back, and step in when something fails.

They run in registration order going out and in reverse coming back, so the first
one you register wraps all the rest.

```dart
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this.tokens);

  final TokenStore tokens;

  @override
  Future<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) async {
    request.headers.set('authorization', 'Bearer ${await tokens.access()}');
    return Interceptor.next();
  }

  @override
  Future<InterceptorResult<HttpResponse>> onError(NitroHttpException exception) async {
    if (exception is NitroHttpStatusCodeException && exception.statusCode == 401) {
      await tokens.refresh();
    }
    return Interceptor.next();
  }
}
```

Four come with the package:

| | |
|---|---|
| `LogInterceptor` | one line per call, four levels, credentials redacted |
| `RetryInterceptor` | exponential backoff with jitter over transient failures |
| `ParallelInterceptors` | runs independent observers concurrently |
| `DelegatingInterceptor` | builds one from closures, handy in tests |

```dart
final client = NitroHttpClient(
  settings: const ClientSettings(baseUrl: 'https://api.example.com'),
  interceptors: [
    LogInterceptor(
      level: kDebugMode ? HttpLogLevel.headers : HttpLogLevel.none,
      sink: (line) => developer.log(line, name: 'http'),
    ),
    RetryInterceptor(maxRetries: 3),
  ],
);
```

```
--> GET https://api.example.com/users/7
<-- 200 OK https://api.example.com/users/7 431b 38ms
```

Levels are `none`, `basic`, `headers` and `body`, checked before anything is
formatted. `authorization`, `proxy-authorization`, `cookie` and `set-cookie` are
redacted. A streamed body logs as `<stream>` rather than being read, since
reading it would buffer the whole response.

#### Keeping them cheap

A hook can return its result without wrapping it in a `Future`, and that matters
more than what the hook does:

| three interceptors, per request | |
|---|---|
| synchronous hooks | 4.4 µs |
| `LogInterceptor` at `basic`, writing | 5.2 µs |
| `async` hooks | 52.3 µs |

So don't mark a hook `async` unless it awaits something. Suspension spreads: once
one hook hands back a future, every hook after it gets awaited too.

When a hook has nothing to say, return the shared constant:

```dart
class TraceHeader extends Interceptor {
  const TraceHeader();

  @override
  FutureOr<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) {
    request.headers.set('x-trace-id', newTraceId());
    return Interceptor.proceedRequest;   // const; no future, no allocation
  }
}
```

For outcomes you expect, prefer `Interceptor.resolve()` or `stop()` to an
exception. `resolve` answers the call without touching the network.

#### Running observers side by side

Interceptors that each await I/O can go in a group instead of the main list:

```dart
interceptors: [
  AuthInterceptor(tokens),             // sequential: must run before signing
  SigningInterceptor(),
  ParallelInterceptors([               // concurrent: independent of each other
    RemoteLogInterceptor(),
    MetricsInterceptor(),
  ]),
],
```

Three 120 ms hooks take about 120 ms grouped, against 360 ms in a row. Members
have to be observers; one that rewrites the request or stops the chain throws.

More detail in
[ADVANCED.md](doc/ADVANCED.md#logging-and-running-interceptors-in-parallel).

### Cookies

On by default, one jar per client, and persistable as a Netscape file:

```dart
final client = NitroHttpClient(
  settings: ClientSettings(
    cookieSettings: CookieSettings(
      storeCookies: true,
      persistPath: '$appSupportDir/cookies.txt',   // Netscape jar
    ),
  ),
);

// After some traffic:
for (final c in client.cookiesFor(Uri.parse('https://api.example.com/'))) {
  print('${c.name}=${c.value} (${c.domain}${c.path})');
}

client.setCookie(const Cookie(
  name: 'consent',
  value: 'granted',
  domain: 'api.example.com',
));
client.flushCookies();      // also happens automatically on dispose()
```

### Caching and prefetch

An RFC 9111 subset: `Cache-Control`, `ETag`, `Last-Modified`, and 304
revalidation that refreshes metadata without re-downloading the body.

```dart
NitroHttp.configureCache(HttpCacheConfig(
  directory: cacheDir,            // e.g. path_provider's getApplicationCacheDirectory()
  maxSizeBytes: 128 * 1024 * 1024,
  maxEntryBytes: 8 * 1024 * 1024,
));

final client = NitroHttpClient(
  settings: const ClientSettings(cacheSettings: CacheSettings(enabled: true)),
);
```

Per request you can override the policy — `refresh` to force revalidation,
`onlyIfCached` for an offline screen:

```dart
await NitroHttp.prefetchOnAppStart([
  'https://api.example.com/v1/feed',
  'https://api.example.com/v1/me',
]);
```

Warm it before the user asks for anything:

```dart
await client.get('/feed', options: const RequestOptions(cacheMode: CacheMode.onlyIfCached));
await client.get('/feed', options: const RequestOptions(cacheMode: CacheMode.refresh));

final stats = NitroHttp.cacheStats();
print('${stats.entryCount} entries, hit rate ${stats.hitRate}');
NitroHttp.clearCache();
```

### TLS and certificates

Versions, root sources, SPKI pinning and mutual TLS, all per client:

```dart
final client = NitroHttpClient(
  settings: ClientSettings(
    tlsSettings: TlsSettings(
      minVersion: TlsVersion.tls13,
      rootCaSource: RootCaSource.platform,
      pinnedSpkiSha256: const ['YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg='],
      clientCertificate: ClientCertificate(
        certificatePem: certPem,
        privateKeyPem: keyPem,
      ),
    ),
  ),
);
```

Pinning is per request too, which is what you want for one sensitive endpoint in
an otherwise ordinary app:

```dart
await client.post(
  '/payments',
  options: const RequestOptions(pinnedSpkiSha256: 'YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg='),
);
```

### Proxies and DNS

```dart
const ClientSettings(proxySettings: ProxySettings.system());     // default
const ClientSettings(proxySettings: ProxySettings.noProxy());

ClientSettings(
  proxySettings: const ProxySettings.http(
    'proxy.corp.example:3128',
    username: 'svc',
    password: 'hunter2',
    noProxy: 'localhost,127.0.0.1,*.internal',
  ),
);

const ProxySettings.socks5('127.0.0.1:1080');           // resolve locally
const ProxySettings.socks5Hostname('127.0.0.1:1080');   // let the proxy resolve
```

Static DNS overrides and DNS-over-HTTPS, without touching the device's resolver:

```dart
ClientSettings(
  dnsSettings: DnsSettings.static({
    'api.example.com': ['203.0.113.10', '2001:db8::10'],
  }, port: 443),
);

const ClientSettings(
  dnsSettings: DnsSettings.doh('https://cloudflare-dns.com/dns-query'),
);
```

### HTTP versions and the connection pool

```dart
const ClientSettings(
  // auto, http11Only, http2, http2Only, http3, http3Only
  httpVersionPref: HttpVersionPref.http2,
  poolSettings: PoolSettings(
    maxConnections: 64,        // across all hosts
    maxConnectionsPerHost: 6,
    idleTimeout: Duration(seconds: 90),
    maxLifetime: Duration(minutes: 10),
  ),
);
```

The `*Only` variants fail the request rather than silently downgrading, which is
what you want when a downgrade would be worse than an error. Check `NitroHttp.supportsHttp3` first — a system libcurl usually has
no QUIC backend.

### WebSockets

```dart
final ws = await NitroWebSocket.connect(
  Uri.parse('wss://echo.example.com/socket'),
  protocols: ['chat'],
  pingInterval: const Duration(seconds: 30),
);

ws.events.listen((event) {
  switch (event) {
    case TextDataReceived(:final text):
      print('text $text');
    case BinaryDataReceived(:final data):
      print('binary ${data.length}');
    case CloseReceived(:final code, :final reason):
      print('closed $code $reason');
  }
});

ws.sendText('hello');
await ws.close(1000, 'done');
```

`NitroWebSocket` implements `package:web_socket`'s `WebSocket` interface, so it
drops into code written against that.

### Using it with package:http or dio

```dart
final client = NitroHttpCompatClient();
final res = await client.get(Uri.parse('https://example.com/'));
print(res.statusCode);
client.close();
```

```dart
final dio = Dio()..useNitroHttp();

// or, with settings or a shared client:
final dio = Dio()
  ..httpClientAdapter = NitroHttpDioAdapter(
    settings: const ClientSettings(timeout: Duration(seconds: 30)),
  );
```

The `package:http` adapter is checked against the official
`package:http_client_conformance_tests` suite. The dio adapter is the separate
`nitro_http_dio` package.

### Engine capabilities and hot restart

Ask the engine what it can actually do, rather than assuming:

```dart
print(NitroHttp.engineVersion);      // libcurl/8.21.0 ... nghttp2/1.70.0 ...
print(NitroHttp.supportsHttp3);
print(NitroHttp.supportsWebSockets);
print(NitroHttp.supportsBrotli);
print(NitroHttp.supportsZstd);
```

Hot restart leaves the native engine threads running while the Dart isolate is
replaced. You do not have to do anything about it: the first time the reloaded
app touches the engine, it joins those threads, aborts the stragglers, flushes
the cookie jars and clears cancellation state.

```dart
void main() {
  runApp(const MyApp());       // nothing to add
}
```


## Configuration

The settings you are most likely to touch:

| Setting | Default | What it does |
|---|---|---|
| `baseUrl` | none | Prefix for relative paths |
| `connectTimeout` | 10 s | DNS + TCP + TLS only |
| `timeout` | 30 s | The whole request |
| `idleTimeout` | 90 s | Aborts a transfer that goes quiet |
| `httpVersionPref` | `auto` | Negotiate, prefer, or require a version |
| `headers` | none | Default headers a request can override |
| `userAgent` | package default | `User-Agent` |
| `throwOnStatusCode` | `false` | Throw on 4xx/5xx instead of returning |
| `enableCompression` | `true` | Advertise and decode gzip/deflate/br/zstd |
| `redirectSettings` | follow, max 5 | Whether and how far to follow 3xx |
| `poolSettings` | 64 total, 6 per host | Pool size and connection lifetimes |
| `tlsSettings` | system | Versions, pinning, roots, mTLS |
| `proxySettings` | system | HTTP or SOCKS5 proxy |
| `dnsSettings` | system | Static overrides or DNS-over-HTTPS |
| `cookieSettings` | on | Jar behaviour and persistence |
| `cacheSettings` | off | Disk cache, after `NitroHttp.configureCache` |
| `streamChunks` | tuned | How streamed chunks are batched |

Interceptors are **not** a setting — they are a `NitroHttpClient` argument, because
they are behaviour rather than configuration:

```dart
final client = NitroHttpClient(
  settings: const ClientSettings(baseUrl: 'https://api.example.com'),
  interceptors: [RetryInterceptor(maxRetries: 3)],
);
```

TLS, proxies and DNS-over-HTTPS have more to them than fits here — see
[doc/ADVANCED.md](doc/ADVANCED.md).

## Limitations

- **No web support**, permanently. Use `BrowserClient` behind `kIsWeb`.
- **HTTP/3 depends on the build you link.** A system libcurl usually has no QUIC
  backend. Check `NitroHttp.supportsHttp3` at runtime.
- **WebSockets are HTTP/1.1 Upgrade only.** No RFC 8441 over HTTP/2 — libcurl
  does not implement it, and neither does reqwest.
- **Cookies have no public-suffix list**, so do not treat the jar as a security
  boundary against a hostile server.
- **Binary size is 3.0–4.8 MB per ABI** with the bundled native stack — measured
  in a release APK: 2.96 MB armeabi-v7a, 4.53 MB arm64-v8a, 4.76 MB x86_64.
  Building the dependencies with `--no-http3` saves about 0.4 MB of that.
- **It is a 0.0.x release.** The API is complete and tested, but it has not yet
  been through a wide range of real apps, so treat breaking changes in a minor
  version as possible until 1.0.

## Try it

The example app is a full HTTP console — pick a library, build any request, and
compare all five clients on the same benchmark:

```sh
cd example
flutter run
```

## Docs

- [doc/ADVANCED.md](doc/ADVANCED.md) — TLS, proxies, DNS, HTTP versions, the
  native build, testing, and the complete benchmark record
- [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) — how the engine works inside: the
  ack protocol, the credit loop, the threading contract. Read this before
  changing native code.
- [CHANGELOG.md](CHANGELOG.md)

## Contributing

Contributions welcome. The Nitro spec in `lib/src/nitro_http.native.dart` is
generated code's source of truth — change it and re-run `nitrogen generate`,
never edit the generated files. Run `dart analyze` and the test suites before
opening a pull request.

Bugs and feature requests: [issue tracker](https://github.com/Shreemanarjun/nitro_http/issues).

## Links

| | |
|---|---|
| Documentation | [doc/ADVANCED.md](doc/ADVANCED.md) |
| Nitro for Flutter | [nitro.shreeman.dev](https://nitro.shreeman.dev/) |
| Issues | [github.com/Shreemanarjun/nitro_http/issues](https://github.com/Shreemanarjun/nitro_http/issues) |
| Changelog | [CHANGELOG.md](CHANGELOG.md) |

If this package saves you time, you can
[buy me a coffee](https://buymeacoffee.com/shreemanarjun).

## License

[MIT](LICENSE) © Shreeman Arjun Sahu.

The published builds statically link libcurl, BoringSSL, nghttp2, nghttp3,
ngtcp2, brotli and zstd. Those carry their own permissive licences (curl, ISC,
MIT, Apache-2.0, BSD) and shipping an app built with this package means
distributing them — worth a line in your app's acknowledgements.


