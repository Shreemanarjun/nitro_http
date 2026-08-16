// swift-tools-version: 5.9
import Foundation
import PackageDescription

// nitro_http has no Swift code any more — the Nitro spec declares
// `AppleNativeImpl.cpp`, so the entire implementation is the C++ engine.
// The former `nitro_http` Swift target (Sources/NitroHttp) is gone, and with it
// the only reason this package depended on FlutterFramework: nothing in
// NitroHttpCpp includes a Flutter header.
//
// TWO WAYS TO GET libcurl, decided here rather than at build time, because a
// SwiftPM manifest is Swift evaluated during resolution.
//
//   1. A vendored NitroCurl.xcframework sitting in `<platform>/Frameworks/`
//      (put there by the podspec's fetch script, by `tool/deps/build.sh` plus
//      `merge_apple.sh`, or by hand for an air-gapped build). That slice carries
//      HTTP/3, brotli and zstd.
//
//   2. Otherwise the platform libcurl the Apple SDK ships. HTTP/1.1 and HTTP/2
//      only, and no brotli or zstd — which the engine reports honestly at
//      runtime through `NitroHttp.supportsHttp3` / `supportsBrotli` /
//      `supportsZstd`, so nothing lies to the caller.
//
// A `.binaryTarget(url:checksum:)` is deliberately NOT used. Pointing one at a
// release that does not exist yet makes `xcodebuild -resolvePackageDependencies`
// hang trying to fetch it, which blocks anyone who only wants the Dart layer.
// Resolution must never depend on the network.
// `resolvingSymlinksInPath` is load-bearing, not defensive. Flutter does not
// hand SwiftPM this directory: it symlinks the package into
// `<app>/macos/Flutter/ephemeral/Packages/.packages/nitro_http` and points the
// generated manifest at that. `#filePath` is then the symlinked path, so walking
// up two levels lands in `.packages/`, which has no `Frameworks/` sibling —
// `hasVendoredCurl` came back false with the xcframework sitting right there,
// and the build silently fell back to the SDK's libcurl (no HTTP/3, no brotli,
// no zstd). Resolving first puts us in the real `<platform>/` directory.
let packageDirectory = URL(fileURLWithPath: #filePath)
    .resolvingSymlinksInPath()     // through Flutter's .packages symlink
    .deletingLastPathComponent()   // <platform>/nitro_http — the package root

// INSIDE the package, not a sibling of it. A binary target's `path:` is a
// literal string SwiftPM resolves against the package root AS IT SEES IT, which
// is Flutter's symlink `…/Packages/.packages/nitro_http`. A `../Frameworks/…`
// path therefore resolved to `.packages/Frameworks/…`, which does not exist:
//
//   xcodebuild: error: Could not resolve package dependencies:
//     local binary target 'NitroCurl' at '…/.packages/Frameworks/NitroCurl.xcframework'
//     does not contain a binary artifact.
//
// Every freshly created Flutter app hit that; only projects whose Xcode
// scaffolding predates it escaped, which is why the example app never showed
// it. `resolvingSymlinksInPath()` fixes the DETECTION below, but cannot fix a
// path string SwiftPM resolves itself — so the framework lives inside the
// package and the path never leaves it.
let vendoredCurl = packageDirectory
    .appendingPathComponent("Frameworks")
    .appendingPathComponent("NitroCurl.xcframework")

let hasVendoredCurl = FileManager.default.fileExists(atPath: vendoredCurl.path)

// ── The published-consumer path ──────────────────────────────────────────────
// A pub.dev consumer has no vendored framework: `<platform>/*/Frameworks/` is
// gitignored, so it is not in the package archive. CocoaPods used to cover that
// by downloading it in `prepare_command`, but SwiftPM never runs a podspec —
// and `nitro` is SPM-only, so CocoaPods is not even available as a fallback.
// Such a consumer got the SDK's libcurl on macOS (no HTTP/3, brotli or zstd)
// and, on iOS, undefined `curl_*` symbols.
//
// A checksum-pinned `.binaryTarget(url:checksum:)` closes that: SwiftPM
// downloads and verifies the archive itself. The manifest previously refused
// URL targets because pointing one at a release that did not exist yet hung
// `xcodebuild -resolvePackageDependencies` — that reasoning held while no deps
// release existed. One does now, and the pin below is only ever read from
// deps/versions.cmake, so a URL is never fabricated for a missing release.
func nitroHttpPin(_ key: String) -> String? {
    let versions = packageDirectory
        .deletingLastPathComponent()   // <platform>
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("deps")
        .appendingPathComponent("versions.cmake")
    guard let text = try? String(contentsOf: versions, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.contains(key) {
        guard let open = line.firstIndex(of: "\"") else { continue }
        let rest = line[line.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { continue }
        let value = String(rest[..<close])
        if !value.isEmpty { return value }
    }
    return nil
}

let curlRelease = nitroHttpPin("NITRO_HTTP_DEPS_RELEASE")
let curlChecksum = nitroHttpPin("NH_APPLE_XCFRAMEWORK_ZIP_SHA256")

// Three states, decided once: a local slice, a pinned download, or the SDK.
enum NitroCurlSource { case vendored, remote, sdk }
let curlSource: NitroCurlSource = {
    if hasVendoredCurl { return .vendored }
    if curlRelease != nil && curlChecksum != nil { return .remote }
    return .sdk   // no pin recorded yet — resolution must still succeed offline
}()
let usesNitroCurl = curlSource != .sdk

// curl headers come from the xcframework when it is present: SwiftPM adds a
// binary target's HeadersPath to its dependents' include path, so
// `#include <curl/curl.h>` resolves with no extra configuration. Without it the
// SDK's own `usr/include/curl` is already on the default search path.
var cxxSettings: [CXXSetting] = [
    .headerSearchPath("include"),
    .unsafeFlags(["-std=c++17"]),
    // -O3 for anything that is not a debug build. Xcode's default here was `-Os`
    // — optimise for SIZE — because neither this manifest nor the podspec set a
    // level, and that is what Release inherits. Confirmed by reading the actual
    // clang invocation, not assumed.
    //
    // Measured honestly, it changes nothing on an M1: on a quiet host, three
    // alternating release runs each way put every scenario between -2.2 % and
    // +3.9 %, while `dart:io` — which these flags cannot touch — moved -1.9 % to
    // +16.7 % across the same rows. The control's spread is wider than our
    // deltas, so this benchmark cannot resolve the change. That is a statement
    // about the benchmark, not the flag: a loopback transfer is bound by syscalls,
    // the server and memcpy, leaving the optimiser little to win.
    //
    // Kept anyway, for reasons that do not depend on that measurement: the engine
    // is one translation unit (EngineUnity.cpp) so the optimiser sees all of it at
    // once; -Os is the wrong default for a transport hot path; and the platforms
    // where per-chunk CPU cost actually dominates are the slow-core ones we cannot
    // A/B as cleanly — an arm64 Android emulator lost a 32 MiB download by 1.75x
    // to exactly that cost. Revisit if a size budget ever makes -Os worth it.
    //
    // Debug is deliberately left alone: -O3 there would make the engine
    // unsteppable for anyone debugging it, and nobody quotes debug timings.
    .unsafeFlags(["-O3"], .when(configuration: .release)),
]

var linkerSettings: [LinkerSetting] = [
    // libcurl's zlib transfer decoding and its threaded resolver.
    .linkedLibrary("z"),
    .linkedLibrary("resolv"),
    // SecTrust chain evaluation in src/engine/CertStore.cpp.
    .linkedFramework("Security"),
    .linkedFramework("CoreFoundation"),
    // SCDynamicStoreCopyProxies, called by curl's lib/macos.c for system-proxy
    // discovery. Not optional: ProxySettings.system() is a supported feature, so
    // a static libcurl fails to link without it.
    .linkedFramework("SystemConfiguration"),
]

if usesNitroCurl {
    // src/engine/ContentDecoder does the inflating itself — libcurl's own
    // content decoding is switched off — so these macros track what is LINKED,
    // not what curl advertises. The vendored slice always ships libbrotlidec and
    // libzstd; zlib needs no macro.
    cxxSettings.append(.define("NITRO_HTTP_HAS_BROTLI", to: "1"))
    cxxSettings.append(.define("NITRO_HTTP_HAS_ZSTD", to: "1"))
} else {
    linkerSettings.append(.linkedLibrary("curl"))
}

let package = Package(
    name: "nitro_http",
    platforms: [.macOS(.v10_15)],
    products: [
        // NitroCurl is listed in the PRODUCT, not left to be reached through
        // NitroHttpCpp's `dependencies`. Xcode does not add a statically linked
        // binary target to the app's link line when it is reached transitively —
        // Runner -> FlutterGeneratedPluginSwiftPackage -> nitro_http -> NitroCurl
        // — so the headers resolved, every engine translation unit compiled, the
        // slice was even copied into the build directory, and then the app failed
        // to link with ~40 undefined `_curl_*` symbols. Naming the binary target
        // in the product the app actually links is what puts it on the link line.
        //
        // This only ever bit the vendored path, which is why it survived so long:
        // macOS silently falls back to the SDK's libcurl via
        // `.linkedLibrary("curl")`, so the branch below is dead there unless a
        // slice is staged. iOS has no system libcurl and cannot fall back, so it
        // fails outright.
        .library(
            name: "nitro-http",
            targets: usesNitroCurl
                ? ["NitroHttpCpp", "NitroCurl"]
                : ["NitroHttpCpp"]
        ),
    ],
    targets: [
        // Sources/NitroHttpCpp holds only forwarders: each `#include`s a file
        // under ../../../../src, and src/HybridNitroHttp.cpp in turn includes
        // src/engine/EngineUnity.cpp — the whole engine as one translation unit.
        // Every include is relative to the including file, so no header search
        // path may escape the package root (SwiftPM forbids that).
        .target(
            name: "NitroHttpCpp",
            dependencies: usesNitroCurl ? ["NitroCurl"] : [],
            path: "Sources/NitroHttpCpp",
            publicHeadersPath: "include",
            cxxSettings: cxxSettings,
            linkerSettings: linkerSettings
        ),
        // libcurl + nghttp2 + ngtcp2/nghttp3 + BoringSSL + brotli + zstd, merged
        // into one xcframework by .github/workflows/build-deps.yml.
        //
        // A local slice wins when present, so an air-gapped or repo build never
        // touches the network. Otherwise SwiftPM fetches the pinned release and
        // verifies the checksum itself. The target is dropped entirely when
        // neither is available, leaving the SDK's libcurl (macOS) — resolution
        // still succeeds so a Dart-only consumer is never blocked.
        curlSource == .vendored
            ? .binaryTarget(
                name: "NitroCurl",
                path: "Frameworks/NitroCurl.xcframework"
              )
            : .binaryTarget(
                name: "NitroCurl",
                url: "https://github.com/Shreemanarjun/nitro_http/releases/download/"
                   + "\(curlRelease ?? "")/NitroCurl.xcframework.zip",
                checksum: curlChecksum ?? ""
              ),
    ].filter { target in
        usesNitroCurl || target.name != "NitroCurl"
    },
    cxxLanguageStandard: .cxx17
)
