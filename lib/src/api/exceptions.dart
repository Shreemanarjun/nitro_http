/// The exception hierarchy thrown by the client.
library;

import 'dart:typed_data';

import 'headers.dart';
import 'request.dart';

/// Which phase of a transfer ran out of time.
enum TimeoutStage {
  /// The connection (DNS, TCP, TLS) was not established in time.
  connect,

  /// The whole request did not finish within the overall deadline.
  request,

  /// The connection stalled: no bytes moved for the idle timeout.
  idle,
}

/// Why a connection could not be established or could not be kept.
enum ConnectionFailure {
  /// The host name did not resolve.
  dns,

  /// The peer actively refused the connection.
  refused,

  /// An established connection was reset by the peer.
  reset,

  /// The connection failed for a reason the engine could not classify.
  failed,

  /// The proxy could not be reached or refused to relay.
  proxy,

  /// The URL scheme is not one the engine can speak.
  unsupportedScheme,

  /// Sending request bytes failed mid-transfer.
  send,

  /// Receiving response bytes failed mid-transfer.
  receive,
}

/// Base class for everything `nitro_http` throws.
///
/// Sealed, so a `switch` over a caught exception is exhaustively checked.
/// A non-2xx response is *not* an error at this layer — it only becomes a
/// [NitroHttpStatusCodeException] when the client is configured to throw.
sealed class NitroHttpException implements Exception {
  /// Creates an exception.
  ///
  /// [message] overrides the automatically composed sentence; leave it `null`
  /// to get one describing the failure, the target URL, and the engine's own
  /// diagnostic text.
  NitroHttpException({
    this.request,
    this._message,
    this.engineMessage,
    this.engineErrorCode = 0,
  });


  /// The request that failed, when the failure happened after one was built.
  final HttpRequest? request;

  /// The native engine's own description of the failure, when it supplied one.
  final String? engineMessage;

  /// The raw `CURLcode` behind the failure, or `0` when there is none.
  ///
  /// Diagnostics only — behaviour must never branch on this value; branch on
  /// the exception type instead.
  final int engineErrorCode;

  final String? _message;

  StackTrace? _stackTrace;

  /// The stack trace captured where the failure surfaced, when available.
  ///
  /// An error crossing the FFI boundary has no useful Dart trace of its own,
  /// so the runner attaches the caller's trace before rethrowing.
  StackTrace? get stackTrace => _stackTrace;

  /// Attaches [value] once. Later assignments are ignored, so the trace
  /// closest to the original failure survives interceptor rethrows.
  set stackTrace(StackTrace? value) => _stackTrace ??= value;

  /// A human-readable description of the failure.
  String get message => _message ?? '${_describe()}$_target$_engineSuffix';

  /// The type-specific part of [message]: what went wrong, without the URL or
  /// the engine's text, both of which the base class appends.
  String _describe();

  String get _target {
    final failed = request;
    return failed == null ? '' : ' for ${failed.methodLabel} ${failed.url}';
  }

  String get _engineSuffix {
    final detail = engineMessage?.trim();
    final hasDetail = detail != null && detail.isNotEmpty;
    if (hasDetail && engineErrorCode != 0) {
      return ' ($detail; engine code $engineErrorCode)';
    }
    if (hasDetail) return ' ($detail)';
    if (engineErrorCode != 0) return ' (engine code $engineErrorCode)';
    return '';
  }

  @override
  String toString() => '$runtimeType: $message';
}

/// A transfer exceeded one of its deadlines.
final class NitroHttpTimeoutException extends NitroHttpException {
  /// Creates a timeout for [stage].
  NitroHttpTimeoutException({
    required this.stage,
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  /// Which deadline fired.
  final TimeoutStage stage;

  @override
  String _describe() => switch (stage) {
    TimeoutStage.connect => 'Timed out connecting',
    TimeoutStage.request => 'Request timed out',
    TimeoutStage.idle => 'Timed out waiting for data',
  };
}

/// The request was cancelled through its `CancelToken`, or by client disposal.
final class NitroHttpCancelException extends NitroHttpException {
  /// Creates a cancellation, optionally carrying the caller's [reason].
  NitroHttpCancelException({
    this.reason,
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  /// The reason passed to `CancelToken.cancel`, when one was given.
  final String? reason;

  @override
  String _describe() =>
      reason == null ? 'Request cancelled' : 'Request cancelled: $reason';
}

/// The server answered with a status code the client was told to reject.
///
/// Thrown only when `throwOnStatusCode` is enabled. The full response is
/// carried so error bodies — the part of an API that actually explains what
/// went wrong — are never lost.
final class NitroHttpStatusCodeException extends NitroHttpException {
  /// Creates a status-code failure from the received response parts.
  NitroHttpStatusCodeException({
    required this.statusCode,
    required this.headers,
    required this.body,
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  /// The rejected status code.
  final int statusCode;

  /// The response headers as received.
  final HttpHeaders headers;

  /// The response body as received, undecoded.
  final Uint8List body;

  @override
  String _describe() => 'Server returned status $statusCode';
}

/// The peer's TLS certificate was rejected.
/// The TLS handshake itself failed, before any certificate was judged.
///
/// Distinct from [NitroHttpCertificateException] on purpose: a chain that is
/// untrusted, expired or mispinned is a *trust* decision the caller can often
/// act on, whereas this means the two ends could not agree on how to talk at
/// all — no shared protocol version or cipher suite. Clamping
/// `TlsSettings.minVersion` above what a server offers lands here, and
/// reporting it as a certificate problem sends the reader looking in entirely
/// the wrong place.
final class NitroHttpTlsException extends NitroHttpException {
  /// Creates a handshake failure.
  NitroHttpTlsException({
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  @override
  String _describe() => 'TLS handshake failed';
}

/// The request was rejected before it reached the network because its
/// configuration cannot be satisfied.
///
/// A programming error rather than a transport failure: a PEM with no
/// certificate in it, a TLS version the linked backend does not know, or
/// `RootCaSource.none` with no pin to authenticate against. These used to
/// surface as [NitroHttpUnknownException], which reads like a transient fault
/// and invites a retry that can never succeed.
final class NitroHttpConfigurationException extends NitroHttpException {
  /// Creates a configuration rejection.
  NitroHttpConfigurationException({
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  @override
  String _describe() => 'Request configuration was rejected';
}

final class NitroHttpCertificateException extends NitroHttpException {
  /// Creates a certificate failure.
  NitroHttpCertificateException({
    required this.isPinMismatch,
    required this.isClientAuthFailure,
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  /// Whether the certificate was valid but did not match a configured SPKI
  /// pin — a distinct situation from an untrusted chain, and usually means
  /// either an active interception attempt or a rotated key with a stale pin.
  final bool isPinMismatch;

  /// Whether the *client* certificate was the problem, not the server's.
  final bool isClientAuthFailure;

  @override
  String _describe() {
    if (isPinMismatch) return 'Certificate did not match the configured pin';
    if (isClientAuthFailure) return 'Client certificate was rejected';
    return 'Server certificate was rejected';
  }
}

/// The connection could not be established, or died mid-transfer.
final class NitroHttpConnectionException extends NitroHttpException {
  /// Creates a connection failure of kind [failure].
  NitroHttpConnectionException({
    required this.failure,
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  /// What exactly went wrong at the transport level.
  final ConnectionFailure failure;

  @override
  String _describe() => switch (failure) {
    ConnectionFailure.dns => 'Could not resolve host',
    ConnectionFailure.refused => 'Connection refused',
    ConnectionFailure.reset => 'Connection reset by peer',
    ConnectionFailure.failed => 'Connection failed',
    ConnectionFailure.proxy => 'Proxy connection failed',
    ConnectionFailure.unsupportedScheme => 'Unsupported URL scheme',
    ConnectionFailure.send => 'Failed while sending the request',
    ConnectionFailure.receive => 'Failed while receiving the response',
  };
}

/// The redirect chain exceeded the configured limit.
final class NitroHttpRedirectException extends NitroHttpException {
  /// Creates a redirect failure after [redirectCount] hops.
  NitroHttpRedirectException({
    required this.redirectCount,
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  /// How many redirects were followed before giving up.
  final int redirectCount;

  @override
  String _describe() => 'Too many redirects after $redirectCount hops';
}

/// The peer spoke something that is not valid HTTP.
final class NitroHttpProtocolException extends NitroHttpException {
  /// Creates a protocol violation failure.
  NitroHttpProtocolException({
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  @override
  String _describe() => 'Protocol error';
}

/// The response body could not be decoded.
///
/// Covers a broken content encoding as well as malformed JSON from
/// `HttpTextResponse.bodyToJson`.
final class NitroHttpDecodingException extends NitroHttpException {
  /// Creates a decoding failure.
  NitroHttpDecodingException({
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  @override
  String _describe() => 'Could not decode the response body';
}

/// `CacheMode.onlyIfCached` was requested and nothing usable was cached.
final class NitroHttpCacheMissException extends NitroHttpException {
  /// Creates a cache-miss failure.
  NitroHttpCacheMissException({
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  @override
  String _describe() => 'No cached response available';
}

/// The client, or the whole engine, was disposed before the request finished.
final class NitroHttpDisposedException extends NitroHttpException {
  /// Creates a disposal failure.
  NitroHttpDisposedException({
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  @override
  String _describe() => 'The client was disposed';
}

/// A failure the engine could not classify.
///
/// [engineErrorCode] carries the raw `CURLcode`, which is the only handle on
/// what actually happened.
final class NitroHttpUnknownException extends NitroHttpException {
  /// Creates an unclassified failure.
  NitroHttpUnknownException({
    super.request,
    super.message,
    super.engineMessage,
    super.engineErrorCode,
  });

  @override
  String _describe() => 'Request failed';
}
