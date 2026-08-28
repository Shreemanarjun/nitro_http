# nitro_http — advanced guide

The README covers what most callers need. This is the rest: the knobs you reach
for when something is unusual, the native build, and the full measurement record
behind the performance claims.

Everything here is written for someone changing the library or debugging it, not
for someone using it. If you only want to make requests, the README is enough.

## Contents

- [Streaming chunk batching](#tuning-how-streamed-chunks-are-batched)
- [TLS: versions, roots, pinning, mTLS](#tls-versions-roots-pinning-mtls)
- [Proxies](#proxies)
- [DNS overrides and DNS-over-HTTPS](#dns-overrides-and-dns-over-https)
- [Logging, and running interceptors in parallel](#logging-and-running-interceptors-in-parallel)
- [Resuming an interrupted transfer](#resuming-an-interrupted-transfer)
- [Runtime capabilities and hot restart](#runtime-capabilities-and-hot-restart)
- [How it compares, feature by feature](#how-it-compares)
- [Native dependencies and building a slice](#native-dependencies)
- [Testing](#testing)
- [Benchmarks and the full measurement record](#benchmarks)

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
`TlsSettings.trustedRootsPem`, and `none` removes every anchor — so it is
**refused unless a pin is configured**, since without one it would accept any
certificate rather than none. `TlsSettings.insecure()` exists for local
development and logs a warning on every request; it must never reach a shipped
build.

Three failures here are easy to confuse, and each points somewhere different:

| exception | meaning |
|---|---|
| `NitroHttpCertificateException` | the chain was judged and rejected — untrusted, expired, or not matching a pin (`isPinMismatch` tells those apart) |
| `NitroHttpTlsException` | the handshake never reached a certificate: no shared protocol version or cipher, which is what a `minVersion` clamp above the server's ceiling produces |
| `NitroHttpConfigurationException` | the settings themselves were refused before a socket opened — an unsatisfiable version range, a PEM with no certificate, `none` without a pin |

None of the three is retryable, but only the last is fixed by changing code
rather than by reaching a different server.
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
### Logging, and running interceptors in parallel

`LogInterceptor` writes one line per call and is built so that leaving it
installed in release costs a branch:

```dart
final client = NitroHttpClient(
  settings: const ClientSettings(baseUrl: 'https://api.example.com'),
  interceptors: [
    LogInterceptor(
      level: kDebugMode ? HttpLogLevel.headers : HttpLogLevel.none,
      sink: (line) => developer.log(line, name: 'http'),
    ),
  ],
);
```

```
--> GET https://api.example.com/users/7
<-- 200 OK https://api.example.com/users/7 431b 38ms
```

Four levels: `none`, `basic` (the line above), `headers`, `body`. The level is
checked before anything is formatted, so a level you are not using costs nothing
to have configured.

A streamed body is never read in order to log it. Doing that would buffer the
whole response to replay it to the caller, turning a constant-memory download
into an unbounded one, so at `body` level a stream logs as `<stream>`. Streamed
and file request bodies work the same way.

Duration is `HttpTimings.total`, which the engine already measures, so there is
no stopwatch and no request-to-start-time map left holding entries when a call
never completes. It reads `-` under `wantTimings: false`.

`authorization`, `proxy-authorization`, `cookie` and `set-cookie` are redacted,
because logs get pasted into issues. `redactedHeaders` replaces that set rather
than adding to it, so widening it means listing the defaults again.

Whatever sink you pass runs inside the chain. `print` or `developer.log` is
negligible; anything that does I/O makes every request wait for it, for the
reason in the next section.

#### What interceptor overhead actually comes from

A hook returns `FutureOr`, so it can answer without a `Future`, and the chain
stays synchronous until one of them doesn't. That property dominates the cost,
well ahead of anything a hook actually does:

| three interceptors, per request | |
|---|---|
| synchronous hooks | 4.4 µs |
| `LogInterceptor` at `none` | 4.7 µs |
| `LogInterceptor` at `basic`, formatting and writing | 5.2 µs |
| one `async` hook among two synchronous ones | 36.7 µs |
| all `async` hooks | 52.3 µs |

The same holds on the way out:

| exit path, one interceptor | |
|---|---|
| `Interceptor.resolve()`, answering without the network | 6.7 µs |
| `Interceptor.next()` | 7.7 µs |
| throwing a `NitroHttpException` from a synchronous hook | 4.9 µs |
| throwing any other object, which gets wrapped | 5.2 µs |
| throwing from an `async` hook | 20.0 µs |

So don't mark a hook `async` unless it awaits something. One that only sets a
header still suspends the chain, and suspension is contagious: once a hook
returns a future, every later hook is awaited too. That is the gap between
4.4 µs and 36.7 µs.

When a hook has nothing to say, return `Interceptor.proceedRequest` or
`Interceptor.proceedResponse`. Both are `const`, so they cost neither an
allocation nor a future, where `Interceptor.next()` builds a fresh result.

For outcomes you expect, prefer a disposition to an exception. `resolve()` was
the cheapest path measured and skips the network entirely; `stop()` ends the
chain without unwinding. Throwing is for real failures, and from a synchronous
hook it is close to free — you pay for the `async`, not the throw. Wrapping a
foreign object adds about 0.3 µs, so throw whichever type reads best.

```dart
class TraceHeader extends Interceptor {
  const TraceHeader();

  @override
  FutureOr<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) {
    request.headers.set('x-trace-id', newTraceId());
    return Interceptor.proceedRequest;
  }
}
```

Numbers are from an in-process chain under the JIT (`flutter test`), so read
them as relative rather than as release figures. The ~4.4 µs floor is the
caller's own two awaits, not the interceptors.

#### Sequential by default, parallel when they are independent

The chain is sequential on purpose: each interceptor sees what the one before it
produced, which is what makes `auth → sign → retry` compose. Registration order
is the middleware order — first-registered is outermost, so it rewrites the
request first and observes the response last.

That ordering costs latency when the members are not actually cooperating.
Several independent observers that each await I/O add up end to end, so group
those with `ParallelInterceptors`:

```dart
NitroHttpClient(
  interceptors: [
    AuthInterceptor(),                 // sequential: must run before signing
    SigningInterceptor(),
    ParallelInterceptors([             // concurrent: independent of each other
      RemoteLogInterceptor(),          // awaits a network write
      MetricsInterceptor(),            // awaits a metrics flush
    ]),
  ],
);
```

Three 120 ms hooks take ~120 ms grouped against ~360 ms in turn.

**Only reach for it when the hooks await something.** Running cheap synchronous
observers through `Future.wait` is slower than letting them run in turn, not
faster — a `LogInterceptor` writing to `print` belongs in the ordinary list.

Members must be observers. One that returns a replacement, stops the chain or
resolves it throws `StateError`, because "first one wins" would depend on
completion order and so would differ run to run. Anything that rewrites goes in
the sequential list. If one member throws, the others are still awaited before
the error propagates — an abandoned hook would go on writing after the call it
belonged to had finished.

One interceptor instance serves every request on its client, including
concurrent ones, so anything you store on it is shared. Keep per-request state in
the request or response rather than in a field.

### Resuming an interrupted transfer

Resume is a header protocol, and the engine stays out of its way. `Range` and
`Content-Range` reach the wire untouched, a `206 Partial Content` stays a 206
rather than being normalised to 200, and a partial body is handed over as it
arrived instead of being stitched back into a whole one.

Downloading the rest of a file you already have part of:

```dart
final have = await file.length();
final response = await client.requestStream(
  HttpMethod.get,
  'https://cdn.example.com/large.bin',
  headers: HttpHeaders.fromMap({'Range': 'bytes=$have-'}),
);

if (response.statusCode == 206) {
  final sink = file.openWrite(mode: FileMode.append);
  await response.body.pipe(sink);        // appends; nothing buffers whole
} else if (response.statusCode == 200) {
  // The server ignored the Range header — this is the whole file, so start over.
  await file.writeAsBytes(await response.body.expand((c) => c).toList());
}
```

Check `Accept-Ranges: bytes` on a `HEAD` first if you want to know whether it is
worth trying. Always handle the 200 case: a server is allowed to ignore `Range`,
and appending a full body to a partial file is how you get a corrupt download.

Uploading from an offset is the same shape — the source stream starts mid-file
and the engine neither rewinds it nor recomputes its length:

```dart
final response = await client.put(
  'https://uploads.example.com/session/$id',
  body: HttpBody.stream(
    file.openRead(offset),
    contentLength: total - offset,
  ),
  headers: HttpHeaders.fromMap({
    'Content-Range': 'bytes $offset-${total - 1}/$total',
  }),
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

**Hot restart needs nothing from you.** A hot restart replaces the Dart isolate
while the plugin's native side keeps running — engine threads, in-flight
transfers, cookie jars and cancellation state all survive it, and Flutter tells
a plugin nothing. The library notices by itself: the first time an incarnation
touches native, it aborts every straggling transfer, joins the engine threads,
flushes the cookie jars and clears cancellation state. There is no call to add
to `main()`.

```dart
void main() {
  runApp(const MyApp());       // that's it
}
```

`NitroHttp.reset()` still exists for the explicit case — a test that wants a
known-clean engine between cases, or an app deliberately dropping everything
mid-run. It is no longer something you have to remember, which matters because
the failure mode was invisible: ghost sockets, or a request that cancelled
itself because a cancellation token id from the previous incarnation was still
live in the engine.

A background isolate is skipped deliberately: its statics are fresh too, so it
cannot tell a hot restart from simply being new, and resetting there would abort
the transfers the root isolate has in flight.
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
| `dio` adapter | Yes | No | Yes, via `package:nitro_http/dio.dart` |
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
([in the README](../README.md#using-it-with-packagehttp-or-dio)). Raw speed is a
separate question with its own section: [Benchmarks](#benchmarks).
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
3. **The system libcurl** — a fallback, reached only when path 2 cannot run:
   no SHA-256 recorded for this slice, or the download refused. Every slice is
   pinned as of `deps-v1`, so a normal build never gets here. When it does,
   HTTP/3, brotli and zstd depend on what that libcurl was built with, and
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
Ninja). Add `--no-http3` to drop QUIC, worth about 0.4 MB per ABI — ~9 % of the
linked `.so`, not the 40 % this once claimed, because `-Wl,--gc-sections`
already discards the QUIC code nothing references; the
engine then reports HTTP/3 as unavailable instead of failing. For per-slice
control, pinned component versions, or offline setups, see `tool/deps/` — the
scripts there are what this command runs.
## Testing

**Unit tests** — 686 of them, most needing no device or native library. Dart
coverage is 96.6 % of hand-written lines, gated at 92 % in CI. Every code
snippet in the README is also a test (`test/readme_examples_test.dart`), so a
breaking API change breaks the build before it breaks a reader.

```sh
flutter test                  # unit suite
tool/coverage.sh              # Dart coverage, fails under the floor
tool/cpp-coverage.sh 75       # C++ ENGINE coverage, fails under the floor
```

The two numbers measure different things: `tool/coverage.sh` covers ~2 200
lines of Dart glue, `tool/cpp-coverage.sh` the ~11 000 lines of C++ engine.
The engine sits at **80 % lines / 88 % functions**, with the thin spots being
`DartPost.cpp` (21 %, needs a live isolate), `EngineRegistry.cpp` (21 %) and
`ClientConfig.cpp` (58 %).

**A passing suite is not a tested behaviour.** HTTPS was broken on Apple and
`wss://` segfaulted against HTTP/2 servers through 0.0.1–0.0.3, with every test
green: the suite only ever talked to a plaintext loopback server, and settings
like `RootCaSource` had configuration tests that checked a value reached the
wire but never that anything acted on it.
`test/tls_settings_e2e_test.dart` and `test/network_settings_e2e_test.dart`
cover TLS, proxies, DNS and protocol negotiation end to end; each assertion is
paired with a control proving it could fail.

**Integration tests** — run in `example/` against an in-process server on
`127.0.0.1`, on any simulator, emulator or desktop target. On macOS add the
[sandbox entitlement](../README.md#setup) first.

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

The charts in the [README](../README.md#how-fast-is-it) are the headline
results: five scenarios, five clients, one in-process loopback server, p50 in
release mode on an M1 Pro, an iPhone 12 and a OnePlus 11. They regenerate from
`tool/gen_platform_charts.py`, each annotated with the `build/bench/` directory
it came from. Treat any margin under ~10 % as a tie, and never compare numbers
from different runs.

This section is the part the charts cannot show.

### Reading the results honestly

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
rather than any client. And with the network removed what is left is the
client's own cost — over a real link latency dominates and everything converges.

Each platform was measured more than once, on separate occasions, and the sets
agree: three independent 10-run sets on macOS put the mixed p50 at 0.81 / 0.84 /
0.84 ms and throughput at 449 / 444 / 449 req/s, and two on iOS agree to within
0.1 % on every row. The charts quote one set each rather than a pooled average,
because pooling runs taken in different machine states is the mistake the whole
harness exists to prevent.

<details>
<summary><b>How the dispatch modes compare on Android</b> — serial, concurrent and parallel (earlier, heavier measurement set)</summary>

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="bench-android-modes-dark.svg">
    <img alt="Serial, concurrent and parallel dispatch on Android" src="bench-android-modes-light.svg" width="100%">
  </picture>
</p>

Generated by `tool/gen_benchmark_charts.py`, not the platform-chart script, and
from an earlier measurement set with a heavier workload — so it is not
comparable with the headline charts and is kept separate for that reason.
</details>

### Run it yourself

The comparison suite needs a real device and a **release** build — debug mode
slows Dart code far more than native code, so it penalises each client
differently. Because `flutter drive` cannot attach to a release engine, the
benchmark is compiled into the example app behind
`--dart-define=NITRO_HTTP_BENCHMARK=1` and prints its table to the platform
log. The example app also has an interactive Benchmark tab with the same
scenarios, live progress and per-scenario rankings.

**Use a harness rather than a single run.** One run of this suite has flipped
the fastest client in four of five scenarios, so a number taken from one is not
evidence of anything:

```sh
tool/bench-macos.sh 10        # ~6 minutes: build once, run 10x, aggregate
tool/bench-android.sh 10      # thermally gated; needs one device attached
tool/bench-ios.sh 10          # physical iPhone/iPad; pulls the report off the device
```

Each refuses to start in a state that would produce an unquotable number: a
busy or battery-powered Mac, an Android emulator or a device below 30 % battery,
locked, or above 42 °C, and iOS without a paired physical device. The Android
thermal gate re-checks before *every* run — two sets minutes apart differed
11–60 % per client purely from heat.

All three then discard the first run as warm-up and hand the rest to
`tool/bench_aggregate.py`, which applies four checks:

- **Validity** — a run counts only if it reached `NITRO_BENCH_END` and never
  printed `NITRO_BENCH_FAIL`.
- **Control drift** — the four competitor clients are untouched by any change
  here, so movement in *their* numbers measures the laptop, not the library. A
  scenario whose controls moved more than 15 % is reported as `NO RESULT`
  instead of a ranking. This is the check that catches the failure mode this
  project has actually hit, where `package:http`'s burst p50 went 9.42 → 18.76 ms
  untouched between consecutive runs.
- **Outliers** — flagged by a MAD-based modified z-score, reported rather than
  silently dropped (`--drop-outliers` excludes them explicitly).
- **Resolution** — a winner is declared only when the gap exceeds both 10 % and
  the spread of the two clients being compared. Everything else is a tie, which
  is a genuine result rather than a failure to measure.

The raw per-run logs are kept under `build/bench/`, so any published number can
be traced back to the runs it came from.

To do it by hand instead:

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
# Settings > General > VPN & Device Management, then launch it.
#
# DO NOT try to scrape the log. An iOS RELEASE build emits no `print` output at
# all: `devicectl device console` attaches happily and captures a zero-byte
# file, and `idevicesyslog` sees nothing either — so the failure is silent and
# looks like the benchmark never ran. That is why the benchmark also writes its
# report into the app's Documents directory. Pull that instead:
xcrun devicectl device copy from --device <udid> \
  --domain-type appDataContainer --domain-identifier dev.shreeman.nitroHttpExample \
  --user mobile --source Documents/nitro_benchmark.md --destination ./report.md
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
