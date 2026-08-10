/// A [dio](https://pub.dev/packages/dio) adapter backed by `nitro_http`'s
/// native libcurl engine.
///
/// ```dart
/// import 'package:dio/dio.dart';
/// import 'package:nitro_http_dio/nitro_http_dio.dart';
///
/// final dio = Dio()..useNitroHttp();
/// final res = await dio.get<Map<String, dynamic>>('https://example.com/api');
/// ```
///
/// This lives in its own package because `dio` is a heavy dependency that many
/// `nitro_http` users do not want in their graph. The `package:http` adapter,
/// whose dependency is tiny and pure Dart, ships inside `nitro_http` itself.
library;

import 'package:dio/dio.dart';
import 'package:nitro_http/nitro_http.dart' show ClientSettings;

import 'src/adapter.dart';

export 'src/adapter.dart'
    show NitroHttpDioAdapter, dioExceptionTypeOf, nitroHttpCacheModeKey;

/// Installs a [NitroHttpDioAdapter] on a [Dio] instance.
extension NitroHttpDio on Dio {
  /// Routes this [Dio] through the `nitro_http` native engine.
  ///
  /// ```dart
  /// final dio = Dio()..useNitroHttp();
  /// ```
  ///
  /// The adapter created here owns its client and disposes it when the
  /// [Dio] instance is closed. Assign [NitroHttpDioAdapter] to
  /// [Dio.httpClientAdapter] directly to share a client between several `Dio`
  /// instances instead.
  void useNitroHttp({ClientSettings settings = const ClientSettings()}) {
    httpClientAdapter = NitroHttpDioAdapter(settings: settings);
  }
}
