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

  group('native identity', () {
    test('every token gets a distinct non-zero id', () {
      final ids = <int>{for (var i = 0; i < 100; i++) CancelToken().nativeId};

      expect(ids, hasLength(100), reason: 'ids must never collide');
      // Zero is the engine's "no token" sentinel. A token that took it would
      // bind itself to every request that carries no token at all.
      expect(ids, isNot(contains(0)));
      expect(ids.every((id) => id > 0), isTrue);
    });

    test('the id is stable across the token lifetime', () {
      final token = CancelToken();
      final id = token.nativeId;

      token.cancel('whatever');

      // The engine keys its state on this; a token whose id moved after
      // cancellation would leave the cancelled state stranded.
      expect(token.nativeId, id);
    });
  });
}
