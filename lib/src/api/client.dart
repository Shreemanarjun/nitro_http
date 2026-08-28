/// The main entry point: a configured HTTP client backed by a native engine.
library;

import 'dart:async';
import 'dart:typed_data';

import '../internal/instance_keys.dart';
import '../internal/raw_mapping.dart';
import '../internal/executor_default.dart';
import '../internal/request_runner.dart';
import 'body.dart';
import 'cancel_token.dart';
import 'cookies.dart';
import 'exceptions.dart';
import 'headers.dart';
import 'interceptor.dart';
import 'progress.dart';
import 'request.dart';
import 'response.dart';
import 'retry_interceptor.dart';
import 'settings.dart';

/// A client owning its own connection pool, cookie jar, TLS configuration and
/// event-loop thread.
///
/// The constructor is **synchronous**, unlike `rhttp`'s `await
/// RhttpClient.create()`: configuring the native engine is a sub-microsecond
/// FFI call, so there is nothing to await.
///
/// ```dart
/// final client = NitroHttpClient(
///   settings: ClientSettings(
///     baseUrl: 'https://api.example.com',
///     timeout: Duration(seconds: 30),
///   ),
///   interceptors: [RetryInterceptor(maxRetries: 3)],
/// );
/// final res = await client.get('/users', query: {'page': '2'});
/// ```
///
/// Dispose the client when you are done with it; that shuts down its engine
/// thread and flushes the cookie jar. A client that is garbage-collected
/// without disposal is cleaned up by a native finalizer, but relying on that
/// leaves a thread alive for an indeterminate time.
class NitroHttpClient {
  /// Creates a client. Pass [executor] and [demux] only from tests — the
  /// defaults wire up the real native engine.
  NitroHttpClient({
    ClientSettings settings = const ClientSettings(),
    List<Interceptor> interceptors = const [],
    RequestExecutor? executor,
    StreamDemux? demux,
  }) : _clientId = executor == null ? Ids.nextClient() : 0,
       _interceptors = InterceptorChain(interceptors),
       _retryPolicy = _findRetryPolicy(interceptors) {
    _runner = RequestRunner(
      executor: executor ?? defaultExecutor(_clientId),
      demux: demux ?? defaultDemux,
      settings: settings,
    );
    _runner.configure(settings);
  }

  final int _clientId;
  final InterceptorChain _interceptors;
  final RetryPolicy? _retryPolicy;
  late final RequestRunner _runner;
  var _disposed = false;

  static RetryPolicy? _findRetryPolicy(List<Interceptor> interceptors) {
    for (final i in interceptors) {
      if (i is RetryInterceptor) return i.policy;
    }
    return null;
  }

  /// The settings this client was configured with.
  ClientSettings get settings => _runner.settings;

  /// Replaces the configuration. Requests already in flight keep the options
  /// they were built with.
  void reconfigure(ClientSettings settings) => _runner.configure(settings);

  // ── Verbs ──────────────────────────────────────────────────────────────────

  Future<HttpTextResponse> get(
    String path, {
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.get,
    path,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<HttpTextResponse> head(
    String path, {
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.head,
    path,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  Future<HttpTextResponse> post(
    String path, {
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.post,
    path,
    body: body,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<HttpTextResponse> put(
    String path, {
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.put,
    path,
    body: body,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<HttpTextResponse> patch(
    String path, {
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.patch,
    path,
    body: body,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    options: options,
  );

  Future<HttpTextResponse> delete(
    String path, {
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.delete,
    path,
    body: body,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  Future<HttpTextResponse> options_(
    String path, {
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.options,
    path,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  Future<HttpTextResponse> trace(
    String path, {
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    RequestOptions options = const RequestOptions(),
  }) => requestText(
    HttpMethod.trace,
    path,
    query: query,
    headers: headers,
    cancelToken: cancelToken,
    options: options,
  );

  // ── Typed request helpers ──────────────────────────────────────────────────

  Future<HttpTextResponse> requestText(
    HttpMethod method,
    String path, {
    String? customMethod,
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) async =>
      await request(
            _build(
              method,
              path,
              HttpExpectedBody.text,
              customMethod: customMethod,
              body: body,
              query: query,
              headers: headers,
              cancelToken: cancelToken,
              onSendProgress: onSendProgress,
              onReceiveProgress: onReceiveProgress,
              options: options,
            ),
          )
          as HttpTextResponse;

  Future<HttpBytesResponse> requestBytes(
    HttpMethod method,
    String path, {
    String? customMethod,
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) async =>
      await request(
            _build(
              method,
              path,
              HttpExpectedBody.bytes,
              customMethod: customMethod,
              body: body,
              query: query,
              headers: headers,
              cancelToken: cancelToken,
              onSendProgress: onSendProgress,
              onReceiveProgress: onReceiveProgress,
              options: options,
            ),
          )
          as HttpBytesResponse;

  /// Streams the response body. The returned stream applies real backpressure:
  /// pausing the subscription withholds native credits, which closes the TCP
  /// window rather than buffering in Dart.
  Future<HttpStreamResponse> requestStream(
    HttpMethod method,
    String path, {
    String? customMethod,
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) async =>
      await request(
            _build(
              method,
              path,
              HttpExpectedBody.stream,
              customMethod: customMethod,
              body: body,
              query: query,
              headers: headers,
              cancelToken: cancelToken,
              onSendProgress: onSendProgress,
              onReceiveProgress: onReceiveProgress,
              options: options,
            ),
          )
          as HttpStreamResponse;

  HttpRequest _build(
    HttpMethod method,
    String path,
    HttpExpectedBody expected, {
    String? customMethod,
    HttpBody? body,
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) {
    return HttpRequest(
      method: method,
      customMethod: customMethod,
      url: settings.resolve(path, query: query),
      headers: headers ?? HttpHeaders(),
      body: body,
      expectedBody: expected,
      options: options,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
    );
  }

  // ── The one path everything funnels through ────────────────────────────────

  /// Runs [request] through the interceptor chain and the retry policy.
  Future<HttpResponse> request(HttpRequest request) async {
    _checkAlive();

    var attempt = 0;
    var current = request;

    while (true) {
      final before = await _interceptors.runBeforeRequest(current);
      switch (before) {
        case InterceptorShortCircuit(:final value):
          current = value;
        case InterceptorRecovered(:final response):
          return response;
        case InterceptorProceed(:final value):
          current = value;
      }

      HttpResponse? response;
      NitroHttpException? failure;
      try {
        response = await _runner.send(current);
      } on NitroHttpException catch (e) {
        failure = e;
      }

      if (response != null) {
        final after = await _interceptors.runAfterResponse(response);
        final resolved = switch (after) {
          InterceptorProceed(:final value) => value,
          InterceptorShortCircuit(:final value) => value,
          InterceptorRecovered(:final response) => response,
        };
        if (!_shouldRetry(resolved, null, attempt)) return resolved;
        response = resolved;
      } else {
        // `runOnError` rethrows when no interceptor recovered: during an error
        // there is no in-flight response, so `InterceptorProceed<HttpResponse>`
        // is unconstructible and rethrowing is the only honest "unhandled"
        // signal. An `onError` hook may also throw on its own — a failed token
        // refresh, say. Catching here is what keeps the retry branch reachable.
        HttpResponse? recovered;
        try {
          final outcome = await _interceptors.runOnError(failure!);
          recovered = switch (outcome) {
            InterceptorRecovered(:final response) => response,
            InterceptorShortCircuit(:final value) => value,
            InterceptorProceed(:final value) => value,
          };
        } on NitroHttpException catch (e) {
          failure = e;
        }
        if (recovered != null) return recovered;
        if (!_shouldRetry(null, failure, attempt)) throw failure;
      }

      // Retry. A streamed request body cannot be replayed, so refuse rather
      // than silently sending a truncated second attempt.
      if (current.body is HttpStreamBody) {
        if (response != null) return response;
        throw failure!;
      }

      final delay = _retryPolicy!.delayFor(
        attempt,
        response: response,
        error: failure,
      );
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final prepared = await _retryPolicy.prepare(current, attempt);
      if (prepared == null) {
        if (response != null) return response;
        throw failure!;
      }
      current = prepared;
      attempt++;
    }
  }

  bool _shouldRetry(
    HttpResponse? response,
    NitroHttpException? error,
    int attempt,
  ) {
    final policy = _retryPolicy;
    if (policy == null) return false;
    if (attempt >= policy.maxRetries) return false;
    if (error is NitroHttpCancelException) return false;
    return policy.shouldRetry(response, error, attempt);
  }

  // ── Cookies ────────────────────────────────────────────────────────────────

  /// Every cookie in this client's jar that matches [url].
  List<Cookie> cookiesFor(Uri url) {
    _checkAlive();
    return _runner
        .rawCookies(url.toString())
        .map(fromRawCookie)
        .where((c) => c.matches(url))
        .toList(growable: false);
  }

  /// Every cookie in this client's jar, unfiltered.
  List<Cookie> allCookies() {
    _checkAlive();
    return _runner.rawCookies('').map(fromRawCookie).toList(growable: false);
  }

  void setCookie(Cookie cookie) {
    _checkAlive();
    _runner.setRawCookie(toRawCookie(cookie));
  }

  void clearCookies() => _runner.clearCookies();

  /// Persists the jar now. Also happens automatically on [dispose].
  void flushCookies() => _runner.flushCookies();

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Cancels every in-flight request on this client.
  void cancelAll() => _runner.cancelAll();

  /// Shuts down the engine thread and flushes the cookie jar. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runner.dispose();
  }

  bool get isDisposed => _disposed;

  void _checkAlive() {
    if (_disposed) {
      throw NitroHttpDisposedException(
        engineMessage: 'this NitroHttpClient has already been disposed',
      );
    }
  }
}

/// Convenience: download straight to bytes without going through the text
/// decoder. Equivalent to `requestBytes(HttpMethod.get, path)`.
extension NitroHttpClientDownload on NitroHttpClient {
  Future<Uint8List> download(
    String path, {
    Map<String, dynamic>? query,
    HttpHeaders? headers,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    RequestOptions options = const RequestOptions(),
  }) async {
    final res = await requestBytes(
      HttpMethod.get,
      path,
      query: query,
      headers: headers,
      cancelToken: cancelToken,
      onReceiveProgress: onReceiveProgress,
      options: options,
    );
    return res.bodyBytes;
  }
}
