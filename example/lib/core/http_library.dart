/// The HTTP client implementations this app can drive.
///
/// One enum, used by both the request console and the benchmark, so a library
/// added here shows up in both without a second list to keep in sync.
library;

/// A client implementation the app can send a request through.
enum HttpLibrary {
  /// This package: a libcurl C++ engine over Nitro's FFI bridge.
  nitroHttp('nitro_http', native: true),

  /// `dart:io`'s `HttpClient`, the SDK baseline.
  dartIo('dart:io HttpClient'),

  /// `package:http`'s default client, which wraps `dart:io` on this platform.
  packageHttp('package:http'),

  /// `dio`, on its default `dart:io` adapter.
  dio('dio'),

  /// `rhttp` — Rust `reqwest` reached through `flutter_rust_bridge`.
  rhttp('rhttp', native: true);

  const HttpLibrary(this.label, {this.native = false});

  /// Human-readable name, used in tables and pickers.
  final String label;

  /// Whether this client needs a native library loaded into the process.
  ///
  /// The two native ones cannot run on the headless Dart test host, and they
  /// are the ones that fail first on a machine with no built engine — so the UI
  /// uses this to explain a failure instead of just reporting it.
  final bool native;

  /// A short identifier safe for keys, log lines and file names.
  String get id => name;
}
