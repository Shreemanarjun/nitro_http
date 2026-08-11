<!--
  This README is for people USING the library. Keep it example-led and short.
  Deep material — TLS/proxy/DNS detail, the native build, the full benchmark
  record — belongs in doc/ADVANCED.md.
-->

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doc/logo-dark.svg">
    <img alt="nitro_http" src="doc/logo-light.svg" width="420">
  </picture>
</p>

<h1 align="center">nitro_http</h1>

<p align="center">
  A fast HTTP client for Flutter. One C++ engine, five platforms, and the same
  behaviour on all of them.
</p>

```dart
final client = NitroHttpClient(settings: const ClientSettings(
  baseUrl: 'https://api.example.com',
));

final res = await client.get('/users/42');
print(jsonDecode(res.body)['name']);
```

Under the hood every request goes to a **libcurl engine written in C++**, reached
through a direct FFI call rather than a platform channel. You get HTTP/1.1,
HTTP/2 and HTTP/3, real streaming in both directions, a disk cache and
WebSockets — and because there is only one engine, proxies, TLS pinning,
redirects, timeouts and cookies behave identically on iOS, Android, macOS,
Windows and Linux. There is no "works differently on Android" caveat, because
there is no second implementation to disagree with the first.

## Why you might want it

- **It is quick where apps actually feel it.** Many requests at once, which is
  what a real screen does. See [How fast is it](#how-fast-is-it).
- **One set of behaviours.** No per-platform surprises to discover in production.
- **Drop-in adapters.** Already on `package:http` or `dio`? Change one line and
  keep your code.
- **Honest about limits.** Everything it cannot do is listed in
  [Limitations](#limitations), not buried.

## How fast is it

Measured in **release** builds on real hardware against `dart:io`,
`package:http`, `dio` and `rhttp` (Rust/reqwest) — all five hitting the same
in-process server, in the same run, on the same machine. Each bar is the median
p50 of **10 runs**, the first discarded as warm-up.

Read the "wins N/9" note on each panel first: it is how many of the nine counted
runs that client was fastest in, and it is the difference between a result and a
coin flip. Bar length cannot show you that.

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doc/bench-android-dark.svg">
    <img alt="Android on a OnePlus 11 (Snapdragon 8 Gen 2, 16 GB, Android 16): nitro_http is fastest in all five scenarios — small GET 0.5 ms, 64 concurrent GETs 19 ms, 32 MiB download 209 ms, 8 MiB upload 227 ms, mixed workload 2.87 ms — winning 9 of 9 runs on concurrency, download and mixed." src="doc/bench-android-light.svg" width="100%">
  </picture>
</p>

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doc/bench-ios-dark.svg">
    <img alt="iOS on an iPhone 12 (A14 Bionic, 4 GB, iOS 26.6): nitro_http wins 64 concurrent GETs at 4.22 ms and the mixed workload at 1.17 ms in 9 of 9 runs, ties rhttp on a 32 MiB download at 135 ms, and trails package:http by 2.7 % on an 8 MiB upload." src="doc/bench-ios-light.svg" width="100%">
  </picture>
</p>

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doc/bench-macos-dark.svg">
    <img alt="macOS on an Apple M1 Pro (16 GB, macOS 26.4): nitro_http wins the mixed workload in 9 of 9 runs at 0.81 ms, ties rhttp on concurrency, and trails dart:io by 0.01 ms on a single small GET." src="doc/bench-macos-light.svg" width="100%">
  </picture>
</p>

<details>
<summary><b>How the dispatch modes compare on Android</b> — serial, concurrent and parallel (earlier measurement set)</summary>

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doc/bench-android-modes-dark.svg">
    <img alt="Serial, concurrent and parallel dispatch on Android" src="doc/bench-android-modes-light.svg" width="100%">
  </picture>
</p>
</details>

**Read it honestly.**

- **The mixed workload is the one result that holds everywhere.** It is also the
  scenario closest to what an app actually does — small and large requests
  interleaved — and `nitro_http` is fastest in **9 runs out of 9 on all three
  platforms**. Requests per second against the next-best client: **1.75x** on
  Android (312 vs 178), **1.27x** on iOS (433 vs 342), **1.14x** on macOS
  (449 vs 394).
- **Concurrency is the second.** 64 GETs in flight is a win on both phones (9/9
  each) and a tie with rhttp on the M1.
- **The Android device wins every scenario; the two Apple targets share a
  different shape.** On the OnePlus it is fastest in all five. On both the iPhone
  and the M1 it wins mixed and concurrency, sits inside the noise of rhttp on the
  download, trails `dart:io` by 0.01 ms on a small GET, and is 4th on the upload.
  So the split is **not** phone-versus-desktop — an iPhone 12 is a phone and it
  patterns with the laptop. What those two share is fast cores, which leave less
  for a native engine to take back. That is a plausible reading of the pattern,
  not something measured directly.
- **The 32 MiB download is a genuine tie on Apple, and the win rate says so
  better than the bars.** iOS: 135.09 vs 135.33 ms, `nitro_http` fastest in 7 of
  9 runs. macOS: 125.47 vs 124.40 ms, rhttp fastest in 8 of 9. A 0.2–0.9 % gap
  that changes direction between two machines is not a ranking. On Android it is
  not close — 208 ms against 280 for the next-best client, **25 % clear**, in 9
  of 9 runs.
- **Streamed upload is the weak row, consistently.** 4th of 5 on both Apple
  targets, 2.7 % behind the leader on each, and fastest in only 6 of 9 runs on
  Android. Two optimisation attempts were measured and both made it slower or did
  nothing; they are written up in `src/engine/BodyPipe.h` and
  `src/engine/ClientConfig.cpp` rather than shipped. The cause is still not fully
  explained, and this row is the honest gap in the set.
- **A small GET is a microbenchmark, and on Apple silicon it is the FFI hop.**
  0.01 ms behind `dart:io` — in every run on the M1, in 7 of 9 on the iPhone.
  Any real network erases it.
- **rhttp is the closest competitor on Apple targets and the furthest on
  Android.** It also costs its users a Rust toolchain, and has no cache, no
  interceptors and no WebSockets.

Two things these numbers are not. The server is a **single-isolate loopback**
server, so on the phones it is plausibly the limit in the burst and mixed rows
rather than any client. And with the network removed what is left is the client's
own cost — over a real link latency dominates and everything converges.

Each platform above was measured more than once, on separate occasions, and the
sets agree: three independent 10-run sets on macOS put the mixed p50 at 0.81 /
0.84 / 0.84 ms and throughput at 449 / 444 / 449 req/s, and two on iOS agree to
within 0.1 % on every row. The charts quote one set each rather than a pooled
average, because pooling runs taken in different machine states is the mistake
the whole harness exists to prevent.

Reproduce any of this with `tool/bench-macos.sh 10`, `tool/bench-android.sh 10`
or `tool/bench-ios.sh 10`. They refuse to run on a busy machine, a hot phone, or
a simulator — Flutter ships no AOT snapshot for the iOS simulator, so a
simulator can only report debug timings, and debug penalises Dart far more than
native code, which would flatter this package specifically. The rest of the
checks are in [doc/ADVANCED.md](doc/ADVANCED.md#benchmarks).

## Install

```yaml
dependencies:
  nitro_http: ^0.1.0
```

**Platform support**

| Platform | Status |
|---|---|
| Android | arm64-v8a, armeabi-v7a, x86_64 (minSdk 24) |
| iOS | 13.0+, device and simulator |
| macOS | 10.15+ |
| Windows | x64 |
| Linux | x64, arm64 |
| Web | Not supported, and never will be — see below |

There is no web build because the whole client *is* native code. Use
`package:http`'s `BrowserClient` behind `kIsWeb`.

**macOS only:** an app in the App Sandbox needs one entitlement, or every request
fails with "connection refused":

```xml
<key>com.apple.security.network.client</key>
<true/>
```

Add it to `Runner/DebugProfile.entitlements` and `Runner/Release.entitlements`.

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
print(jsonDecode(user.body)['name'] as String);

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
jsonDecode(res.body);        // JSON — decode it yourself, with dart:convert
res.headers['etag'];         // case-insensitive lookup
res.isSuccess;               // 2xx
```

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

They run in order on the way out and in reverse on the way back. One can
short-circuit a request and answer it itself, which is how you fake a response in
a test:

```dart
final logger = DelegatingInterceptor(
  onResponse: (res) async {
    print('${res.statusCode} ${res.finalUrl} in ${res.timings.total}');
    return Interceptor.next();
  },
);
```

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
- **Binary size is roughly 1.5–3 MB per ABI** with the bundled native stack.
- **No prebuilt binaries are published yet.** Until then you build a slice or
  link a system libcurl — see [doc/ADVANCED.md](doc/ADVANCED.md#native-dependencies).

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

## License

Not yet chosen; one will be in place before this package is published.
