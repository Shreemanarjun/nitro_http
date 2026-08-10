<!--
  This README is for people USING the library. Keep it example-led and short.
  Deep material — TLS/proxy/DNS detail, the native build, the full benchmark
  record — belongs in docs/ADVANCED.md.
-->

# nitro_http

A fast HTTP client for Flutter. One C++ engine, five platforms, and the same
behaviour on all of them.

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
`package:http`, `dio` and `rhttp` (Rust/reqwest), all five hitting the same
in-process server. Lower is better; **bold** is the winner.

**Apple M1 Pro (macOS)**

| Scenario | nitro_http | dart:io | package:http | dio | rhttp |
|---|--:|--:|--:|--:|--:|
| 1 KiB GET, one at a time | 0.16 ms | **0.13 ms** | 0.14 ms | 0.18 ms | 0.18 ms |
| 512 GETs at once | **27 ms** | 31 ms | 55 ms | 68 ms | 33 ms |
| Mixed workload | **0.78 ms** | 1.13 ms | 1.02 ms | 1.28 ms | 0.98 ms |
| 256 MiB download | 1111 ms | 1119 ms | 1132 ms | 1126 ms | **1030 ms** |
| 128 MiB upload | 1714 ms | 1718 ms | 1755 ms | **1707 ms** | 1836 ms |

**iPhone 12 (A14)** — 64 requests at once: **4.8 ms**, ahead of every other
client including rhttp. Upload and mixed land within 1 % of the fastest.

**Read it honestly.** This client wins when requests overlap, because the engine
runs its own event loop and connection pool off your UI isolate. On a single
small request it is a few tens of microseconds behind `dart:io` — that is the
FFI hop, and any real network erases it. On one huge transfer everyone converges,
because at that point you are measuring the socket.

Numbers, method, and how to reproduce them: [docs/ADVANCED.md](docs/ADVANCED.md#benchmarks).

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

## Cookbook

### Query parameters and headers

```dart
final res = await client.get(
  '/search',
  query: {'q': 'flutter', 'limit': '20'},
  headers: HttpHeaders.fromMap({'Authorization': 'Bearer $token'}),
);
```

### Request bodies

```dart
await client.post('/echo', body: HttpBody.json({'hello': 'world'}));
await client.post('/echo', body: HttpBody.text('plain text'));
await client.post('/echo', body: HttpBody.bytes(bytes));
await client.post('/login', body: HttpBody.form({'user': 'ada', 'pass': 'lovelace'}));

// Multipart, including a file that never loads into memory
await client.post('/upload', body: HttpBody.multipart([
  MultipartItem.text('caption', 'holiday'),
  MultipartItem.file('photo', '/path/to/photo.jpg', contentType: 'image/jpeg'),
]));
```

### Reading a response

```dart
final res = await client.get('/users/42');

res.statusCode;              // 200
res.body;                    // String, decoded using the response charset
res.bodyBytes;               // Uint8List
jsonDecode(res.body);        // JSON — decode it yourself, with dart:convert
res.headers['etag'];         // case-insensitive lookup
res.isSuccess;               // 2xx
```

### Errors are typed, not strings

Every failure is a subclass of `NitroHttpException`, so you can handle the case
you care about and let the rest bubble:

```dart
try {
  await client.get('/users/42');
} on NitroHttpTimeoutException catch (e) {
  showRetry(e.message);
} on NitroHttpConnectionException {
  showOffline();
} on NitroHttpStatusCodeException catch (e) {
  if (e.statusCode == 404) showNotFound();
}
```

By default a 4xx or 5xx is returned, not thrown — check `res.statusCode`. Set
`throwOnStatusCode: true` in `ClientSettings` if you would rather it threw.

### Downloading with progress

```dart
final res = await client.get(
  '/big.zip',
  onReceiveProgress: (received, total) {
    setState(() => _progress = total == null ? null : received / total);
  },
);
```

### Streaming a response

For anything large, stream it — the body never has to fit in memory, and a slow
consumer slows the network down instead of filling the heap:

```dart
final res = await client.requestStream(HttpMethod.get, '/big.zip');
final sink = File('big.zip').openWrite();
await res.body.pipe(sink);
```

### Uploading a file without a Dart buffer

```dart
await client.post('/upload', body: HttpBody.file('/path/to/video.mp4'));
```

The engine reads the file itself, so a 2 GB upload uses a few KB of Dart memory.

### Cancelling

```dart
final cancelToken = CancelToken();
final future = client.get('/slow', cancelToken: cancelToken);

cancelToken.cancel('user left the screen');
// `future` completes with NitroHttpCancelException, whose .reason is that string
```

### Timeouts and retries

```dart
final client = NitroHttpClient(
  settings: const ClientSettings(
    baseUrl: 'https://api.example.com',
    connectTimeout: Duration(seconds: 5),
    timeout: Duration(seconds: 30),
  ),
  interceptors: [
    RetryInterceptor(
      maxRetries: 4,
      baseDelay: const Duration(milliseconds: 250),
      respectRetryAfter: true,
    ),
  ],
);
```

`RetryPolicy` retries only what is safe to retry — connection failures, timeouts,
429 and 5xx — with exponential backoff and jitter, and honours `Retry-After`.

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
}
```

Pass them as `NitroHttpClient(interceptors: [...])`. They run in order on the way
out and in reverse on the way back, and one can short-circuit a request
entirely — which is how you fake a response in tests.

### Cookies

On by default and per client:

```dart
final client = NitroHttpClient(
  settings: ClientSettings(
    cookieSettings: CookieSettings(
      storeCookies: true,
      persistPath: '$appSupportDir/cookies.txt',   // Netscape jar, survives restarts
    ),
  ),
);

for (final c in client.cookiesFor(Uri.parse('https://api.example.com/'))) {
  print('${c.name}=${c.value}');
}
```

### Disk cache

```dart
NitroHttp.configureCache(HttpCacheConfig(
  directory: cacheDir,                  // a String path, e.g. from path_provider
  maxSizeBytes: 128 * 1024 * 1024,
));

final client = NitroHttpClient(
  settings: const ClientSettings(cacheSettings: CacheSettings(enabled: true)),
);
```

An RFC 9111 subset: `Cache-Control`, `ETag`, `Last-Modified`, revalidation with
304s. Per request you can force `CacheMode.refresh` or `CacheMode.onlyIfCached`
for an offline screen.

### WebSockets

```dart
final ws = await NitroWebSocket.connect(Uri.parse('wss://example.com/socket'));

ws.events.listen((e) => switch (e) {
  TextDataReceived(:final text) => handleText(text),
  BinaryDataReceived(:final data) => handleBinary(data),
  CloseReceived(:final code, :final reason) => handleClose(code, reason),
});

ws.sendText('hello');
await ws.close(1000, 'done');
```

### Already using package:http or dio?

```dart
// package:http — anywhere a http.Client is expected
final http.Client client = NitroHttpCompatClient();

// dio
final dio = Dio()..useNitroHttp();
```

The `package:http` adapter is checked against the official
`package:http_client_conformance_tests` suite. The dio adapter lives in the
separate `nitro_http_dio` package.

## Configuration

The settings you are most likely to touch:

| Setting | Default | What it does |
|---|---|---|
| `baseUrl` | none | Prefix for relative paths |
| `connectTimeout` | 10 s | Connect phase only |
| `timeout` | 30 s | Whole request |
| `idleTimeout` | 90 s | Abort a transfer that goes quiet |
| `maxRedirects` | 5 | 0 disables following |
| `throwOnStatusCode` | `false` | Throw on 4xx/5xx instead of returning |
| `enableCompression` | `true` | Advertise and decode gzip/deflate/br/zstd |
| `maxConnections` | 64 | Pool size across all hosts |
| `cacheSettings` | off | Disk cache, after `NitroHttp.configureCache` |
| `cookieSettings` | on | Jar behaviour and persistence |
| `tlsSettings` | system | Versions, pinning, custom roots, mTLS |

TLS, proxies and DNS-over-HTTPS have more to them than fits here — see
[docs/ADVANCED.md](docs/ADVANCED.md).

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
  link a system libcurl — see [docs/ADVANCED.md](docs/ADVANCED.md#native-dependencies).

## Try it

The example app is a full HTTP console — pick a library, build any request, and
compare all five clients on the same benchmark:

```sh
cd example
flutter run
```

## Docs

- [docs/ADVANCED.md](docs/ADVANCED.md) — TLS, proxies, DNS, the native build,
  testing, and the complete benchmark record
- [CHANGELOG.md](CHANGELOG.md)

## Contributing

Contributions welcome. The Nitro spec in `lib/src/nitro_http.native.dart` is
generated code's source of truth — change it and re-run `nitrogen generate`,
never edit the generated files. Run `dart analyze` and the test suites before
opening a pull request.

## License

Not yet chosen; one will be in place before this package is published.
