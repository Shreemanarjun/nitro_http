/// The FFI-backed [EngineExecutor].
///
/// Split from `engine_runner.dart` for the same reason the request executor is:
/// the browser never loads the native module, so the capability queries and the
/// cache have to come from somewhere else there.
library;

import '../nitro_http.native.dart';
import 'engine_runner.dart';
import 'instance_keys.dart';
import 'native_attach.dart';

final class NativeEngineExecutor implements EngineExecutor {
  NativeEngineExecutor() : _native = attachedNative(kEngineKey);

  final NitroHttpNative _native;

  @override
  String get engineVersion => _native.engineVersion();

  @override
  bool get supportsHttp3 => _native.supportsHttp3();

  @override
  bool get supportsWebSockets => _native.supportsWebSockets();

  @override
  bool get supportsBrotli => _native.supportsBrotli();

  @override
  bool get supportsZstd => _native.supportsZstd();

  @override
  void resetNative() => _native.resetNative();

  @override
  void configureCache(RawCacheConfig config) => _native.configureCache(config);

  @override
  Future<RawResponse> prefetch(RawRequest request) =>
      _native.prefetch(request);

  @override
  void clearCache() => _native.clearCache();

  @override
  RawCacheStats cacheStats() => _native.cacheStats();
}

/// Runs a prefetch and converts a transport failure into the typed exception.
///
/// The engine executor on a platform with `dart:ffi`.
EngineExecutor defaultEngineExecutor() => NativeEngineExecutor();
