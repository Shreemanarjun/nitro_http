import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  group('parseSetCookie', () {
    test('parses a plain name=value pair with the default scope', () {
      final cookie = Cookie.parseSetCookie('sid=abc123')!;

      expect(cookie.name, 'sid');
      expect(cookie.value, 'abc123');
      expect(cookie.domain, '');
      expect(cookie.path, '/');
      expect(cookie.expires, isNull);
      expect(cookie.secure, isFalse);
      expect(cookie.httpOnly, isFalse);
    });

    test('unquotes a double-quoted value', () {
      expect(Cookie.parseSetCookie('sid="a b c"')!.value, 'a b c');
      // A lone quote is not a quoted string and must survive verbatim.
      expect(Cookie.parseSetCookie('sid="unbalanced')!.value, '"unbalanced');
    });

    test('parses Expires in IMF-fixdate form', () {
      final cookie = Cookie.parseSetCookie(
        'sid=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT',
      )!;

      expect(cookie.expires, DateTime.utc(1994, 11, 6, 8, 49, 37));
    });

    test('parses Expires in RFC 850 form, applying the two-digit year window', () {
      expect(
        Cookie.parseSetCookie('sid=1; Expires=Sunday, 06-Nov-94 08:49:37 GMT')!
            .expires,
        DateTime.utc(1994, 11, 6, 8, 49, 37),
      );
      expect(
        Cookie.parseSetCookie('sid=1; Expires=Monday, 01-Jan-30 00:00:00 GMT')!
            .expires,
        DateTime.utc(2030),
      );
    });

    test('an unparseable Expires leaves the cookie a session cookie', () {
      expect(Cookie.parseSetCookie('sid=1; Expires=never')!.expires, isNull);
    });

    test('Max-Age wins over Expires in both attribute orders', () {
      final before = DateTime.now().toUtc();
      final maxAgeFirst = Cookie.parseSetCookie(
        'sid=1; Max-Age=3600; Expires=Sun, 06 Nov 1994 08:49:37 GMT',
      )!;
      final expiresFirst = Cookie.parseSetCookie(
        'sid=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=3600',
      )!;
      final after = DateTime.now().toUtc();

      for (final cookie in <Cookie>[maxAgeFirst, expiresFirst]) {
        expect(
          cookie.expires!.isAfter(before.add(const Duration(minutes: 59))),
          isTrue,
        );
        expect(
          cookie.expires!.isBefore(after.add(const Duration(minutes: 61))),
          isTrue,
        );
      }
    });

    test('a non-positive Max-Age resolves to an already-expired cookie', () {
      final cookie = Cookie.parseSetCookie('sid=1; Max-Age=0')!;

      expect(cookie.isSessionCookie, isFalse);
      expect(cookie.isExpired(), isTrue);
    });

    test('strips every leading dot from Domain and lower-cases it', () {
      expect(
        Cookie.parseSetCookie('sid=1; Domain=.Example.COM')!.domain,
        'example.com',
      );
      expect(
        Cookie.parseSetCookie('sid=1; Domain=..example.com')!.domain,
        'example.com',
      );
    });

    test('reads Secure and HttpOnly case-insensitively', () {
      final cookie = Cookie.parseSetCookie('sid=1; secure; HTTPONLY')!;

      expect(cookie.secure, isTrue);
      expect(cookie.httpOnly, isTrue);
    });

    test('ignores a Path that is not absolute, and unknown attributes', () {
      expect(Cookie.parseSetCookie('sid=1; Path=relative')!.path, '/');
      expect(Cookie.parseSetCookie('sid=1; Path=/deep/er')!.path, '/deep/er');
      expect(Cookie.parseSetCookie('sid=1; SameSite=Lax')!.path, '/');
    });

    test('returns null when there is no usable name', () {
      expect(Cookie.parseSetCookie('=novalue'), isNull);
      expect(Cookie.parseSetCookie('   =novalue'), isNull);
      expect(Cookie.parseSetCookie('bare-token'), isNull);
    });
  });

  group('matches', () {
    const cookie = Cookie(name: 'sid', value: '1', domain: 'example.com');

    test('an exact host matches', () {
      expect(cookie.matches(Uri.parse('http://example.com/')), isTrue);
      expect(cookie.matches(Uri.parse('http://EXAMPLE.com/')), isTrue);
    });

    test('a dot-suffix subdomain matches', () {
      expect(cookie.matches(Uri.parse('http://api.example.com/')), isTrue);
      expect(cookie.matches(Uri.parse('http://a.b.example.com/')), isTrue);
    });

    test('a non-suffix host is rejected', () {
      expect(cookie.matches(Uri.parse('http://notexample.com/')), isFalse);
      expect(cookie.matches(Uri.parse('http://example.com.evil.net/')), isFalse);
    });

    test('an unscoped cookie matches nothing', () {
      const unscoped = Cookie(name: 'sid', value: '1');
      expect(unscoped.matches(Uri.parse('http://example.com/')), isFalse);
    });

    test('an IP-literal domain only matches itself', () {
      const byIp = Cookie(name: 'sid', value: '1', domain: '10.0.0.1');
      expect(byIp.matches(Uri.parse('http://10.0.0.1/')), isTrue);
      expect(byIp.matches(Uri.parse('http://a.10.0.0.1/')), isFalse);
    });

    test('path matching stops at a segment boundary', () {
      const scoped = Cookie(
        name: 'sid',
        value: '1',
        domain: 'example.com',
        path: '/a',
      );

      expect(scoped.matches(Uri.parse('http://example.com/a')), isTrue);
      expect(scoped.matches(Uri.parse('http://example.com/a/b')), isTrue);
      expect(scoped.matches(Uri.parse('http://example.com/ab')), isFalse);
      expect(scoped.matches(Uri.parse('http://example.com/b')), isFalse);
    });

    test('a trailing-slash path matches everything beneath it', () {
      const scoped = Cookie(
        name: 'sid',
        value: '1',
        domain: 'example.com',
        path: '/a/',
      );

      expect(scoped.matches(Uri.parse('http://example.com/a/b')), isTrue);
    });

    test('a secure cookie is never sent over plain http', () {
      const secure = Cookie(
        name: 'sid',
        value: '1',
        domain: 'example.com',
        secure: true,
      );

      expect(secure.matches(Uri.parse('http://example.com/')), isFalse);
      expect(secure.matches(Uri.parse('https://example.com/')), isTrue);
    });
  });

  group('lifetime', () {
    test('isSessionCookie tracks the absence of an expiry', () {
      expect(const Cookie(name: 'a', value: '1').isSessionCookie, isTrue);
      expect(
        Cookie(name: 'a', value: '1', expires: DateTime.utc(2030)).isSessionCookie,
        isFalse,
      );
    });

    test('isExpired is inclusive of the deadline and false for session cookies', () {
      final deadline = DateTime.utc(2020, 1, 1, 12);
      final cookie = Cookie(name: 'a', value: '1', expires: deadline);

      expect(cookie.isExpired(deadline.subtract(const Duration(seconds: 1))), isFalse);
      expect(cookie.isExpired(deadline), isTrue);
      expect(cookie.isExpired(deadline.add(const Duration(seconds: 1))), isTrue);
      expect(const Cookie(name: 'a', value: '1').isExpired(deadline), isFalse);
    });
  });

  group('header rendering', () {
    test('toHeaderValue is the bare pair', () {
      expect(const Cookie(name: 'a', value: '1').toHeaderValue(), 'a=1');
    });

    test('buildCookieHeader joins with a semicolon and a space', () {
      expect(
        Cookie.buildCookieHeader(const <Cookie>[
          Cookie(name: 'a', value: '1'),
          Cookie(name: 'b', value: '2'),
        ]),
        'a=1; b=2',
      );
      expect(Cookie.buildCookieHeader(const <Cookie>[]), '');
    });
  });

  group('InMemoryCookieJar', () {
    test('round trips a cookie scoped from the response URL', () async {
      final jar = InMemoryCookieJar();
      final url = Uri.parse('https://example.com/api/v1/list');

      await jar.saveFromResponse(url, <Cookie>[
        Cookie.parseSetCookie('sid=abc')!,
      ]);

      final stored = jar.cookies.single;
      expect(stored.domain, 'example.com');
      expect(stored.path, '/');

      expect(
        (await jar.loadForRequest(url)).map((c) => c.toHeaderValue()),
        <String>['sid=abc'],
      );
    });

    test('replaces a cookie with the same name, domain and path', () async {
      final jar = InMemoryCookieJar();
      final url = Uri.parse('https://example.com/');

      await jar.saveFromResponse(url, <Cookie>[Cookie.parseSetCookie('sid=1')!]);
      await jar.saveFromResponse(url, <Cookie>[Cookie.parseSetCookie('sid=2')!]);

      expect(jar.cookies, hasLength(1));
      expect(jar.cookies.single.value, '2');
    });

    test('returns the longest path first', () async {
      final jar = InMemoryCookieJar();
      final url = Uri.parse('https://example.com/a/b');

      await jar.saveFromResponse(url, <Cookie>[
        Cookie.parseSetCookie('k=root; Path=/')!,
        Cookie.parseSetCookie('k=deep; Path=/a/b')!,
      ]);

      expect(
        (await jar.loadForRequest(url)).map((c) => c.value),
        <String>['deep', 'root'],
      );
    });

    test('evicts expired cookies on load and never stores a dead one', () async {
      final jar = InMemoryCookieJar();
      final url = Uri.parse('https://example.com/');

      await jar.saveFromResponse(url, <Cookie>[
        Cookie.parseSetCookie('live=1; Max-Age=600')!,
        Cookie.parseSetCookie('dead=1; Max-Age=-1')!,
      ]);

      // An already-expired cookie is a delete instruction, not an entry.
      expect(jar.cookies.map((c) => c.name), <String>['live']);

      await jar.saveFromResponse(url, <Cookie>[
        Cookie(
          name: 'brief',
          value: '1',
          domain: 'example.com',
          expires: DateTime.now().add(const Duration(milliseconds: 50)),
        ),
      ]);
      expect(jar.cookies.map((c) => c.name), <String>['live', 'brief']);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect((await jar.loadForRequest(url)).map((c) => c.name), <String>['live']);
      expect(jar.cookies.map((c) => c.name), <String>['live']);
    });

    test('clear empties the jar', () async {
      final jar = InMemoryCookieJar();
      await jar.saveFromResponse(
        Uri.parse('https://example.com/'),
        <Cookie>[Cookie.parseSetCookie('sid=1')!],
      );

      await jar.clear();

      expect(jar.cookies, isEmpty);
    });

    test('defaultPathFor follows RFC 6265 §5.1.4', () {
      expect(InMemoryCookieJar.defaultPathFor(Uri.parse('https://a.com')), '/');
      expect(InMemoryCookieJar.defaultPathFor(Uri.parse('https://a.com/')), '/');
      expect(InMemoryCookieJar.defaultPathFor(Uri.parse('https://a.com/x')), '/');
      expect(
        InMemoryCookieJar.defaultPathFor(Uri.parse('https://a.com/x/y')),
        '/x',
      );
    });
  });
}
