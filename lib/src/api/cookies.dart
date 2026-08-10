/// Pure-Dart cookie value type, `Set-Cookie` parsing, and the [CookieJar]
/// abstraction.
///
/// The engine's native libcurl jar is the default cookie store — it is faster
/// and it survives redirects inside a single transfer, which a Dart-side jar
/// cannot observe. Everything here exists for tests and for applications that
/// want to own cookie policy in Dart.
library;

/// A single HTTP cookie.
///
/// This is a value type: two cookies with identical fields are equal. It
/// deliberately models only the attributes libcurl's Netscape jar can round
/// trip (`SameSite`, `Priority` and `Partitioned` have no jar representation
/// and are dropped by [parseSetCookie]).
final class Cookie {
  /// Creates a cookie.
  ///
  /// [domain] and [path] should be the *resolved* scope — a [CookieJar] fills
  /// them in from the request URL when a `Set-Cookie` header omits them.
  const Cookie({
    required this.name,
    required this.value,
    this.domain = '',
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
  });

  /// Cookie name, case-sensitive, sent verbatim in the `Cookie:` header.
  final String name;

  /// Cookie value, sent verbatim. Never quoted or percent-encoded here.
  final String value;

  /// Host scope with any leading dot stripped, lower-cased.
  ///
  /// An empty domain is *unscoped*: [matches] returns `false` for it, because
  /// silently broadening a cookie to every host is a credential leak. Jars
  /// assign the request host on save.
  final String domain;

  /// Path scope. Matched as a prefix at a `/` boundary by [matches].
  final String path;

  /// Absolute expiry in UTC, or `null` for a session cookie.
  ///
  /// A `Max-Age` attribute is resolved against the parse time and stored here,
  /// so the distinction between the two wire forms does not survive parsing.
  final DateTime? expires;

  /// When `true` the cookie is only sent over `https`.
  final bool secure;

  /// When `true` the cookie is hidden from scripting environments.
  ///
  /// Carried for fidelity when persisting a jar; it has no effect on [matches].
  final bool httpOnly;

  /// Parses one `Set-Cookie` header value.
  ///
  /// Returns `null` when the header has no usable name — a blank name, or a
  /// bare token with no `=`.
  ///
  /// Understood attributes: `Expires` (IMF-fixdate and the RFC 850 two-digit
  /// year form), `Max-Age` (which wins over `Expires` regardless of order, per
  /// RFC 6265 §5.3), `Domain` (leading dot stripped), `Path`, `Secure` and
  /// `HttpOnly`. Unknown attributes are ignored.
  static Cookie? parseSetCookie(String header) {
    final segments = header.split(';');
    final pair = segments.first;
    final eq = pair.indexOf('=');
    if (eq < 0) return null;
    final name = pair.substring(0, eq).trim();
    if (name.isEmpty) return null;
    final value = _unquote(pair.substring(eq + 1).trim());

    DateTime? expires;
    int? maxAge;
    var domain = '';
    var path = '';
    var secure = false;
    var httpOnly = false;

    for (var i = 1; i < segments.length; i++) {
      final segment = segments[i];
      final split = segment.indexOf('=');
      final attribute = (split < 0 ? segment : segment.substring(0, split))
          .trim()
          .toLowerCase();
      final attributeValue = split < 0
          ? ''
          : segment.substring(split + 1).trim();

      switch (attribute) {
        case 'expires':
          expires = _parseCookieDate(attributeValue);
        case 'max-age':
          maxAge = int.tryParse(attributeValue);
        case 'domain':
          var d = attributeValue.toLowerCase();
          while (d.startsWith('.')) {
            d = d.substring(1);
          }
          domain = d;
        case 'path':
          if (attributeValue.startsWith('/')) path = attributeValue;
        case 'secure':
          secure = true;
        case 'httponly':
          httpOnly = true;
      }
    }

    if (maxAge != null) {
      // A non-positive Max-Age is the RFC's delete instruction; resolving it to
      // a past instant makes `isExpired` report it without a special case.
      expires = DateTime.now().toUtc().add(Duration(seconds: maxAge));
    }

    return Cookie(
      name: name,
      value: value,
      domain: domain,
      path: path.isEmpty ? '/' : path,
      expires: expires,
      secure: secure,
      httpOnly: httpOnly,
    );
  }

  /// Whether this cookie should be sent to [url].
  ///
  /// Checks the secure flag, then domain-match (exact host, or a dot-suffix of
  /// [domain] when [domain] is not an IP literal), then path-match (equal, or a
  /// prefix ending at a `/` boundary). Expiry is *not* checked — jars drop
  /// expired cookies; see [isExpired].
  bool matches(Uri url) {
    if (secure && url.scheme != 'https') return false;
    if (domain.isEmpty) return false;

    final host = url.host.toLowerCase();
    if (host != domain) {
      if (_isIpLiteral(domain)) return false;
      if (!host.endsWith('.$domain')) return false;
    }

    final cookiePath = path.isEmpty ? '/' : path;
    final requestPath = url.path.isEmpty ? '/' : url.path;
    if (requestPath == cookiePath) return true;
    if (!requestPath.startsWith(cookiePath)) return false;
    return cookiePath.endsWith('/') || requestPath[cookiePath.length] == '/';
  }

  /// Whether this cookie dies with the session (no `Expires`/`Max-Age`).
  bool get isSessionCookie => expires == null;

  /// Whether the cookie's expiry is at or before [now] (default: wall clock).
  ///
  /// Session cookies are never expired.
  bool isExpired([DateTime? now]) {
    final deadline = expires;
    if (deadline == null) return false;
    return !deadline.isAfter(now ?? DateTime.now());
  }

  /// Renders the `name=value` form used inside a `Cookie:` request header.
  String toHeaderValue() => '$name=$value';

  /// Joins [cookies] into a single `Cookie:` request header value.
  static String buildCookieHeader(Iterable<Cookie> cookies) =>
      cookies.map((c) => c.toHeaderValue()).join('; ');

  /// Returns a copy with the given fields replaced.
  ///
  /// Passing `null` keeps the current value; a session cookie cannot be
  /// produced from an expiring one this way.
  Cookie copyWith({
    String? name,
    String? value,
    String? domain,
    String? path,
    DateTime? expires,
    bool? secure,
    bool? httpOnly,
  }) => Cookie(
    name: name ?? this.name,
    value: value ?? this.value,
    domain: domain ?? this.domain,
    path: path ?? this.path,
    expires: expires ?? this.expires,
    secure: secure ?? this.secure,
    httpOnly: httpOnly ?? this.httpOnly,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cookie &&
          other.name == name &&
          other.value == value &&
          other.domain == domain &&
          other.path == path &&
          other.expires == expires &&
          other.secure == secure &&
          other.httpOnly == httpOnly;

  @override
  int get hashCode =>
      Object.hash(name, value, domain, path, expires, secure, httpOnly);

  @override
  String toString() =>
      'Cookie($name=$value; domain=$domain; path=$path'
      '${expires == null ? '' : '; expires=$expires'}'
      '${secure ? '; secure' : ''}${httpOnly ? '; httpOnly' : ''})';
}

/// A Dart-side cookie store.
///
/// Implementations are consulted before a request is sent and after a response
/// arrives. All three methods are async so a jar can be disk- or
/// database-backed.
abstract interface class CookieJar {
  /// Returns the cookies that should be sent with a request to [url], in the
  /// order they belong in the `Cookie:` header.
  Future<List<Cookie>> loadForRequest(Uri url);

  /// Stores [cookies] parsed from a response served by [url].
  ///
  /// Implementations resolve empty `domain`/`path` scopes against [url] and
  /// treat an already-expired cookie as a deletion.
  Future<void> saveFromResponse(Uri url, List<Cookie> cookies);

  /// Drops every stored cookie.
  Future<void> clear();
}

/// A [CookieJar] that keeps everything in memory for the lifetime of the
/// object. Suitable for tests and for short-lived, non-persistent sessions.
final class InMemoryCookieJar implements CookieJar {
  /// Creates an empty jar.
  InMemoryCookieJar();

  final List<Cookie> _cookies = <Cookie>[];

  /// The live contents of the jar, most-recently-stored last.
  ///
  /// Expired entries may still be present until the next
  /// [loadForRequest]; callers that care should filter with [Cookie.isExpired].
  List<Cookie> get cookies => List<Cookie>.unmodifiable(_cookies);

  @override
  Future<List<Cookie>> loadForRequest(Uri url) async {
    final now = DateTime.now();
    _cookies.removeWhere((c) => c.isExpired(now));
    // RFC 6265 §5.4: longer paths first, so the most specific cookie wins for
    // servers that only read the first occurrence of a name.
    return _cookies.where((c) => c.matches(url)).toList(growable: false)
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
  }

  @override
  Future<void> saveFromResponse(Uri url, List<Cookie> cookies) async {
    for (final cookie in cookies) {
      final scoped = cookie.copyWith(
        domain: cookie.domain.isEmpty ? url.host.toLowerCase() : null,
        path: cookie.path.isEmpty ? defaultPathFor(url) : null,
      );
      _cookies.removeWhere(
        (e) =>
            e.name == scoped.name &&
            e.domain == scoped.domain &&
            e.path == scoped.path,
      );
      if (scoped.isExpired()) continue;
      _cookies.add(scoped);
    }
  }

  @override
  Future<void> clear() async => _cookies.clear();

  /// The default cookie path for [url] per RFC 6265 §5.1.4: everything up to
  /// and including the last `/`, or `/` when the URL has no directory part.
  static String defaultPathFor(Uri url) {
    final path = url.path;
    if (!path.startsWith('/')) return '/';
    final lastSlash = path.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : path.substring(0, lastSlash);
  }
}

/// Matches both `Sun, 06 Nov 1994 08:49:37 GMT` (IMF-fixdate) and
/// `Sunday, 06-Nov-94 08:49:37 GMT` (RFC 850) — they differ only in the
/// separators around the month and in the year width.
final RegExp _cookieDate = RegExp(
  r'^(?:[A-Za-z]+,\s*)?(\d{1,2})[\s-]([A-Za-z]{3})[\s-](\d{2,4})\s+'
  r'(\d{1,2}):(\d{2}):(\d{2})',
);

const List<String> _months = <String>[
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

DateTime? _parseCookieDate(String text) {
  final match = _cookieDate.firstMatch(text.trim());
  if (match == null) return null;

  final month = _months.indexOf(match.group(2)!.toLowerCase()) + 1;
  if (month == 0) return null;

  var year = int.parse(match.group(3)!);
  if (year < 100) {
    // RFC 6265 §5.1.1 two-digit year window.
    year += year >= 70 ? 1900 : 2000;
  }

  return DateTime.utc(
    year,
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

String _unquote(String value) =>
    value.length >= 2 && value.startsWith('"') && value.endsWith('"')
    ? value.substring(1, value.length - 1)
    : value;

final RegExp _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

bool _isIpLiteral(String host) => host.contains(':') || _ipv4.hasMatch(host);
