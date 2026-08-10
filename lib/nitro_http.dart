/// A high-performance, type-safe HTTP client for Flutter.
///
/// The entire transport lives in C++ behind [Nitro](https://nitro.shreeman.dev)'s
/// FFI bridge: Dart never touches a socket. One libcurl engine serves iOS,
/// Android, macOS, Windows and Linux, so there is no "works differently on
/// Android" caveat for proxies, TLS pinning, redirects or timeouts.
///
/// ```dart
/// final client = NitroHttpClient(
///   settings: ClientSettings(
///     baseUrl: 'https://api.example.com',
///     timeout: Duration(seconds: 30),
///   ),
///   interceptors: [RetryInterceptor(maxRetries: 3)],
/// );
///
/// final res = await client.get('/users', query: {'page': '2'});
/// print(res.bodyToJson());
/// ```
///
/// Or without ceremony:
///
/// ```dart
/// final res = await fetch('https://api.example.com/users');
/// ```
///
/// ## Not supported
///
/// * **Web / WASM.** `dart:ffi` and `Dart_PostCObject_DL` do not exist there.
///   Import `package:http`'s browser client behind `kIsWeb`.
/// * **WebSockets over HTTP/2** (RFC 8441). The transport is an HTTP/1.1
///   Upgrade, the same limitation reqwest has.
library;

export 'src/api/body.dart';
export 'src/api/cache.dart';
export 'src/api/cancel_token.dart';
export 'src/api/client.dart';
export 'src/api/cookies.dart';
export 'src/api/exceptions.dart';
export 'src/api/fetch.dart';
export 'src/api/headers.dart';
export 'src/api/interceptor.dart';
export 'src/api/progress.dart';
export 'src/api/request.dart';
export 'src/api/response.dart';
export 'src/api/retry_interceptor.dart';
export 'src/api/settings.dart';
export 'src/api/websocket.dart';
export 'src/compat/http_compat.dart';
