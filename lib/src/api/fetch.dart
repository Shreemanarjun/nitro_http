/// The convenience layer: a lazily created default client, one-liner verbs, and
/// the process-wide cache and prefetch controls.
library;

import 'dart:async';

import '../internal/engine_runner.dart';
import '../internal/raw_mapping.dart';
import 'body.dart';
import 'cache.dart';
import 'cancel_token.dart';
import 'client.dart';
import 'exceptions.dart';
import 'headers.dart';
import 'interceptor.dart';
import 'progress.dart';
import 'request.dart';
import 'response.dart';
import 'settings.dart';

/// Static, process-wide entry points.
///
/// Everything here delegates to [defaultClient], which is created on first use
/// with default settings. Call [init] before the first request to configure it;
/// calling [init] afterwards replaces the client, so any in-flight request on
/// the old one is cancelled.
abstract final class NitroHttp {
  static NitroHttpClient? _client;
  static EngineExecutor? _engine;

  /// The lazily created default client.
  static NitroHttpClient get defaultClient =>
      _client ??= NitroHttpClient(settings: const ClientSettings());

  static EngineExecutor get _engineExecutor =>
      _engine ??= NativeEngineExecutor();

  /// Configures the default client. Replaces any existing one.
  static void init(
    ClientSettings settings, {
    List<Interceptor> interceptors = const [],
  }) {
    _client?.dispose();
    _client = NitroHttpClient(settings: settings, interceptors: interceptors);
  }

  /// Test seam: injects the engine-role executor.
  static void overrideEngineExecutorForTesting(EngineExecutor? executor) {
    _engine = executor;
  }

  /// Test seam: injects the client the static verbs delegate to.
  ///
  /// Passing `null` drops the override, so the next call lazily builds a real
  /// client again. Unlike [init] this does not dispose the client it replaces —
  /// a test owns the lifetime of the fake it installed.
  static void overrideDefaultClientForTesting(NitroHttpClient? client) {
    _client = client;
  }

  /// Hot-restart recovery.
  ///
  /// On hot restart the Dart isolate is torn down without cancelling
  /// subscriptions while native threads keep running. Calling this at startup
  /// aborts every straggling transfer, joins the engine threads and flushes the
  /// cookie jars, so a reloaded app does not inherit ghost sockets.
  ///
  /// ```dart
  /// void main() {
  ///   NitroHttp.reset();
  ///   runApp(const MyApp());
  /// }
  /// ```
  static void reset() {
    _client?.dispose();
    _client = null;
    _engineExecutor.resetNative();
  }

  // ── Capabilities ───────────────────────────────────────────────────────────

  /// The native stack, verbatim — e.g.
  /// `libcurl/8.21.0 OpenSSL/3.5.0 nghttp2/1.70.0 ngtcp2/1.25.0`.
  static String get engineVersion => _engineExecutor.engineVersion;

  /// Whether the linked libcurl was built with QUIC support. `HttpVersionPref`
  /// values requesting HTTP/3 fall back to HTTP/2 when this is false.
  static bool get supportsHttp3 => _engineExecutor.supportsHttp3;

  static bool get supportsWebSockets => _engineExecutor.supportsWebSockets;
  static bool get supportsBrotli => _engineExecutor.supportsBrotli;
  static bool get supportsZstd => _engineExecutor.supportsZstd;

  // ── Verbs on the default client ────────────────────────────────────────────

  static Future<HttpTextResponse> get(
    String url, {
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) => defaultClient.get(
    url,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  static Future<HttpTextResponse> post(
    String url, {
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) => defaultClient.post(
    url,
    body: body,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  static Future<HttpTextResponse> put(
    String url, {
    HttpBody? body,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => defaultClient.put(
    url,
    body: body,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  static Future<HttpTextResponse> patch(
    String url, {
    HttpBody? body,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => defaultClient.patch(
    url,
    body: body,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  static Future<HttpTextResponse> delete(
    String url, {
    HttpBody? body,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => defaultClient.delete(
    url,
    body: body,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  static Future<HttpTextResponse> head(
    String url, {
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => defaultClient.head(
    url,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  static Future<HttpStreamResponse> getStream(
    String url, {
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => defaultClient.requestStream(
    HttpMethod.get,
    url,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  // ── Disk cache ─────────────────────────────────────────────────────────────

  /// Configures the process-wide disk cache.
  ///
  /// The directory is not guessed: pass one obtained from the app (for example
  /// `path_provider`'s cache directory). A plugin inventing a path is how you
  /// end up writing to a location the OS reclaims mid-transfer.
  ///
  /// Individual clients still opt in through `CacheSettings.enabled`.
  static void configureCache(HttpCacheConfig config) =>
      _engineExecutor.configureCache(toRawCacheConfig(config));

  static void clearCache() => _engineExecutor.clearCache();

  static CacheStats cacheStats() =>
      fromRawCacheStats(_engineExecutor.cacheStats());

  // ── Prefetch ───────────────────────────────────────────────────────────────

  /// Fetches [url] and populates the cache, discarding the body.
  ///
  /// Runs on a dedicated internal engine with a deliberately small pool, so a
  /// prefetch storm cannot starve a user client's connections. Identical
  /// in-flight prefetches are de-duplicated by cache key.
  ///
  /// Completes normally even when the fetch failed: a prefetch is an
  /// optimisation, and a caller should not have to guard every warm-up call with
  /// a try/catch. Use [prefetchDetailed] when you do want to know.
  static Future<void> prefetch(String url, {HttpHeaders? headers}) async {
    try {
      await prefetchDetailed(url, headers: headers);
    } on NitroHttpException {
      // Deliberately swallowed — see the doc comment.
    }
  }

  /// Like [prefetch], but throws the transport failure instead of swallowing it.
  static Future<void> prefetchDetailed(
    String url, {
    HttpHeaders? headers,
  }) => runPrefetch(
    _engineExecutor,
    url,
    headers?.entries ?? const <(String, String)>[],
  );

  /// Warms the cache for a batch of URLs concurrently.
  ///
  /// Intended for app start: fire this during initialisation and the first
  /// screen's data is already local by the time it asks.
  static Future<void> prefetchOnAppStart(
    List<String> urls, {
    HttpHeaders? headers,
  }) => Future.wait(urls.map((u) => prefetch(u, headers: headers)));
}

/// One-liner GET on the default client.
///
/// ```dart
/// final res = await fetch('https://api.example.com/users');
/// ```
Future<HttpTextResponse> fetch(
  String url, {
  HttpHeaders? headers,
  CancelToken? cancelToken,
  RequestOptions options = const RequestOptions(),
}) => NitroHttp.get(
  url,
  headers: headers,
  cancelToken: cancelToken,
  options: options,
);
