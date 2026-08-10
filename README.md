<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doc/logo-dark.svg">
    <img src="doc/logo-light.svg" alt="nitro_http" width="440">
  </picture>
</p>

# nitro_http

**A Flutter HTTP client whose entire transport is C++.** Requests go straight to
a libcurl engine over [Nitro](https://nitro.shreeman.dev)'s FFI bridge — a
direct C++ call, not a method channel — and Dart never touches a socket.

- **Fast where it matters** — fastest of five clients in 13 of 15 cells of the
  Android stress matrix below, and fastest at concurrency and mixed traffic on
  macOS and iOS too ([every number, including the cells it loses](#benchmarks)).
- **HTTP/1.1, HTTP/2, HTTP/3** on the engine's own event-loop thread, with a
  shared connection pool.
- **One engine, five platforms** — iOS, Android, macOS, Windows and Linux run
  the same C++, so proxies, TLS pinning, redirects, timeouts and cookies behave
  identically everywhere. There is no "works differently on Android" caveat,
  because there is no second implementation to disagree with the first.
- **Drop-in** — keep your `package:http` or `dio` call sites via the bundled
  adapters, or use the typed API directly.


Measured against `dart:io`, `package:http`, `dio` and `rhttp` — same run, same
in-process server, release mode, real hardware
([methodology and every number, including the rows it loses](#benchmarks)):

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="doc/bench-android-modes-dark.svg">
  <img src="doc/bench-android-modes-light.svg" alt="Android, OnePlus 11: five scenarios under serial, concurrent and parallel dispatch. nitro_http is fastest in 13 of 15 cells, including every download, every upload, and every scenario under parallel dispatch." width="100%">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="doc/bench-macos-dark.svg">
  <img src="doc/bench-macos-light.svg" alt="macOS benchmark: nitro_http is fastest at 64 concurrent GETs and the mixed workload, ties rhttp on download, and trails dart:io by 20 microseconds on small GETs." width="100%">
</picture>

<details>
<summary><b>More hardware</b> — iPhone 12 (A14) and the per-scenario Android chart</summary>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="doc/bench-ios-dark.svg">
  <img src="doc/bench-ios-light.svg" alt="iOS benchmark results" width="100%">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="doc/bench-android-dark.svg">
  <img src="doc/bench-android-light.svg" alt="Android per-scenario benchmark: nitro_http is fastest at 64 concurrent GETs, 32 MiB download and the mixed workload; dart:io is fastest at small GETs; upload is a near-tie." width="100%">
</picture>
</details>

- [Install](#install)
- [Quick start](#quick-start)
- [How it compares to other clients](#how-it-compares)
- [Feature tour](#feature-tour)
- [Native dependencies](#native-dependencies) · [building libcurl in one command](#building-a-slice-yourself)
- [Known limitations](#known-limitations)
- [Testing](#testing)
- [Benchmarks](#benchmarks)
- [Contributing](#contributing)
- [License](#license)

Every Dart snippet in this README is compiled and run by
[`test/readme_examples_test.dart`](test/readme_examples_test.dart) (the `dio`
one by `nitro_http_dio/test/readme_example_test.dart`), so the documentation
cannot drift from the API.

## Install

```yaml
dependencies:
  nitro_http: ^0.0.1
```

Requires Dart `^3.12.2` and Flutter `>=3.3.0`. The package pulls in `http` and
`web_socket` — both tiny and pure Dart — because the `package:http` adapter and
the WebSocket interface are part of the public surface.

### Platform support

| Platform | Minimum | Where libcurl comes from |
|---|---|---|
| Android | `minSdk 24`, NDK r27 | Prebuilt slice per ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`). Android ships no usable system libcurl. |
| iOS | 13.0 | `NitroCurl.xcframework` in `ios/Frameworks/`, vendored there by `build_curl apple` (or unzipped by hand). **Mandatory** — the iPhoneOS SDK ships no curl headers and no libcurl. |
| macOS | 10.15 | `NitroCurl.xcframework` when present; otherwise the podspec and SwiftPM manifest fall back to the SDK's own libcurl, which builds and runs today without HTTP/3, brotli or zstd. |
| Windows | x64 | Prebuilt slice, or a system libcurl (for example from vcpkg). |
| Linux | x64, arm64 | System libcurl (`libcurl4-openssl-dev` and friends) by default, or a prebuilt slice. |
| Web / WASM | **not supported** | — |

See [Native dependencies](#native-dependencies) for how a slice is resolved,
built and pinned.

### macOS: the App Sandbox needs one entitlement

A sandboxed macOS app must declare outgoing network access, or the sandbox
refuses every connection the engine opens — including to `127.0.0.1` — and each
transfer fails with `CURLcode 7`. Flutter's macOS template does not include the
key, so add it to both `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

`com.apple.security.network.server` is separate and only needed if your app also
listens for incoming connections. iOS has no equivalent requirement.

### Why there is no web build

The bridge is `dart:ffi` plus `Dart_PostCObject_DL`. Neither exists in a browser
or under `dart2wasm`, and no amount of shimming produces a libcurl in a web page.
This is a permanent non-goal, not a missing feature.

Conditionally import a browser client instead:

```dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:nitro_http/nitro_http.dart';

http.Client createClient() =>
    kIsWeb ? BrowserClient() : NitroHttpCompatClient();
```

Both sides of that expression are an `http.Client`, so the rest of the app never
learns which one it got.

## Quick start

One line, on a lazily created default client:

```dart
import 'package:nitro_http/nitro_http.dart';

Future<void> main() async {
  final res = await fetch('https://api.example.com/health');
  print(res.statusCode);
  print(res.body);
}
```

Or a configured client that owns its pool, cookie jar and TLS setup:

```dart
final client = NitroHttpClient(
  settings: const ClientSettings(
    baseUrl: 'https://api.example.com/v1',
    timeout: Duration(seconds: 30),
    connectTimeout: Duration(seconds: 10),
    httpVersionPref: HttpVersionPref.http2,
    cookieSettings: CookieSettings(storeCookies: true),
  ),
  interceptors: [RetryInterceptor(maxRetries: 3)],
);

final res = await client.get('/users', query: {'page': '2', 'tag': ['a', 'b']});
final users = res.bodyToJson();

client.dispose();
```

The constructor is synchronous. Configuring the engine is one sub-microsecond
FFI call, so there is nothing to `await` — unlike `rhttp`, where every client
starts with `await RhttpClient.create()`.

`dispose()` shuts the engine thread down and flushes the cookie jar. A client
that is collected without disposal is cleaned up by a native finalizer, but that
leaves a thread alive for an indeterminate time.

## Feature tour

Everything ships today — each link jumps to a worked example:

| | | |
|---|---|---|
| [All verbs + custom](#verbs) | [Typed bodies & multipart](#request-bodies) | [Sealed responses](#responses) |
| [Typed errors](#errors) | [Streaming downloads](#streaming-downloads-with-real-backpressure) | [Chunk batching tuning](#tuning-how-streamed-chunks-are-batched) |
| [Streaming uploads](#streaming-uploads) | [File uploads, zero-copy](#uploading-a-file-without-a-dart-buffer) | [Cancellation](#cancellation) |
| [Progress](#progress) | [Transfer timings](#timings) | [TLS, pinning, mTLS](#tls-versions-roots-pinning-mtls) |
| [Proxies](#proxies) | [DNS overrides / DoH](#dns-overrides-and-dns-over-https) | [Cookies + persistent jar](#cookies) |
| [Interceptors](#interceptors) | [Retry with backoff](#retry) | [Disk cache + prefetch](#disk-cache-and-prefetch) |
| [WebSockets](#websockets) | [`package:http` adapter](#packagehttp-adapter) | [`dio` adapter](#dio) |

Every snippet below compiles against the API as it exists in `lib/src/api/`.

### Verbs

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

`options_` carries the trailing underscore because `options` is already the name
of the per-request options parameter on every verb.

Anything else — including a verb your server invented — goes through the typed
helpers:

```dart
await client.requestText(HttpMethod.custom, '/graph', customMethod: 'PURGE');
```

### Request bodies

`HttpBody` is sealed and every variant is `const`-constructible.

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

Each variant supplies its own `Content-Type` unless the caller set one; a
multipart body generates a cryptographically random boundary and keeps it stable
for the life of the object, so the header and the payload can never disagree.

### Responses

`HttpResponse` is sealed on the shape of the body, and which shape you get is
decided by the method you called, so a `switch` is exhaustive:

```dart
String describe(HttpResponse res) => switch (res) {
  HttpTextResponse(:final body) => 'text: ${body.length} chars',
  HttpBytesResponse(:final bodyBytes) => 'bytes: ${bodyBytes.length}',
  HttpStreamResponse(:final contentLength) => 'stream: ${contentLength ?? -1}',
};
```

Every response carries the negotiated version, the final URL after redirects,
the peer address, whether it came from the disk cache, and the headers as an
ordered case-insensitive multimap (so `Set-Cookie` survives intact):

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

A non-2xx response is **not** a transport error. At the wire layer a 500 is a
successful transfer; it becomes an exception only because `throwOnStatusCode`
defaults to `true`. Set it to `false` and you get the response back like any
other.

`NitroHttpException` is sealed, so error handling is exhaustive too:

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

`NitroHttpStatusCodeException` carries the status, the headers and the raw body,
because the error body is usually the part of an API that explains what went
wrong.

### Streaming downloads, with real backpressure

```dart
final res = await client.requestStream(HttpMethod.get, '/dataset.ndjson');

await for (final chunk in res.body) {
  sink.add(chunk);              // a slow consumer stalls the socket, not the heap
}
```

Pausing or slowly draining that stream does not buffer in Dart. The runner grants
the engine a small window of chunk *credits*; when the window is exhausted the
`WRITEFUNCTION` returns `CURL_WRITEFUNC_PAUSE`, curl stops reading the socket and
the TCP window closes on the server. Resuming re-grants credits and unpauses the
transfer. Cancelling the subscription cancels the transfer instead of downloading
into a discarded stream.

### Tuning how streamed chunks are batched

Each chunk that crosses into Dart costs a struct, a zero-copy proxy, a credit and
a `StreamController.add` — 4.81 µs, which is 9.9 ms spread over a 32 MiB body at
libcurl's native 16 KiB blocks. The engine therefore batches, and the default
sizes each response for itself:

```dart
final client = NitroHttpClient(
  settings: ClientSettings(
    baseUrl: 'https://api.example.com',
    streamChunks: const StreamChunkSettings.adaptive(),   // the default
  ),
);
```

Adaptive batches to 128 KiB, but **only** for a body that declares a length of at
least 1 MiB. A response with no `Content-Length`, one that is content-decoded, or
one below the threshold streams as it arrives — so server-sent events and long
polls keep their latency with nothing configured. A part-full chunk older than
`maxHold` (25 ms) is emitted anyway, which bounds the cost of a large body that
turns out to arrive slowly.

Two explicit alternatives:

```dart
// Never batch. Lowest latency, slowest bulk transfer — worth setting for a
// client that only ever consumes live streams.
streamChunks: const StreamChunkSettings.immediate(),

// Batch to an exact size, for a workload the heuristic reads wrongly.
streamChunks: const StreamChunkSettings.fixed(64 * 1024),
```

**Treat `fixed` as a measurement, not a dial.** Sweeping chunk size against body
size (`example/integration_test/chunk_ladder_test.dart`) shows the curve is not
monotonic: 128 KiB won at every size from 8 MiB to 256 MiB, and 256 KiB was
*slower than not batching at all* at four of five sizes. A larger size also
multiplies what the 64-credit window keeps in flight, since a credit stands for
one chunk regardless of its size.

### Streaming uploads

```dart
await client.post(
  '/ingest',
  body: HttpBody.stream(source, contentLength: totalBytes),
);
```

Chunks are fed into a bounded native ring buffer. Once more than 1 MiB is
buffered the Dart source is paused and resumed on a drain event from the engine,
so a fast producer cannot outrun a slow network. Omit `contentLength` and the
request goes out with `Transfer-Encoding: chunked`.

A streamed body is consumed exactly once, which means it cannot be replayed. The
retry loop knows that and refuses to retry rather than sending a truncated second
attempt.

### Uploading a file without a Dart buffer

```dart
await client.put('/backups/nightly.zip', body: HttpBody.file('/var/tmp/nightly.zip'));
```

The path — not the contents — crosses the bridge. curl opens the file and reads
it directly, so a 500 MB upload allocates a file descriptor and nothing else.
Neither `rhttp` nor `react-native-nitro-fetch` offers this; both make you produce
the bytes in the managed runtime first.

### Cancellation

```dart
final token = CancelToken();
Timer(const Duration(seconds: 2), () => token.cancel('user navigated away'));

try {
  await client.get('/slow', cancelToken: token);
} on NitroHttpCancelException catch (e) {
  print(e.reason);              // user navigated away
}
```

One token can drive any number of requests. Cancellation works at every stage —
queued, connecting, mid-body and paused — and always produces exactly one
completion. `client.cancelAll()` aborts everything in flight on that client.

### Progress

```dart
await client.post(
  '/upload',
  body: HttpBody.file('/tmp/video.mp4'),
  onSendProgress: (sent, total) => print('$sent / ${total ?? -1}'),
  onReceiveProgress: (received, total) => print('down $received'),
);
```

Progress is coalesced natively (at most one event per 100 ms) so a fast transfer
cannot flood the isolate, and the terminal 100 % value is synthesized from the
completion path, so callers always see a final event.

### Timings

```dart
final res = await client.get('/ping');
print(res.timings.dns);
print(res.timings.tls);
print(res.timings.firstByte);
print(res.timings.total);
```

Collection is on by default; pass `wantTimings: false` to switch it off, and
`res.timings.isEmpty` is then `true`. A phase that did not happen — no DNS
lookup on a pooled connection — is `Duration.zero`, never `null`.

### TLS: versions, roots, pinning, mTLS

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

`pinnedSpkiSha256` is a list of base64 SHA-256 SPKI hashes — libcurl's
`sha256//<base64>` form without the prefix. A mismatch raises
`NitroHttpCertificateException` with `isPinMismatch == true`, which is
deliberately distinguishable from an untrusted chain: the two mean very different
things (a rotated key with a stale pin, versus an interception attempt).

A single high-value endpoint can be pinned more tightly than the rest of the API:

```dart
await client.post(
  '/payments',
  options: const RequestOptions(pinnedSpkiSha256: 'YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg='),
);
```

`RootCaSource.platform` (the default) validates against the operating system
trust store, honouring user-installed and MDM-deployed roots. `bundled` uses the
Mozilla CA set compiled into the plugin, `custom` uses only
`TlsSettings.trustedRootsPem`, and `none` trusts nothing — useful only alongside
a pin. `TlsSettings.insecure()` exists for local development and logs a warning
on every request; it must never reach a shipped build.

### Proxies

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

### DNS overrides and DNS-over-HTTPS

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

Static overrides map onto `CURLOPT_RESOLVE`, so they are keyed by `host:port` —
which is why the port is part of the settings object rather than guessed.

### Cookies

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

The jar lives in the engine and is shared across every transfer on that client
via `curl_share`, so it survives redirects inside a single request — something a
Dart-side jar cannot observe. A pure-Dart `Cookie` / `CookieJar` /
`InMemoryCookieJar` trio is also exported for applications that want to own
cookie policy themselves.

### Interceptors

`beforeRequest` runs in registration order; `afterResponse` and `onError` run in
reverse, so the first-registered interceptor is the outermost layer and observes
the response last. Every hook is `async`, so refreshing a token is an ordinary
`await`.

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

Three dispositions: `Interceptor.next()` continues the chain (optionally
replacing the value), `Interceptor.stop()` short-circuits it, and
`Interceptor.resolve(response)` abandons the chain and completes the call — from
`beforeRequest` that is a mock or cache hit, from `onError` it is a recovery.
When nothing recovers, `onError` rethrows, which is the only correct signal that
the failure is unhandled.

For one-off hooks there is a closure-based version:

```dart
final logger = DelegatingInterceptor(
  onResponse: (res) async {
    print('${res.statusCode} ${res.finalUrl} in ${res.timings.total}');
    return Interceptor.next();
  },
);
```

### Retry

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

`RetryInterceptor` carries a `RetryPolicy`; the runner reads that policy and
drives the loop itself. An interceptor cannot legitimately re-issue a request —
it would observe its own retries and recurse through its own state — so the
decision and the action are deliberately separated.

The default schedule is exponential with jitter, capped by `maxDelay`, and
`Retry-After` (both delta-seconds and HTTP-date forms) overrides it up to
`maxRetryAfter`. The default rule retries connection failures, timeouts and
408/429/500/502/503/504, and never retries a cancellation. Narrow or widen it
without subclassing:

```dart
RetryInterceptor(
  shouldRetry: (response, error, attempt) =>
      response?.statusCode == 503 ||
      RetryPolicy.isRetryableByDefault(response, error),
);
```

`delay`, `sleep` and `random` are all injectable, so a test asserts the exact
backoff sequence without waiting for it.

### Disk cache and prefetch

The cache is process-wide — two clients sharing one store is the entire point —
and clients opt in individually.

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

The directory is required and never guessed: a plugin inventing a path is how
purgeable bytes end up in a backed-up, user-visible location.

Warm it before the first screen asks:

```dart
await NitroHttp.prefetchOnAppStart([
  'https://api.example.com/v1/feed',
  'https://api.example.com/v1/me',
]);
```

`prefetch` swallows transport failures because a warm-up is an optimisation;
`prefetchDetailed` throws if you actually want to know. Prefetches run on a
dedicated internal engine with a small pool, so a prefetch storm cannot starve a
user client's connections.

Per-request overrides, and the counters:

```dart
await client.get('/feed', options: const RequestOptions(cacheMode: CacheMode.onlyIfCached));
await client.get('/feed', options: const RequestOptions(cacheMode: CacheMode.refresh));

final stats = NitroHttp.cacheStats();
print('${stats.entryCount} entries, hit rate ${stats.hitRate}');
NitroHttp.clearCache();
```

`CacheMode.onlyIfCached` raises `NitroHttpCacheMissException` instead of touching
the network, which is what an offline-first screen wants.

### WebSockets

`NitroWebSocket` implements the Dart team's `package:web_socket` `WebSocket`
interface, so it drops into `web_socket_channel` via `.fromWebSocket` and into
anything else built against that interface.

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

Framing, masking, fragment reassembly, ping/pong and the close handshake are
implemented in C++ over a connection curl established (and, for `wss://`,
terminated TLS on) — so the socket inherits the same trust configuration, proxy
settings and DNS behaviour as every other request. Frames are credit-controlled
exactly like body chunks. `ws.handshakeHeaders` exposes the 101 response headers,
which the official interface has no slot for and some servers need.

### package:http adapter

```dart
final client = NitroHttpCompatClient();
final res = await client.get(Uri.parse('https://example.com/'));
print(res.statusCode);
client.close();
```

`NitroHttpCompatClient` is an `http.BaseClient`, so an existing `Client`-based
codebase moves over by changing one constructor call. Requests larger than
256 KiB, or of unknown length, take the streamed path; smaller ones are buffered,
because the credit loop is not worth its overhead for a 2 KB JSON call.
`throwOnStatusCode` is forced off — a 404 is an ordinary response under the
`package:http` contract. Correctness is checked against
`package:http_client_conformance_tests`, the suite `cronet_http` and
`cupertino_http` use. `NitroHttpCompatClient.wrap(existingClient)` reuses a
client you already configured, and does not dispose it on `close()`.

### dio

The dio adapter is a separate package, `nitro_http_dio`, in this repository —
dio is a heavier dependency than many apps want, and `rhttp` makes the same
split.

```dart
final dio = Dio()..useNitroHttp();

// or, with settings or a shared client:
final dio = Dio()
  ..httpClientAdapter = NitroHttpDioAdapter(
    settings: const ClientSettings(timeout: Duration(seconds: 30)),
  );
```

### Runtime capabilities and hot restart

One binary has to behave correctly against whatever libcurl it was linked with,
so features are queried rather than assumed:

```dart
print(NitroHttp.engineVersion);      // libcurl/8.21.0 ... nghttp2/1.70.0 ...
print(NitroHttp.supportsHttp3);
print(NitroHttp.supportsWebSockets);
print(NitroHttp.supportsBrotli);
print(NitroHttp.supportsZstd);
```

On hot restart the Dart isolate is torn down without cancelling subscriptions
while native threads keep running. Call `NitroHttp.reset()` at startup and every
straggling transfer is aborted, the engine threads joined, and the cookie jars
flushed, so a reloaded app does not inherit ghost sockets:

```dart
void main() {
  NitroHttp.reset();
  runApp(const MyApp());
}
```

## How it compares

The feature target was: everything **rhttp** has (Rust/`reqwest`, the most
feature-complete non-Dart client on pub.dev) plus everything
**react-native-nitro-fetch** has (Margelo's client over Cronet/URLSession, which
popularised disk caching and prefetch on mobile). The table shows where that
landed. Every "Yes" is shipped in 0.0.1, not planned.

| Capability | rhttp | nitro-fetch | nitro_http 0.0.1 |
|---|:--:|:--:|:--|
| HTTP/1.1 | Yes | Yes | Yes |
| HTTP/2 | Yes | Yes | Yes, when the linked libcurl has nghttp2 |
| HTTP/3 (QUIC) | Yes | Yes (Cronet) | Depends on the linked libcurl; report it with `NitroHttp.supportsHttp3` |
| All verbs plus a custom verb | Yes | Yes | Yes |
| Text / JSON / bytes bodies | Yes | Yes | Yes |
| URL-encoded form | Yes | Yes | Yes |
| Multipart | Yes | Yes | Yes, composed lazily so file parts never load into the heap |
| Streaming request body | Yes | Partial | Yes, with a 1 MiB drain watermark |
| Streaming response body | Yes | Yes | Yes, credit-based |
| File body with no managed-heap round trip | No | No | Yes |
| Timeouts (connect / total / idle) | Yes | Partial | Yes, all three, separately |
| Redirect policy and limit | Yes | Yes | Yes |
| Cookies plus a persistent jar | Yes | Yes | Yes (no public-suffix validation — see limitations) |
| Cancellation | Yes | Yes | Yes |
| Upload and download progress | Yes | No | Yes |
| Connection pooling | Yes | Yes | Yes, per client |
| gzip / deflate | Yes | Yes | Yes, always — the engine decodes, not libcurl |
| brotli / zstd | brotli yes, zstd partial | No | Yes on the prebuilt slices; a system-libcurl build advertises neither and passes such a body through |
| An unrecognised `Content-Encoding` | Passed through | Passed through | Passed through byte for byte, headers intact |
| Interceptors | Yes | No | Yes |
| Retry with backoff | Yes | No | Yes |
| TLS min/max version | Yes | No | Yes |
| mTLS client certificates | Yes | No | Yes |
| SPKI certificate pinning | Yes | No | Yes, per client and per request |
| Root CA source selection | Yes | No | Yes |
| Proxies (HTTP / SOCKS5) | Yes | Partial | Yes |
| DNS overrides / DoH | Yes | No | Yes |
| Typed exception hierarchy | Yes | No | Yes, sealed |
| Transfer timings (DNS/TLS/TTFB) | Partial | No | Yes, on by default, disable per request |
| `package:http` adapter | Yes | No | Yes |
| `dio` adapter | Yes | No | Yes, in `nitro_http_dio` |
| WebSockets | No | Separate package | Yes, HTTP/1.1 Upgrade only |
| Disk cache (RFC 9111 subset) | No | Yes | Yes |
| Prefetch | No | Yes | Yes |
| Desktop (Windows / Linux / macOS) | Yes | No | Yes |
| Web | No | No | No, permanently |
| Toolchain required of consumers | Rust | None | None once a `deps-vN` release is published; today a slice must be built or supplied (see below) |

The two rows worth dwelling on are WebSockets and cache/prefetch: they are where
`nitro_http` beats both baselines at once.

Against the pure-Dart clients the difference is not a feature checklist but a
layer: `package:http` is a thin portable interface, `dio` adds interceptors,
progress, cancellation and adapters on top of `dart:io` — and all three share
`dart:io`'s transport, so none of them can offer HTTP/3, TLS pinning, mTLS,
DNS-over-HTTPS, an RFC 9111 disk cache, or transfer timings, because the socket
layer they sit on has no such knobs. `nitro_http` owns its transport, which is
where those features live — and you keep your existing call sites either way,
because it ships a `package:http` adapter and a `dio` adapter
([below](#packagehttp-adapter)). Raw speed is a separate question with its own
section: [Benchmarks](#benchmarks).


## Native dependencies

The build finds libcurl in this order, stopping at the first match:

1. **`NITRO_HTTP_DEPS_DIR`** — an environment variable pointing at a directory
   of prebuilt slices (`include/` + `lib/`, or `NitroCurl.xcframework` on
   Apple). Use this for your own builds, CI caches, and offline machines —
   nothing on this path touches the network.
2. **A checksum-pinned download** from the [`deps-v1`][deps-release] GitHub
   release — one slice per platform, each verified against the SHA-256 in
   `deps/versions.cmake` before it is used. A checksum that does not match
   fails the build rather than being trusted.
3. **The system libcurl** — the default on Linux, macOS and Windows. Builds and
   runs today; HTTP/3, brotli and zstd depend on what that libcurl has, and
   `NitroHttp.supportsHttp3` / `supportsBrotli` / `supportsZstd` report the
   truth at runtime.

**Android and iOS have no system libcurl**, so they rely on a slice from path 1
or path 2. macOS falls back to the SDK's libcurl when no xcframework is
present; iOS has no fallback and fails the build with undefined `curl_*`
symbols if neither path supplies one.

[deps-release]: https://github.com/Shreemanarjun/nitro_http/releases/tag/deps-v1

### Building a slice yourself

One command, from any app that depends on this package — no repo clone. It
compiles the full stack (curl, BoringSSL, nghttp2/3, ngtcp2, brotli, zstd, zlib)
with every BoringSSL symbol prefixed so it can never collide with another
plugin's OpenSSL, and prints the `NITRO_HTTP_DEPS_DIR` export to use when done:

The `apple` build also vendors `NitroCurl.xcframework` into the plugin's
`ios/` and `macos/` folders — required because Swift Package Manager builds
(the Flutter default) resolve it by path and never run the podspec.

```sh
flutter pub run nitro_http:build_curl apple    # 5 Apple slices + xcframework merge
flutter pub run nitro_http:build_curl android  # arm64-v8a, armeabi-v7a, x86_64 (finds your NDK)
flutter pub run nitro_http:build_curl linux    # host architecture
flutter pub run nitro_http:build_curl --list   # print the plan, build nothing
```

On Windows the same command runs `tool/deps/build.ps1` (VS 2022 x64, NASM,
Ninja). Add `--no-http3` to drop QUIC, which is roughly 40 % of the binary; the
engine then reports HTTP/3 as unavailable instead of failing. For per-slice
control, pinned component versions, or offline setups, see `tool/deps/` — the
scripts there are what this command runs.

## Known limitations

All of these are current.

- **No web or WASM support, ever.** `dart:ffi` and `Dart_PostCObject_DL` do not
  exist there. Use `package:http`'s `BrowserClient` behind `kIsWeb`.
- **WebSockets are HTTP/1.1 Upgrade only.** RFC 8441 (`Extended CONNECT`, i.e. a
  WebSocket over an HTTP/2 stream) is not implemented, so a socket cannot share
  an h2 connection. libcurl does not implement RFC 8441, and neither does
  reqwest, so this is not a gap relative to the alternatives.
- **No public-suffix validation for cookies.** libpsl is not vendored, so the jar
  cannot reject a `Domain` attribute naming a public suffix. curl's own domain
  checks still apply, but do not treat the jar as a security boundary against a
  hostile server.
- **HTTP/3 depends on the libcurl you actually link.** A system libcurl usually
  has no QUIC backend. Check `NitroHttp.supportsHttp3` at runtime; a client that
  prefers HTTP/3 without one silently negotiates HTTP/2 instead, and
  `HttpVersionPref.http3Only` fails the request.
- **Binary size: roughly 1.5–3 MB per ABI** with the vendored stack. Dropping
  HTTP/3 (`--no-http3`) removes about 40 % of that.
- **`TlsSettings.sniHostname` is accepted but not applied.** The field exists on
  the wire record and round-trips through the config, but the engine does not yet
  set `CURLOPT_RESOLVE`-style SNI overriding from it, so reaching a host by IP
  while validating another hostname does not work yet.
- **WebSockets are HTTP/1.1 Upgrade only.** A WebSocket cannot share an HTTP/2
  connection (RFC 8441 `Extended CONNECT` is not implemented), which is also
  true of reqwest-based clients.

## Testing

**Unit tests** — 621 of them, no device or native library needed. Coverage is
96.4 % of hand-written lines, gated at 92 % in CI. Every code snippet in this
README is also a test (`test/readme_examples_test.dart`), so a breaking API
change breaks the build before it breaks a reader.

```sh
flutter test                  # unit suite
tool/coverage.sh              # coverage report, fails under the floor
```

**Integration tests** — run in `example/` against an in-process server on
`127.0.0.1`, on any simulator, emulator or desktop target. On macOS add the
[sandbox entitlement](#macos-the-app-sandbox-needs-one-entitlement) first.

```sh
cd example
flutter test -d macos integration_test        # or -d <simulator|emulator id>
```

**C++ engine tests** — GoogleTest, desktop only, opt-in:

```sh
cmake -S src -B build/cpp -DNITRO_HTTP_BUILD_TESTS=ON
cmake --build build/cpp
ctest --test-dir build/cpp --output-on-failure
```

## Benchmarks

The charts at the top of this page are the results: five scenarios, five
clients, one in-process loopback server, p50 in release mode on real devices —
an M1 Pro, an iPhone 12 and a OnePlus 11. Charts regenerate from the data table
in `tool/gen_benchmark_charts.py`. Phone numbers vary run to run (heat alone
moved every client 11–60 % between sets), so treat any margin under ~10 % as a
tie, and never compare numbers from different runs.

### Run it yourself

The comparison suite needs a real device and a **release** build — debug mode
slows Dart code far more than native code, so it penalises each client
differently. Because `flutter drive` cannot attach to a release engine, the
benchmark is compiled into the example app behind
`--dart-define=NITRO_HTTP_BENCHMARK=1` and prints its table to the platform
log. The example app also has an interactive Benchmark tab with the same
scenarios, live progress and per-scenario rankings.

```sh
cd example

# macOS — stdout of the built binary
flutter build macos --release --dart-define=NITRO_HTTP_BENCHMARK=1
./build/macos/Build/Products/Release/nitro_http_example.app/Contents/MacOS/nitro_http_example

# Android — logcat. Pin the ABI to the slice you built.
flutter build apk --release --target-platform android-arm64 \
  --dart-define=NITRO_HTTP_BENCHMARK=1
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb logcat -c && adb shell monkey -p <application-id> 1 && adb logcat -s flutter:I

# iOS — a physical DEVICE. Simulators cannot do this: Flutter has no AOT
# snapshot for them, so `--release` and `--profile` are both rejected there and a
# simulator can only ever report debug timings.
flutter build ios --release --dart-define=NITRO_HTTP_BENCHMARK=1
# install with Xcode or devicectl, trust the developer certificate once under
# Settings > General > VPN & Device Management, then:
xcrun devicectl device console --device <udid> | grep NITRO_BENCH
```

Filter the log for `NITRO_BENCH`. A run is only valid if it ends
`NITRO_BENCH_END`; `NITRO_BENCH_FAIL` means the report failed its own consistency
gate — every client must have completed every scenario and moved the same number
of bytes, which is what stops a fast result from being a client that skipped the
work. `BenchmarkReport.consistencyProblems()` enforces that, and the integration
test asserts on the same method, so both paths apply one standard.

Two things will invalidate a run: a **loaded machine** (three concurrent builds on
this host turned one client's p99 from 10 ms into 42 ms), and quoting a debug
build. The `NITRO_BENCH_BEGIN` line states the mode it was actually compiled in,
and a non-release build additionally logs a warning, so a pasted log carries its
own caveat.

Note the cost of the comparison: **`example/pubspec.yaml` depends on `dio` and
`rhttp` solely for this benchmark, and `rhttp` builds a Rust crate**, so building
the example app needs a Rust toolchain (1.88 or newer at the time of writing). If
you only want to see the client work, delete those two dependencies and the
`_DioSubject` and `_RhttpSubject` classes in
`example/lib/benchmark/benchmark.dart`; nothing else references them.

## Contributing

Contributions are welcome. Two things make review much easier:

- Read `doc/ARCHITECTURE.md` first, especially the payload-ownership section.
  The zero-copy chunk protocol is the one invariant in this codebase that is easy
  to break invisibly.
- Do not hand-edit generated files. The Nitro spec lives in
  `lib/src/nitro_http.native.dart`; changing it requires regenerating and
  relinking, which changes the bridge checksum on both sides. All hand-written
  build logic lives in `src/deps.cmake` and `src/engine.cmake`, outside every
  section `nitrogen link` manages, so regeneration cannot clobber it.

Run `dart analyze` and the Dart unit suite before opening a pull request. The
C++ suite needs a libcurl, so it is not required locally if you did not touch
`src/engine/`.

## License

[MIT](LICENSE) © 2026 Shreeman Arjun Sahu. The vendored native dependencies
(curl, BoringSSL, nghttp2, nghttp3, ngtcp2, brotli, zstd, zlib) keep their own
licenses — all permissive (curl, OpenSSL/ISC, MIT, BSD).
