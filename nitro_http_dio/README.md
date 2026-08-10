# nitro_http_dio

A [`dio`](https://pub.dev/packages/dio) `HttpClientAdapter` backed by
[`nitro_http`](https://pub.dev/packages/nitro_http)'s native libcurl engine.

Keep dio's API — its interceptors, transformers, `FormData`, `CancelToken` and
`Response<T>` — and swap the transport underneath for one C++ engine that
behaves identically on Android, iOS, macOS, Windows and Linux, with HTTP/2 and
HTTP/3, real streaming backpressure and TLS pinning.

This is a separate package because `dio` is a heavy dependency many `nitro_http`
users do not want in their graph. The `package:http` adapter, whose dependency
is tiny and pure Dart, ships inside `nitro_http` itself.

## Install

```yaml
dependencies:
  dio: ^5.7.0
  nitro_http: ^0.0.1
  nitro_http_dio: ^0.0.1
```

## Usage

```dart
import 'package:dio/dio.dart';
import 'package:nitro_http_dio/nitro_http_dio.dart';

final dio = Dio()..useNitroHttp();
```

With engine settings, or sharing one client across several `Dio` instances:

```dart
import 'package:nitro_http/nitro_http.dart';

final client = NitroHttpClient(
  settings: const ClientSettings(
    timeout: Duration(seconds: 30),
    // Required for a shared client: dio's `validateStatus` decides what counts
    // as a failure, so the engine must not throw on a 4xx as well.
    throwOnStatusCode: false,
    tlsSettings: TlsSettings(pinnedSpkiSha256: ['sha256/AAAA…']),
  ),
);

final api = Dio()..httpClientAdapter = NitroHttpDioAdapter(client: client);
final cdn = Dio()..httpClientAdapter = NitroHttpDioAdapter(client: client);
```

An adapter given a `client` **borrows** it: `close()` leaves it running and the
caller disposes it. An adapter that built its own client owns it and disposes it
on `close()`.

Select a cache mode for one request:

```dart
await dio.get<String>(
  '/feed',
  options: Options(extra: {nitroHttpCacheModeKey: CacheMode.onlyIfCached}),
);
```

The value may be a `CacheMode` or its `name` as a `String` (`'normal'`,
`'noStore'`, `'bypass'`, `'onlyIfCached'`, `'refresh'`), so code that does not
import `nitro_http` can still reach the cache. An unrecognised value throws
`ArgumentError` rather than being silently ignored.

## Mapping

| dio | engine | notes |
| --- | --- | --- |
| `RequestOptions.method` | `HttpMethod` | Unknown verbs become `HttpMethod.custom` carrying the token verbatim, so `PROPFIND` reaches the wire unchanged. |
| `RequestOptions.uri` | `HttpRequest.url` | dio has already applied its own `baseUrl` and query, so the absolute URI is passed straight through. `ClientSettings.baseUrl` never re-resolves it. |
| `RequestOptions.headers` | `HttpHeaders` | `null` drops the field, an `Iterable` becomes one field per element, a `DateTime` becomes an HTTP-date, anything else gets `toString()` — the same rules `dart:io` applies for dio's default adapter. |
| `requestStream` | `HttpBody.stream` | Length taken from the `content-length` header dio set; without one the upload is chunked. |
| `RequestOptions.connectTimeout` | `RequestOptions.connectTimeout` | `null` and `Duration.zero` both mean "inherit from the client". |
| `RequestOptions.receiveTimeout` | `RequestOptions.timeout` | The engine's deadline covers the whole transfer. |
| `RequestOptions.sendTimeout` | — | No separate engine deadline; see the gaps below. |
| `RequestOptions.followRedirects` / `maxRedirects` | `RequestOptions.followRedirects` / `maxRedirects` | |
| `RequestOptions.extra['nitroHttp.cacheMode']` | `RequestOptions.cacheMode` | `CacheMode` or its name. |
| `cancelFuture` | `CancelToken` | The engine takes a token rather than a bare `Future` precisely so a transfer already on the wire can be aborted. |
| `RequestOptions.onSendProgress` / `onReceiveProgress` | — | dio drives both itself, above the adapter. Nothing is lost, and because the adapter asks for no engine progress events the native transfer skips `XFERINFO` emission entirely — one less callback per socket write. |
| `RequestOptions.responseType` | — | The adapter always takes the engine's streamed path; dio collects that stream into bytes, a `String` or JSON above it, so `ResponseType.stream` works unchanged. |
| `ResponseBody.headers` | `HttpHeaders` | Built with `getAll`, never `toMap()`: folding repeated fields with `', '` would corrupt `Set-Cookie`, whose `Expires` attribute contains a comma. |
| `ResponseBody.isRedirect` | `redirectCount` | True when a hop was followed, and also for an unfollowed 3xx carrying a `Location`. |
| `ResponseBody.statusMessage` | `reasonPhrase` | Forwarded verbatim. HTTP/2 and HTTP/3 removed the reason phrase from the protocol, so it arrives empty there and is passed as `null` for dio to derive one from the status code. |
| `content-encoding` / `content-length` on a decoded response | — | The engine, not libcurl, does the inflating, and it removes both headers from a body it decoded: they describe the encoded bytes nothing above the engine ever sees. A coding the engine cannot decode is passed through untouched, with both headers intact. |

### Errors

`NitroHttpException` becomes a `DioException` with the original kept as
`DioException.error`.

| `nitro_http` | `DioExceptionType` |
| --- | --- |
| `NitroHttpTimeoutException(TimeoutStage.connect)` | `connectionTimeout` |
| `NitroHttpTimeoutException(TimeoutStage.request \| idle)` | `receiveTimeout` |
| `NitroHttpCancelException` | `cancel` |
| `NitroHttpCertificateException` | `badCertificate` |
| `NitroHttpConnectionException` | `connectionError` |
| `NitroHttpStatusCodeException` | `badResponse` |
| everything else | `unknown` |

A non-2xx status is **not** an error at the wire layer: the adapter forces
`throwOnStatusCode: false` on any client it creates, so a 500 arrives as an
ordinary `ResponseBody` and dio's `validateStatus` decides. A *borrowed* client
is never mutated, so one left on `throwOnStatusCode: true` degrades to a
`badResponse` `DioException` without an attached `Response` — configure shared
clients with the flag off.

Failures that happen mid-body are mapped too: the returned stream errors with a
`DioException`, not a raw `NitroHttpException`.

## Gaps

* **`sendTimeout` is not enforced separately.** libcurl times the whole
  transfer, so an upload that stalls is caught by `receiveTimeout` (mapped to
  the engine's total deadline) rather than by `sendTimeout`. The adapter never
  produces `DioExceptionType.sendTimeout`.
* **Two interceptor layers.** dio's interceptors run *above* this adapter and
  `nitro_http`'s run *below* it. Neither sees the other's rewrites, and a
  `nitro_http` `RetryInterceptor` retries inside a single dio call. Pick one
  layer per concern; mixing a retry policy on both means multiplied attempts.
* **No web support.** The engine is native code. Behind `kIsWeb`, keep dio's
  default browser adapter.

## Tests

The unit suite runs the adapter against `nitro_http`'s `RequestExecutor` and
`StreamDemux` seams, so it needs no native library. The end-to-end test against
a local `shelf` server skips itself, with a reason, when the engine is not
loadable.

```sh
flutter test
```

`flutter test` rather than `dart test`: `nitro_http` is an FFI plugin, and its
package graph reaches the Flutter SDK.
