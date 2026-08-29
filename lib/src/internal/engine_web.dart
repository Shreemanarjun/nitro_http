/// The browser [EngineExecutor].
///
/// There is no engine in a page, so these answer for `fetch` instead of asking
/// a native module that was never loaded. Reporting the truth matters more than
/// reporting something: code that branches on `supportsHttp3` should take the
/// same path it would on a platform genuinely without it.
library;

import '../api/exceptions.dart';
import '../nitro_http.native.dart';
import 'engine_runner.dart';

/// The engine executor in the browser.
EngineExecutor defaultEngineExecutor() => const WebEngineExecutor();

/// Answers capability queries for a page.
final class WebEngineExecutor implements EngineExecutor {
  /// Creates the browser engine executor.
  const WebEngineExecutor();

  @override
  String get engineVersion => 'fetch (browser)';

  /// The browser may well negotiate HTTP/3, but a page cannot ask for it or
  /// find out, and this flag exists to decide whether to try.
  @override
  bool get supportsHttp3 => false;

  /// The browser's own `WebSocket`, which `ws_browser.dart` drives.
  @override
  bool get supportsWebSockets => true;

  /// Content decoding is the browser's, and every target browser does brotli.
  @override
  bool get supportsBrotli => true;

  /// zstd content-encoding is not broadly available in browsers yet.
  @override
  bool get supportsZstd => false;

  /// Nothing native to reset; a page has no engine to tear down.
  @override
  void resetNative() {}

  @override
  void configureCache(RawCacheConfig config) => throw _noCache();

  @override
  Future<RawResponse> prefetch(RawRequest request) async => throw _noCache();

  @override
  void clearCache() => throw _noCache();

  @override
  RawCacheStats cacheStats() => throw _noCache();

  NitroHttpConfigurationException _noCache() =>
      NitroHttpConfigurationException(
        engineMessage:
            'the disk cache is not available in the browser: the browser runs '
            'its own HTTP cache and a page cannot drive it.',
      );
}
