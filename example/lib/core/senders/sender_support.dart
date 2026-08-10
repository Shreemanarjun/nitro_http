/// The parts of a send that are the same whichever client performs it.
///
/// Five senders is five chances to encode a form body, fold a header list or
/// classify a socket error slightly differently — and then the benchmark would
/// be measuring the encoders rather than the clients. Everything that is not
/// genuinely library-specific lives here and is called from all five.
///
/// What is deliberately *not* here: request bodies. Each client has its own body
/// type (`HttpBody.form`, `Request.bodyFields`, `FormData`, …) and exercising it
/// is the point of the comparison, so every sender switches over
/// [RequestBodyKind] itself and only borrows the pieces below.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

// The helpers borrowed here — a form encoder, a MIME sniffer and the multipart
// composer — are pure Dart with no FFI behind them, so taking them costs
// nothing at run time and saves the app a second encoder, a second MIME table
// and a second set of header-injection rules that could disagree with the
// engine's. Every byte still travels over whichever client the sender drives.
import 'package:nitro_http/nitro_http.dart'
    show
        MultipartItem,
        composeMultipart,
        encodeFormFields,
        generateMultipartBoundary,
        guessContentTypeFromPath,
        multipartContentLength;

import '../../server/local_server.dart' show deterministicByteStream;
import '../http_sender.dart';
import '../request_spec.dart';
import '../sent_response.dart';

// ── Request shape ────────────────────────────────────────────────────────────

/// The method token to put on the wire.
///
/// Upper-cased: HTTP methods are case-sensitive and every server spells them in
/// capitals, so a console that sent `get` because that is what the user typed
/// would look broken for a reason invisible on screen. Custom verbs survive —
/// `propfind` becomes `PROPFIND`, not `GET`.
String methodTokenOf(RequestSpec spec) => spec.method.trim().toUpperCase();

/// The request headers folded to one value per name, with the last row winning.
///
/// Case-insensitive, because a user who adds `content-type` below
/// `Content-Type` means to replace it, not to send both.
Map<String, String> headerMapOf(RequestSpec spec) {
  final out = LinkedHashMap<String, String>(
    equals: (String a, String b) => a.toLowerCase() == b.toLowerCase(),
    hashCode: (String key) => key.toLowerCase().hashCode,
  );
  for (final row in spec.effectiveHeaders) {
    out[row.name.trim()] = row.value;
  }
  return out;
}

/// The `Accept-Encoding` value to force, or null to leave the client's default.
///
/// Only the clients with no compression switch of their own need this: asking
/// for `identity` is the portable way to say "do not compress" when the library
/// will not stop advertising gzip on its own.
String? acceptEncodingOverride(RequestSpec spec) =>
    spec.acceptEncoding ? null : 'identity';

/// The `Content-Type` the body should be sent with, or null to leave the
/// client's own default standing.
///
/// [RequestSpec.contentTypeOverride] beats an explicit `Content-Type` header
/// row, which beats the type the body kind implies. That order is the point of
/// the override: it exists so a user can lie about the type of a body the
/// console built for them.
///
/// Multipart is the one kind with no answer here. Its content type carries the
/// boundary, so only the encoder that composed the payload can name it, and
/// every client overwrites whatever you set. Senders therefore skip this for
/// multipart and say so through `capabilities.notes['contentTypeOverride']`.
String? contentTypeOf(RequestSpec spec) {
  final override = spec.contentTypeOverride?.trim();
  if (override != null && override.isNotEmpty) return override;
  for (final row in spec.effectiveHeaders) {
    if (row.name.trim().toLowerCase() == 'content-type') return row.value;
  }
  return defaultContentTypeFor(spec, spec.bodyKind);
}

/// The content type [kind] implies when nobody said otherwise.
String? defaultContentTypeFor(RequestSpec spec, RequestBodyKind kind) =>
    switch (kind) {
      RequestBodyKind.none => null,
      RequestBodyKind.text => 'text/plain; charset=utf-8',
      RequestBodyKind.json => 'application/json; charset=utf-8',
      RequestBodyKind.form => 'application/x-www-form-urlencoded',
      RequestBodyKind.multipart => null,
      RequestBodyKind.generatedBytes => 'application/octet-stream',
      RequestBodyKind.file =>
        guessContentTypeFromPath(spec.filePath ?? '') ??
            'application/octet-stream',
    };

/// The form rows that will actually be sent, as a map.
Map<String, String> formMapOf(RequestSpec spec) => <String, String>{
  for (final row in spec.formFields.where((KeyValueRow r) => r.isUsable))
    row.name.trim(): row.value,
};

/// The form rows encoded as an `application/x-www-form-urlencoded` payload.
///
/// Only needed by clients with no form body type of their own; the rest hand
/// the map over and let the library encode it.
String encodedFormOf(RequestSpec spec) => encodeFormFields(formMapOf(spec));

/// How many bytes [RequestBodyKind.generatedBytes] should produce.
int generatedLengthOf(RequestSpec spec) =>
    spec.generatedByteCount < 0 ? 0 : spec.generatedByteCount;

/// The synthetic payload for [RequestBodyKind.generatedBytes].
///
/// Streamed rather than buffered, and deterministic, for two reasons: asking
/// for a 200 MB body must not need 200 MB of heap, and two libraries uploading
/// "10 MB" have to upload byte-identical 10 MB or the throughput column is
/// comparing payloads instead of clients.
Stream<Uint8List> generatedStreamOf(RequestSpec spec) =>
    deterministicByteStream(generatedLengthOf(spec));

/// The multipart parts that will actually be sent.
Iterable<MultipartPart> enabledParts(RequestSpec spec) => spec.parts.where(
  (MultipartPart part) => part.enabled && part.field.trim().isNotEmpty,
);

/// A hand-encoded `multipart/form-data` payload.
///
/// Only `dart:io`'s `HttpClient` needs this; the other four ship a multipart
/// body type of their own. Composing it from `nitro_http`'s encoder rather than
/// a fifth hand-rolled one is a deliberate call: multipart is where a naive
/// implementation leaks a CRLF out of a user-supplied filename and lets the
/// upload forge an extra part, and that encoder already quotes filenames and
/// streams file parts off disk.
final class MultipartPayload {
  MultipartPayload._(this._items, this._boundary);

  /// Encodes the enabled parts of [spec] under a fresh random boundary.
  factory MultipartPayload.of(RequestSpec spec) => MultipartPayload._(
    <MultipartItem>[
      for (final part in enabledParts(spec))
        if (part.isFile)
          MultipartItem.file(
            part.field,
            part.filePath!,
            contentType: part.contentType,
          )
        else
          MultipartItem.text(part.field, part.value),
    ],
    generateMultipartBoundary(),
  );

  final List<MultipartItem> _items;
  final String _boundary;

  /// The `Content-Type` this payload must be sent with. Carries the boundary,
  /// which is why no other value for it can be honoured.
  String get contentType => 'multipart/form-data; boundary=$_boundary';

  /// The payload, composed lazily. Single-subscription: open it once.
  Stream<List<int>> open() => composeMultipart(_items, _boundary);

  /// The encoded length, or null when a file part cannot be measured — in
  /// which case the caller must fall back to a chunked upload rather than
  /// advertise a `Content-Length` it cannot honour.
  Future<int?> contentLength() => multipartContentLength(_items, _boundary);
}

/// Why [spec] cannot be sent at all, or null when it can.
///
/// Checked before any client is touched so that a missing file reads as
/// [SendFailureKind.unsupported] — the request never happened — instead of as a
/// connection error, which is what a mid-stream `FileSystemException` would
/// otherwise look like.
String? refuseReason(RequestSpec spec) {
  switch (spec.bodyKind) {
    case RequestBodyKind.file:
      final path = spec.filePath;
      if (path == null || path.trim().isEmpty) {
        return 'The body kind is File but no file was chosen.';
      }
      if (!File(path).existsSync()) return 'No file at $path.';
    case RequestBodyKind.multipart:
      for (final part in enabledParts(spec)) {
        if (part.isFile && !File(part.filePath!).existsSync()) {
          return 'Part "${part.field}" points at ${part.filePath}, '
              'which does not exist.';
        }
      }
    case RequestBodyKind.none:
    case RequestBodyKind.text:
    case RequestBodyKind.json:
    case RequestBodyKind.form:
    case RequestBodyKind.generatedBytes:
      break;
  }
  return null;
}

// ── Response shape ───────────────────────────────────────────────────────────

/// Response headers as the shared outcome type wants them.
List<KeyValueRow> headerRowsOf(Iterable<(String, String)> entries) =>
    <KeyValueRow>[
      for (final (name, value) in entries)
        KeyValueRow(name: name, value: value),
    ];

/// Response headers from a client that already folded them into a map.
List<KeyValueRow> headerRowsOfMap(Map<String, String> headers) => <KeyValueRow>[
  for (final MapEntry(:key, :value) in headers.entries)
    KeyValueRow(name: key, value: value),
];

/// Reads [body] into one buffer, reporting progress and honouring [abort].
///
/// Driven through a [StreamIterator] rather than `await for` so the
/// subscription is a value this function can hand to [abort]: cancelling it is
/// what actually tears the socket down mid-body, and without that a cancel
/// during a slow 100 MB download would only stop the *reporting*.
Future<Uint8List> collectBody(
  Stream<List<int>> body, {
  required int sentBytes,
  int? sendTotal,
  int? receiveTotal,
  void Function(SendProgress)? onProgress,
  AbortSignal? abort,
}) async {
  final out = BytesBuilder(copy: false);
  final chunks = StreamIterator<List<int>>(body);
  abort?.also(() => unawaited(chunks.cancel()));
  try {
    while (await chunks.moveNext()) {
      out.add(chunks.current);
      onProgress?.call(
        SendProgress(
          sent: sentBytes,
          received: out.length,
          sendTotal: sendTotal,
          receiveTotal: receiveTotal,
        ),
      );
    }
  } finally {
    await chunks.cancel();
  }
  // A cancelled iterator ends the loop quietly, so the abort has to be turned
  // back into a failure here or a torn-off download would look like a short but
  // successful one.
  final aborted = abort?.kind;
  if (aborted != null) {
    throw SendAborted(
      aborted == SendFailureKind.timeout
          ? 'The response body was still arriving when the total timeout '
                'elapsed; ${out.length} bytes had been read.'
          : 'Cancelled while reading the response body; '
                '${out.length} bytes had been read.',
    );
  }
  return out.takeBytes();
}

// ── Aborting ─────────────────────────────────────────────────────────────────

/// Raised when a transfer was torn down by [AbortSignal] rather than by the
/// peer, so the sender can report the reason it actually had.
final class SendAborted implements Exception {
  /// Creates an abort report.
  const SendAborted(this.message);

  /// What was already transferred, in words the console can show.
  final String message;

  @override
  String toString() => message;
}

/// One-shot abort for a request, fired by a deadline or by the caller.
///
/// A `totalTimeout` and a `cancel` future end the same way in every client —
/// trip a cancel token, abort a socket, drop a subscription — and both then
/// surface as whatever error that client raises when its transfer is pulled out
/// from under it. Recording *which* fired is what lets a sender report
/// `timeout` or `cancelled` instead of the client's misleading
/// "connection closed by peer".
final class AbortSignal {
  /// Arms the signal. [onAbort] runs at most once, as do any actions added
  /// later through [also].
  AbortSignal({
    required void Function() onAbort,
    Duration? after,
    Future<void>? cancel,
  }) {
    _actions.add(onAbort);
    final deadline = after;
    if (deadline != null && deadline > Duration.zero) {
      _timer = Timer(deadline, () => _fire(timedOut: true));
    }
    // A cancel future that completes with an error still means "stop", and
    // leaving that error unobserved would make it unhandled in the caller's
    // zone.
    unawaited(
      cancel?.then<void>(
        (void _) => _fire(cancelled: true),
        onError: (Object _) => _fire(cancelled: true),
      ),
    );
  }

  final List<void Function()> _actions = <void Function()>[];
  Timer? _timer;
  bool _fired = false;
  bool _finished = false;
  bool _timedOut = false;
  bool _cancelled = false;

  /// Whether the deadline fired.
  bool get timedOut => _timedOut;

  /// Whether the caller's cancel future fired.
  bool get cancelled => _cancelled;

  /// The failure kind an abort should be reported as, or null if none fired.
  SendFailureKind? get kind => _timedOut
      ? SendFailureKind.timeout
      : _cancelled
      ? SendFailureKind.cancelled
      : null;

  /// Registers another teardown action.
  ///
  /// Requests acquire things to abort as they progress — a socket, then a
  /// response subscription — so the list grows after the signal is armed. An
  /// action added after the signal already fired runs immediately, which is
  /// what stops a late subscription from surviving its own cancellation.
  void also(void Function() action) {
    if (_finished) return;
    if (_fired) {
      action();
      return;
    }
    _actions.add(action);
  }

  void _fire({bool timedOut = false, bool cancelled = false}) {
    if (_fired || _finished) return;
    _fired = true;
    _timedOut = timedOut;
    _cancelled = cancelled;
    _timer?.cancel();
    for (final action in _actions) {
      // One client refusing to be torn down must not stop the others from
      // being torn down, and none of it should escape into the caller's zone.
      try {
        action();
      } on Object {
        continue;
      }
    }
  }

  /// Disarms the signal once the request is over. Safe to call twice.
  void finish() {
    _finished = true;
    _timer?.cancel();
    _timer = null;
    _actions.clear();
  }
}

// ── Failure classification ───────────────────────────────────────────────────

/// Classifies a `dart:io` transport failure.
///
/// Shared by the three senders that ultimately sit on `dart:io` sockets, so
/// `package:http`'s `ClientException` wrapper and `dio`'s `error` payload land
/// in the same buckets as raw `HttpClient` does. Anything else would make the
/// comparison table lie: one refused connection must not read as "Connection"
/// under one library and "Error" under another.
SendFailureKind classifyIoFailure(Object error) {
  if (error is TimeoutException) return SendFailureKind.timeout;
  if (error is CertificateException) return SendFailureKind.certificate;
  if (error is HandshakeException) {
    // A handshake fails either because the chain was rejected or because the
    // peer is not speaking TLS at all; only the first is a certificate problem.
    return error.toString().toLowerCase().contains('certificate')
        ? SendFailureKind.certificate
        : SendFailureKind.connection;
  }
  if (error is TlsException) return SendFailureKind.certificate;
  if (error is SocketException) return SendFailureKind.connection;
  // A body the sender could not read off disk means the request was never
  // viable, not that the network failed.
  if (error is FileSystemException) return SendFailureKind.unsupported;
  if (error is HttpException) {
    // `dart:io` raises this both for a truncated response and for exceeding the
    // redirect limit. The first is a dead connection; the second is a policy
    // decision, which has no bucket of its own.
    return error.message.toLowerCase().contains('redirect')
        ? SendFailureKind.unknown
        : SendFailureKind.connection;
  }
  return SendFailureKind.unknown;
}

// ── Cookies ──────────────────────────────────────────────────────────────────

/// An in-memory cookie jar for the clients that ship without one.
///
/// `dart:io`'s `HttpClient`, `package:http` and `dio` all expose cookies on the
/// request and on the response and then store nothing in between: a
/// `Set-Cookie` is dropped the moment the response is read, and the next
/// request goes out bare. `nitro_http` and `rhttp` both keep a real jar, so
/// without this the console's cookie switch would do something under two
/// libraries out of five.
///
/// Scope is deliberately RFC 6265's common path and no more — host and domain
/// matching, path prefixes, `Secure`, and expiry — which is what the demo
/// server's `/setcookie` and `/readcookie` exercise.
final class CookieJar {
  final List<Cookie> _cookies = <Cookie>[];

  /// The `Cookie` header value for [url], or null when nothing matches.
  String? headerFor(Uri url) {
    _evictExpired();
    final matched = <String>[
      for (final cookie in _cookies)
        if (_matches(cookie, url)) '${cookie.name}=${cookie.value}',
    ];
    return matched.isEmpty ? null : matched.join('; ');
  }

  /// Stores every `Set-Cookie` value from a response and reports how many were
  /// kept.
  ///
  /// A malformed cookie is skipped rather than failing the send: one bad
  /// `Set-Cookie` should not cost you the response it came with.
  int store(Uri url, Iterable<String> setCookieValues) {
    var stored = 0;
    for (final raw in setCookieValues) {
      final Cookie cookie;
      try {
        cookie = Cookie.fromSetCookieValue(raw);
      } on Exception {
        continue;
      }
      cookie.domain ??= url.host;
      cookie.path ??= _directoryOf(url.path);
      _cookies.removeWhere(
        (Cookie existing) =>
            existing.name == cookie.name &&
            existing.domain == cookie.domain &&
            existing.path == cookie.path,
      );
      // A cookie dated in the past is a deletion instruction, not a cookie.
      final expiry = cookie.expires;
      final maxAge = cookie.maxAge;
      final isDeletion =
          (expiry != null && expiry.isBefore(DateTime.now())) ||
          (maxAge != null && maxAge <= 0);
      if (!isDeletion) {
        _cookies.add(cookie);
        stored++;
      }
    }
    return stored;
  }

  /// How many cookies are held.
  int get length => _cookies.length;

  /// Empties the jar.
  void clear() => _cookies.clear();

  void _evictExpired() {
    final now = DateTime.now();
    _cookies.removeWhere((Cookie cookie) {
      final expires = cookie.expires;
      return expires != null && expires.isBefore(now);
    });
  }

  static bool _matches(Cookie cookie, Uri url) {
    if (cookie.secure && url.scheme != 'https') return false;
    final domain = cookie.domain;
    if (domain != null) {
      final host = url.host.toLowerCase();
      final want = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      if (host != want && !host.endsWith('.$want')) return false;
    }
    final path = cookie.path;
    if (path != null && path.isNotEmpty && path != '/') {
      final target = url.path.isEmpty ? '/' : url.path;
      final prefix = path.endsWith('/') ? path : '$path/';
      if (target != path && !target.startsWith(prefix)) return false;
    }
    return true;
  }

  static String _directoryOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }
}
