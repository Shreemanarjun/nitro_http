import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

/// Builds a timing record with only the phases a test cares about.
///
/// `HttpTimings` requires all seven, which would make every case here a wall
/// of `Duration.zero`.
HttpTimings _timings({
  Duration queue = Duration.zero,
  Duration dns = Duration.zero,
  Duration connect = Duration.zero,
  Duration tls = Duration.zero,
  Duration firstByte = Duration.zero,
  Duration redirect = Duration.zero,
  Duration total = Duration.zero,
}) => HttpTimings(
  queue: queue,
  dns: dns,
  connect: connect,
  tls: tls,
  firstByte: firstByte,
  redirect: redirect,
  total: total,
);

ResponseMetadata _meta({
  int statusCode = 200,
  String reasonPhrase = 'OK',
  HttpHeaders? headers,
  HttpVersion version = HttpVersion.http11,
  HttpTimings? timings,
  bool fromCache = false,
  bool revalidated = false,
  int redirectCount = 0,
  String primaryIp = '127.0.0.1',
  int primaryPort = 8080,
}) => ResponseMetadata(
  request: HttpRequest(url: Uri.parse('http://example.test/a')),
  statusCode: statusCode,
  reasonPhrase: reasonPhrase,
  version: version,
  headers: headers ?? HttpHeaders(),
  finalUrl: Uri.parse('http://example.test/a'),
  redirectCount: redirectCount,
  fromCache: fromCache,
  revalidated: revalidated,
  primaryIp: primaryIp,
  primaryPort: primaryPort,
  timings: timings ?? const HttpTimings.zero(),
);

void main() {
  group('HttpTimings', () {
    test('the zero record is empty', () {
      expect(const HttpTimings.zero().isEmpty, isTrue);
    });

    test('is empty when total and firstByte are both zero', () {
      // A response with only a queue time never reached the wire, so there is
      // nothing meaningful to report.
      expect(_timings(queue: const Duration(microseconds: 5)).isEmpty, isTrue);
    });

    test('is not empty once a real phase is recorded', () {
      expect(
        _timings(total: const Duration(milliseconds: 1)).isEmpty,
        isFalse,
      );
      expect(
        _timings(firstByte: const Duration(milliseconds: 1)).isEmpty,
        isFalse,
      );
    });

    test('the zero record sets every phase to zero', () {
      const zero = HttpTimings.zero();

      expect(zero.queue, Duration.zero);
      expect(zero.dns, Duration.zero);
      expect(zero.connect, Duration.zero);
      expect(zero.tls, Duration.zero);
      expect(zero.firstByte, Duration.zero);
      expect(zero.redirect, Duration.zero);
      expect(zero.total, Duration.zero);
    });

    test('equal timings compare equal and hash alike', () {
      final a = _timings(
        queue: const Duration(microseconds: 2),
        dns: const Duration(microseconds: 3),
        connect: const Duration(microseconds: 4),
        tls: const Duration(microseconds: 5),
        firstByte: const Duration(microseconds: 6),
        redirect: const Duration(microseconds: 7),
        total: const Duration(microseconds: 8),
      );
      final b = _timings(
        queue: const Duration(microseconds: 2),
        dns: const Duration(microseconds: 3),
        connect: const Duration(microseconds: 4),
        tls: const Duration(microseconds: 5),
        firstByte: const Duration(microseconds: 6),
        redirect: const Duration(microseconds: 7),
        total: const Duration(microseconds: 8),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, same(a));
    });

    test('each differing phase breaks equality', () {
      const base = HttpTimings.zero();
      const one = Duration(seconds: 1);

      expect(base, isNot(_timings(queue: one)));
      expect(base, isNot(_timings(dns: one)));
      expect(base, isNot(_timings(connect: one)));
      expect(base, isNot(_timings(tls: one)));
      expect(base, isNot(_timings(firstByte: one)));
      expect(base, isNot(_timings(redirect: one)));
      expect(base, isNot(_timings(total: one)));
      expect(base, isNot(Object()));
    });

    group('toString', () {
      test('says none when every phase is zero', () {
        // Seven zeroes would tell a reader nothing.
        expect(const HttpTimings.zero().toString(), 'HttpTimings(none)');
      });

      test('lists only the phases that took time, in milliseconds', () {
        final timings = _timings(
          connect: const Duration(microseconds: 1500),
          total: const Duration(microseconds: 20000),
        );

        expect(timings.toString(), 'HttpTimings(connect 1.5ms, total 20.0ms)');
      });

      test('renders every phase when all are set', () {
        final rendered = _timings(
          queue: const Duration(microseconds: 100),
          dns: const Duration(microseconds: 200),
          connect: const Duration(microseconds: 300),
          tls: const Duration(microseconds: 400),
          firstByte: const Duration(microseconds: 500),
          redirect: const Duration(microseconds: 600),
          total: const Duration(microseconds: 700),
        ).toString();

        for (final phase in [
          'queue',
          'dns',
          'connect',
          'tls',
          'firstByte',
          'redirect',
          'total',
        ]) {
          expect(rendered, contains(phase));
        }
      });
    });
  });

  group('HttpResponse metadata forwarding', () {
    test('exposes every metadata field', () {
      final headers = HttpHeaders()..set('x-a', '1');
      final timings = _timings(total: const Duration(milliseconds: 3));
      final response = HttpBytesResponse(
        meta: _meta(
          statusCode: 201,
          reasonPhrase: 'Created',
          headers: headers,
          version: HttpVersion.http2,
          timings: timings,
          fromCache: true,
          revalidated: true,
          redirectCount: 2,
          primaryIp: '10.0.0.1',
          primaryPort: 443,
        ),
        bodyBytes: Uint8List(0),
      );

      expect(response.statusCode, 201);
      expect(response.reasonPhrase, 'Created');
      expect(response.version, HttpVersion.http2);
      expect(response.headers, same(headers));
      expect(response.finalUrl, Uri.parse('http://example.test/a'));
      expect(response.redirectCount, 2);
      expect(response.fromCache, isTrue);
      expect(response.revalidated, isTrue);
      expect(response.primaryIp, '10.0.0.1');
      expect(response.primaryPort, 443);
      expect(response.timings, timings);
      expect(response.request.url, Uri.parse('http://example.test/a'));
      expect(response.meta.statusCode, 201);
    });

    test('isSuccess covers exactly the 2xx range', () {
      HttpResponse at(int code) => HttpBytesResponse(
        meta: _meta(statusCode: code),
        bodyBytes: Uint8List(0),
      );

      expect(at(199).isSuccess, isFalse);
      expect(at(200).isSuccess, isTrue);
      expect(at(204).isSuccess, isTrue);
      expect(at(299).isSuccess, isTrue);
      expect(at(300).isSuccess, isFalse);
      expect(at(404).isSuccess, isFalse);
    });
  });

  group('HttpTextResponse body decoding', () {
    HttpTextResponse textWith(String? contentType, List<int> bytes) {
      final headers = HttpHeaders();
      if (contentType != null) headers.set('content-type', contentType);
      return HttpTextResponse(
        meta: _meta(headers: headers),
        bodyBytes: Uint8List.fromList(bytes),
      );
    }

    test('defaults to UTF-8 when no charset is given', () {
      expect(textWith('text/plain', utf8.encode('héllo')).body, 'héllo');
    });

    test('defaults to UTF-8 when there is no content-type at all', () {
      expect(textWith(null, utf8.encode('hi')).body, 'hi');
    });

    test('honours an explicit utf-8 charset', () {
      expect(textWith('text/plain; charset=utf-8', utf8.encode('é')).body, 'é');
    });

    test('honours latin-1 under each of its spellings', () {
      for (final name in ['latin1', 'latin-1', 'iso-8859-1', 'iso8859-1']) {
        expect(
          textWith('text/plain; charset=$name', [0xE9]).body,
          'é',
          reason: name,
        );
      }
    });

    test('honours ascii under each of its spellings', () {
      for (final name in ['ascii', 'us-ascii']) {
        expect(
          textWith('text/plain; charset=$name', [0x41]).body,
          'A',
          reason: name,
        );
      }
    });

    test('is case-insensitive about the charset name', () {
      expect(textWith('text/plain; charset=LATIN1', [0xE9]).body, 'é');
    });

    test('strips quotes around the charset value', () {
      expect(textWith('text/plain; charset="latin1"', [0xE9]).body, 'é');
    });

    test('skips parameters that are not charset', () {
      expect(
        textWith('text/plain; boundary=xyz; charset=latin1', [0xE9]).body,
        'é',
      );
    });

    test('ignores a parameter with no equals sign', () {
      expect(textWith('text/plain; junk; charset=latin1', [0xE9]).body, 'é');
    });

    test('falls back to UTF-8 for an unknown charset', () {
      expect(
        textWith('text/plain; charset=shift_jis', utf8.encode('ok')).body,
        'ok',
      );
    });

    test('replaces malformed bytes rather than throwing', () {
      // One bad sequence in a large page must not crash the app.
      final body = textWith('text/plain; charset=utf-8', [0xFF, 0xFE]).body;

      expect(body, contains('�'));
    });

    test('replaces malformed latin-1 and ascii bytes leniently', () {
      expect(textWith('text/plain; charset=ascii', [0xFF]).body, isNotEmpty);
    });

    test('decodes once and caches', () {
      final response = textWith('text/plain', utf8.encode('x'));

      expect(identical(response.body, response.body), isTrue);
    });
  });

  group('HttpTextResponse.bodyToJson', () {
    HttpTextResponse jsonWith(String body) => HttpTextResponse(
      meta: _meta(
        headers: HttpHeaders()..set('content-type', 'application/json'),
      ),
      bodyBytes: Uint8List.fromList(utf8.encode(body)),
    );

    test('parses an object', () {
      expect(jsonWith('{"a":1}').bodyToJson(), {'a': 1});
    });

    test('parses a list', () {
      expect(jsonWith('[1,2]').bodyToJson(), [1, 2]);
    });

    test('parses a bare scalar and null', () {
      expect(jsonWith('42').bodyToJson(), 42);
      expect(jsonWith('null').bodyToJson(), isNull);
    });

    test('throws a nitro_http exception rather than a FormatException', () {
      // One `on NitroHttpException` clause has to catch every failure mode.
      final response = jsonWith('{not json');

      expect(response.bodyToJson, throwsA(isA<NitroHttpDecodingException>()));
      expect(response.bodyToJson, throwsA(isA<NitroHttpException>()));
    });
  });

  group('toString', () {
    test('HttpTextResponse reports status, version and byte count', () {
      final response = HttpTextResponse(
        meta: _meta(version: HttpVersion.http2),
        bodyBytes: Uint8List(12),
      );

      expect(response.toString(), 'HttpTextResponse(200 HTTP/2, 12 bytes)');
    });

    test('HttpBytesResponse reports status, version and byte count', () {
      final response = HttpBytesResponse(
        meta: _meta(statusCode: 404),
        bodyBytes: Uint8List(3),
      );

      expect(response.toString(), 'HttpBytesResponse(404 HTTP/1.1, 3 bytes)');
    });

    test('HttpStreamResponse reports the content length when known', () {
      final response = HttpStreamResponse(
        meta: _meta(),
        body: const Stream<List<int>>.empty(),
        contentLength: 99,
      );

      expect(response.toString(), 'HttpStreamResponse(200 HTTP/1.1, 99 bytes)');
    });

    test('HttpStreamResponse renders an unknown length as a question mark', () {
      final response = HttpStreamResponse(
        meta: _meta(),
        body: const Stream<List<int>>.empty(),
      );

      expect(response.toString(), 'HttpStreamResponse(200 HTTP/1.1, ? bytes)');
    });
  });

  group('HttpStreamResponse.contentLength', () {
    test('defaults to the Content-Length header', () {
      final response = HttpStreamResponse(
        meta: _meta(headers: HttpHeaders()..set('content-length', '512')),
        body: const Stream<List<int>>.empty(),
      );

      expect(response.contentLength, 512);
    });

    test('is null for a chunked response', () {
      final response = HttpStreamResponse(
        meta: _meta(),
        body: const Stream<List<int>>.empty(),
      );

      expect(response.contentLength, isNull);
    });

    test('an explicit value overrides the header', () {
      final response = HttpStreamResponse(
        meta: _meta(headers: HttpHeaders()..set('content-length', '512')),
        body: const Stream<List<int>>.empty(),
        contentLength: 7,
      );

      expect(response.contentLength, 7);
    });

    test('delivers its body exactly once', () async {
      final response = HttpStreamResponse(
        meta: _meta(),
        body: Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      );

      expect(await response.body.expand((chunk) => chunk).toList(), [1, 2, 3]);
    });
  });
}
