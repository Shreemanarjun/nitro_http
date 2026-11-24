# nitro_http_dartnative

[nitro_http](https://pub.dev/packages/nitro_http) for DartNative apps: a fast
HTTP client backed by a native libcurl engine over FFI, with HTTP/1.1, HTTP/2,
HTTP/3, streaming and WebSockets.

This package only re-exports `nitro_http`. The engine, its native code and the
documentation all live there.

## Setup

```sh
dn pub add nitro_http_dartnative
```

```dart
import 'package:nitro_http_dartnative/nitro_http_dartnative.dart';

final client = NitroHttpClient();
final response = await client.get('https://example.com');
print('${response.statusCode} over ${response.version.label}');
client.dispose();
```

Works on Android and iOS. See the
[nitro_http README](https://github.com/Shreemanarjun/nitro_http#readme) for
settings, streaming, WebSockets and the `package:http` / `dio` adapters.

## Benchmark

In a DartNative 1.9 release build on an iPhone 12, against a server in the same
app, HTTPS requests were 2.1–4.1× faster than `dart:io`.
