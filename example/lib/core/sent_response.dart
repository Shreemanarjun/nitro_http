/// The normalised outcome of one request, whichever client produced it.
///
/// Every field here is something all five clients can report. Anything only one
/// of them knows goes in [extras], so the console can surface it without the
/// shared type growing a column per library.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'http_library.dart';
import 'request_spec.dart';

/// Phase timings, where the client can report them.
///
/// Every field is nullable because only `nitro_http` reports the full breakdown;
/// the others report total elapsed time and nothing else. A missing phase is
/// rendered as `—` rather than as zero, which would read as "instant".
@immutable
final class ResponseTimings {
  /// Creates a timing set.
  const ResponseTimings({
    required this.total,
    this.dns,
    this.connect,
    this.tls,
    this.firstByte,
  });

  /// Wall time from send to the last byte. Always present.
  final Duration total;

  /// Name resolution.
  final Duration? dns;

  /// TCP connect.
  final Duration? connect;

  /// TLS handshake.
  final Duration? tls;

  /// Time to the first response byte.
  final Duration? firstByte;
}

/// What went wrong, in terms the console can group and colour.
enum SendFailureKind {
  /// The client refused the spec before touching the network.
  unsupported('Unsupported'),

  /// DNS, connect or TLS failed.
  connection('Connection'),

  /// A timeout fired.
  timeout('Timeout'),

  /// The certificate was rejected.
  certificate('Certificate'),

  /// The caller cancelled it.
  cancelled('Cancelled'),

  /// Anything else.
  unknown('Error');

  const SendFailureKind(this.label);

  /// Human-readable name.
  final String label;
}

/// A request that did not produce a response.
@immutable
final class SendFailure {
  /// Creates a failure.
  const SendFailure({
    required this.kind,
    required this.message,
    this.elapsed = Duration.zero,
  });

  /// The category, used for grouping and colour.
  final SendFailureKind kind;

  /// The message to show. Should be the client's own, not a paraphrase.
  final String message;

  /// How long the attempt took before failing.
  final Duration elapsed;
}

/// A response, or the failure that replaced it.
///
/// A sealed pair rather than a nullable-everything record, so the UI must handle
/// the failure case to compile.
sealed class SendOutcome {
  const SendOutcome({required this.library, required this.spec});

  /// Which client produced this.
  final HttpLibrary library;

  /// The request that produced it.
  final RequestSpec spec;
}

/// A completed response.
final class SentResponse extends SendOutcome {
  /// Creates a response.
  const SentResponse({
    required super.library,
    required super.spec,
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.bodyBytes,
    required this.timings,
    this.httpVersion,
    this.finalUrl,
    this.redirectCount = 0,
    this.fromCache = false,
    this.extras = const <String, String>{},
  });

  /// The status code of the final response.
  final int statusCode;

  /// The reason phrase, empty over HTTP/2 and HTTP/3 which removed it.
  final String reasonPhrase;

  /// Response headers in the order received.
  final List<KeyValueRow> headers;

  /// The body. Empty for a HEAD or a 204.
  final Uint8List bodyBytes;

  /// Phase timings.
  final ResponseTimings timings;

  /// The negotiated protocol, where the client reports it.
  final String? httpVersion;

  /// The URL that answered, after redirects.
  final String? finalUrl;

  /// How many redirects were followed.
  final int redirectCount;

  /// Whether this came from a disk cache.
  final bool fromCache;

  /// Library-specific detail, shown verbatim in the response inspector.
  final Map<String, String> extras;

  /// Size of the body in bytes.
  int get byteCount => bodyBytes.length;

  /// The `Content-Type` header, if any.
  String? get contentType {
    for (final header in headers) {
      if (header.name.toLowerCase() == 'content-type') return header.value;
    }
    return null;
  }

  /// Whether the body looks like text worth showing in a code view.
  ///
  /// Decided from the content type first, then by sniffing for NUL bytes, so an
  /// unlabelled JSON body still renders and a PNG still does not.
  bool get looksTextual {
    final type = contentType?.toLowerCase();
    if (type != null) {
      if (type.startsWith('text/')) return true;
      if (type.contains('json') ||
          type.contains('xml') ||
          type.contains('javascript') ||
          type.contains('x-www-form-urlencoded')) {
        return true;
      }
      if (type.startsWith('image/') ||
          type.startsWith('audio/') ||
          type.startsWith('video/') ||
          type.contains('octet-stream')) {
        return false;
      }
    }
    final sample = bodyBytes.length > 512 ? bodyBytes.sublist(0, 512) : bodyBytes;
    return !sample.contains(0);
  }

  /// The body decoded as UTF-8, tolerating malformed bytes.
  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);

  /// The body pretty-printed when it parses as JSON, else [bodyText].
  String get prettyBody {
    if (!looksTextual) return '';
    final text = bodyText;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } on Object {
      return text;
    }
  }

  /// Whether the status is in the 2xx range.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// A request that failed.
final class FailedSend extends SendOutcome {
  /// Creates a failed outcome.
  const FailedSend({
    required super.library,
    required super.spec,
    required this.failure,
  });

  /// What went wrong.
  final SendFailure failure;
}
