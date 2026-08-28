/// A [dio](https://pub.dev/packages/dio) adapter backed by `nitro_http`'s
/// native libcurl engine.
///
/// ```dart
/// import 'package:dio/dio.dart';
/// import 'package:nitro_http/dio.dart';
///
/// final dio = Dio()..useNitroHttp();
/// final res = await dio.get<Map<String, dynamic>>('https://example.com/api');
/// ```
///
/// Import this library rather than `package:nitro_http/nitro_http.dart` — the
/// main barrel stays free of `dio`, so an app that never imports this file
/// tree-shakes the adapter away.
library;

import 'package:dio/dio.dart';
import 'src/api/settings.dart' show ClientSettings;

import 'src/compat/dio_compat.dart';

export 'src/compat/dio_compat.dart'
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
