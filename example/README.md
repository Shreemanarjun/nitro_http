# nitro_http_example

The demo app for [`nitro_http`](https://pub.dev/packages/nitro_http). It runs an
in-process [`shelf`](https://pub.dev/packages/shelf) server so every tab works
offline, with no external endpoint to configure.

Six tabs, one per capability:

| Tab | What it exercises |
|---|---|
| **Console** | Request playground — every verb, headers, typed bodies, live response inspector |
| **Streaming** | Chunked download and streamed upload with progress and cancellation |
| **WebSocket** | Echo console over the native `WsSession` |
| **Cache** | Disk-cache hit / revalidate / prefetch, with live stats |
| **Cookies** | Jar round-trip and persistence |
| **Benchmark** | `nitro_http` vs `dart:io`, `package:http`, `dio` and `rhttp` |

The header shows what the linked engine actually supports — HTTP/3, WebSockets,
brotli, zstd — read from the binary rather than assumed, which is the quickest
way to tell whether a build picked up the vendored `NitroCurl` slice.

```sh
flutter run                     # any platform
```

## Benchmarks

The Benchmark tab is interactive and fine for a quick look, but a **single run
resolves nothing** — one run of this suite has flipped the fastest client in
four of five scenarios. For numbers worth quoting, use the harnesses, which
build a release binary, run it ten times, discard the first as warm-up, and
refuse to start on a busy machine or a hot phone:

```sh
tool/bench-macos.sh 10
tool/bench-android.sh 10
tool/bench-ios.sh 10            # physical device only
```

Details and the checks they apply: [doc/ADVANCED.md](../doc/ADVANCED.md#benchmarks).
