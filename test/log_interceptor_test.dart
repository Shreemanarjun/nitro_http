import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

import 'support/fakes.dart';

void main() {
  late List<String> lines;
  void sink(String line) => lines.add(line);

  setUp(() => lines = <String>[]);

  group('LogInterceptor', () {
    test('level none writes nothing and reuses the pass-through result',
        () async {
      const logger = LogInterceptor(level: HttpLogLevel.none, sink: print);
      final request = fakeRequest(url: 'https://example.com/x');

      final before = await logger.beforeRequest(request);
      final after = await logger.afterResponse(fakeTextResponse());
      final failed = await logger.onError(
        NitroHttpTimeoutException(stage: TimeoutStage.request),
      );

      expect(lines, isEmpty);
      expect(before.disposition, InterceptorDisposition.next);
      expect(before.value, isNull, reason: 'must not replace the request');
      expect(after.disposition, InterceptorDisposition.next);
      expect(failed.disposition, InterceptorDisposition.next);
    });

    test('basic writes one line each way and nothing else', () async {
      final logger = LogInterceptor(sink: sink);
      await logger.beforeRequest(
        fakeRequest(url: 'https://example.com/x', method: HttpMethod.post),
      );
      await logger.afterResponse(fakeTextResponse(status: 201, body: 'hi'));

      expect(lines, hasLength(2));
      expect(lines[0], '--> POST https://example.com/x');
      expect(lines[1], contains('<-- 201 OK'));
      expect(lines[1], contains('2b'));
      // Timings are all zero on the fixture, which reads as "not collected".
      expect(lines[1], contains('-'));
    });

    test('headers level redacts credentials by default', () async {
      final logger = LogInterceptor(level: HttpLogLevel.headers, sink: sink);
      await logger.beforeRequest(
        fakeRequest(
          headers: HttpHeaders.fromMap({
            'authorization': 'Bearer supersecret',
            'accept': 'application/json',
          }),
        ),
      );

      final joined = lines.join('\n');
      expect(joined, isNot(contains('supersecret')));
      expect(joined, contains('<redacted>'));
      expect(joined, contains('accept: application/json'));
    });

    test('a caller can widen or narrow what is redacted', () async {
      final logger = LogInterceptor(
        level: HttpLogLevel.headers,
        sink: sink,
        redactedHeaders: const {'x-tenant'},
      );
      await logger.beforeRequest(
        fakeRequest(
          headers: HttpHeaders.fromMap({
            'x-tenant': 'acme',
            'authorization': 'Bearer now-visible',
          }),
        ),
      );

      final joined = lines.join('\n');
      expect(joined, contains('<redacted>'));
      expect(joined, isNot(contains('acme')));
      // Opting in to a custom set replaces the default one entirely.
      expect(joined, contains('Bearer now-visible'));
    });

    test('body level writes bodies', () async {
      final logger = LogInterceptor(level: HttpLogLevel.body, sink: sink);
      await logger.beforeRequest(
        fakeRequest(body: HttpBody.text('{"a":1}')),
      );
      await logger.afterResponse(fakeTextResponse(body: 'pong'));

      expect(lines.join('\n'), contains('{"a":1}'));
      expect(lines.join('\n'), contains('pong'));
    });

    test('a streamed response is never drained to log it', () async {
      // The whole point: draining here would buffer the body and hand the
      // caller an already-consumed stream.
      var subscribed = false;
      final source = Stream<List<int>>.fromIterable([
        utf8.encode('chunk-1'),
        utf8.encode('chunk-2'),
      ]).map((chunk) {
        subscribed = true;
        return chunk;
      });
      final response = HttpStreamResponse(
        meta: fakeTextResponse().meta,
        body: source,
        contentLength: 14,
      );

      final logger = LogInterceptor(level: HttpLogLevel.body, sink: sink);
      await logger.afterResponse(response);

      expect(subscribed, isFalse, reason: 'logging must not read the body');
      expect(lines.join('\n'), contains('<stream>'));
      expect(lines.join('\n'), contains('stream'));

      // And the caller still gets every byte.
      final received = <int>[];
      await for (final chunk in response.body) {
        received.addAll(chunk);
      }
      expect(utf8.decode(received), 'chunk-1chunk-2');
    });

    test('a request stream body is not consumed either', () async {
      var subscribed = false;
      final body = HttpBody.stream(
        Stream<List<int>>.fromIterable([
          Uint8List.fromList([1, 2, 3]),
        ]).map((chunk) {
          subscribed = true;
          return chunk;
        }),
        contentLength: 3,
      );

      final logger = LogInterceptor(level: HttpLogLevel.body, sink: sink);
      await logger.beforeRequest(fakeRequest(body: body));

      expect(subscribed, isFalse);
      expect(lines.join('\n'), contains('<stream>'));
    });

    test('failures are logged with their type', () async {
      final logger = LogInterceptor(sink: sink);
      await logger.onError(
        NitroHttpTimeoutException(
          stage: TimeoutStage.connect,
          request: fakeRequest(url: 'https://example.com/slow'),
        ),
      );

      expect(lines.single, contains('FAILED'));
      expect(lines.single, contains('https://example.com/slow'));
      expect(lines.single, contains('NitroHttpTimeoutException'));
    });

    test('it passes the request through untouched', () async {
      // A logger that rewrote anything would be a bug; the chain applies
      // `value` when non-null, so returning null is what "observe only" means.
      final logger = LogInterceptor(level: HttpLogLevel.body, sink: sink);
      final request = fakeRequest();
      final result = await logger.beforeRequest(request);

      expect(result.value, isNull);
      expect(result.resolved, isNull);
      expect(result.disposition, InterceptorDisposition.next);
    });

    test('it runs in a real chain in registration order', () async {
      final chain = InterceptorChain([
        LogInterceptor(sink: (l) => lines.add('outer $l')),
        LogInterceptor(sink: (l) => lines.add('inner $l')),
      ]);

      await chain.runBeforeRequest(fakeRequest());
      await chain.runAfterResponse(fakeTextResponse());

      // Requests run outermost-first, responses outermost-last.
      expect(lines[0], startsWith('outer -->'));
      expect(lines[1], startsWith('inner -->'));
      expect(lines[2], startsWith('inner <--'));
      expect(lines[3], startsWith('outer <--'));
    });
  });

  group('ParallelInterceptors', () {
    test('members run concurrently rather than end to end', () async {
      Interceptor slow() => DelegatingInterceptor(
        onRequest: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return Interceptor.next();
        },
      );

      final watch = Stopwatch()..start();
      await ParallelInterceptors([slow(), slow(), slow()])
          .beforeRequest(fakeRequest());
      final parallel = watch.elapsedMilliseconds;

      watch.reset();
      await InterceptorChain([slow(), slow(), slow()])
          .runBeforeRequest(fakeRequest());
      final sequential = watch.elapsedMilliseconds;

      // Three 120 ms hooks: ~120 ms together against ~360 ms in turn.
      expect(parallel, lessThan(250));
      expect(sequential, greaterThan(300));
    });

    test('every member still runs when one throws', () async {
      var ran = 0;
      final group = ParallelInterceptors([
        DelegatingInterceptor(onRequest: (_) async => throw StateError('boom')),
        DelegatingInterceptor(
          onRequest: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            ran++;
            return Interceptor.next();
          },
        ),
      ]);

      await expectLater(
        group.beforeRequest(fakeRequest()),
        throwsA(isA<StateError>()),
      );
      // An abandoned hook would go on writing after its call had finished.
      expect(ran, 1);
    });

    test('a member that modifies the chain is rejected', () async {
      final group = ParallelInterceptors([
        DelegatingInterceptor(
          onRequest: (r) async => Interceptor.next(
            r.copyWith(headers: HttpHeaders.fromMap({'x': 'y'})),
          ),
        ),
      ]);

      await expectLater(
        group.beforeRequest(fakeRequest()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('observe, not modify'),
          ),
        ),
      );
    });

    test('a member that stops the chain is rejected', () async {
      final group = ParallelInterceptors([
        DelegatingInterceptor(onResponse: (_) async => Interceptor.stop()),
      ]);

      await expectLater(
        group.afterResponse(fakeTextResponse()),
        throwsA(isA<StateError>()),
      );
    });

    test('an empty group is a pass-through', () async {
      const group = ParallelInterceptors([]);
      final result = await group.beforeRequest(fakeRequest());
      expect(result.disposition, InterceptorDisposition.next);
      expect(result.value, isNull);
    });

    test('observers see responses and errors too', () async {
      final seen = <String>[];
      final group = ParallelInterceptors([
        DelegatingInterceptor(
          onResponse: (r) async {
            seen.add('response ${r.statusCode}');
            return Interceptor.next();
          },
          onFailure: (e) async {
            seen.add('error ${e.runtimeType}');
            return Interceptor.next();
          },
        ),
        LogInterceptor(sink: sink),
      ]);

      await group.afterResponse(fakeTextResponse(status: 204));
      await group.onError(
        NitroHttpTimeoutException(stage: TimeoutStage.request),
      );

      expect(seen, ['response 204', 'error NitroHttpTimeoutException']);
      expect(lines.join('\n'), contains('204'));
      expect(lines.join('\n'), contains('FAILED'));
    });
  });
}
