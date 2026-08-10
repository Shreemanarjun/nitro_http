import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  test('starts active', () {
    final token = CancelToken();

    expect(token.isCancelled, isFalse);
    expect(token.reason, isNull);
    expect(token.toString(), 'CancelToken(active)');
  });

  test('cancel is idempotent and keeps the first reason', () {
    final token = CancelToken();
    var calls = 0;
    token.addListener(() => calls++);

    token
      ..cancel('first')
      ..cancel('second');

    expect(token.isCancelled, isTrue);
    expect(token.reason, 'first');
    expect(calls, 1);
    expect(token.toString(), 'CancelToken(cancelled: first)');
  });

  test('whenCancelled completes without an error', () async {
    final token = CancelToken();
    var completed = false;
    unawaited(token.whenCancelled.then((_) => completed = true));

    expect(completed, isFalse);
    token.cancel();
    await token.whenCancelled;

    expect(completed, isTrue);
  });

  test('whenCancelled still completes when cancel runs twice', () async {
    final token = CancelToken()
      ..cancel()
      ..cancel();

    await expectLater(token.whenCancelled, completes);
  });

  group('throwIfCancelled', () {
    test('does nothing while active', () {
      expect(CancelToken().throwIfCancelled, returnsNormally);
    });

    test('throws a cancel exception carrying the reason', () {
      final token = CancelToken()..cancel('user navigated away');

      expect(
        token.throwIfCancelled,
        throwsA(
          isA<NitroHttpCancelException>()
              .having((e) => e.reason, 'reason', 'user navigated away')
              .having(
                (e) => e.message,
                'message',
                'Request cancelled: user navigated away',
              ),
        ),
      );
    });
  });

  group('listeners', () {
    test('a listener added after cancellation fires exactly once', () {
      final token = CancelToken()..cancel();
      var calls = 0;

      token.addListener(() => calls++);
      expect(calls, 1);

      // Cancelling again must not re-notify a listener the token never stored.
      token.cancel();
      expect(calls, 1);
    });

    test('every registered listener runs, in registration order', () {
      final token = CancelToken();
      final order = <String>[];
      token
        ..addListener(() => order.add('a'))
        ..addListener(() => order.add('b'))
        ..cancel();

      expect(order, <String>['a', 'b']);
    });

    test('removeListener prevents the call', () {
      final token = CancelToken();
      var calls = 0;
      void listener() => calls++;

      token
        ..addListener(listener)
        ..removeListener(listener)
        ..cancel();

      expect(calls, 0);
    });

    test('a listener may remove itself while being notified', () {
      final token = CancelToken();
      var calls = 0;
      late void Function() listener;
      listener = () {
        calls++;
        token.removeListener(listener);
      };

      token
        ..addListener(listener)
        ..cancel();

      expect(calls, 1);
    });
  });
}
