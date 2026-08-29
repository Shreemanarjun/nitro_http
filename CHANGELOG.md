## 0.0.5

### Added

* **Web support** — compiles and runs under `flutter build web` (dart2js and
  `--wasm`), served by `fetch` rather than the engine, because a browser gives
  native code no socket. See the [web section](README.md#web).
* WebSockets work on web, on the browser's own `WebSocket` — `NitroWebSocket`
  already implements `package:web_socket`'s interface, so the API is unchanged.
  Request headers, `pingInterval` and TLS settings throw there: the browser
  performs the upgrade and owns them.
* Per-phase `HttpTimings` on web, read from Resource Timing and reported the way
  the engine reports them — time from the start of the request, so the type
  means one thing on every platform.
* Per-request `CacheMode` on web: `fetch`'s cache modes line up with it almost
  exactly, and the browser runs the cache.
* Timeouts, download progress, cancellation and cookies now work on web; they
  were previously ignored there.
* Web answers its own capability queries: `engineVersion` reads
  `fetch (browser)`, `supportsHttp3` is `false` and `supportsWebSockets` is `true`.

### Fixed

* **Streams delivered nothing on `nitro` 0.7.4** ([#2]) — 0.7.4 partitions
  stream ports by emitting instance, and the sink emitted through a different
  instance from the one Dart subscribed on.

### Changed

* **The `dio` adapter ships inside `nitro_http`** ([#1]) — import
  `package:nitro_http/dio.dart` instead of the never-published `nitro_http_dio`
  package; the API is unchanged and `dio` is now a dependency of this package.
* Engine settings a browser cannot honour — TLS pinning, mTLS, custom roots,
  proxies, DNS, HTTP version, the pool, timings, the cookie jar, the disk cache
  and streamed uploads — throw `NitroHttpConfigurationException` on web rather
  than being ignored.
* Upgraded to `nitro` 0.7.4 from 0.7.0.

[#1]: https://github.com/Shreemanarjun/nitro_http/issues/1
[#2]: https://github.com/Shreemanarjun/nitro_http/issues/2

## 0.0.4

### Fixed

* `RootCaSource.none` verified nothing instead of trusting nothing — every chain
  was accepted. It is now refused unless `pinnedSpkiSha256` is set; use
  `TlsSettings.insecure()` to skip verification deliberately.

* HTTPS failed on every iOS and macOS request against the vendored engine
  (`CURLcode 60`). The TLS backend is detected at runtime and the bundled
  Mozilla roots are installed when the platform store is unreachable. Note that
  `RootCaSource.platform` on Apple is then served by that bundle, so a root added
  to the Keychain by a user or MDM profile is not trusted — use
  `RootCaSource.custom` with your own PEM. Android was never affected.

* `wss://` segfaulted against any HTTP/2-capable server. The handshake pins
  HTTP/1.1. Plain `ws://` was unaffected.

* `StreamChunkSettings.minContentLength: 0` was read as "unset" and replaced with
  the 1 MiB default, so nothing under 1 MiB batched.

* `StreamChunkSettings.maxHold` never fired while a connection was idle, which is
  the case it exists for. The engine loop polls the deadline.

### Added

* `LogInterceptor` — one line per call at four levels (`none`, `basic`,
  `headers`, `body`), credential headers redacted, streamed bodies never drained,
  duration taken from the engine's timings.

* `ParallelInterceptors` — runs independent observers concurrently for when each
  awaits I/O. Members that modify the chain throw.

* Interceptor hooks return `FutureOr`, and the chain stays synchronous until one
  returns a future: three synchronous interceptors cost 4.4 µs per request
  against 50.8 µs before. `Interceptor.proceedRequest` and
  `Interceptor.proceedResponse` are `const` pass-through results.

* `NitroHttpTlsException` for a handshake that failed before any certificate, and
  `NitroHttpConfigurationException` for settings refused before a socket opens.
  Split out of `NitroHttpCertificateException` and `NitroHttpUnknownException`.

* `NitroWebSocket.connect` accepts `tlsSettings`, so `wss://` can use custom
  roots, SPKI pinning, mTLS and a version clamp.

### Changed

* Chunk-batching defaults are set where the engine config is constructed instead
  of being inferred from `0` where it is read, so `0` means zero.

### Migration

* `NitroHttpException` is sealed: exhaustive switches need
  `NitroHttpTlsException` and `NitroHttpConfigurationException`.

* An `Interceptor` subclass that returns `super.beforeRequest(…)` from a method
  declared `Future<…>` must widen its own return type to `FutureOr`. Ordinary
  `async` overrides are unaffected.

* `InterceptorChain.runOnError` throws synchronously for an unhandled failure
  rather than returning a rejected future. `await` behaves as before.

### Tests

Behavioural coverage, added because the three TLS and WebSocket bugs above all
shipped past configuration-only tests.

* 26 settings that had configuration tests but no end-to-end ones: redirect caps,
  cookie suppression and persistence, the idle deadline, compression, pool
  limits, SOCKS5, proxy credentials, upload progress, chunk batching, custom
  verbs, alt-svc, DoH, h3 negotiation, and the TLS settings against a locally
  generated CA. `TlsSettings.sniHostname` is a named skip, since it is still
  ignored.
* WebSockets against a real peer: 7 engine tests (binary and 200 KB payloads,
  empty frames, fragment reassembly, automatic pong, `maxFrameBytes`, send after
  close) and 13 Dart tests (close codes, subprotocols, keepalive, burst
  ordering, concurrent sockets not crossing streams).
* Resumable downloads and uploads. `Range` and `Content-Range` always worked;
  nothing proved it. See
  [ADVANCED.md](doc/ADVANCED.md#resuming-an-interrupted-transfer).

## 0.0.3

Documentation only. `lib/` and `src/` are still byte-identical to 0.0.1.

### Fixed

* **The logo now renders on any background.** It was a `<picture>` with a
  near-black wordmark for light themes and a white one for dark, and the light
  variant did not appear on pub.dev. Both variants are replaced by one PNG whose
  wordmark is a single mid blue (`#2a78d6`), measured at 4.42:1 on white,
  4.29:1 on GitHub dark and 3.90:1 on pub.dev dark — so one asset is legible
  everywhere and the theme switch is gone rather than fixed.

## 0.0.2

Documentation only. `lib/` and `src/` are byte-identical to 0.0.1, so upgrading
changes nothing at runtime.

### Fixed

* **Asset links in the README, so the logo and benchmark charts actually render
  on pub.dev.** They now use absolute URLs rather than repository-relative ones.
  pub.dev rewrites and proxies an `<img src>` but leaves the `<source srcset>`
  of a `<picture>` alone, so every dark-theme variant resolved to nothing and
  readers on a dark theme saw blanks where the charts should be. A published
  README can only be corrected by publishing again, which is what this release
  is for.

## 0.0.1

First release.

A Flutter HTTP client whose transport is a C++ libcurl engine, reached over
Nitro's FFI bridge rather than a platform channel. One engine serves iOS,
Android, macOS, Windows and Linux, so proxies, TLS pinning, redirects, timeouts
and cookies behave the same everywhere.

### Added

* **HTTP/1.1, HTTP/2 and HTTP/3**, negotiated automatically or forced per
  client. Which are available depends on the libcurl actually linked, so the
  engine asks it at runtime — see `NitroHttp.supportsHttp3`.
* **Every verb, and seven body shapes** — text, JSON, bytes, form, multipart,
  stream and file. `HttpBody.file` uploads straight from disk without ever
  allocating a Dart buffer.
* **Streaming in both directions**, with credit-based backpressure: a slow
  consumer throttles the socket instead of filling the Dart heap. Response
  chunks are handed over zero-copy.
* **Cancellation** with `CancelToken`. The token lives in the engine, so a
  request bound to an already-cancelled one never opens a socket, and cancelling
  reaches every request sharing that token in a single call.
* **Timeouts** for connect and total, plus a real idle deadline enforced by the
  engine's own event loop. `TimeoutStage` tells the three apart.
* **Progress callbacks and per-phase timings** — DNS, connect, TLS and
  time-to-first-byte.
* **A sealed Dart API.** `HttpBody`, `HttpResponse` and `NitroHttpException` are
  sealed, so a `switch` over them is exhaustive and the compiler catches a case
  you forgot.
* **Content decoding in the engine** — gzip and deflate always, brotli and zstd
  when linked, bounded so a compression bomb cannot exhaust memory. It advertises
  exactly what it can decode, so results do not depend on how the local libcurl
  happened to be built.
* **TLS** — minimum and maximum version, custom or bundled root CAs, mutual TLS,
  and SPKI pinning per client or per request.
* **Proxies and DNS** — system, HTTP and SOCKS5 proxies, static host overrides,
  and DNS-over-HTTPS.
* **Cookies** — an in-memory or file-backed jar shared across a client's
  transfers.
* **Interceptors and retry** — async `beforeRequest` / `afterResponse` /
  `onError`, so a token refresh is a normal `await`, plus a retry interceptor
  with configurable backoff.
* **A disk cache** implementing a subset of RFC 9111: freshness, revalidation
  with `ETag` / `Last-Modified`, LRU eviction against a byte budget, per-request
  `CacheMode`, and an explicit prefetch API.
* **WebSockets** on the same engine, inheriting its proxy and DNS behaviour,
  and implementing `package:web_socket`'s `WebSocket` interface. (TLS settings
  did not reach them until 0.0.4.)
* **Adapters for `package:http` and `dio`**, so existing call sites keep
  working. The `package:http` adapter passes the official
  `http_client_conformance_tests` suite.
* **Hot restart needs nothing from you.** The library reconciles native state
  the first time a reloaded app touches the engine — aborting stragglers,
  joining engine threads, flushing cookie jars — so there is no call to add to
  `main()`.

Built against `nitro` 0.6.1, which bounds the Android direct-buffer pool behind
`@zeroCopy` returns and settles batched completions on disposal rather than
dropping them.

Benchmarks against `dart:io`, `package:http`, `dio` and `rhttp`, measured in
release builds on real hardware, are in the README.

### Known gaps

* **No web or WASM support.** The engine is native code; this is a permanent
  non-goal. Use `package:http`'s `BrowserClient` behind `kIsWeb`.
* **HTTP/3 is not guaranteed.** It needs a libcurl with a QUIC backend, which a
  system libcurl usually lacks. Without one, `HttpVersionPref.http3` quietly
  negotiates HTTP/2 and `http3Only` fails the request.
* **WebSockets are HTTP/1.1 Upgrade only.** RFC 8441 is not implemented, so a
  socket cannot share an HTTP/2 connection.
* **No public-suffix validation for cookies.** libpsl is not vendored yet, so
  the jar cannot reject a `Domain` naming a public suffix — do not treat it as a
  security boundary against a hostile server.
* **`TlsSettings.sniHostname` is accepted but not applied.** It round-trips
  through the configuration; the engine does not yet override SNI from it.
* **Binary size** is 3.0–4.8 MB per ABI with the vendored stack (release APK:
  2.96 MB armeabi-v7a, 4.53 MB arm64-v8a, 4.76 MB x86_64). Building the
  dependencies with `--no-http3` saves about 0.4 MB, not the 40 % this entry
  claimed at 0.0.1 — see 0.0.4.
* **Prebuilt binaries cover x64 and arm64 only.** Windows arm64 has no slice and
  needs a system libcurl, or one built locally with `tool/deps/build.ps1`.
