## 0.0.4

### Fixed

* **`RootCaSource.none` did the opposite of what it documents.** It is specified
  as "no trust anchors at all — every chain fails unless a pin matches", but the
  engine implemented it by clearing `CURLOPT_SSL_VERIFYPEER`, so every chain
  *succeeded*: the option that reads as the strictest was silently the least
  safe. Without a pin it is now refused outright, with a message pointing at
  `TlsSettings.insecure()` for callers who really do want no verification.
  With a pin it is unchanged — the documented pin-only mode.

* **HTTPS was completely broken on iOS and macOS.** `CertStore` assumed an
  Apple platform meant a Keychain-integrated TLS backend, which is true of the
  SDK's libcurl but not of the vendored slice — that links BoringSSL, which has
  neither platform trust nor a compiled-in CA bundle, so the engine installed no
  roots and trusted nothing. Every request failed with `CURLcode 60`. The linked
  backend is now detected at runtime and the compiled-in Mozilla bundle is
  installed when it cannot read the Keychain. Android was never affected.

  Note the remaining limit: `RootCaSource.platform` on Apple is served by that
  bundle, so a root a user or MDM profile added to the Keychain is not trusted.
  Use `RootCaSource.custom` with your own PEM if you need one.

* **`wss://` crashed the process against any HTTP/2-capable server.** The
  handshake runs a `CONNECT_ONLY` handle and reads with `curl_easy_recv`, but
  never pinned the HTTP version, so ALPN negotiated h2 and curl routed the read
  through its nghttp2 filter — a segfault in `Curl_multi_connchanged`. A
  WebSocket is an HTTP/1.1 Upgrade, so the handshake now pins HTTP/1.1. Plain
  `ws://` was unaffected because it never negotiates ALPN.

### Added

* **Two new exception types, so TLS failures are distinguishable.**
  `NitroHttpTlsException` covers a handshake that never reached a certificate —
  no shared version or cipher — which previously arrived as
  `NitroHttpCertificateException` and sent readers looking at their trust store
  for a problem that was never there. `NitroHttpConfigurationException` covers
  settings the engine refuses before opening a socket; those used to surface as
  `NitroHttpUnknownException`, which reads like a transient fault and invites a
  retry that can never succeed. Both are permanent failures for
  `RetryInterceptor`.

  The exception family is sealed, so an exhaustive `switch` over
  `NitroHttpException` needs the two new cases added.

* **End-to-end coverage for the settings the engine is supposed to honour.**
  An audit found 30 public settings with configuration tests but no behavioural
  ones — the shape that let `RootCaSource.none`, the Apple trust path and
  `sniHostname` all ship broken. 22 now have end-to-end tests: redirect caps,
  cookie suppression and persistence, the idle deadline, compression
  negotiation, pool limits, SOCKS5 and proxy credentials, upload progress,
  chunk-batching modes, custom verbs, alt-svc recording, DoH, and protocol
  negotiation through h3.

* **`LogInterceptor`, and `ParallelInterceptors` for independent observers.**
  The logger checks its level before formatting anything, takes its duration
  from the engine's own timings rather than a stopwatch, redacts credential
  headers, and never drains a streamed body to log it — which would quietly turn
  a constant-memory download into an unbounded one. `ParallelInterceptors` runs
  a group of observers concurrently for when each awaits I/O; it rejects members
  that try to modify the chain, since their order would otherwise depend on
  completion order.

* **Interceptor hooks no longer allocate to say nothing.** The pass-through
  result and its future are immutable, so they are now shared rather than rebuilt
  per hook per request — worth ~3 µs per interceptor per request, and it applies
  to every interceptor that does not override all three hooks.

* **Resumable downloads and uploads are covered by tests.** `Range` and
  `Content-Range` always passed through, but nothing proved a `206` survived as
  a `206` or that a streamed upload could start mid-file. Both now have
  end-to-end tests, and [ADVANCED.md](doc/ADVANCED.md#resuming-an-interrupted-transfer)
  shows the append-on-206 / restart-on-200 shape that a resumed download needs.

* **WebSockets accept `TlsSettings`.** `RawWsConfig` carried no TLS block, so a
  `wss://` socket could not use custom roots, SPKI pinning, mTLS or a version
  clamp even when the same client applied them to its HTTP requests — the 0.0.1
  note that WebSockets inherit the engine's TLS behaviour was only true of its
  *defaults*. `NitroWebSocket.connect` now takes `tlsSettings`, defaulting to
  the previous behaviour.

* **End-to-end tests for the TLS settings the engine is supposed to honour**,
  against a locally generated CA: custom roots, SPKI pinning (both directions),
  mutual TLS, the version clamp, and `wss://`. Every one of these was previously
  covered only by configuration tests, which is precisely how the two bugs above
  shipped. `TlsSettings.sniHostname` is present as a named skip, because it is
  still accepted-but-ignored.

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
