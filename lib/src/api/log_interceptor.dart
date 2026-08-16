/// A request logger that costs nothing when it is not logging.
library;

import 'dart:async';
import 'dart:typed_data';

import 'body.dart';
import 'exceptions.dart';
import 'headers.dart';
import 'interceptor.dart';
import 'request.dart';
import 'response.dart';

/// How much [LogInterceptor] writes about each call.
///
/// Each level includes everything below it.
enum HttpLogLevel {
  /// Nothing at all. Every hook becomes a pass-through with no work and no
  /// allocation, so a logger left installed in release costs a branch.
  none,

  /// One line per call: method, URL, status, body size, total time.
  basic,

  /// Adds request and response headers, [LogInterceptor.redactedHeaders]
  /// applied.
  headers,

  /// Adds bodies. Never drains a streamed body — see [LogInterceptor].
  body,
}

/// Logs each request and response without getting in the way of either.
///
/// ```dart
/// final client = NitroHttpClient(
///   settings: const ClientSettings(baseUrl: 'https://api.example.com'),
///   interceptors: [LogInterceptor(level: HttpLogLevel.headers)],
/// );
/// ```
///
/// Three things keep it off the critical path:
///
/// * **Nothing is formatted that is not printed.** The level is checked before
///   any string is built, so [HttpLogLevel.none] does no work — and neither does
///   [HttpLogLevel.basic] on the header and body branches.
/// * **Every hook is synchronous.** It returns a value rather than a future, so
///   the chain never suspends on it and the request costs no extra microtask.
///   That holds only while [sink] is synchronous — see below.
/// * **A streamed body is never drained.** Logging one would mean buffering the
///   whole response to replay it to the caller, turning a constant-memory
///   download into an unbounded one. At [HttpLogLevel.body] a stream logs as
///   `<stream>`; if you need its contents, log at the call site where you are
///   already reading them.
/// * **Duration comes from the engine.** [HttpTimings.total] is already measured
///   natively, so there is no stopwatch, no map from request to start time, and
///   nothing to leak when a request never completes. It reads `-` when the
///   client was configured with `wantTimings: false`.
///
/// Output goes to [sink], which defaults to `print`. Point it at your own logger
/// to control routing; if that sink is slow, this interceptor is slow, because
/// the chain awaits each hook in turn.
///
/// `authorization`, `cookie`, `set-cookie` and `proxy-authorization` are
/// redacted by default — logs get pasted into issues.
final class LogInterceptor extends Interceptor {
  /// Creates a logger writing at [level].
  const LogInterceptor({
    this.level = HttpLogLevel.basic,
    this.sink = print,
    this.redactedHeaders = defaultRedactedHeaders,
  });

  /// How much to write. [HttpLogLevel.none] disables the interceptor.
  final HttpLogLevel level;

  /// Where lines go. Defaults to `print`.
  final void Function(String line) sink;

  /// Header names whose values are replaced with `<redacted>`, lower-case.
  final Set<String> redactedHeaders;

  /// The headers redacted unless you say otherwise.
  static const Set<String> defaultRedactedHeaders = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
  };

  @override
  FutureOr<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) {
    if (level == HttpLogLevel.none) return super.beforeRequest(request);

    final method = request.customMethod ?? request.method.name.toUpperCase();
    sink('--> $method ${request.url}');
    if (level.index >= HttpLogLevel.headers.index) {
      _writeHeaders(request.headers);
    }
    if (level == HttpLogLevel.body && request.body != null) {
      _writeBody(_describeRequestBody(request.body!));
    }
    return super.beforeRequest(request);
  }

  @override
  FutureOr<InterceptorResult<HttpResponse>> afterResponse(
    HttpResponse response,
  ) {
    if (level == HttpLogLevel.none) return super.afterResponse(response);

    final timings = response.meta.timings;
    final took = timings.isEmpty ? '-' : '${timings.total.inMilliseconds}ms';
    final cached = response.fromCache ? ' (cache)' : '';
    sink('<-- ${response.statusCode} ${response.reasonPhrase} '
        '${response.finalUrl} ${_sizeOf(response)} $took$cached');
    if (level.index >= HttpLogLevel.headers.index) {
      _writeHeaders(response.headers);
    }
    if (level == HttpLogLevel.body) {
      _writeBody(_describeResponseBody(response));
    }
    return super.afterResponse(response);
  }

  @override
  FutureOr<InterceptorResult<HttpResponse>> onError(
    NitroHttpException exception,
  ) {
    if (level == HttpLogLevel.none) return super.onError(exception);

    final url = exception.request?.url;
    sink('<-- FAILED ${url ?? ''} ${exception.runtimeType}: ${exception.message}');
    return super.onError(exception);
  }

  void _writeHeaders(HttpHeaders headers) {
    for (final (name, value) in headers.entries) {
      final shown = redactedHeaders.contains(name.toLowerCase())
          ? '<redacted>'
          : value;
      sink('    $name: $shown');
    }
  }

  void _writeBody(String description) {
    if (description.isNotEmpty) sink('    $description');
  }

  String _sizeOf(HttpResponse response) => switch (response) {
    HttpTextResponse(:final bodyBytes) => '${bodyBytes.length}b',
    HttpBytesResponse(:final bodyBytes) => '${bodyBytes.length}b',
    // Not yet read, and asking would mean consuming it.
    HttpStreamResponse() => 'stream',
  };

  String _describeResponseBody(HttpResponse response) => switch (response) {
    HttpTextResponse(:final body) => body,
    HttpBytesResponse(:final bodyBytes) => _describeBytes(bodyBytes),
    // Draining this to log it would buffer the whole body and hand the caller
    // an already-consumed stream.
    HttpStreamResponse() => '<stream>',
  };

  String _describeRequestBody(HttpBody body) => switch (body) {
    HttpTextBody(:final text) => text,
    HttpJsonBody(:final json) => '$json',
    HttpBytesBody(:final bytes) => _describeBytes(bytes),
    HttpFormBody(:final fields) => '$fields',
    HttpMultipartBody(:final parts) => '<multipart, ${parts.length} parts>',
    // Reading it here would consume the caller's stream or the file twice.
    HttpStreamBody() => '<stream>',
    HttpFileBody(:final path) => '<file $path>',
  };

  String _describeBytes(Uint8List bytes) => '<${bytes.length} bytes>';
}
