// The tail of the value-type surface: `toString` implementations, a couple of
// error paths, and the outcome types the interceptor chain returns.
//
// Small and unglamorous, but these are exactly the lines that go wrong
// unnoticed — a `toString` that throws turns a useful log line into a crash,
// and an outcome type that renders badly makes a chain bug hard to read.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/instance_keys.dart';

import 'support/fakes.dart';

void main() {
  group('Cookie.toString', () {
    test('renders the minimum: name, value, domain and path', () {
      const cookie = Cookie(
        name: 'sid',
        value: 'abc',
        domain: 'example.test',
        path: '/',
      );

      expect(
        cookie.toString(),
        'Cookie(sid=abc; domain=example.test; path=/)',
      );
    });

    test('appends expires only when the cookie is not a session cookie', () {
      final cookie = Cookie(
        name: 'sid',
        value: 'abc',
        domain: 'example.test',
        path: '/',
        expires: DateTime.utc(2030),
      );

      expect(cookie.toString(), contains('; expires='));
    });

    test('appends the secure and httpOnly flags when set', () {
      const cookie = Cookie(
        name: 'sid',
        value: 'abc',
        domain: 'example.test',
        path: '/',
        secure: true,
        httpOnly: true,
      );

      final rendered = cookie.toString();

      expect(rendered, contains('; secure'));
      expect(rendered, contains('; httpOnly'));
    });

    test('omits the flags when they are clear', () {
      const cookie = Cookie(
        name: 'sid',
        value: 'abc',
        domain: 'example.test',
        path: '/',
      );

      expect(cookie.toString(), isNot(contains('secure')));
      expect(cookie.toString(), isNot(contains('httpOnly')));
    });

    test('equal cookies hash alike', () {
      const a = Cookie(name: 'a', value: 'b', domain: 'd', path: '/');
      const b = Cookie(name: 'a', value: 'b', domain: 'd', path: '/');

      expect(a.hashCode, b.hashCode);
    });
  });

  group('CancelToken listener failures', () {
    test('a throwing listener does not stop the others', () async {
      // One widget's bad listener must not strand every other request waiting
      // on the same token.
      final token = CancelToken();
      var reached = false;
      token.addListener(() => throw StateError('boom'));
      token.addListener(() => reached = true);

      final errors = <Object>[];
      await runZonedGuarded(() async {
        token.cancel();
      }, (error, _) => errors.add(error));

      expect(reached, isTrue);
      expect(errors.single, isA<StateError>());
    });

    test('a listener added after cancellation still fires, and may throw', () async {
      final token = CancelToken()..cancel();

      final errors = <Object>[];
      await runZonedGuarded(() async {
        token.addListener(() => throw StateError('late'));
      }, (error, _) => errors.add(error));

      expect(errors, hasLength(1));
    });
  });

  group('Ids', () {
    test('resetForTesting rewinds every counter', () {
      Ids.nextClient();
      Ids.nextSocket();
      Ids.nextRequest();

      Ids.resetForTesting();

      // Each counter pre-increments, so the first id after a reset is 1.
      expect(Ids.nextClient(), 1);
      expect(Ids.nextSocket(), 1);
      expect(Ids.nextRequest(), 1);
    });

    test('request ids are process-global and strictly increasing', () {
      // Two clients sharing an id would cross-deliver chunks, because the
      // `chunks` and `events` streams are module-global.
      Ids.resetForTesting();
      final ids = List.generate(100, (_) => Ids.nextRequest());

      expect(ids, equals(List.generate(100, (i) => i + 1)));
    });
  });

  group('InterceptorOutcome', () {
    final request = HttpRequest(url: Uri.parse('http://example.test/a'));

    test('proceed renders the value it carries', () {
      final outcome = InterceptorProceed(request);

      expect(outcome.value, same(request));
      expect(outcome.toString(), contains('InterceptorProceed('));
      expect(outcome.toString(), contains('GET http://example.test/a'));
    });

    test('shortCircuit renders the value it stopped on', () {
      final outcome = InterceptorShortCircuit(request);

      expect(outcome.value, same(request));
      expect(outcome.toString(), contains('InterceptorShortCircuit('));
    });

    test('recovered renders the status code of its response', () {
      final response = fakeTextResponse(status: 418);
      final outcome = InterceptorRecovered<HttpRequest>(response);

      expect(outcome.response, same(response));
      expect(outcome.toString(), 'InterceptorRecovered(418)');
    });
  });

  group('HttpBody', () {
    test('bytes carries its payload and default content type', () {
      final body = HttpBody.bytes(Uint8List.fromList([1, 2, 3]));

      expect(body, isA<HttpBytesBody>());
      expect((body as HttpBytesBody).bytes, [1, 2, 3]);
    });

    test('multipart generates a boundary when none is given', () {
      final body = HttpBody.multipart([MultipartItem.text('a', 'b')]);

      expect((body as HttpMultipartBody).boundary, isNull);
    });

    test('multipart keeps an explicit boundary', () {
      final body = HttpBody.multipart(
        [MultipartItem.text('a', 'b')],
        boundary: 'XYZ',
      );

      expect((body as HttpMultipartBody).boundary, 'XYZ');
    });
  });
}
