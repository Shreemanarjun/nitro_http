// swift-tools-version:5.9
//
// Raw native URLSession benchmark, the Apple-platform baseline for the
// nitro_http comparison. Built release (`swift run -c release`) and pointed at
// the same shelf test server the Flutter harness uses (tool/bench_serve.dart),
// so the only difference from nitro_http's numbers is the stack under test:
// URLSession here vs libcurl-over-Nitro-FFI there.
import PackageDescription

let package = Package(
    name: "nativebench",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "nativebench", path: "Sources/nativebench")
    ]
)
