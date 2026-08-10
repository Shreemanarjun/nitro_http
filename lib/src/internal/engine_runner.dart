/// The process-wide `engine` role: capabilities, disk cache, prefetch.
///
/// Separate from `RequestRunner` because these operations belong to no client.
/// The cache directory and the prefetch pool are process-global by design — two
/// clients sharing a cache is the entire point of having one.
library;

import 'dart:typed_data';

import '../nitro_http.native.dart';
import 'instance_keys.dart';
import 'raw_mapping.dart';

/// Seam over the `engine` instance, so the cache and prefetch API are testable
/// without a native library.
abstract interface class EngineExecutor {
  String get engineVersion;
  bool get supportsHttp3;
  bool get supportsWebSockets;
  bool get supportsBrotli;
  bool get supportsZstd;

  void resetNative();

  void configureCache(RawCacheConfig config);
  Future<RawResponse> prefetch(RawRequest request);
  void clearCache();
  RawCacheStats cacheStats();
}

final class NativeEngineExecutor implements EngineExecutor {
  NativeEngineExecutor() : _native = NitroHttpNative.forKey(kEngineKey);

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
/// Lives here rather than in `fetch.dart` so the public API never has to name a
/// `Raw*` type.
Future<void> runPrefetch(
  EngineExecutor executor,
  String url,
  Iterable<(String, String)> headers,
) async {
  final response = await executor.prefetch(
    RawRequest(
      requestId: Ids.nextRequest(),
      method: RawMethod.get,
      customMethod: '',
      url: url,
      headers: <RawHeader>[
        for (final (name, value) in headers) RawHeader(name: name, value: value),
      ],
      // A prefetch carries no body and expects none back — the point is to
      // populate the cache, not to deliver anything.
      bodyKind: RawBodyKind.none,
      bodyFilePath: '',
      options: const RawRequestOptions(
        connectTimeoutMs: -1,
        requestTimeoutMs: -1,
        followRedirects: 1,
        maxRedirects: -1,
        cacheMode: RawCacheMode.normal,
        reportProgress: false,
        wantTimings: false,
        uploadContentLength: -1,
        pinnedSpkiOverride: '',
      ),
    ),
  );
  if (response.errorKind != RawErrorKind.none) {
    throw mapError(
      kind: response.errorKind,
      message: response.errorMessage,
      engineErrorCode: response.engineErrorCode,
    );
  }
}

/// Empty body constant, to avoid allocating one per call on the hot paths.
final Uint8List emptyBody = Uint8List(0);
