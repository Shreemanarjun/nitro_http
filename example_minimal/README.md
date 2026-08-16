# nitro_http_minimal

A clean-room app for checking that **nitro_http itself** works on a platform.

It depends on `nitro_http` and nothing else. That is the whole point: the main
[`example/`](../example) also depends on `dio`, `rhttp` and `package:http` so it
can benchmark them against each other, which makes it a bad instrument for
"does this platform work?" — a red build there might belong to any of the four.
`rhttp` needs a Rust toolchain and has broken that app's build more than once
for reasons that had nothing to do with this package.

Reach for this app when checking:

* a fresh platform setup, or a machine that has never built the plugin
* a new Flutter or Dart SDK
* a change to the native build — the podspecs, `Package.swift`, `deps.cmake`,
  the Gradle wiring
* whether a build actually linked the vendored engine, rather than silently
  falling back to a system libcurl

```sh
cd example_minimal
flutter run           # any platform
```

## What the buttons do

| Button | Checks |
|---|---|
| **Capabilities** | `engineVersion` and the `supportsHttp3` / `supportsWebSockets` / `supportsBrotli` / `supportsZstd` flags, read from the linked binary at runtime |
| **GET json** | a real request, JSON decode, negotiated protocol, and per-phase timings |
| **Stream 1 MiB** | streamed download with backpressure — nothing buffers the whole body |
| **Cancel** | `CancelToken` against a slow endpoint; cancellation is enforced in the engine, not by dropping a Dart future |

**Capabilities is the one that matters most.** `http3 false` on a platform that
should have it means the build fell back to the SDK's libcurl instead of the
vendored slice — a failure that otherwise stays invisible until someone wonders
why HTTP/3 never negotiates.

The requests go to `httpbin.org`, so this app needs a network. That is
deliberate: it exercises real DNS, TLS and redirects, which an in-process
loopback server cannot.

## macOS

`macos/Runner/*.entitlements` here already carry:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

A sandboxed macOS app without it fails every request with "connection refused".
`flutter create` does not add it, so your own app will need the same line — see
the [Setup section](../README.md#setup) of the main README.
