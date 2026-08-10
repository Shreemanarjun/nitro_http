import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  group('lookup', () {
    test('is case-insensitive in both directions', () {
      final headers = HttpHeaders()..add('Content-Type', 'application/json');

      expect(headers['content-type'], 'application/json');
      expect(headers['CONTENT-TYPE'], 'application/json');
      expect(headers.containsKey('Content-TYPE'), isTrue);
      expect(headers['content_type'], isNull);
    });

    test('returns the first value when a field repeats', () {
      final headers = HttpHeaders()
        ..add('Via', '1.1 alpha')
        ..add('via', '1.1 beta');

      expect(headers['via'], '1.1 alpha');
      expect(headers.getAll('VIA'), <String>['1.1 alpha', '1.1 beta']);
    });

    test('getAll returns an empty list for an absent field', () {
      expect(HttpHeaders().getAll('x-missing'), isEmpty);
    });
  });

  group('mutation', () {
    test('add preserves duplicates, original casing and order', () {
      final headers = HttpHeaders()
        ..add('X-A', '1')
        ..add('X-B', '2')
        ..add('x-a', '3');

      expect(headers.entries, <(String, String)>[
        ('X-A', '1'),
        ('X-B', '2'),
        ('x-a', '3'),
      ]);
      expect(headers.length, 3);
      expect(headers.names, <String>['x-a', 'x-b']);
    });

    test('set replaces every value but keeps the first position', () {
      final headers = HttpHeaders()
        ..add('Accept', 'text/html')
        ..add('X-Trace', 'abc')
        ..add('accept', 'application/xml')
        ..set('ACCEPT', 'application/json');

      expect(headers.entries, <(String, String)>[
        ('ACCEPT', 'application/json'),
        ('X-Trace', 'abc'),
      ]);
      expect(headers.getAll('accept'), <String>['application/json']);
    });

    test('set on an absent field appends it', () {
      final headers = HttpHeaders()
        ..add('A', '1')
        ..set('B', '2');

      expect(headers.entries.last, ('B', '2'));
    });

    test('remove drops every occurrence and is a no-op when absent', () {
      final headers = HttpHeaders()
        ..add('Set-Cookie', 'a=1')
        ..add('set-cookie', 'b=2')
        ..add('Date', 'now')
        ..remove('SET-COOKIE')
        ..remove('nothing-here');

      expect(headers.entries, <(String, String)>[('Date', 'now')]);
      expect(headers.containsKey('set-cookie'), isFalse);
    });

    test('clear empties the collection', () {
      final headers = HttpHeaders()
        ..add('A', '1')
        ..clear();

      expect(headers.isEmpty, isTrue);
      expect(headers.isNotEmpty, isFalse);
      expect(headers.length, 0);
    });

    test('addAll keeps the duplicates of both sides', () {
      final a = HttpHeaders()..add('X', '1');
      final b = HttpHeaders()
        ..add('x', '2')
        ..add('Y', '3');

      a.addAll(b);

      expect(a.getAll('x'), <String>['1', '2']);
      expect(a.length, 3);
    });
  });

  test('toMap joins repeated fields with a comma and a space', () {
    final headers = HttpHeaders()
      ..add('Via', '1.1 alpha')
      ..add('via', '1.1 beta')
      ..add('Date', 'now');

    expect(headers.toMap(), <String, String>{
      'Via': '1.1 alpha, 1.1 beta',
      'Date': 'now',
    });
  });

  group('typed accessors', () {
    test('contentType reads and writes', () {
      final headers = HttpHeaders()..contentType = 'text/plain';
      expect(headers.contentType, 'text/plain');

      headers.contentType = null;
      expect(headers.contentType, isNull);
      expect(headers.containsKey('content-type'), isFalse);
    });

    test('contentLength parses, trims, and yields null when unusable', () {
      expect((HttpHeaders()..add('Content-Length', ' 42 ')).contentLength, 42);
      expect((HttpHeaders()..add('Content-Length', 'many')).contentLength, isNull);
      expect(HttpHeaders().contentLength, isNull);
    });

    test('location reads the Location field', () {
      final headers = HttpHeaders()..add('location', '/next');
      expect(headers.location, '/next');
    });

    test('setCookie keeps both values separate', () {
      final headers = HttpHeaders()
        ..add('Set-Cookie', 'a=1; Path=/')
        ..add('set-cookie', 'b=2; Path=/x');

      expect(headers.setCookie, <String>['a=1; Path=/', 'b=2; Path=/x']);
    });
  });

  test('clone shares no mutable state', () {
    final original = HttpHeaders()..add('A', '1');
    final copy = original.clone()..add('B', '2');

    expect(original.containsKey('B'), isFalse);
    expect(copy.getAll('A'), <String>['1']);

    original.set('A', 'changed');
    expect(copy['A'], '1');
  });

  group('equality', () {
    test('ignores field order', () {
      final a = HttpHeaders()
        ..add('A', '1')
        ..add('B', '2');
      final b = HttpHeaders()
        ..add('b', '2')
        ..add('a', '1');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('respects multiplicity', () {
      final once = HttpHeaders()..add('A', '1');
      final twice = HttpHeaders()
        ..add('A', '1')
        ..add('a', '1');

      expect(once, isNot(twice));
      // A hash that xor-ed entries would collide these two; the sum must not.
      expect(once.hashCode, isNot(twice.hashCode));
    });

    test('distinguishes different values under the same name', () {
      final a = HttpHeaders()
        ..add('A', '1')
        ..add('A', '2');
      final b = HttpHeaders()
        ..add('A', '1')
        ..add('A', '3');

      expect(a, isNot(b));
    });

    test('an empty collection equals another empty one', () {
      expect(HttpHeaders(), HttpHeaders());
      expect(HttpHeaders().hashCode, HttpHeaders().hashCode);
    });
  });

  test('toString redacts credentials and cookies but nothing else', () {
    final headers = HttpHeaders()
      ..add('Authorization', 'Bearer supersecret')
      ..add('Proxy-Authorization', 'Basic cHJveHk=')
      ..add('Cookie', 'session=deadbeef')
      ..add('Set-Cookie', 'session=deadbeef; HttpOnly')
      ..add('X-Request-Id', 'visible');

    final text = headers.toString();

    expect(text, isNot(contains('supersecret')));
    expect(text, isNot(contains('cHJveHk=')));
    expect(text, isNot(contains('deadbeef')));
    expect(text, contains('Authorization: <redacted>'));
    expect(text, contains('Proxy-Authorization: <redacted>'));
    expect(text, contains('Cookie: <redacted>'));
    expect(text, contains('Set-Cookie: <redacted>'));
    expect(text, contains('X-Request-Id: visible'));
  });

  test('fromMap and fromEntries preserve their input order', () {
    expect(
      HttpHeaders.fromMap(<String, String>{'B': '2', 'A': '1'}).entries,
      <(String, String)>[('B', '2'), ('A', '1')],
    );
    expect(
      HttpHeaders.fromEntries(<(String, String)>[('A', '1'), ('a', '2')]).getAll('A'),
      <String>['1', '2'],
    );
  });
}
