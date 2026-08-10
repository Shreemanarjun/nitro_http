/// Request body representations and their encoders.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A request payload.
///
/// Every variant is a `const`-constructible value so a body can be built at
/// compile time and shared. Nothing here touches the network: the runner turns
/// a body into either an in-memory buffer, a file path handed straight to the
/// native engine, or a stream that is pumped chunk by chunk.
sealed class HttpBody {
  /// Const-constructible base for the body variants.
  const HttpBody();

  /// A UTF-8 text payload.
  const factory HttpBody.text(String text, {String? contentType}) = HttpTextBody;

  /// A payload encoded as JSON with `dart:convert`.
  const factory HttpBody.json(Object? json) = HttpJsonBody;

  /// A raw byte payload.
  const factory HttpBody.bytes(Uint8List bytes, {String? contentType}) =
      HttpBytesBody;

  /// An `application/x-www-form-urlencoded` payload.
  const factory HttpBody.form(Map<String, String> fields) = HttpFormBody;

  /// A `multipart/form-data` payload.
  const factory HttpBody.multipart(
    List<MultipartItem> parts, {
    String? boundary,
  }) = HttpMultipartBody;

  /// A streamed payload of unknown or known length.
  const factory HttpBody.stream(
    Stream<List<int>> stream, {
    int? contentLength,
    String? contentType,
  }) = HttpStreamBody;

  /// A payload read directly from a file by the native engine.
  const factory HttpBody.file(String path, {String? contentType}) =
      HttpFileBody;

  /// The `Content-Type` to use when the caller did not set one explicitly.
  ///
  /// `null` means "the body cannot say" — the caller sniffs the file
  /// extension, or sends the payload without a content type at all.
  String? get defaultContentType;
}

/// A textual body, encoded as UTF-8 on the wire.
final class HttpTextBody extends HttpBody {
  /// Creates a text body, optionally overriding the content type.
  const HttpTextBody(this.text, {this.contentType});

  /// The text to send.
  final String text;

  /// An explicit content type, or `null` to use [defaultContentType].
  final String? contentType;

  @override
  String? get defaultContentType => contentType ?? 'text/plain; charset=utf-8';
}

/// A body serialised with `jsonEncode`.
final class HttpJsonBody extends HttpBody {
  /// Creates a JSON body from any `jsonEncode`-able value.
  const HttpJsonBody(this.json);

  /// The value to encode. May be a map, a list, a primitive, or `null`.
  final Object? json;

  @override
  String? get defaultContentType => 'application/json; charset=utf-8';
}

/// A raw byte body.
final class HttpBytesBody extends HttpBody {
  /// Creates a byte body, optionally overriding the content type.
  const HttpBytesBody(this.bytes, {this.contentType});

  /// The bytes to send.
  final Uint8List bytes;

  /// An explicit content type, or `null` to use [defaultContentType].
  final String? contentType;

  @override
  String? get defaultContentType => contentType ?? 'application/octet-stream';
}

/// An `application/x-www-form-urlencoded` body.
final class HttpFormBody extends HttpBody {
  /// Creates a form body from [fields].
  const HttpFormBody(this.fields);

  /// The form fields, encoded in iteration order.
  final Map<String, String> fields;

  /// The encoded payload, ready to be UTF-8 encoded onto the wire.
  String encode() => encodeFormFields(fields);

  @override
  String? get defaultContentType => 'application/x-www-form-urlencoded';
}

/// Per-instance boundaries for multipart bodies that did not specify one.
///
/// [HttpMultipartBody] is `const`-constructible, so it cannot cache a lazily
/// generated boundary in a field. The boundary must nevertheless be stable for
/// the lifetime of the body: the value used in the `Content-Type` header has
/// to be the same one used to compose the payload, or the request is garbage.
final Expando<String> _generatedBoundaries = Expando<String>(
  'nitro_http multipart boundary',
);

/// A `multipart/form-data` body.
final class HttpMultipartBody extends HttpBody {
  /// Creates a multipart body from [parts].
  ///
  /// When [boundary] is omitted a cryptographically random one is generated on
  /// first use and reused for the lifetime of this instance.
  const HttpMultipartBody(this.parts, {this.boundary});

  /// The parts to send, in order.
  final List<MultipartItem> parts;

  /// The caller-supplied boundary, or `null` to generate one.
  final String? boundary;

  /// The boundary actually used to compose this body.
  ///
  /// Stable across calls, so composing the payload and building the
  /// `Content-Type` header cannot disagree.
  String get effectiveBoundary =>
      boundary ?? (_generatedBoundaries[this] ??= generateMultipartBoundary());

  /// Streams this body using [effectiveBoundary].
  Stream<List<int>> compose() => composeMultipart(parts, effectiveBoundary);

  /// The total encoded length, or `null` when a file part is unreadable.
  Future<int?> computeContentLength() =>
      multipartContentLength(parts, effectiveBoundary);

  @override
  String? get defaultContentType =>
      'multipart/form-data; boundary=$effectiveBoundary';
}

/// A body pumped from a Dart stream.
final class HttpStreamBody extends HttpBody {
  /// Creates a streamed body.
  ///
  /// Supply [contentLength] when it is known; otherwise the request is sent
  /// with `Transfer-Encoding: chunked`.
  const HttpStreamBody(this.stream, {this.contentLength, this.contentType});

  /// The source of body bytes. Consumed exactly once.
  final Stream<List<int>> stream;

  /// The total length in bytes, or `null` when unknown.
  final int? contentLength;

  /// An explicit content type, or `null` to leave it unset.
  final String? contentType;

  @override
  String? get defaultContentType => contentType;
}

/// A body read straight off disk by the native engine.
///
/// The file is never loaded into the Dart heap, so uploading a multi-gigabyte
/// asset costs a file descriptor and nothing else.
final class HttpFileBody extends HttpBody {
  /// Creates a file body for the file at [path].
  const HttpFileBody(this.path, {this.contentType});

  /// Absolute or relative path to the file to upload.
  final String path;

  /// An explicit content type, or `null` to sniff it from the extension.
  final String? contentType;

  /// The content type to use, sniffing [path] when none was supplied.
  String? get resolvedContentType =>
      contentType ?? guessContentTypeFromPath(path);

  @override
  String? get defaultContentType => contentType;
}

/// One part of a [HttpMultipartBody].
sealed class MultipartItem {
  /// Const-constructible base carrying the form field name.
  const MultipartItem(this.field);

  /// A text part.
  const factory MultipartItem.text(String field, String value) =
      MultipartTextItem;

  /// A part carrying in-memory bytes.
  const factory MultipartItem.bytes(
    String field,
    Uint8List bytes, {
    String? filename,
    String? contentType,
  }) = MultipartBytesItem;

  /// A part streamed from a file on disk.
  const factory MultipartItem.file(
    String field,
    String path, {
    String? filename,
    String? contentType,
  }) = MultipartFileItem;

  /// The form field name, sent as the `name` parameter of
  /// `Content-Disposition`.
  final String field;

  /// The `filename` parameter, or `null` when the part is not a file.
  String? get filename => null;

  /// An explicit part content type, or `null`.
  String? get contentType => null;
}

/// A plain text form field.
final class MultipartTextItem extends MultipartItem {
  /// Creates a text field named [field] holding [value].
  const MultipartTextItem(super.field, this.value);

  /// The field value, sent as UTF-8.
  final String value;
}

/// A form field whose content is an in-memory byte buffer.
final class MultipartBytesItem extends MultipartItem {
  /// Creates a byte field named [field].
  const MultipartBytesItem(
    super.field,
    this.bytes, {
    this.filename,
    this.contentType,
  });

  /// The bytes to send.
  final Uint8List bytes;

  @override
  final String? filename;

  @override
  final String? contentType;
}

/// A form field whose content is streamed from a file.
final class MultipartFileItem extends MultipartItem {
  /// Creates a file field named [field] reading from [path].
  const MultipartFileItem(
    super.field,
    this.path, {
    this.filename,
    this.contentType,
  });

  /// Path to the file to stream.
  final String path;

  @override
  final String? filename;

  @override
  final String? contentType;

  /// The filename advertised to the server: the explicit one, else the last
  /// path segment.
  String get effectiveFilename => filename ?? _basename(path);
}

/// Encodes [fields] as an `application/x-www-form-urlencoded` payload.
///
/// Follows the HTML form rules: UTF-8 percent-encoding with a space written as
/// `+`, pairs joined with `&`.
String encodeFormFields(Map<String, String> fields) {
  final buffer = StringBuffer();
  var first = true;
  fields.forEach((key, value) {
    if (!first) buffer.write('&');
    first = false;
    buffer
      ..write(Uri.encodeQueryComponent(key))
      ..write('=')
      ..write(Uri.encodeQueryComponent(value));
  });
  return buffer.toString();
}

/// Characters allowed in a generated boundary.
///
/// Restricted to the unreserved URI set so the boundary is safe inside a
/// header parameter without quoting, and cannot terminate the parameter early.
const String _boundaryAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/// Generates a random `multipart/form-data` boundary.
///
/// The boundary must not occur anywhere in the payload. Since parts can carry
/// attacker-controlled bytes, the value is drawn from a secure RNG when the
/// platform provides one — a guessable boundary would let a hostile upload
/// forge extra form parts.
String generateMultipartBoundary() {
  Random random;
  try {
    random = Random.secure();
  } on UnsupportedError {
    random = Random();
  }
  final chars = List<String>.generate(
    32,
    (_) => _boundaryAlphabet[random.nextInt(_boundaryAlphabet.length)],
    growable: false,
  );
  return 'nitroHttpBoundary${chars.join()}';
}

/// Streams [parts] as a `multipart/form-data` payload delimited by [boundary].
///
/// File parts are read incrementally with `File.openRead`, so a 500 MB
/// attachment never materialises in the Dart heap. The returned stream is
/// single-subscription and reads each file only when the consumer asks for it.
Stream<List<int>> composeMultipart(
  List<MultipartItem> parts,
  String boundary,
) async* {
  const crlf = [13, 10];
  for (final part in parts) {
    yield utf8.encode('--$boundary\r\n${_partHeaders(part)}');
    switch (part) {
      case MultipartTextItem(:final value):
        yield utf8.encode(value);
      case MultipartBytesItem(:final bytes):
        yield bytes;
      case MultipartFileItem(:final path):
        yield* File(path).openRead();
    }
    yield crlf;
  }
  yield utf8.encode('--$boundary--\r\n');
}

/// The total encoded length of [parts] under [boundary], or `null` when it
/// cannot be determined.
///
/// A `null` result means at least one file part is missing or unreadable, in
/// which case the caller must fall back to a chunked upload instead of
/// advertising a `Content-Length` it cannot honour.
Future<int?> multipartContentLength(
  List<MultipartItem> parts,
  String boundary,
) async {
  var total = 0;
  for (final part in parts) {
    total += utf8.encode('--$boundary\r\n${_partHeaders(part)}').length;
    switch (part) {
      case MultipartTextItem(:final value):
        total += utf8.encode(value).length;
      case MultipartBytesItem(:final bytes):
        total += bytes.length;
      case MultipartFileItem(:final path):
        final file = File(path);
        try {
          if (!await file.exists()) return null;
          total += await file.length();
        } on FileSystemException {
          return null;
        }
    }
    total += 2; // The CRLF that terminates the part body.
  }
  return total + utf8.encode('--$boundary--\r\n').length;
}

/// Guesses a content type from the extension of [path], or `null`.
///
/// Deliberately small and honest: the common web and media types, nothing
/// more. Callers that need a full database should supply the type themselves.
String? guessContentTypeFromPath(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return switch (name.substring(dot + 1).toLowerCase()) {
    'json' => 'application/json',
    'txt' => 'text/plain; charset=utf-8',
    'html' || 'htm' => 'text/html; charset=utf-8',
    'css' => 'text/css; charset=utf-8',
    'js' || 'mjs' => 'text/javascript; charset=utf-8',
    'csv' => 'text/csv; charset=utf-8',
    'xml' => 'application/xml',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'zip' => 'application/zip',
    'gz' => 'application/gzip',
    'mp4' => 'video/mp4',
    'mp3' => 'audio/mpeg',
    'wasm' => 'application/wasm',
    // Required: the subject is an arbitrary filename extension, not a closed
    // type; an unknown one means "no opinion".
    _ => null,
  };
}

/// The header block of one part, terminated by the blank line before its body.
String _partHeaders(MultipartItem part) {
  final buffer = StringBuffer('Content-Disposition: form-data; name="')
    ..write(_quoteHeaderParameter(part.field))
    ..write('"');
  final filename = switch (part) {
    MultipartTextItem() => null,
    MultipartBytesItem(:final filename) => filename,
    MultipartFileItem() => part.effectiveFilename,
  };
  if (filename != null) {
    buffer
      ..write('; filename="')
      ..write(_quoteHeaderParameter(filename))
      ..write('"');
  }
  buffer.write('\r\n');
  final contentType = _effectiveContentType(part);
  if (contentType != null) {
    buffer.write('Content-Type: $contentType\r\n');
  }
  buffer.write('\r\n');
  return buffer.toString();
}

/// The content type advertised for [part], or `null` to omit the header.
///
/// Text fields go out bare, matching what browsers send. Anything with a
/// filename gets at least `application/octet-stream`, because a server that
/// sees no type for a file part usually rejects it.
String? _effectiveContentType(MultipartItem part) => switch (part) {
  MultipartTextItem() => part.contentType,
  MultipartBytesItem() =>
    part.contentType ??
        (part.filename == null ? null : 'application/octet-stream'),
  MultipartFileItem() =>
    part.contentType ??
        guessContentTypeFromPath(part.path) ??
        'application/octet-stream',
};

/// Makes [value] safe inside a quoted header parameter.
///
/// CR, LF and other control characters are dropped outright: a filename is
/// frequently user-supplied, and letting one carry a newline lets it inject
/// arbitrary headers or a whole extra part into the request.
String _quoteHeaderParameter(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune < 0x20 || rune == 0x7f) continue;
    if (rune == 0x22 || rune == 0x5c) buffer.write(r'\');
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

/// The last segment of [path], handling both POSIX and Windows separators.
String _basename(String path) {
  var cut = -1;
  for (var i = path.length - 1; i >= 0; i--) {
    final unit = path.codeUnitAt(i);
    if (unit == 0x2f || unit == 0x5c) {
      cut = i;
      break;
    }
  }
  return cut < 0 ? path : path.substring(cut + 1);
}
