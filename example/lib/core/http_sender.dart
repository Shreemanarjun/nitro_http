/// The seam every HTTP library is reached through.
///
/// One interface, five implementations, and both the request console and the
/// benchmark drive it. That is what makes "switch the library and send the same
/// request" a one-line change rather than a per-library code path in the UI.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'http_library.dart';
import 'request_spec.dart';
import 'sent_response.dart';

/// What a given client can and cannot do.
///
/// Declared rather than discovered, because the alternative is a UI that offers
/// every control for every library and then silently drops the ones a client
/// ignores. A greyed-out control with a reason attached is honest; a control that
/// does nothing is a lie.
@immutable
final class SenderCapabilities {
  /// Creates a capability set. Everything defaults to supported; an
  /// implementation lists only what it cannot do.
  const SenderCapabilities({
    this.customMethods = true,
    this.streamedResponses = true,
    this.multipart = true,
    this.fileBodyWithoutHeap = false,
    this.perRequestConnectTimeout = true,
    this.perRequestTotalTimeout = true,
    this.redirectPolicy = true,
    this.cookieJar = true,
    this.phaseTimings = false,
    this.diskCache = false,
    this.notes = const <String, String>{},
  });

  /// Whether a verb outside the common set is accepted.
  final bool customMethods;

  /// Whether the response body can be consumed as a stream.
  final bool streamedResponses;

  /// Whether `multipart/form-data` is supported.
  final bool multipart;

  /// Whether a file body is streamed from disk without a Dart-heap copy.
  final bool fileBodyWithoutHeap;

  /// Whether a connect timeout can be set per request.
  final bool perRequestConnectTimeout;

  /// Whether a whole-request timeout can be set per request.
  final bool perRequestTotalTimeout;

  /// Whether redirect following and its limit are controllable.
  final bool redirectPolicy;

  /// Whether the client keeps a cookie jar.
  final bool cookieJar;

  /// Whether DNS/connect/TLS/TTFB are reported separately.
  final bool phaseTimings;

  /// Whether the client has an HTTP disk cache.
  final bool diskCache;

  /// Why a capability is missing, keyed by the field name it explains.
  ///
  /// Surfaced as the tooltip on a disabled control, so a reader learns the actual
  /// limitation instead of wondering whether the app is broken.
  final Map<String, String> notes;

  /// The explanation for [field], if one was given.
  String? noteFor(String field) => notes[field];
}

/// Progress while a body is moving, for the console's progress bars.
@immutable
final class SendProgress {
  /// Creates a progress sample.
  const SendProgress({
    required this.sent,
    required this.received,
    this.sendTotal,
    this.receiveTotal,
  });

  /// Request bytes handed to the socket so far.
  final int sent;

  /// Response bytes received so far.
  final int received;

  /// Expected request size, when known.
  final int? sendTotal;

  /// Expected response size, when known.
  final int? receiveTotal;
}

/// Sends a [RequestSpec] through one library.
///
/// Implementations MUST:
/// - never throw from [send]; return a [FailedSend] instead, so one library
///   failing cannot abort a benchmark row or take down the console;
/// - report the client's own error text in [SendFailure.message] rather than a
///   paraphrase, because the whole point of switching libraries is to compare
///   what each one says;
/// - honour every field they advertise in [capabilities] and ignore only the ones
///   they do not.
abstract interface class HttpSender {
  /// Which library this is.
  HttpLibrary get library;

  /// What this library can do.
  SenderCapabilities get capabilities;

  /// Issues [spec] and returns its outcome.
  ///
  /// [baseUrl] resolves a bare path in [RequestSpec.url]. [onProgress] is
  /// optional and may be called many times a second, so callers should coalesce.
  /// [cancel] completing aborts the transfer where the client supports it.
  Future<SendOutcome> send(
    RequestSpec spec, {
    required String baseUrl,
    void Function(SendProgress)? onProgress,
    Future<void>? cancel,
  });

  /// Releases the client's connections. Safe to call twice.
  Future<void> close();
}

/// Builds a sender for [library].
///
/// A typedef rather than a switch inside the UI, so the registry is the only
/// place that knows every implementation.
typedef SenderFactory = HttpSender Function();
