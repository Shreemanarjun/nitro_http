/// Response value types.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';
import 'headers.dart';
import 'request.dart';

/// Per-phase timings for one transfer.
///
/// Phases are cumulative durations measured by the engine. A phase that did
/// not happen — no DNS lookup on a warm connection, no redirect — is
/// [Duration.zero] rather than `null`, so arithmetic over the record never
/// needs a null check.
class HttpTimings {
  /// Creates a timing record.
  const HttpTimings({
    required this.queue,
    required this.dns,
    required this.connect,
    required this.tls,
    required this.firstByte,
    required this.redirect,
    required this.total,
  });

  /// Creates a record with every phase at zero, for responses that did not
  /// ask for timings.
  const HttpTimings.zero()
    : queue = Duration.zero,
      dns = Duration.zero,
      connect = Duration.zero,
      tls = Duration.zero,
      firstByte = Duration.zero,
      redirect = Duration.zero,
      total = Duration.zero;

  /// Time the request waited before the engine started it.
  final Duration queue;

  /// Time spent resolving the host name.
  final Duration dns;

  /// Time spent establishing the TCP or QUIC connection.
  final Duration connect;

  /// Time spent on the TLS handshake.
  final Duration tls;

  /// Time from starting the request to the first response byte.
  final Duration firstByte;

  /// Time spent on redirect hops before the final request.
  final Duration redirect;

  /// Total wall-clock time for the transfer.
  final Duration total;

  /// Whether every phase is zero, meaning no timings were collected.
  bool get isEmpty => total == Duration.zero && firstByte == Duration.zero;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HttpTimings &&
          other.queue == queue &&
          other.dns == dns &&
          other.connect == connect &&
          other.tls == tls &&
          other.firstByte == firstByte &&
          other.redirect == redirect &&
          other.total == total;

  @override
  int get hashCode =>
      Object.hash(queue, dns, connect, tls, firstByte, redirect, total);

  /// Lists only the phases that actually took time, because a line of seven
  /// zeroes tells a reader nothing.
  @override
  String toString() {
    final parts = <String>[
      if (queue != Duration.zero) 'queue ${_ms(queue)}',
      if (dns != Duration.zero) 'dns ${_ms(dns)}',
      if (connect != Duration.zero) 'connect ${_ms(connect)}',
      if (tls != Duration.zero) 'tls ${_ms(tls)}',
      if (firstByte != Duration.zero) 'firstByte ${_ms(firstByte)}',
      if (redirect != Duration.zero) 'redirect ${_ms(redirect)}',
      if (total != Duration.zero) 'total ${_ms(total)}',
    ];
    return parts.isEmpty ? 'HttpTimings(none)' : 'HttpTimings(${parts.join(', ')})';
  }

  static String _ms(Duration d) =>
      '${(d.inMicroseconds / 1000).toStringAsFixed(1)}ms';
}

/// The metadata every concrete [HttpResponse] carries.
///
/// Bundled into one value so the runner can build the metadata once and hand
/// it to whichever response subtype the caller asked for, instead of
/// threading eleven arguments through three constructors.
final class ResponseMetadata {
  /// Creates a metadata record.
  const ResponseMetadata({
    required this.request,
    required this.statusCode,
    this.reasonPhrase = '',
    required this.version,
    required this.headers,
    required this.finalUrl,
    required this.redirectCount,
    required this.fromCache,
    required this.revalidated,
    required this.primaryIp,
    required this.primaryPort,
    required this.timings,
  });

  /// The request this response answers, after interceptors rewrote it.
  final HttpRequest request;

  /// The status code of the final response.
  final int statusCode;

  /// The status line's reason phrase, verbatim — `'OK'`, `'Not Found'`, or
  /// whatever custom text the server chose.
  ///
  /// Empty when there was none. HTTP/2 and HTTP/3 removed the reason phrase from
  /// the protocol entirely, so a response negotiated over either will always
  /// report `''`; branch on [statusCode], never on this.
  final String reasonPhrase;

  /// The HTTP version actually negotiated.
  final HttpVersion version;

  /// The response headers, in the order received.
  final HttpHeaders headers;

  /// The URL the response came from, after any redirects.
  final Uri finalUrl;

  /// How many redirects were followed.
  final int redirectCount;

  /// Whether the body was served from the on-disk cache.
  final bool fromCache;

  /// Whether a cached entry was revalidated with the origin (a 304).
  final bool revalidated;

  /// The peer's IP address, or the empty string when unavailable.
  final String primaryIp;

  /// The peer's port, or `0` when unavailable.
  final int primaryPort;

  /// Per-phase timings, all zero unless timings were requested.
  final HttpTimings timings;
}

/// A completed HTTP response.
///
/// Sealed on the shape of the body: text, bytes, or a stream. Which one you
/// get is decided by `HttpExpectedBody` on the request, so a `switch` over a
/// response is exhaustive.
sealed class HttpResponse {
  /// Creates a response carrying [meta].
  const HttpResponse({required this.meta});

  /// The metadata shared by every response shape.
  final ResponseMetadata meta;

  /// The request this response answers.
  HttpRequest get request => meta.request;

  /// The status code of the final response.
  int get statusCode => meta.statusCode;

  /// The status line's reason phrase, or `''` when the server sent none.
  /// Always `''` over HTTP/2 and HTTP/3, which removed it from the protocol.
  String get reasonPhrase => meta.reasonPhrase;

  /// The HTTP version actually negotiated.
  HttpVersion get version => meta.version;

  /// The response headers, in the order received.
  HttpHeaders get headers => meta.headers;

  /// The URL the response came from, after any redirects.
  Uri get finalUrl => meta.finalUrl;

  /// Whether the body was served from the on-disk cache.
  bool get fromCache => meta.fromCache;

  /// Whether a cached entry was revalidated with the origin.
  bool get revalidated => meta.revalidated;

  /// How many redirects were followed.
  int get redirectCount => meta.redirectCount;

  /// The peer's IP address, or the empty string when unavailable.
  String get primaryIp => meta.primaryIp;

  /// The peer's port, or `0` when unavailable.
  int get primaryPort => meta.primaryPort;

  /// Per-phase timings, all zero unless timings were requested.
  HttpTimings get timings => meta.timings;

  /// Whether [statusCode] is in the 2xx range.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// A buffered response decoded as text.
final class HttpTextResponse extends HttpResponse {
  /// Creates a text response over the raw [bodyBytes].
  HttpTextResponse({required super.meta, required this.bodyBytes});

  /// The undecoded body, so callers do not have to re-encode [body] to get
  /// the bytes back.
  final Uint8List bodyBytes;

  /// The body decoded using the charset from `Content-Type`.
  ///
  /// Decoded lazily and cached: a caller that only wants the status code
  /// should not pay for decoding a megabyte of text.
  late final String body = _decodeText(bodyBytes, headers.contentType);

  /// Parses [body] as JSON.
  ///
  /// Throws [NitroHttpDecodingException] when the body is not valid JSON,
  /// rather than a bare `FormatException`, so a caller can handle every
  /// `nitro_http` failure with one `on NitroHttpException` clause.
  Object? bodyToJson() {
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw NitroHttpDecodingException(
        request: request,
        engineMessage: error.message,
      );
    }
  }

  @override
  String toString() =>
      'HttpTextResponse($statusCode ${version.label}, ${bodyBytes.length} bytes)';
}

/// A buffered response delivered as raw bytes.
final class HttpBytesResponse extends HttpResponse {
  /// Creates a byte response.
  const HttpBytesResponse({required super.meta, required this.bodyBytes});

  /// The response body, exactly as received.
  final Uint8List bodyBytes;

  @override
  String toString() =>
      'HttpBytesResponse($statusCode ${version.label}, ${bodyBytes.length} bytes)';
}

/// A response whose body arrives incrementally.
///
/// The body is a single-subscription stream; consuming it slowly applies
/// backpressure all the way down to the TCP window.
final class HttpStreamResponse extends HttpResponse {
  /// Creates a streamed response.
  ///
  /// [contentLength] defaults to the value of the `Content-Length` header.
  HttpStreamResponse({
    required super.meta,
    required this.body,
    int? contentLength,
  }) : contentLength = contentLength ?? meta.headers.contentLength;

  /// The response body as it arrives. Consume exactly once.
  final Stream<List<int>> body;

  /// The expected body length, or `null` for a chunked response.
  final int? contentLength;

  @override
  String toString() =>
      'HttpStreamResponse($statusCode ${version.label}, ${contentLength ?? '?'} bytes)';
}

/// Decodes [bytes] using the charset named in [contentType].
///
/// Only the charsets that actually show up on the web are honoured; anything
/// else falls back to UTF-8. Decoding is always lenient — a server that emits
/// one malformed sequence in a 200 KB page must not crash the app, so bad
/// bytes become U+FFFD instead of an exception.
String _decodeText(Uint8List bytes, String? contentType) {
  switch (_charsetOf(contentType)) {
    case 'ascii':
    case 'us-ascii':
      return ascii.decode(bytes, allowInvalid: true);
    case 'latin1':
    case 'latin-1':
    case 'iso-8859-1':
    case 'iso8859-1':
      return latin1.decode(bytes, allowInvalid: true);
    // Required: the subject is a charset name off the wire, not a closed type.
    default:
      return utf8.decode(bytes, allowMalformed: true);
  }
}

/// The lower-cased `charset` parameter of [contentType], or `null`.
String? _charsetOf(String? contentType) {
  if (contentType == null) return null;
  for (final parameter in contentType.split(';').skip(1)) {
    final separator = parameter.indexOf('=');
    if (separator < 0) continue;
    if (parameter.substring(0, separator).trim().toLowerCase() != 'charset') {
      continue;
    }
    var value = parameter.substring(separator + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value.toLowerCase();
  }
  return null;
}
