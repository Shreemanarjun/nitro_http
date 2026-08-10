import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

import 'support/fakes.dart';

/// A [Random] that walks a fixed sequence, so a jittered backoff has one
/// correct answer instead of a range.
final class _SeqRandom implements Random {
  _SeqRandom(this._values);

  final List<double> _values;
  int _index = 0;

  @override
  double nextDouble() => _values[_index++ % _values.length];

  @override
  int nextInt(int max) => (nextDouble() * max).floor();

  @override
  bool nextBool() => nextDouble() >= 0.5;
}

/// A sleeper that records the requested durations without waiting.
final class _Clock {
  final List<Duration> slept = <Duration>[];

  Future<void> sleep(Duration duration) async => slept.add(duration);
}

NitroHttpStatusCodeException _statusFailure(int code, {HttpHeaders? headers}) =>
    NitroHttpStatusCodeException(
      statusCode: code,
      headers: headers ?? HttpHeaders(),
      body: Uint8List(0),
      request: fakeRequest(),
    );


void main() {
  group('backoff schedule', () {
    test('produces the exact jittered sequence for a fixed Random', () {
      final policy = RetryPolicy(
        random: _SeqRandom(<double>[0.5, 0.25, 1]),
        baseDelay: const Duration(milliseconds: 200),
        maxDelay: const Duration(seconds: 30),
      );

      // cap = 200ms * 2^attempt, then full jitter: cap * nextDouble().
      expect(policy.delayFor(0), const Duration(milliseconds: 100));
      expect(policy.delayFor(1), const Duration(milliseconds: 100));
      expect(policy.delayFor(2), const Duration(milliseconds: 800));
    });

    test('saturates at maxDelay', () {
      final policy = RetryPolicy(
        random: _SeqRandom(<double>[1]),
        baseDelay: const Duration(milliseconds: 200),
        maxDelay: const Duration(seconds: 1),
      );

      expect(policy.delayFor(0), const Duration(milliseconds: 200));
      expect(policy.delayFor(1), const Duration(milliseconds: 400));
      expect(policy.delayFor(2), const Duration(milliseconds: 800));
      expect(policy.delayFor(3), const Duration(seconds: 1));
      expect(policy.delayFor(30), const Duration(seconds: 1));
    });

    test('full jitter can return zero', () {
      final policy = RetryPolicy(random: _SeqRandom(<double>[0]));
      expect(policy.delayFor(4), Duration.zero);
    });

    test('a custom delay closure replaces the schedule entirely', () {
      final policy = RetryPolicy(
        delay: (attempt) => Duration(seconds: attempt + 1),
      );

      expect(policy.delayFor(0), const Duration(seconds: 1));
      expect(policy.delayFor(2), const Duration(seconds: 3));
    });

    test('without an injected Random the delay still stays within the cap', () {
      const policy = RetryPolicy(baseDelay: Duration(milliseconds: 100));

      for (var i = 0; i < 20; i++) {
        final delay = policy.delayFor(1);
        expect(delay, greaterThanOrEqualTo(Duration.zero));
        expect(delay, lessThanOrEqualTo(const Duration(milliseconds: 200)));
      }
    });
  });

  group('shouldRetry', () {
    const policy = RetryPolicy();

    test('is true for the transient status codes', () {
      for (final code in const <int>[408, 429, 500, 502, 503, 504]) {
        expect(
          policy.shouldRetry(fakeTextResponse(status: code), null, 0),
          isTrue,
          reason: 'status $code',
        );
        expect(
          policy.shouldRetry(null, _statusFailure(code), 0),
          isTrue,
          reason: 'status $code as an exception',
        );
      }
      expect(RetryPolicy.retryableStatusCodes, <int>{408, 429, 500, 502, 503, 504});
    });

    test('is false for permanent status codes', () {
      for (final code in const <int>[200, 400, 404, 451, 501, 505]) {
        expect(
          policy.shouldRetry(fakeTextResponse(status: code), null, 0),
          isFalse,
          reason: 'status $code',
        );
      }
    });

    test('is true for every timeout stage', () {
      for (final stage in TimeoutStage.values) {
        expect(
          policy.shouldRetry(null, NitroHttpTimeoutException(stage: stage), 0),
          isTrue,
          reason: '$stage',
        );
      }
    });

    test('is true for connection failures except an unsupported scheme', () {
      for (final failure in ConnectionFailure.values) {
        expect(
          policy.shouldRetry(
            null,
            NitroHttpConnectionException(failure: failure),
            0,
          ),
          failure == ConnectionFailure.unsupportedScheme ? isFalse : isTrue,
          reason: '$failure',
        );
      }
    });

    test('is always false for a cancellation', () {
      expect(policy.shouldRetry(null, NitroHttpCancelException(), 0), isFalse);
      expect(
        RetryPolicy.isRetryableByDefault(null, NitroHttpCancelException()),
        isFalse,
      );
      // Even with a permissive custom rule, the default helper stays false.
      final permissive = RetryPolicy(
        shouldRetry: (response, error, attempt) =>
            RetryPolicy.isRetryableByDefault(response, error),
      );
      expect(
        permissive.shouldRetry(null, NitroHttpCancelException(), 0),
        isFalse,
      );
    });

    test('is false for an unclassified failure and for no signal at all', () {
      expect(policy.shouldRetry(null, NitroHttpProtocolException(), 0), isFalse);
      expect(policy.shouldRetry(null, null, 0), isFalse);
    });

    test('the budget is checked before any custom predicate runs', () {
      var consulted = 0;
      final policy = RetryPolicy(
        maxRetries: 2,
        shouldRetry: (_, _, _) {
          consulted++;
          return true;
        },
      );

      expect(policy.shouldRetry(null, null, 1), isTrue);
      expect(policy.shouldRetry(null, null, 2), isFalse);
      expect(consulted, 1);
    });
  });

  group('parseRetryAfter', () {
    test('reads delta-seconds', () {
      expect(RetryInterceptor.parseRetryAfter('120'), const Duration(seconds: 120));
      expect(RetryInterceptor.parseRetryAfter('  0 '), Duration.zero);
    });

    test('reads an IMF-fixdate against an injected clock', () {
      expect(
        RetryInterceptor.parseRetryAfter(
          'Wed, 21 Oct 2015 07:28:00 GMT',
          now: DateTime.utc(2015, 10, 21, 7, 27),
        ),
        const Duration(minutes: 1),
      );
    });

    test('reads the obsolete RFC 850 and asctime forms', () {
      expect(
        RetryInterceptor.parseRetryAfter(
          'Sunday, 06-Nov-94 08:49:37 GMT',
          now: DateTime.utc(1994, 11, 6, 8, 49, 27),
        ),
        const Duration(seconds: 10),
      );
      expect(
        RetryInterceptor.parseRetryAfter(
          'Sun Nov  6 08:49:37 1994',
          now: DateTime.utc(1994, 11, 6, 8, 49, 27),
        ),
        const Duration(seconds: 10),
      );
    });

    test('a date in the past is zero, never negative', () {
      expect(
        RetryInterceptor.parseRetryAfter(
          'Wed, 21 Oct 2015 07:28:00 GMT',
          now: DateTime.utc(2030),
        ),
        Duration.zero,
      );
    });

    test('garbage yields null', () {
      expect(RetryInterceptor.parseRetryAfter(''), isNull);
      expect(RetryInterceptor.parseRetryAfter('   '), isNull);
      expect(RetryInterceptor.parseRetryAfter('soon'), isNull);
      expect(RetryInterceptor.parseRetryAfter('-5'), isNull);
      expect(RetryInterceptor.parseRetryAfter('Wed, 99 Xxx 2015 07:28:00 GMT'), isNull);
      expect(RetryInterceptor.parseRetryAfter('Wed, 21 Oct 2015 07:28 GMT'), isNull);
    });
  });

  group('Retry-After precedence', () {
    HttpHeaders headersWith(String value) =>
        HttpHeaders()..add('Retry-After', value);

    test('a response header overrides the computed backoff', () {
      final policy = RetryPolicy(random: _SeqRandom(<double>[1]));

      expect(
        policy.delayFor(
          0,
          response: fakeTextResponse(status: 503, headers: headersWith('5')),
        ),
        const Duration(seconds: 5),
      );
    });

    test('a status-code exception header overrides it too', () {
      final policy = RetryPolicy(random: _SeqRandom(<double>[1]));

      expect(
        policy.delayFor(
          0,
          error: _statusFailure(429, headers: headersWith('7')),
        ),
        const Duration(seconds: 7),
      );
    });

    test('the hint is clamped to maxRetryAfter', () {
      final policy = RetryPolicy(
        random: _SeqRandom(<double>[1]),
        maxRetryAfter: const Duration(seconds: 10),
      );

      expect(
        policy.delayFor(
          0,
          response: fakeTextResponse(status: 503, headers: headersWith('3600')),
        ),
        const Duration(seconds: 10),
      );
    });

    test('respectRetryAfter: false ignores the header', () {
      final policy = RetryPolicy(
        random: _SeqRandom(<double>[1]),
        respectRetryAfter: false,
        baseDelay: const Duration(milliseconds: 200),
      );

      expect(
        policy.delayFor(
          0,
          response: fakeTextResponse(status: 503, headers: headersWith('5')),
        ),
        const Duration(milliseconds: 200),
      );
    });

    test('an unparseable header falls back to the schedule', () {
      final policy = RetryPolicy(
        random: _SeqRandom(<double>[1]),
        baseDelay: const Duration(milliseconds: 200),
      );

      expect(
        policy.delayFor(
          0,
          response: fakeTextResponse(status: 503, headers: headersWith('soon')),
        ),
        const Duration(milliseconds: 200),
      );
    });
  });

  group('nextAttempt', () {
    test('waits the scheduled backoff and counts the retry', () async {
      final clock = _Clock();
      final interceptor = RetryInterceptor(
        maxRetries: 3,
        sleep: clock.sleep,
        random: _SeqRandom(<double>[1]),
        baseDelay: const Duration(milliseconds: 200),
      );
      final request = fakeRequest();

      for (var attempt = 0; attempt < 3; attempt++) {
        final next = await interceptor.nextAttempt(
          request,
          attempt: attempt,
          response: fakeTextResponse(status: 503),
        );
        expect(next, same(request));
      }

      expect(clock.slept, <Duration>[
        const Duration(milliseconds: 200),
        const Duration(milliseconds: 400),
        const Duration(milliseconds: 800),
      ]);
      expect(interceptor.retriesPerformed, 3);
    });

    test('stops once the budget is exhausted, without sleeping', () async {
      final clock = _Clock();
      final interceptor = RetryInterceptor(
        maxRetries: 1,
        sleep: clock.sleep,
        delay: (_) => Duration.zero,
      );

      expect(
        await interceptor.nextAttempt(
          fakeRequest(),
          attempt: 1,
          response: fakeTextResponse(status: 503),
        ),
        isNull,
      );
      expect(clock.slept, isEmpty);
      expect(interceptor.retriesPerformed, 0);
    });

    test('a non-retryable failure stops immediately', () async {
      final clock = _Clock();
      final interceptor = RetryInterceptor(sleep: clock.sleep);

      expect(
        await interceptor.nextAttempt(
          fakeRequest(),
          attempt: 0,
          error: NitroHttpCancelException(),
        ),
        isNull,
      );
      expect(clock.slept, isEmpty);
    });

    test('beforeRetry may rewrite the request', () async {
      final clock = _Clock();
      final interceptor = RetryInterceptor(
        sleep: clock.sleep,
        delay: (_) => Duration.zero,
        beforeRetry: (request, attempt) =>
            request.copyWith(url: Uri.parse('https://retry.test/$attempt')),
      );

      final next = await interceptor.nextAttempt(
        fakeRequest(),
        attempt: 0,
        response: fakeTextResponse(status: 500),
      );

      expect(next!.url.toString(), 'https://retry.test/0');
    });

    test('beforeRetry returning null aborts the retry before sleeping', () async {
      final clock = _Clock();
      final interceptor = RetryInterceptor(
        sleep: clock.sleep,
        delay: (_) => const Duration(seconds: 9),
        beforeRetry: (_, _) => null,
      );

      expect(
        await interceptor.nextAttempt(
          fakeRequest(),
          attempt: 0,
          response: fakeTextResponse(status: 500),
        ),
        isNull,
      );
      expect(clock.slept, isEmpty);
      expect(interceptor.retriesPerformed, 0);
    });

    test('withPolicy reuses an already-built policy and the injected clock', () async {
      final clock = _Clock();
      final policy = RetryPolicy(
        maxRetries: 1,
        random: _SeqRandom(<double>[1]),
        baseDelay: const Duration(milliseconds: 50),
      );
      final interceptor = RetryInterceptor.withPolicy(policy, sleep: clock.sleep);

      expect(interceptor.policy, same(policy));
      await interceptor.nextAttempt(
        fakeRequest(),
        attempt: 0,
        error: NitroHttpTimeoutException(stage: TimeoutStage.request),
      );
      expect(clock.slept, <Duration>[const Duration(milliseconds: 50)]);

      await interceptor.wait(const Duration(seconds: 3));
      expect(clock.slept.last, const Duration(seconds: 3));
    });
  });

  test('the interceptor hooks stay pass-throughs', () async {
    final interceptor = RetryInterceptor(sleep: (_) async {});
    final request = fakeRequest();

    expect(
      (await interceptor.beforeRequest(request)).disposition,
      InterceptorDisposition.next,
    );
    expect(
      (await interceptor.afterResponse(fakeTextResponse())).disposition,
      InterceptorDisposition.next,
    );
    expect(
      (await interceptor.onError(NitroHttpProtocolException())).disposition,
      InterceptorDisposition.next,
    );
  });
}
