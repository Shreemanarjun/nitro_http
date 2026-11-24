// Host tests for the parts of nitro_http that run without the native engine.
// Real requests need the engine, which is only built into apps: the example
// app covers those on Android and iOS.
import 'dart:typed_data';

import 'package:nitro_http_dartnative/nitro_http_dartnative.dart';
import 'package:test/test.dart';

void main() {
  group('HttpHeaders', () {
    test('looks names up case-insensitively', () {
      final headers = HttpHeaders.fromMap({'Content-Type': 'text/plain'});
      expect(headers['content-type'], 'text/plain');
      expect(headers['CONTENT-TYPE'], 'text/plain');
      expect(headers.containsKey('Content-type'), isTrue);
      expect(headers.contentType, 'text/plain');
    });

    test('set replaces every value, add appends one', () {
      final headers = HttpHeaders()
        ..add('Accept', 'text/html')
        ..add('accept', 'application/json');
      expect(headers.getAll('Accept'), ['text/html', 'application/json']);
      expect(headers.length, 2);

      headers.set('ACCEPT', '*/*');
      expect(headers.getAll('accept'), ['*/*']);
      expect(headers.length, 1);

      headers.remove('Accept');
      expect(headers.isEmpty, isTrue);
    });

    test('rejects CR, LF and NUL so a header cannot split the request', () {
      final headers = HttpHeaders();
      expect(() => headers.set('X-Evil', 'a\r\nInjected: 1'), throwsArgumentError);
      expect(() => headers.add('X-Evil', 'a\nb'), throwsArgumentError);
      expect(() => headers.set('X-Evil\u0000', 'a'), throwsArgumentError);
      expect(headers.isEmpty, isTrue);
    });

    test('parses Content-Length, ignoring junk', () {
      expect(HttpHeaders.fromMap({'Content-Length': ' 42 '}).contentLength, 42);
      expect(HttpHeaders.fromMap({'Content-Length': 'abc'}).contentLength, isNull);
      expect(HttpHeaders().contentLength, isNull);
    });
  });

  group('HttpBody', () {
    test('each kind has the expected default Content-Type', () {
      expect(const HttpBody.text('hi').defaultContentType, 'text/plain; charset=utf-8');
      expect(const HttpBody.json({'a': 1}).defaultContentType, 'application/json; charset=utf-8');
      expect(HttpBody.bytes(Uint8List(3)).defaultContentType, 'application/octet-stream');
      expect(const HttpBody.form({'a': 'b'}).defaultContentType, 'application/x-www-form-urlencoded');
    });

    test('an explicit Content-Type wins over the default', () {
      expect(const HttpBody.text('<a/>', contentType: 'text/xml').defaultContentType, 'text/xml');
    });

    test('form fields are URL-encoded', () {
      const body = HttpBody.form({'q': 'a b&c', 'n': '1'});
      expect((body as HttpFormBody).encode(), 'q=a+b%26c&n=1');
    });
  });

  group('CancelToken', () {
    test('starts live and keeps the first reason it is cancelled with', () async {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
      token.throwIfCancelled(); // no throw while live

      var calls = 0;
      token.addListener(() => calls++);
      token.cancel('screen closed');
      token.cancel('second reason');

      expect(token.isCancelled, isTrue);
      expect(token.reason, 'screen closed');
      expect(calls, 1);
      await token.whenCancelled; // completes
    });

    test('throwIfCancelled throws NitroHttpCancelException with the reason', () {
      final token = CancelToken()..cancel('gone');
      expect(
        token.throwIfCancelled,
        throwsA(isA<NitroHttpCancelException>().having((e) => e.reason, 'reason', 'gone')),
      );
    });

    test('a listener added after cancel runs immediately', () {
      final token = CancelToken()..cancel();
      var ran = false;
      token.addListener(() => ran = true);
      expect(ran, isTrue);
    });
  });

  group('ClientSettings', () {
    test('4xx and 5xx throw by default', () {
      expect(const ClientSettings().throwOnStatusCode, isTrue);
    });

    test('copyWith changes only what it is given', () {
      const base = ClientSettings(baseUrl: 'https://api.example.com', userAgent: 'app/1');
      final changed = base.copyWith(timeout: const Duration(seconds: 5));
      expect(changed.baseUrl, 'https://api.example.com');
      expect(changed.userAgent, 'app/1');
      expect(changed.timeout, const Duration(seconds: 5));
      expect(base.timeout, isNull);
    });

    test('compares by value', () {
      expect(
        const ClientSettings(baseUrl: 'https://a.example'),
        equals(const ClientSettings(baseUrl: 'https://a.example')),
      );
      expect(
        const ClientSettings(baseUrl: 'https://a.example'),
        isNot(equals(const ClientSettings(baseUrl: 'https://b.example'))),
      );
    });
  });

  test('HttpVersion labels match the wire names', () {
    expect(HttpVersion.values.map((v) => v.label), [
      'HTTP/?',
      'HTTP/1.0',
      'HTTP/1.1',
      'HTTP/2',
      'HTTP/3',
    ]);
  });
}
