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

**On macOS, use the harness rather than a single run.** One run of this suite
has flipped the fastest client in four of five scenarios, so a number taken from
one is not evidence of anything:

```sh
tool/bench-macos.sh 10        # ~6 minutes: build once, run 10x, aggregate
```

It refuses to start on battery, in Low Power Mode, above half load, with any
process over 25 % CPU, or with a simulator, emulator or build alive — because a
benchmark that runs anyway produces numbers someone quotes later, long after the
machine state is forgotten. Then it discards the first run as warm-up and hands
the rest to `tool/bench_aggregate.py`, which applies four checks:

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
