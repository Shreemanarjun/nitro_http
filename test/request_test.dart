import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  group('HttpVersionLabel', () {
    test('labels every version', () {
      expect(HttpVersion.unknown.label, 'HTTP/?');
      expect(HttpVersion.http10.label, 'HTTP/1.0');
      expect(HttpVersion.http11.label, 'HTTP/1.1');
      expect(HttpVersion.http2.label, 'HTTP/2');
      expect(HttpVersion.http3.label, 'HTTP/3');
    });

    test('covers the whole enum', () {
      // Guards against a version being added without a label.
      for (final version in HttpVersion.values) {
        expect(version.label, isNotEmpty);
      }
    });
  });

  group('RequestOptions.isEmpty', () {
    test('is true for the default', () {
      expect(const RequestOptions().isEmpty, isTrue);
    });

    test('is false when any single field is set', () {
      const options = <RequestOptions>[
        RequestOptions(connectTimeout: Duration(seconds: 1)),
        RequestOptions(timeout: Duration(seconds: 1)),
        RequestOptions(followRedirects: false),
        RequestOptions(maxRedirects: 3),
        RequestOptions(cacheMode: CacheMode.bypass),
        RequestOptions(wantTimings: false),
        RequestOptions(pinnedSpkiSha256: 'abc'),
      ];

      for (final option in options) {
        expect(option.isEmpty, isFalse, reason: '$option');
      }
    });
  });

  group('RequestOptions.copyWith', () {
    test('replaces only what is passed', () {
      const base = RequestOptions(
        timeout: Duration(seconds: 5),
        maxRedirects: 3,
      );

      final copy = base.copyWith(maxRedirects: 10);

      expect(copy.timeout, const Duration(seconds: 5));
      expect(copy.maxRedirects, 10);
    });

    test('keeps the current value when an argument is omitted', () {
      const base = RequestOptions(
        connectTimeout: Duration(seconds: 2),
        timeout: Duration(seconds: 5),
        followRedirects: false,
        maxRedirects: 3,
        cacheMode: CacheMode.refresh,
        wantTimings: false,
        pinnedSpkiSha256: 'pin',
      );

      expect(base.copyWith(), base);
    });

    test('sets every field', () {
      final copy = const RequestOptions().copyWith(
        connectTimeout: const Duration(seconds: 2),
        timeout: const Duration(seconds: 5),
        followRedirects: true,
        maxRedirects: 7,
        cacheMode: CacheMode.onlyIfCached,
        wantTimings: true,
        pinnedSpkiSha256: 'pin',
      );

      expect(copy.connectTimeout, const Duration(seconds: 2));
      expect(copy.timeout, const Duration(seconds: 5));
      expect(copy.followRedirects, isTrue);
      expect(copy.maxRedirects, 7);
      expect(copy.cacheMode, CacheMode.onlyIfCached);
      expect(copy.wantTimings, isTrue);
      expect(copy.pinnedSpkiSha256, 'pin');
    });
  });

  group('RequestOptions.clear', () {
    const full = RequestOptions(
      connectTimeout: Duration(seconds: 2),
      timeout: Duration(seconds: 5),
      followRedirects: false,
      maxRedirects: 3,
      cacheMode: CacheMode.refresh,
      wantTimings: false,
      pinnedSpkiSha256: 'pin',
    );

    test('drops nothing by default', () {
      expect(full.clear(), full);
    });

    test('drops each field independently', () {
      expect(full.clear(connectTimeout: true).connectTimeout, isNull);
      expect(full.clear(timeout: true).timeout, isNull);
      expect(full.clear(followRedirects: true).followRedirects, isNull);
      expect(full.clear(maxRedirects: true).maxRedirects, isNull);
      expect(full.clear(cacheMode: true).cacheMode, isNull);
      expect(full.clear(wantTimings: true).wantTimings, isNull);
      expect(full.clear(pinnedSpkiSha256: true).pinnedSpkiSha256, isNull);
    });

    test('clearing everything yields the empty options', () {
      final cleared = full.clear(
        connectTimeout: true,
        timeout: true,
        followRedirects: true,
        maxRedirects: true,
        cacheMode: true,
        wantTimings: true,
        pinnedSpkiSha256: true,
      );

      expect(cleared.isEmpty, isTrue);
    });

    test('clearing one field keeps the others', () {
      final cleared = full.clear(timeout: true);

      expect(cleared.timeout, isNull);
      expect(cleared.connectTimeout, const Duration(seconds: 2));
      expect(cleared.maxRedirects, 3);
    });
  });

  group('RequestOptions.inheritFrom', () {
    test('returns this when the fallback is null', () {
      const options = RequestOptions(maxRedirects: 1);

      expect(identical(options.inheritFrom(null), options), isTrue);
    });

    test('returns this when the fallback is empty', () {
      const options = RequestOptions(maxRedirects: 1);

      expect(
        identical(options.inheritFrom(const RequestOptions()), options),
        isTrue,
      );
    });

    test('fills only the unset fields', () {
      const patch = RequestOptions(maxRedirects: 10);
      const fallback = RequestOptions(
        connectTimeout: Duration(seconds: 2),
        timeout: Duration(seconds: 5),
        followRedirects: false,
        maxRedirects: 3,
        cacheMode: CacheMode.refresh,
        wantTimings: false,
        pinnedSpkiSha256: 'pin',
      );

      final merged = patch.inheritFrom(fallback);

      // The patch wins where it is set.
      expect(merged.maxRedirects, 10);
      // Everything else comes from the fallback.
      expect(merged.connectTimeout, const Duration(seconds: 2));
      expect(merged.timeout, const Duration(seconds: 5));
      expect(merged.followRedirects, isFalse);
      expect(merged.cacheMode, CacheMode.refresh);
      expect(merged.wantTimings, isFalse);
      expect(merged.pinnedSpkiSha256, 'pin');
    });
  });

  group('RequestOptions value semantics', () {
    test('equal options compare equal and hash alike', () {
      const a = RequestOptions(timeout: Duration(seconds: 5), maxRedirects: 3);
      const b = RequestOptions(timeout: Duration(seconds: 5), maxRedirects: 3);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, same(a));
    });

    test('each differing field breaks equality', () {
      const base = RequestOptions();

      expect(base, isNot(const RequestOptions(connectTimeout: Duration.zero)));
      expect(base, isNot(const RequestOptions(timeout: Duration.zero)));
      expect(base, isNot(const RequestOptions(followRedirects: true)));
      expect(base, isNot(const RequestOptions(maxRedirects: 0)));
      expect(base, isNot(const RequestOptions(cacheMode: CacheMode.bypass)));
      expect(base, isNot(const RequestOptions(wantTimings: true)));
      expect(base, isNot(const RequestOptions(pinnedSpkiSha256: '')));
      expect(base, isNot(Object()));
    });
  });

  group('RequestOptions.toString', () {
    test('renders nothing for the empty options', () {
      expect(const RequestOptions().toString(), 'RequestOptions()');
    });

    test('lists only the fields that are set', () {
      const options = RequestOptions(
        timeout: Duration(seconds: 5),
        maxRedirects: 3,
      );

      expect(
        options.toString(),
        'RequestOptions(timeout: 0:00:05.000000, maxRedirects: 3)',
      );
    });

    test('names the cache mode and redacts the pin', () {
      const options = RequestOptions(
        cacheMode: CacheMode.onlyIfCached,
        pinnedSpkiSha256: 'super-secret-pin',
      );

      final rendered = options.toString();

      expect(rendered, contains('cacheMode: onlyIfCached'));
      expect(rendered, contains('pinnedSpkiSha256: <set>'));
      expect(rendered, isNot(contains('super-secret-pin')));
    });

    test('renders every field at once', () {
      const options = RequestOptions(
        connectTimeout: Duration(seconds: 2),
        timeout: Duration(seconds: 5),
        followRedirects: false,
        maxRedirects: 3,
        cacheMode: CacheMode.refresh,
        wantTimings: false,
        pinnedSpkiSha256: 'pin',
      );

      final rendered = options.toString();

      expect(rendered, contains('connectTimeout:'));
      expect(rendered, contains('followRedirects: false'));
      expect(rendered, contains('wantTimings: false'));
    });
  });

  group('HttpRequest.methodToken', () {
    test('upper-cases a standard method', () {
      for (final method in HttpMethod.values) {
        if (method == HttpMethod.custom) continue;
        final request = HttpRequest(
          url: Uri.parse('http://x/'),
          method: method,
        );
        expect(request.methodToken, method.name.toUpperCase());
      }
    });

    test('uses the custom token when the method is custom', () {
      final request = HttpRequest(
        url: Uri.parse('http://x/'),
        method: HttpMethod.custom,
        customMethod: '  PROPFIND  ',
      );

      expect(request.methodToken, 'PROPFIND');
    });

    test('throws when a custom method has no token', () {
      // An empty method token would produce a malformed request line, so this
      // has to fail before it reaches the engine.
      for (final token in [null, '', '   ']) {
        final request = HttpRequest(
          url: Uri.parse('http://x/'),
          method: HttpMethod.custom,
          customMethod: token,
        );
        expect(() => request.methodToken, throwsArgumentError, reason: '$token');
      }
    });
  });

  group('HttpRequest.methodLabel', () {
    test('matches methodToken for standard methods', () {
      final request = HttpRequest(
        url: Uri.parse('http://x/'),
        method: HttpMethod.delete,
      );

      expect(request.methodLabel, 'DELETE');
    });

    test('never throws for a malformed custom method', () {
      // Composing a diagnostic must not itself blow up.
      for (final token in [null, '', '  ']) {
        final request = HttpRequest(
          url: Uri.parse('http://x/'),
          method: HttpMethod.custom,
          customMethod: token,
        );
        expect(request.methodLabel, 'CUSTOM');
      }
    });

    test('uses the trimmed token when one is present', () {
      final request = HttpRequest(
        url: Uri.parse('http://x/'),
        method: HttpMethod.custom,
        customMethod: ' REPORT ',
      );

      expect(request.methodLabel, 'REPORT');
    });
  });

  group('HttpRequest.copyWith', () {
    HttpRequest base() => HttpRequest(
      url: Uri.parse('http://example.test/a'),
      method: HttpMethod.post,
      customMethod: 'ignored',
      headers: HttpHeaders()..set('x-a', '1'),
      body: HttpBody.text('hi'),
      expectedBody: HttpExpectedBody.bytes,
      options: const RequestOptions(maxRedirects: 2),
      cancelToken: CancelToken(),
      onSendProgress: (_, _) {},
      onReceiveProgress: (_, _) {},
    );

    test('keeps every field when nothing is passed', () {
      final original = base();
      final copy = original.copyWith();

      expect(copy.method, original.method);
      expect(copy.customMethod, original.customMethod);
      expect(copy.url, original.url);
      expect(copy.body, original.body);
      expect(copy.expectedBody, original.expectedBody);
      expect(copy.options, original.options);
      expect(copy.cancelToken, same(original.cancelToken));
      expect(copy.onSendProgress, same(original.onSendProgress));
      expect(copy.onReceiveProgress, same(original.onReceiveProgress));
    });

    test('clones the headers so copies stay independent', () {
      final original = base();
      final copy = original.copyWith();

      copy.headers.set('x-b', '2');

      expect(original.headers['x-b'], isNull);
      expect(copy.headers['x-a'], '1');
    });

    test('adopts a replacement header collection without cloning', () {
      final original = base();
      final replacement = HttpHeaders()..set('x-c', '3');

      final copy = original.copyWith(headers: replacement);

      expect(copy.headers, same(replacement));
    });

    test('replaces each supplied field', () {
      final original = base();
      final url = Uri.parse('http://example.test/b');

      final copy = original.copyWith(
        method: HttpMethod.put,
        url: url,
        expectedBody: HttpExpectedBody.stream,
        options: const RequestOptions(maxRedirects: 9),
      );

      expect(copy.method, HttpMethod.put);
      expect(copy.url, url);
      expect(copy.expectedBody, HttpExpectedBody.stream);
      expect(copy.options.maxRedirects, 9);
    });

    test('an explicit null clears a nullable field', () {
      // The `_unset` sentinel is what makes this different from omitting the
      // argument, which keeps the current value.
      final copy = base().copyWith(
        customMethod: null,
        body: null,
        cancelToken: null,
        onSendProgress: null,
        onReceiveProgress: null,
      );

      expect(copy.customMethod, isNull);
      expect(copy.body, isNull);
      expect(copy.cancelToken, isNull);
      expect(copy.onSendProgress, isNull);
      expect(copy.onReceiveProgress, isNull);
    });

    test('replaces nullable fields with new values', () {
      final token = CancelToken();
      final body = HttpBody.bytes(Uint8List.fromList([1, 2, 3]));

      final copy = base().copyWith(
        customMethod: 'PATCHY',
        body: body,
        cancelToken: token,
      );

      expect(copy.customMethod, 'PATCHY');
      expect(copy.body, same(body));
      expect(copy.cancelToken, same(token));
    });
  });

  test('HttpRequest.toString names the method and url', () {
    final request = HttpRequest(
      url: Uri.parse('http://example.test/a?b=c'),
      method: HttpMethod.get,
    );

    expect(request.toString(), 'HttpRequest(GET http://example.test/a?b=c)');
  });

  test('HttpRequest defaults are sane', () {
    final request = HttpRequest(url: Uri.parse('http://x/'));

    expect(request.method, HttpMethod.get);
    expect(request.customMethod, isNull);
    expect(request.headers.isEmpty, isTrue);
    expect(request.body, isNull);
    expect(request.expectedBody, HttpExpectedBody.text);
    expect(request.options.isEmpty, isTrue);
    expect(request.cancelToken, isNull);
  });
}
