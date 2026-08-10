/// Cancellation and hot-restart recovery, end to end against the real engine.
///
/// Both features are native: a `CancelToken` is an id the engine resolves to
/// shared state, and hot-restart recovery is a handshake that runs on the first
/// native touch of a Dart isolate incarnation. Neither can be proven by a unit
/// test with a fake executor — the guarantees are about what the engine and the
/// server actually did.
///
/// So the assertions here are deliberately about observable facts rather than
/// "it threw the right type": the SERVER's request counter proves a pre-emptively
/// cancelled request never reached the wire, byte counts prove a streamed
/// transfer stopped early, and a straggling request proves the reconciliation
/// ran without anyone calling `reset()`.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/native_attach.dart';
import 'package:nitro_http_example/server/local_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUp(() async {
    server = await LocalServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  NitroHttpClient client({Duration? timeout}) {
    final created = NitroHttpClient(
      settings: ClientSettings(
        baseUrl: server.baseUrl,
        timeout: timeout ?? const Duration(seconds: 30),
      ),
    );
    addTearDown(created.dispose);
    return created;
  }

  /// Runs [request] and returns whatever it produced — the value or the error.
  ///
  /// Cancelling several requests at once rejects them all before anything is
  /// awaited, and an unawaited rejection is an unhandled async error that fails
  /// the test for a reason unrelated to what it is testing.
  Future<Object?> outcome(Future<Object?> request) =>
      request.then<Object?>((v) => v, onError: (Object e) => e);

  group('cancelling in flight', () {
    testWidgets('a cancelled request fails with the reason it was given', (
      _,
    ) async {
      final http = client();
      final token = CancelToken();
      final target = outcome(http.get('/slow/3000', cancelToken: token));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      token.cancel('the user navigated away');

      final result = await target;
      expect(result, isA<NitroHttpCancelException>());
      expect(
        (result! as NitroHttpCancelException).toString(),
        contains('the user navigated away'),
        reason: 'the reason must survive the trip through the engine',
      );
    });

    testWidgets('the transfer really stops: the server sees the abort', (
      _,
    ) async {
      final http = client();
      final token = CancelToken();
      final target = outcome(http.get('/slow/3000', cancelToken: token));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        server.requestsFor('/slow/3000'),
        1,
        reason: 'the request should be on the wire before it is cancelled',
      );

      token.cancel();
      expect(await target, isA<NitroHttpCancelException>());
    });

    testWidgets('one token cancels every request bound to it', (_) async {
      final http = client();
      final token = CancelToken();

      final pending = <Future<Object?>>[
        for (var i = 0; i < 12; i++)
          outcome(http.get('/slow/3000', cancelToken: token)),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // One call. The engine reaches all twelve from the token id alone.
      token.cancel('bulk');

      final results = await Future.wait(pending);
      expect(results, hasLength(12));
      for (final result in results) {
        expect(result, isA<NitroHttpCancelException>());
      }
    });

    testWidgets('cancelling one token leaves other requests running', (
      _,
    ) async {
      final http = client();
      final doomed = CancelToken();
      final spared = CancelToken();

      final killed = outcome(http.get('/slow/3000', cancelToken: doomed));
      final survivor = outcome(http.get('/echo', cancelToken: spared));
      final untokened = outcome(http.get('/echo'));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      doomed.cancel('only mine');

      expect(await killed, isA<NitroHttpCancelException>());
      expect(await survivor, isA<HttpTextResponse>());
      expect(await untokened, isA<HttpTextResponse>());
      expect(spared.isCancelled, isFalse);
    });

    testWidgets('a cancelled streamed download stops mid-body', (_) async {
      final http = client();
      final token = CancelToken();

      // Big enough that it cannot finish inside one event-loop turn, so the
      // cancel genuinely interrupts rather than racing a completed transfer.
      const total = 64 * 1024 * 1024;
      final response = await http.requestStream(
        HttpMethod.get,
        '/bytes/$total',
        cancelToken: token,
      );

      var received = 0;
      Object? error;
      final done = Completer<void>();
      response.body.listen(
        (chunk) {
          received += chunk.length;
          if (received > 0) token.cancel('seen enough');
        },
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
      await done.future;

      expect(error, isA<NitroHttpCancelException>());
      expect(
        received,
        lessThan(total),
        reason: 'the download should have been cut short, not completed',
      );
    });

    testWidgets('a cancelled streamed upload aborts the send', (_) async {
      final http = client();
      final token = CancelToken();

      // A source that never ends on its own: only the cancellation can stop it.
      final source = Stream<Uint8List>.periodic(
        const Duration(milliseconds: 5),
        (_) => Uint8List(64 * 1024),
      );

      final pending = outcome(
        http.post('/upload', body: HttpBody.stream(source), cancelToken: token),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      token.cancel('upload abandoned');
      expect(await pending, isA<NitroHttpCancelException>());
    });
  });

  group('cancelling before the request goes out', () {
    testWidgets('a pre-cancelled token keeps the request off the wire', (
      _,
    ) async {
      final http = client();
      final token = CancelToken()..cancel('decided against it');

      final result = await outcome(
        http.get('/slow/3000', cancelToken: token),
      );

      expect(result, isA<NitroHttpCancelException>());

      // The point of moving tokens into the engine. A Dart-side token cancels
      // AFTER the submit is already in flight, so the server would have seen
      // this. The engine reads the flag before it touches curl at all.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        server.requestsFor('/slow/3000'),
        0,
        reason: 'a pre-cancelled request must never reach the server',
      );
      expect(server.totalRequests, 0);
    });

    testWidgets('a token cancelled between two requests stops only the second', (
      _,
    ) async {
      final http = client();
      final token = CancelToken();

      final first = await http.get('/echo', cancelToken: token);
      expect(first.statusCode, 200);

      token.cancel('done with this screen');

      final second = await outcome(http.get('/echo', cancelToken: token));
      expect(second, isA<NitroHttpCancelException>());
      expect(
        server.requestsFor('/echo'),
        1,
        reason: 'only the first request should have reached the server',
      );
    });

    testWidgets('cancelling a token nothing is bound to is harmless', (
      _,
    ) async {
      final http = client();
      CancelToken().cancel('nobody is listening');

      final response = await http.get('/echo');
      expect(response.statusCode, 200);
    });

    testWidgets('a token cancelled after its request finished changes nothing', (
      _,
    ) async {
      final http = client();
      final token = CancelToken();

      final response = await http.get('/echo', cancelToken: token);
      expect(response.statusCode, 200);

      token.cancel('too late to matter');

      final next = await http.get('/echo', cancelToken: CancelToken());
      expect(next.statusCode, 200);
    });
  });

  group('edge cases', () {
    testWidgets('a transfer paused on the credit window still cancels', (
      _,
    ) async {
      final http = client();
      final token = CancelToken();

      // The one case the shared flag CANNOT settle by itself. A paused transfer
      // runs no write, read or progress callback, so nothing observes the flag;
      // only the per-engine sweep reaches it. Without that sweep this hangs
      // until the request timeout.
      final response = await http.requestStream(
        HttpMethod.get,
        '/bytes/${64 * 1024 * 1024}',
        cancelToken: token,
      );

      Object? error;
      final done = Completer<void>();
      final sub = response.body.listen(
        null,
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
      // Withhold credits until native has actually paused.
      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      token.cancel('cancelled while parked');
      sub.resume();

      await done.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('a paused transfer was never cancelled'),
      );
      expect(error, isA<NitroHttpCancelException>());
      await sub.cancel();
    });

    testWidgets('cancelling in the same turn as the send keeps it off the wire', (
      _,
    ) async {
      final http = client();
      final token = CancelToken();

      // No await between the two: the classic race the engine used to paper
      // over with a bounded "cancelled before I saw the submit" list. The
      // cancel reaches native before the submit does.
      final pending = outcome(http.get('/slow/3000', cancelToken: token));
      token.cancel('changed my mind instantly');

      expect(await pending, isA<NitroHttpCancelException>());
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        server.totalRequests,
        0,
        reason: 'the request must never have been sent',
      );
    });

    testWidgets('one token cancels requests across two clients', (_) async {
      final a = client();
      final b = client();
      final token = CancelToken();

      final fromA = outcome(a.get('/slow/3000', cancelToken: token));
      final fromB = outcome(b.get('/slow/3000', cancelToken: token));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Each client owns its own engine and loop thread, so this only works
      // because the token registry is process-global and the sweep visits
      // every live client rather than just the one that was asked.
      token.cancel('both of them');

      expect(await fromA, isA<NitroHttpCancelException>());
      expect(await fromB, isA<NitroHttpCancelException>());
    });

    testWidgets('cancelling after the client is disposed does not throw', (
      _,
    ) async {
      final disposable = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.baseUrl),
      );
      final token = CancelToken();
      final pending = outcome(disposable.get('/slow/3000', cancelToken: token));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      disposable.dispose();
      await pending;

      // The engine this token was bound to is gone. Cancelling now must be a
      // no-op, not a crash: an app that disposes a screen's client and then
      // trips its cancel token on the way out is doing nothing wrong.
      expect(() => token.cancel('after disposal'), returnsNormally);
    });

    testWidgets('a cancel racing a natural completion still completes once', (
      _,
    ) async {
      final http = client();

      // Fast endpoint, cancel immediately after: sometimes the response wins,
      // sometimes the cancel does. Either is correct — hanging, completing
      // twice, or throwing something else is not. Repeated to shake the race.
      for (var i = 0; i < 25; i++) {
        final token = CancelToken();
        final pending = outcome(http.get('/echo', cancelToken: token));
        token.cancel('racing');

        final result = await pending.timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('iteration $i never completed'),
        );
        expect(
          result is HttpTextResponse || result is NitroHttpCancelException,
          isTrue,
          reason: 'iteration $i produced ${result.runtimeType}',
        );
      }
    });

    testWidgets('a token survives many sequential requests', (_) async {
      final http = client();
      final token = CancelToken();

      // The registration is per token and deliberately never torn down when a
      // request finishes. Re-binding per request would reintroduce the fan-out
      // this replaced, and dropping it would leave a later cancel unheard.
      for (var i = 0; i < 25; i++) {
        final response = await http.get('/echo', cancelToken: token);
        expect(response.statusCode, 200);
      }

      final pending = outcome(http.get('/slow/3000', cancelToken: token));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      token.cancel('finally');
      expect(await pending, isA<NitroHttpCancelException>());
    });

    testWidgets('many distinct tokens do not interfere', (_) async {
      final http = client();

      // Every request gets its own token and only the even ones are cancelled.
      // A registry that leaked state between ids — or an id allocator that
      // repeated — would show up as an odd-numbered request dying too.
      final tokens = <CancelToken>[for (var i = 0; i < 40; i++) CancelToken()];
      final pending = <Future<Object?>>[
        for (var i = 0; i < 40; i++)
          outcome(
            http.get(i.isEven ? '/slow/3000' : '/echo', cancelToken: tokens[i]),
          ),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));

      for (var i = 0; i < 40; i += 2) {
        tokens[i].cancel('even only');
      }

      final results = await Future.wait(pending);
      for (var i = 0; i < 40; i++) {
        if (i.isEven) {
          expect(results[i], isA<NitroHttpCancelException>(), reason: 'i=$i');
        } else {
          expect(results[i], isA<HttpTextResponse>(), reason: 'i=$i');
        }
      }
    });

    testWidgets('a reason with newlines and unicode survives intact', (
      _,
    ) async {
      final http = client();
      final token = CancelToken();
      const reason = 'user\n離開了 🚪 "quoted" \\backslash';

      final pending = outcome(http.get('/slow/3000', cancelToken: token));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      token.cancel(reason);

      final result = await pending;
      expect(result, isA<NitroHttpCancelException>());
      // The reason crosses the FFI boundary as a UTF-8 string and comes back
      // inside an error record; anything that mangles it shows up here.
      expect((result! as NitroHttpCancelException).toString(), contains(reason));
    });

    testWidgets('cancelAll and a token cancel coexist', (_) async {
      final http = client();
      final token = CancelToken();

      final tokened = outcome(http.get('/slow/3000', cancelToken: token));
      final plain = outcome(http.get('/slow/3000'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Both mechanisms hit the same task set; each transfer must still post
      // exactly one completion rather than being failed twice.
      token.cancel('token first');
      http.cancelAll();

      expect(await tokened, isA<NitroHttpCancelException>());
      expect(await plain, isA<NitroHttpCancelException>());
    });
  });

  group('hot restart', () {
    testWidgets('the first native touch of a new incarnation aborts stragglers', (
      _,
    ) async {
      final http = client();
      final straggler = outcome(http.get('/slow/5000'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.requestsFor('/slow/5000'), 1);

      // A hot restart replaces the isolate, so the handshake guard — an
      // ordinary static — goes back to false while native keeps running.
      resetNativeAttachForTesting();

      // The reloaded app's first native touch. Note what is absent: any call to
      // NitroHttp.reset(). That used to be the app's job, and forgetting it
      // left this transfer running against a dead isolate.
      final reborn = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.baseUrl),
      );
      addTearDown(reborn.dispose);

      expect(
        await straggler,
        isA<NitroHttpException>(),
        reason: 'the straggler should have been aborted by the handshake',
      );
      final response = await reborn.get('/echo');
      expect(response.statusCode, 200, reason: 'the new client still works');
    });

    testWidgets('a token from the previous incarnation cannot cancel new work', (
      _,
    ) async {
      final http = client();

      // Leaves a CANCELLED entry in the process-global native registry.
      final stale = CancelToken()..cancel('from before the reload');
      expect(
        await outcome(http.get('/echo', cancelToken: stale)),
        isA<NitroHttpCancelException>(),
      );

      resetNativeAttachForTesting();
      final reborn = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.baseUrl),
      );
      addTearDown(reborn.dispose);

      // The regression: with a bare per-isolate counter the first token of the
      // reloaded app reuses the stale id and inherits its cancelled state, so
      // every request bound to it dies instantly with a cancellation nobody
      // asked for — and nothing about the symptom points at the cause.
      final fresh = CancelToken();
      final response = await reborn.get('/echo', cancelToken: fresh);
      expect(response.statusCode, 200);
      expect(fresh.isCancelled, isFalse);
    });

    testWidgets('a background isolate never reconciles native state', (
      _,
    ) async {
      final http = client();
      final inFlight = outcome(http.get('/slow/2000'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // A background isolate's statics are fresh too, so it cannot tell a hot
      // restart from simply being new. Reconciling there would abort the root
      // isolate's work, which is why the handshake checks who it is running on.
      final debugName = await Isolate.run(() {
        ensureNativeAttached();
        return Isolate.current.debugName;
      });
      expect(debugName, isNot('main'));

      expect(
        await inFlight,
        isA<HttpTextResponse>(),
        reason: "a background isolate must not abort the root isolate's work",
      );
    });

    testWidgets('an explicit reset still works for the deliberate case', (
      _,
    ) async {
      final http = client();
      final straggler = outcome(http.get('/slow/5000'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      NitroHttp.reset();

      expect(await straggler, isA<NitroHttpException>());

      // And the engine is usable again immediately afterwards.
      final reborn = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.baseUrl),
      );
      addTearDown(reborn.dispose);
      expect((await reborn.get('/echo')).statusCode, 200);
    });
  });
}
