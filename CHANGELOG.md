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
* **WebSockets** on the same engine, inheriting its TLS, proxy and DNS
  behaviour. Implements `package:web_socket`'s `WebSocket` interface.
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
* **Binary size** is roughly 1.5–3 MB per ABI with the vendored stack. Building
  the dependencies with `--no-http3` removes about 40 % of that.
* **Prebuilt binaries cover x64 and arm64 only.** Windows arm64 has no slice and
  needs a system libcurl, or one built locally with `tool/deps/build.ps1`.
