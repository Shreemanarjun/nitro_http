## Unreleased

### Fixed

* **Disposing a client no longer strands its in-flight requests.** With
  completion batching on — the default — a request still running when
  `dispose()` was called never completed at all: not with an error, not at
  ever. The engine posts its shutdown completions correctly, but `dispose()` is
  synchronous, so the isolate has had no turn to deliver those messages by the
  time `NitroCoalescer.dispose()` closes the port and drops the completers it is
  holding. Disposal now lets the queued completions land first, and reports a
  definite failure for anything that still has not arrived, so every request
  ends exactly once. This affected any client disposed mid-request — closing a
  screen with a request outstanding is the ordinary case.

* **Cancelling a token after its client was disposed threw.** The token
  listener deliberately outlives any one request, so tripping a token on the way
  out of a disposed screen called into a disposed native instance and threw from
  inside a listener — surfacing as an uncaught error rather than doing nothing.
  Token operations and record release now go through the engine role, a process
  singleton no client owns; both are process-wide operations that never belonged
  on a per-client instance. That also fixes a quieter bug: two clients sharing a
  token would lose cancellation entirely once the first was disposed.

* **A hot restart no longer needs anything from you, and no longer breaks
  cancellation.** A hot restart replaces the Dart isolate while the plugin's
  native side keeps running, and Flutter tells a plugin nothing. That used to be
  the app's problem: the docs asked every `main()` to call `NitroHttp.reset()`,
  and a missed call left ghost sockets behind.

  Moving cancellation into the engine turned that from untidy into wrong. Token
  ids came from a plain per-isolate counter, while the registry holding their
  state is process-global and survives a restart — so the first token after a
  reload reused id 1 and inherited whatever id 1 had been left in. If that was a
  cancelled token, every request bound to it failed instantly with a
  cancellation nobody asked for, and nothing about the symptom pointed at the
  cause.

  Both halves are fixed. Token ids now carry 30 bits of per-incarnation epoch, so
  a collision across a restart is impossible rather than certain; and the
  library reconciles native state itself the first time an incarnation touches
  the engine — aborting stragglers, joining the engine threads, flushing the
  cookie jars and clearing cancellation state. `NitroHttp.reset()` remains for
  the explicit case (a test wanting a clean engine) but is no longer something
  to remember. A background isolate is deliberately skipped: its statics are
  fresh too, so it cannot tell a restart from being new, and reconciling there
  would abort the root isolate's transfers.

### Changed

* **`CancelToken` is now a native object.** The public API is unchanged —
  construct one, pass it to requests, call `cancel()` — but the token is no
  longer a Dart-side list of per-request listeners. It carries an id the engine
  resolves to shared, atomically-read state, which buys two things the old
  fan-out could not:

  * **A request bound to an already-cancelled token never opens a socket.** The
    engine reads the flag in `startTask`, before `curl_multi_add_handle`, so the
    request never reaches the server, never takes a pool slot and never leaves
    the process. Previously the submit was already in flight by the time a Dart
    listener could run, so it was cancelled *after* the wire saw it. The bounded
    1024-entry "cancelled before I saw the submit" list this used to need is
    gone with it — the token carries its own state, so how far apart the cancel
    and the submit are no longer matters.

  * **Cancelling N bound requests is one call, not N.** Every bound transfer
    shares one flag, so a token held by 100 in-flight requests is cancelled by a
    single store, visible on every client at once.

  Cancellation is also observed sooner: the flag is raised on the calling thread
  before any engine is notified, and the download write callback now checks it,
  so a cancelled large download stops at the next 16 KiB block rather than at the
  next throttled progress tick.

* **The cancellation reason reaches the error.** `CancelToken.cancel('why')` used
  to be Dart-only; the engine now records it and `NitroHttpCancelException`
  reports it.

### Fixed

* `deps/versions.cmake` pins were regenerated. The `deps-v1` tag was force-moved
  during a repository history rewrite, which re-ran the dependency build and
  replaced every published asset — and these builds are not byte-reproducible, so
  the committed checksums no longer described the files being downloaded and
  every consumer build failed with a HASH mismatch. `build-deps` now refuses to
  publish over an existing release rather than invalidating pins silently.

## 0.0.1

First release.

### Added

* **One native engine, five platforms.** A C++ HTTP engine built on libcurl
  drives Android, iOS, macOS, Windows and Linux. It is reached over Nitro for
  Flutter's zero-overhead FFI bridge — no method channels, no per-platform
  implementation to keep in sync.
* **HTTP/1.1, HTTP/2 and HTTP/3.** Negotiated automatically, or forced per
  client via `HttpVersionPref`. Which of the three are actually available
  depends on the libcurl the plugin was linked against, so the engine queries
  `curl_version_info()` at runtime and reports through `NitroHttp.supportsHttp3`.
  One binary therefore behaves correctly against any libcurl build instead of
  failing at the first request.
* **Content decoding belongs to the engine, not to libcurl.** `gzip` and
  `deflate` always, `br` and `zstd` when those libraries are linked, chained
  right-to-left and bounded by an output ceiling so a compression bomb cannot
  exhaust memory. `Accept-Encoding` advertises exactly the set the engine can
  decode, and an unrecognised `Content-Encoding` passes through byte-for-byte
  with its headers intact. curl's own decoder aborts such a response with
  `CURLE_BAD_CONTENT_ENCODING`, and — more importantly — which codings worked
  would otherwise depend on how the local libcurl happened to be built, which
  is exactly the per-platform divergence this package exists to remove.
  `NitroHttp.supportsBrotli` and `supportsZstd` report what the engine can
  decode.
* **A sealed-class Dart API.** `HttpBody`, `HttpResponse`,
  `NitroHttpException` and friends are sealed, so `switch` over them is
  exhaustive and the compiler catches an unhandled case.
* **Streaming in both directions**, with credit-based backpressure: the engine
  pauses the transfer when Dart falls behind and resumes when it catches up.
  Response chunks are handed to Dart zero-copy; the native buffer is released
  only once Dart acknowledges the copy.
* **Cancellation** via `CancelToken`, upload/download **progress** callbacks,
  and per-phase **timings** (DNS, connect, TLS, time-to-first-byte), collected
  by default and disabled per request with `RequestOptions(wantTimings: false)`.
* **A real idle deadline.** `ClientSettings.idleTimeout` aborts a transfer that
  goes quiet for that long, enforced by the engine's own event loop rather than
  curl's `CURLOPT_LOW_SPEED_LIMIT`. A rate floor averages over a rolling window,
  so a body that delivers a large chunk and then stalls indefinitely keeps a
  healthy average and is never aborted; its resolution is also whole seconds.
  The clock is armed by the first response header, so a slow connect stays
  charged to the connect budget, and it pauses while either direction is paused
  for flow control — a consumer that stopped granting credit is not a peer that
  went quiet. `TimeoutStage` therefore distinguishes `connect`, `request` and
  `idle` for real.
* **`HttpResponse.reasonPhrase`**, carried on the wire from the status line
  rather than derived from the status code, because a server may send a custom
  one. Empty over HTTP/2 and HTTP/3, which removed it from the protocol.
* **TLS**: minimum/maximum version, custom or bundled root CAs, mutual TLS
  with a client certificate, and SPKI SHA-256 certificate pinning per client
  or per request.
* **Proxies**: system, explicit HTTP, SOCKS5 and SOCKS5-with-remote-DNS.
* **DNS**: static host overrides and DNS-over-HTTPS.
* **Cookies** with an in-memory or file-backed persistent jar, shared across
  every transfer on a client through `curl_share`.
* **Interceptors** — `beforeRequest` / `afterResponse` / `onError`, `async`
  throughout so a token refresh is a normal `await` — plus a retry
  interceptor with configurable backoff.
* **An HTTP cache** on disk implementing a subset of RFC 9111: `Cache-Control`
  freshness, revalidation with `ETag` / `Last-Modified`, LRU eviction against a
  byte budget, `CacheMode` overrides per request, and an explicit prefetch API.
* **WebSockets** over the same engine. libcurl establishes the connection —
  including TLS, so a socket inherits the client's trust configuration, proxy
  and DNS behaviour — and RFC 6455 framing, masking, reassembly, ping/pong and
  the close handshake are implemented in C++ on top of it. The socket takes its
  connection out of curl, so it does not share the HTTP connection pool.
  `NitroWebSocket` implements `package:web_socket`'s `WebSocket` interface.
* **A `package:http` adapter**, so an existing `Client`-based codebase can
  move over without touching its call sites. Checked against
  `package:http_client_conformance_tests`.
* `HttpBody.file` uploads straight from a path: curl reads the file natively
  and a 500 MB upload never allocates a Dart buffer.
* **Benchmarked in release on three real machines** — an M1 Pro Mac, a physical
  iPhone 12 and a physical Android 16 phone — against `dart:io`, `package:http`,
  `dio` and `rhttp`. Upload is at parity or better everywhere (fastest of the five
  on Android), the mixed workload is a dead heat, download is 1.07x/1.08x/1.34x,
  and concurrency is the best row on Apple and the worst on Android. Numbers and
  the full method are in the README.
* The benchmark can now run in a **release** build, which is the only build worth
  quoting: `flutter drive` refuses release mode outright, so the suite is compiled
  into the example app behind `--dart-define=NITRO_HTTP_BENCHMARK=1`. It writes its
  report to the app's documents directory as well as the platform log, because an
  iOS release build emits no `print` output at all — neither `devicectl
  --console` nor `idevicesyslog` captures a line of it.
* **A benchmark suite** comparing this client against `dart:io`, `package:http`,
  `dio` and `rhttp` over one in-process loopback server:
  `example/integration_test/benchmark_test.dart`, run with `flutter drive
  --profile`. On an Apple M1 Pro it leads every other client on concurrency
  (64 requests in flight, p50 4.79 ms versus 7.43 ms for the next-fastest Dart
  client), and is at parity on large single transfers — 8 MiB upload 110 ms
  against 108 ms for the best, 32 MiB download 147 ms against 144 ms for
  `dart:io`, with `dio` and rhttp 7–11 % ahead on that one row. See "Measured
  performance" in the README.
* The credit window for streamed downloads is 64 chunks topped up every 16,
  rather than 16 topped up every 8. The old window ran out constantly, and each
  restart cost a cross-thread wake plus a curl socket re-arm: 32 MiB took 162 ms
  before and 147 ms after, for the same ~1 MiB of native memory in flight.
* `unpauseTransfer` no longer calls `curl_easy_pause` when nothing is actually
  paused. Every upload feed and every credit grant asked for an unpause, and the
  call is not free even when it changes nothing — it re-arms the socket and drives
  a round of transfer processing.
* **The engine is compiled `-O3` on Apple platforms.** It was `-Os` — optimise
  for size — because neither `Package.swift` nor the podspecs set an optimisation
  level and that is Xcode's default for Release. Verified from the compiler
  invocation rather than assumed. The whole engine is one translation unit
  (`EngineUnity.cpp`), so the optimiser sees all of it at once. Debug is left at
  `-O0` deliberately. The CMake path (Android, Linux, Windows) also moves its
  non-standard-config fallback from `-O2` to `-O3`, so a Flutter profile build is
  no longer a notch slower than release on identical source.
* **Fixed: the vendored libcurl xcframework never linked under Swift Package
  Manager.** `NitroCurl` was reached transitively — Runner ->
  FlutterGeneratedPluginSwiftPackage -> nitro_http -> NitroCurl — and Xcode does
  not add a statically linked binary target to the app's link line that way. The
  headers resolved, every engine translation unit compiled, the slice was copied
  into the build directory, and then the app failed to link with ~40 undefined
  `_curl_*` symbols. Naming the binary target in the product the app links fixes
  it. This affected **iOS fatally** (no system libcurl to fall back on) and was
  invisible on macOS, which silently fell back to the SDK's libcurl. Confirmed
  fixed: 97 `_curl_*` symbols now resolve as defined in the app binary and no
  libcurl dylib is referenced.
* **Fixed: `find_library` could never locate a vendored slice on Android.** The
  NDK toolchain sets `CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY`, which re-roots even
  an explicit `PATHS` entry under the NDK sysroot, so every lookup returned
  NOTFOUND on the one platform that has no system libcurl. `src/deps.cmake` now
  passes `NO_CMAKE_FIND_ROOT_PATH`.
* **Fixed: BoringSSL's symbol audit cross-compiled incorrectly on a Mac.**
  `util/audit_symbols.go` derives its object-file format from the host
  `runtime.GOOS`, so building any Android or Linux slice on macOS fed ELF objects
  to a Mach-O reader and died with `invalid magic number`.
  `tool/deps/prefix_symbols.sh` now derives the format from the forwarded
  `CMAKE_SYSTEM_NAME` and accepts an `--obj-format` override. Load-bearing for
  Linux and Windows slices too, not only Android.
* **`WsOpcode` is an enum rather than a set of `static const int`s**, so the
  frame switch is checked for exhaustiveness. As ints the compiler could not tell
  a complete handler from an incomplete one and a new engine-side opcode would
  have fallen through an unnamed `default`; adding one now fails to compile.
  Unrecognised wire values map to an explicit `WsOpcode.unknown`.
* **Strict analyzer modes are on** — `strict-casts`, `strict-inference` and
  `strict-raw-types` — in the package, the example and the dio adapter, with
  inexhaustive switches over sealed types pinned as errors. Five sealed switches
  lost their `default` catch-all (`MultipartItem`, `NitroHttpException` twice,
  `HttpExpectedBody`, and one in the example); the catch-alls that remain are on
  genuinely open domains such as an `int` status code, each with a stated reason.
* Curl's automatic `Expect: 100-continue` is suppressed unless the caller asks
  for it. Servers that ignore the header — including `dart:io`'s own
  `HttpServer`, and therefore `shelf` — made curl wait out its one-second
  continue timeout before sending any body, which cost every large upload a flat
  ~1 s (8 MiB POST: 1134 ms before, 120 ms after).

### Known gaps

* **No web/WASM support.** The engine is native code; there is no browser
  target and there will not be one.
* **WebSockets are HTTP/1.1 Upgrade only.** RFC 8441 (`Extended CONNECT`, i.e.
  WebSockets over an HTTP/2 stream) is not implemented, so a WebSocket
  connection cannot share an h2 connection.
* **No public-suffix validation for cookies.** libpsl is not vendored yet, so
  the cookie jar cannot reject a `Domain` attribute that names a public
  suffix. Do not rely on the jar as a security boundary against a hostile
  server.
* **HTTP/3 is not guaranteed.** It requires a libcurl with a QUIC backend,
  which a system libcurl usually lacks. Check `NitroHttp.supportsHttp3`;
  without it `HttpVersionPref.http3` quietly negotiates HTTP/2 and
  `http3Only` fails the request.
* **`TlsSettings.sniHostname` is accepted but not applied.** The field
  round-trips through the configuration, but the engine does not yet override
  SNI and certificate-hostname matching from it.
* **Binary size** is roughly 1.5–3 MB per ABI with the vendored stack. Building
  the dependencies with `--no-http3` drops ngtcp2 and nghttp3, about 40 % of
  that.
* **The prebuilt slices are x64/arm64 only.** `deps-v1` covers android
  {arm64-v8a, armeabi-v7a, x86_64}, linux {x64, arm64}, windows-x64 and an
  Apple xcframework. Windows arm64 has no slice; that platform needs a system
  libcurl or a slice built locally with `tool/deps/build.ps1`.
