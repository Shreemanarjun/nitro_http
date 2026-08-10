/// The request value type and its per-request options.
library;

import 'body.dart';
import 'cancel_token.dart';
import 'headers.dart';
import 'progress.dart';

/// An HTTP method.
enum HttpMethod {
  /// `GET`.
  get,

  /// `HEAD`.
  head,

  /// `POST`.
  post,

  /// `PUT`.
  put,

  /// `DELETE`.
  delete,

  /// `PATCH`.
  patch,

  /// `OPTIONS`.
  options,

  /// `TRACE`.
  trace,

  /// A method token supplied by the caller through `HttpRequest.customMethod`.
  custom,
}

/// The HTTP version actually negotiated for a transfer.
enum HttpVersion {
  /// The engine did not report a version.
  unknown,

  /// HTTP/1.0.
  http10,

  /// HTTP/1.1.
  http11,

  /// HTTP/2.
  http2,

  /// HTTP/3 over QUIC.
  http3,
}

/// Human-readable version labels.
extension HttpVersionLabel on HttpVersion {
  /// The wire name of this version, such as `HTTP/1.1`.
  String get label => switch (this) {
    HttpVersion.unknown => 'HTTP/?',
    HttpVersion.http10 => 'HTTP/1.0',
    HttpVersion.http11 => 'HTTP/1.1',
    HttpVersion.http2 => 'HTTP/2',
    HttpVersion.http3 => 'HTTP/3',
  };
}

/// How the caller wants the response body delivered.
enum HttpExpectedBody {
  /// Buffer the body and decode it as text.
  text,

  /// Buffer the body and hand back the raw bytes.
  bytes,

  /// Deliver the body as a stream of chunks as they arrive.
  stream,
}

/// How a request interacts with the on-disk HTTP cache.
enum CacheMode {
  /// Normal RFC 9111 behaviour: serve fresh entries, revalidate stale ones.
  normal,

  /// Perform the request but do not write the response to the cache.
  noStore,

  /// Ignore any cached entry and go to the network, but still store the
  /// result.
  bypass,

  /// Serve only from the cache; fail with `NitroHttpCacheMissException` when
  /// nothing usable is stored.
  onlyIfCached,

  /// Force a revalidation even when the stored entry is still fresh.
  refresh,
}

/// Distinguishes "argument not supplied" from "argument supplied as null" in
/// the `copyWith` methods below, which is the only way `copyWith(body: null)`
/// can mean "remove the body" rather than "keep the current one".
class _Unset {
  const _Unset();
}

const _Unset _unset = _Unset();

/// Per-request overrides of the client's settings.
///
/// Every field is nullable and every `null` means *inherit from the client*.
/// That is what makes a single [RequestOptions] usable as a sparse patch on
/// top of whatever the client was configured with.
class RequestOptions {
  /// Creates a set of overrides. Omitted fields inherit from the client.
  const RequestOptions({
    this.connectTimeout,
    this.timeout,
    this.followRedirects,
    this.maxRedirects,
    this.cacheMode,
    this.wantTimings,
    this.pinnedSpkiSha256,
  });

  /// Deadline for establishing the connection (DNS, TCP and TLS).
  final Duration? connectTimeout;

  /// Deadline for the whole transfer.
  final Duration? timeout;

  /// Whether redirects are followed.
  final bool? followRedirects;

  /// Maximum number of redirects to follow.
  final int? maxRedirects;

  /// How this request interacts with the HTTP cache.
  final CacheMode? cacheMode;

  /// Whether to collect phase timings for this request. Defaults to `true`.
  ///
  /// Collection is a handful of `curl_easy_getinfo` calls on a handle that is
  /// being torn down anyway, so it is on unless you say otherwise. Set it to
  /// `false` and `HttpResponse.timings` comes back empty
  /// ([HttpTimings.isEmpty]).
  final bool? wantTimings;

  /// A base64 SPKI SHA-256 pin that the server certificate must match.
  ///
  /// Overrides the client-wide pin set for this one request, which is how a
  /// single high-value endpoint gets a stricter pin than the rest of the API.
  final String? pinnedSpkiSha256;

  /// Whether no override at all is set.
  bool get isEmpty =>
      connectTimeout == null &&
      timeout == null &&
      followRedirects == null &&
      maxRedirects == null &&
      cacheMode == null &&
      wantTimings == null &&
      pinnedSpkiSha256 == null;

  /// Returns a copy with the supplied overrides replaced.
  ///
  /// Passing `null` — or omitting an argument — keeps the current value. Use
  /// [clear] to drop overrides back to "inherit from the client".
  RequestOptions copyWith({
    Duration? connectTimeout,
    Duration? timeout,
    bool? followRedirects,
    int? maxRedirects,
    CacheMode? cacheMode,
    bool? wantTimings,
    String? pinnedSpkiSha256,
  }) => RequestOptions(
    connectTimeout: connectTimeout ?? this.connectTimeout,
    timeout: timeout ?? this.timeout,
    followRedirects: followRedirects ?? this.followRedirects,
    maxRedirects: maxRedirects ?? this.maxRedirects,
    cacheMode: cacheMode ?? this.cacheMode,
    wantTimings: wantTimings ?? this.wantTimings,
    pinnedSpkiSha256: pinnedSpkiSha256 ?? this.pinnedSpkiSha256,
  );

  /// Returns a copy with the named overrides removed, so they inherit again.
  RequestOptions clear({
    bool connectTimeout = false,
    bool timeout = false,
    bool followRedirects = false,
    bool maxRedirects = false,
    bool cacheMode = false,
    bool wantTimings = false,
    bool pinnedSpkiSha256 = false,
  }) => RequestOptions(
    connectTimeout: connectTimeout ? null : this.connectTimeout,
    timeout: timeout ? null : this.timeout,
    followRedirects: followRedirects ? null : this.followRedirects,
    maxRedirects: maxRedirects ? null : this.maxRedirects,
    cacheMode: cacheMode ? null : this.cacheMode,
    wantTimings: wantTimings ? null : this.wantTimings,
    pinnedSpkiSha256: pinnedSpkiSha256 ? null : this.pinnedSpkiSha256,
  );

  /// Returns these options with any unset field taken from [fallback].
  ///
  /// Used to layer a per-request patch over a per-call default without either
  /// side having to know which fields the other set.
  RequestOptions inheritFrom(RequestOptions? fallback) {
    if (fallback == null || fallback.isEmpty) return this;
    return RequestOptions(
      connectTimeout: connectTimeout ?? fallback.connectTimeout,
      timeout: timeout ?? fallback.timeout,
      followRedirects: followRedirects ?? fallback.followRedirects,
      maxRedirects: maxRedirects ?? fallback.maxRedirects,
      cacheMode: cacheMode ?? fallback.cacheMode,
      wantTimings: wantTimings ?? fallback.wantTimings,
      pinnedSpkiSha256: pinnedSpkiSha256 ?? fallback.pinnedSpkiSha256,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RequestOptions &&
          other.connectTimeout == connectTimeout &&
          other.timeout == timeout &&
          other.followRedirects == followRedirects &&
          other.maxRedirects == maxRedirects &&
          other.cacheMode == cacheMode &&
          other.wantTimings == wantTimings &&
          other.pinnedSpkiSha256 == pinnedSpkiSha256;

  @override
  int get hashCode => Object.hash(
    connectTimeout,
    timeout,
    followRedirects,
    maxRedirects,
    cacheMode,
    wantTimings,
    pinnedSpkiSha256,
  );

  @override
  String toString() {
    final parts = <String>[
      if (connectTimeout != null) 'connectTimeout: $connectTimeout',
      if (timeout != null) 'timeout: $timeout',
      if (followRedirects != null) 'followRedirects: $followRedirects',
      if (maxRedirects != null) 'maxRedirects: $maxRedirects',
      if (cacheMode != null) 'cacheMode: ${cacheMode!.name}',
      if (wantTimings != null) 'wantTimings: $wantTimings',
      if (pinnedSpkiSha256 != null) 'pinnedSpkiSha256: <set>',
    ];
    return 'RequestOptions(${parts.join(', ')})';
  }
}

/// An immutable description of one HTTP request.
///
/// Interceptors receive a request and return a possibly modified copy, so the
/// value has to be cheap to copy and impossible to mutate behind the runner's
/// back — hence [copyWith] rather than setters. [headers] is the one mutable
/// component, and [copyWith] clones it.
class HttpRequest {
  /// Creates a request for [url].
  ///
  /// [headers] is adopted as-is when supplied, so a caller can build one
  /// collection and hand it over without an extra copy.
  HttpRequest({
    required this.url,
    this.method = HttpMethod.get,
    this.customMethod,
    HttpHeaders? headers,
    this.body,
    this.expectedBody = HttpExpectedBody.text,
    this.options = const RequestOptions(),
    this.cancelToken,
    this.onSendProgress,
    this.onReceiveProgress,
  }) : headers = headers ?? HttpHeaders();

  /// The method to use.
  final HttpMethod method;

  /// The method token when [method] is [HttpMethod.custom]; otherwise `null`.
  final String? customMethod;

  /// The absolute URL to request.
  final Uri url;

  /// The request headers. Mutable, and owned by this request.
  final HttpHeaders headers;

  /// The payload, or `null` for a request without a body.
  final HttpBody? body;

  /// How the caller wants the response body delivered.
  final HttpExpectedBody expectedBody;

  /// Per-request overrides of the client's settings.
  final RequestOptions options;

  /// The token that can abort this request.
  final CancelToken? cancelToken;

  /// Called as request body bytes are handed to the engine.
  final ProgressCallback? onSendProgress;

  /// Called as response body bytes arrive.
  final ProgressCallback? onReceiveProgress;

  /// The method token to put on the wire.
  ///
  /// Throws [ArgumentError] when [method] is [HttpMethod.custom] but
  /// [customMethod] is missing or blank — sending a request with an empty
  /// method token would produce a malformed request line.
  String get methodToken {
    if (method != HttpMethod.custom) return method.name.toUpperCase();
    final token = customMethod?.trim();
    if (token == null || token.isEmpty) {
      throw ArgumentError.value(
        customMethod,
        'customMethod',
        'HttpMethod.custom requires a non-empty method token',
      );
    }
    return token;
  }

  /// The method token for logs and error messages.
  ///
  /// Unlike [methodToken] this never throws, so composing a diagnostic for a
  /// malformed request cannot itself blow up.
  String get methodLabel {
    if (method != HttpMethod.custom) return method.name.toUpperCase();
    final token = customMethod?.trim();
    return token == null || token.isEmpty ? 'CUSTOM' : token;
  }

  /// Returns a copy with the supplied fields replaced.
  ///
  /// Nullable fields are typed `Object?` so that passing an explicit `null`
  /// clears them, which an omitted argument does not. [headers] is cloned when
  /// it is not replaced, keeping copies independent.
  HttpRequest copyWith({
    HttpMethod? method,
    Object? customMethod = _unset,
    Uri? url,
    HttpHeaders? headers,
    Object? body = _unset,
    HttpExpectedBody? expectedBody,
    RequestOptions? options,
    Object? cancelToken = _unset,
    Object? onSendProgress = _unset,
    Object? onReceiveProgress = _unset,
  }) => HttpRequest(
    method: method ?? this.method,
    customMethod: identical(customMethod, _unset)
        ? this.customMethod
        : customMethod as String?,
    url: url ?? this.url,
    headers: headers ?? this.headers.clone(),
    body: identical(body, _unset) ? this.body : body as HttpBody?,
    expectedBody: expectedBody ?? this.expectedBody,
    options: options ?? this.options,
    cancelToken: identical(cancelToken, _unset)
        ? this.cancelToken
        : cancelToken as CancelToken?,
    onSendProgress: identical(onSendProgress, _unset)
        ? this.onSendProgress
        : onSendProgress as ProgressCallback?,
    onReceiveProgress: identical(onReceiveProgress, _unset)
        ? this.onReceiveProgress
        : onReceiveProgress as ProgressCallback?,
  );

  @override
  String toString() => 'HttpRequest($methodLabel $url)';
}
