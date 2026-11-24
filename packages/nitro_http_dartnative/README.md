# nitro_http_dartnative

[nitro_http](https://pub.dev/packages/nitro_http) for **DartNative** apps: a
fast HTTP client backed by a native libcurl engine over FFI, with HTTP/1.1,
HTTP/2, HTTP/3, streaming, WebSockets, and adapters for `package:http` and `dio`.

This package is a thin wrapper. It re-exports `nitro_http` from pub.dev
unchanged, so the engine, its native code and the full API reference all live
there. It exists so the package can be found and installed from dartpub.dev.

| | |
|---|---|
| Platforms | Android, iOS |
| DartNative | 1.10.0 or newer |
| Version | Always the same as the `nitro_http` it ships (0.0.8 → `nitro_http` 0.0.8) |

## Install

```sh
dn pub add nitro_http_dartnative
```

Then `dn run`. There is no other step: no podspec, no Gradle change, no
registration code. The native engine is fetched as a checksum-pinned prebuilt on
the first build (about 4 MB per Android ABI) and compiled with the app.

Import one library:

```dart
import 'package:nitro_http_dartnative/nitro_http_dartnative.dart';
```

## First request

```dart
final client = NitroHttpClient(
  settings: const ClientSettings(
    baseUrl: 'https://api.example.com',
    userAgent: 'my_app/1.0',
  ),
);

final res = await client.get('/users/42');
print('${res.statusCode} over ${res.version.label}'); // 200 over HTTP/2
print((res.bodyToJson() as Map)['name']);

client.dispose(); // closes pooled connections
```

Keep one client per API and reuse it. The client owns the connection pool, the
cookie jar and the cache, which is what makes the second request fast. In a
widget, create it in `initState` and call `dispose()` in `dispose`.

## Common tasks

**Send JSON**

```dart
final created = await client.post('/users', body: HttpBody.json({'name': 'Ada'}));
```

**Query parameters and headers**

```dart
final res = await client.get(
  '/search',
  query: {'q': 'dart', 'limit': '20'},
  headers: HttpHeaders.fromMap({'Authorization': 'Bearer $token'}),
);
```

**Handle errors.** Every failure throws a subtype of the sealed
`NitroHttpException`, including a 4xx or 5xx response, which throws
`NitroHttpStatusCodeException`:

```dart
try {
  await client.get('/users');
} on NitroHttpStatusCodeException catch (e) {
  print('server said ${e.statusCode}');
} on NitroHttpTimeoutException catch (e) {
  print('timed out at ${e.stage.name}');
} on NitroHttpException catch (e) {
  print('request failed: $e');
}
```

To get 4xx and 5xx responses back instead, set `throwOnStatusCode: false` in
`ClientSettings` and check `res.statusCode`.

**Timeouts**

```dart
const ClientSettings(
  connectTimeout: Duration(seconds: 10), // DNS + TCP + TLS
  timeout: Duration(seconds: 30),        // the whole request
  idleTimeout: Duration(seconds: 90),    // a transfer that goes quiet
);
```

**Cancel when a screen closes.** Pass one token to every request the screen
makes, and cancel it in `dispose()`:

```dart
final token = CancelToken();

try {
  final res = await client.get('/feed', cancelToken: token);
} on NitroHttpCancelException catch (e) {
  print(e.reason); // screen closed
}

// in dispose():
token.cancel('screen closed');
```

**Stream a large download** (the socket slows down when you stop reading)

```dart
final res = await client.requestStream(HttpMethod.get, '/dataset.ndjson');
await for (final chunk in res.body) {
  sink.add(chunk);
}
```

**WebSockets**

```dart
final ws = await NitroWebSocket.connect(Uri.parse('wss://echo.example.com/socket'));
ws.events.listen((event) {
  if (event is TextDataReceived) print(event.text);
});
ws.sendText('hello');
await ws.close(1000, 'done');
```

## Already using package:http or dio?

Keep your call sites and swap the transport.

`package:http`:

```dart
final client = NitroHttpCompatClient();
final res = await client.get(Uri.parse('https://example.com/'));
client.close();
```

`dio` (add it with `dn pub add dio`), through its own library so apps without
dio don't pull it in:

```dart
import 'package:dio/dio.dart';
import 'package:nitro_http_dartnative/dio.dart';

final dio = Dio()..useNitroHttp();
```

dio and nitro_http both export a `CancelToken`. In a file that imports both
libraries, hide one: `import 'package:dio/dio.dart' hide CancelToken;`.

## Performance

Measured in a DartNative 1.9 release build, against a server inside the same
app, with every response checked byte for byte.

| Device | vs `dart:io`, HTTPS | vs `dart:io`, HTTP 1 MB |
|---|---|---|
| iPhone 12 (iOS 27.2) | 2.1–4.1× faster | 1.4–1.7× faster |
| Android 14 emulator | 2.0–9.1× faster | 2.4–2.7× faster |

On the iPhone, small plain-HTTP requests are on par with `dart:io` (0.95–1.00×)
and about 3× faster than `dartnative_http`.

## Versioning

`nitro_http_dartnative` X.Y.Z depends on exactly `nitro_http` X.Y.Z. To upgrade,
bump this package; never add `nitro_http` to your pubspec as well.

## Troubleshooting

- **`nitro_http ... doesn't match any versions` after switching from a local
  path.** The old path entry in `pubspec.lock` blocks resolution. Delete
  `pubspec.lock` and run `dn pub get`.
- **iOS debug run hangs at "The Dart VM Service was not discovered".** Over a
  wireless connection the app needs the Local Network permission: tap **Allow**
  on the phone, or connect the cable.
- **Engine version or features.** Ask at runtime instead of assuming:
  `NitroHttp.engineVersion`, `NitroHttp.supportsHttp3`,
  `NitroHttp.supportsBrotli`.
- **Hot restart** needs nothing: the engine cleans up after the previous isolate
  the first time the new one uses it.

## More

- Full API guide: [nitro_http README](https://github.com/Shreemanarjun/nitro_http#readme)
  (TLS pinning, mTLS, proxies, DNS-over-HTTPS, caching, cookies, retries,
  interceptors, progress and timings).
- Example app: [`example/`](example/lib/main.dart) sends one request and shows
  the status, protocol and time.
- Issues: https://github.com/Shreemanarjun/nitro_http/issues

## License

MIT, same as nitro_http.
