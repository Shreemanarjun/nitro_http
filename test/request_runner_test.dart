import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/raw_mapping.dart';
import 'package:nitro_http/src/internal/request_runner.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'support/fakes.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late FakeRequestExecutor executor;
  late FakeStreamDemux demux;

  RequestRunner runnerWith([ClientSettings settings = const ClientSettings()]) =>
      RequestRunner(executor: executor, demux: demux, settings: settings);

  setUp(() {
    executor = FakeRequestExecutor();
    demux = FakeStreamDemux();
  });

  tearDown(() => demux.closeAll());

  group('buffered path', () {
    test('a success becomes a decoded text response', () async {
      executor.bufferedResponses.add(
        rawResponse(
          status: 201,
          body: _bytes('{"ok":true}'),
          headers: const <RawHeader>[
            RawHeader(name: 'Content-Type', value: 'application/json'),
            RawHeader(name: 'Set-Cookie', value: 'a=1'),
            RawHeader(name: 'set-cookie', value: 'b=2'),
          ],
          version: RawHttpVersion.http2,
          finalUrl: 'https://example.com/final',
          redirectCount: 1,
          fromCache: true,
          revalidated: true,
          primaryIp: '198.51.100.1',
          primaryPort: 8443,
          timings: const RawTimings(
            queueMs: 1,
            dnsMs: 2,
            connectMs: 3,
            tlsMs: 4,
            firstByteMs: 5,
            redirectMs: 6,
            totalMs: 7,
          ),
        ),
      );

      final response = await runnerWith().send(fakeRequest());

      expect(response, isA<HttpTextResponse>());
      final text = response as HttpTextResponse;
      expect(text.body, '{"ok":true}');
      expect(text.bodyToJson(), <String, Object>{'ok': true});
      expect(text.statusCode, 201);
      expect(text.version, HttpVersion.http2);
      expect(text.headers.setCookie, <String>['a=1', 'b=2']);
      expect(text.finalUrl, Uri.parse('https://example.com/final'));
      expect(text.redirectCount, 1);
      expect(text.fromCache, isTrue);
      expect(text.revalidated, isTrue);
      expect(text.primaryIp, '198.51.100.1');
      expect(text.primaryPort, 8443);
      expect(text.timings.total, const Duration(milliseconds: 7));
      expect(text.timings.dns, const Duration(milliseconds: 2));
      expect(demux.released, hasLength(1));
    });

    test('expectedBody bytes yields an undecoded byte response', () async {
      executor.bufferedResponses.add(
        rawResponse(body: Uint8List.fromList(<int>[0xff, 0x00, 0x01])),
      );

      final response = await runnerWith().send(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          expectedBody: HttpExpectedBody.bytes,
        ),
      );

      expect(response, isA<HttpBytesResponse>());
      expect(
        (response as HttpBytesResponse).bodyBytes,
        <int>[0xff, 0x00, 0x01],
      );
    });

    test('the body content type is merged in without overriding the caller', () async {
      executor.bufferedResponses
        ..add(rawResponse())
        ..add(rawResponse());
      final runner = runnerWith();

      await runner.send(
        fakeRequest(method: HttpMethod.post, body: const HttpBody.json(1)),
      );
      await runner.send(
        fakeRequest(
          method: HttpMethod.post,
          headers: HttpHeaders()..set('content-type', 'application/vnd.me+json'),
          body: const HttpBody.json(1),
        ),
      );

      String contentTypeOf(int index) => executor
          .bufferedRequests[index]
          .request
          .headers
          .firstWhere((h) => h.name.toLowerCase() == 'content-type')
          .value;

      expect(contentTypeOf(0), 'application/json; charset=utf-8');
      expect(contentTypeOf(1), 'application/vnd.me+json');
    });

    test('a non-2xx throws by default, carrying status, headers and body', () async {
      executor.bufferedResponses.add(
        rawResponse(
          status: 503,
          body: _bytes('over capacity'),
          headers: const <RawHeader>[
            RawHeader(name: 'Retry-After', value: '30'),
          ],
        ),
      );

      await expectLater(
        runnerWith().send(fakeRequest()),
        throwsA(
          isA<NitroHttpStatusCodeException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.headers['retry-after'], 'Retry-After', '30')
              .having((e) => utf8.decode(e.body), 'body', 'over capacity'),
        ),
      );
      expect(demux.released, hasLength(1), reason: 'released on the throw path');
    });

    test('a non-2xx is an ordinary response when throwing is disabled', () async {
      executor.bufferedResponses.add(
        rawResponse(status: 404, body: _bytes('nope')),
      );

      final response =
          await runnerWith(const ClientSettings(throwOnStatusCode: false))
              .send(fakeRequest());

      expect(response.statusCode, 404);
      expect(response.isSuccess, isFalse);
      expect((response as HttpTextResponse).body, 'nope');
    });

    test('every error kind surfaces as its mapped exception', () async {
      final runner = runnerWith();

      for (final kind in RawErrorKind.values) {
        if (kind == RawErrorKind.none) continue;

        final expected = mapError(kind: kind, message: 'x', engineErrorCode: 3);
        executor.bufferedResponses.add(
          rawResponse(kind: kind, message: 'x', engineCode: 3, status: 0),
        );
        final request = fakeRequest();

        await expectLater(
          runner.send(request),
          throwsA(
            isA<NitroHttpException>()
                .having((e) => e.runtimeType, 'type', expected.runtimeType)
                .having((e) => e.engineMessage, 'engineMessage', 'x')
                .having((e) => e.engineErrorCode, 'engineErrorCode', 3)
                .having((e) => e.request, 'request', same(request)),
          ),
          reason: '$kind',
        );
      }

      expect(demux.released, hasLength(RawErrorKind.values.length - 1));
    });
  });

  group('streamed path', () {
    Future<(HttpStreamResponse, int)> start({
      RawResponseHead? head,
      ClientSettings settings = const ClientSettings(),
      HttpRequest? request,
    }) async {
      executor.streamedHeads.add(head ?? rawHead(contentLength: 3));
      final response = await runnerWith(settings).sendStreamed(
        request ??
            HttpRequest(
              url: Uri.parse('https://example.com/'),
              expectedBody: HttpExpectedBody.stream,
            ),
      );
      return (response, executor.streamedRequests.last.request.requestId);
    }

    test('chunks are delivered in order and the stream closes on done', () async {
      final (response, id) = await start();
      final collected = <int>[];
      final done = Completer<void>();

      response.body.listen(collected.addAll, onDone: done.complete);
      demux
        ..push(chunk(id, <int>[1, 2]))
        ..push(chunk(id, <int>[3]))
        ..push(doneChunk(id));
      await done.future;

      expect(collected, <int>[1, 2, 3]);
      expect(response.contentLength, 3);
      expect(demux.released, <int>[id]);
    });

    test('a negative content length is reported as unknown', () async {
      final (response, id) = await start(head: rawHead());
      final done = Completer<void>();
      response.body.listen(null, onDone: done.complete);
      demux.push(doneChunk(id));
      await done.future;

      expect(response.contentLength, isNull);
    });

    test('grants the initial window, tops up per batch, and releases at the end', () async {
      final (response, id) = await start();
      final done = Completer<void>();
      response.body.listen(null, onDone: done.complete);

      expect(executor.credits, <CreditGrant>[
        (requestId: id, chunkCount: kInitialCredits, ackedChunks: 0),
      ]);

      for (var i = 0; i < 2 * kCreditBatch; i++) {
        demux.push(chunk(id, <int>[i]));
      }
      await pumpEventQueue();

      expect(executor.credits, <CreditGrant>[
        (requestId: id, chunkCount: kInitialCredits, ackedChunks: 0),
        (requestId: id, chunkCount: kCreditBatch, ackedChunks: kCreditBatch),
        (
          requestId: id,
          chunkCount: kCreditBatch,
          ackedChunks: 2 * kCreditBatch,
        ),
      ]);

      demux.push(doneChunk(id));
      await done.future;

      expect(executor.credits.last, (
        requestId: id,
        chunkCount: 0,
        ackedChunks: 2 * kCreditBatch + 1,
      ));
    });

    test('a paused consumer withholds credits until it resumes', () async {
      final (response, id) = await start();
      final sub = response.body.listen(null);
      await pumpEventQueue();

      sub.pause();
      for (var i = 0; i < kCreditBatch; i++) {
        demux.push(chunk(id, <int>[i]));
      }
      await pumpEventQueue();

      expect(
        executor.credits,
        <CreditGrant>[
          (requestId: id, chunkCount: kInitialCredits, ackedChunks: 0),
        ],
        reason: 'backpressure must close the TCP window, not buffer in Dart',
      );

      sub.resume();
      await pumpEventQueue();

      expect(executor.credits.last, (
        requestId: id,
        chunkCount: kCreditBatch,
        ackedChunks: kCreditBatch,
      ));

      await sub.cancel();
    });

    test('cancelling the body subscription cancels the transfer', () async {
      final (response, id) = await start();
      final sub = response.body.listen(null);
      demux.push(chunk(id, <int>[1]));
      await pumpEventQueue();

      await sub.cancel();

      expect(executor.cancelled, <int>[id]);
      expect(executor.credits.last, (
        requestId: id,
        chunkCount: 0,
        ackedChunks: 1,
      ));
      expect(demux.released, <int>[id]);
    });

    test('an error chunk surfaces as the mapped exception after the data', () async {
      final (response, id) = await start();
      final collected = <int>[];
      Object? error;
      final done = Completer<void>();

      response.body.listen(
        collected.addAll,
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
      demux
        ..push(chunk(id, <int>[1, 2, 3]))
        ..push(errorChunk(id, RawErrorKind.timeoutIdle, 'stalled'));
      await done.future;

      expect(collected, <int>[1, 2, 3]);
      expect(
        error,
        isA<NitroHttpTimeoutException>()
            .having((e) => e.stage, 'stage', TimeoutStage.idle)
            .having((e) => e.engineMessage, 'engineMessage', 'stalled'),
      );
      expect(demux.released, <int>[id]);
    });

    test('a head error throws before any body stream exists', () async {
      executor.streamedHeads.add(
        rawHead(kind: RawErrorKind.dnsFailure, message: 'no such host'),
      );

      await expectLater(
        runnerWith().sendStreamed(
          HttpRequest(
            url: Uri.parse('https://example.com/'),
            expectedBody: HttpExpectedBody.stream,
          ),
        ),
        throwsA(
          isA<NitroHttpConnectionException>().having(
            (e) => e.failure,
            'failure',
            ConnectionFailure.dns,
          ),
        ),
      );
      expect(demux.released, hasLength(1));
    });

    test('a non-2xx head drains the body into the exception', () async {
      executor.streamedHeads.add(rawHead(status: 500));
      final future = runnerWith().sendStreamed(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          expectedBody: HttpExpectedBody.stream,
        ),
      );
      await pumpEventQueue();
      final id = executor.streamedRequests.single.request.requestId;

      demux
        ..push(chunk(id, _bytes('server ')))
        ..push(chunk(id, _bytes('exploded')))
        ..push(doneChunk(id));

      await expectLater(
        future,
        throwsA(
          isA<NitroHttpStatusCodeException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => utf8.decode(e.body), 'body', 'server exploded'),
        ),
      );
      expect(executor.credits, <CreditGrant>[
        (requestId: id, chunkCount: kInitialCredits, ackedChunks: 0),
        (requestId: id, chunkCount: 1, ackedChunks: 1),
        (requestId: id, chunkCount: 1, ackedChunks: 2),
        (requestId: id, chunkCount: 0, ackedChunks: 3),
      ]);
      expect(demux.released, <int>[id]);
    });

    test('send routes to the streamed path for a stream body expectation', () async {
      executor.streamedHeads.add(rawHead());
      final response = await runnerWith().send(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          expectedBody: HttpExpectedBody.stream,
        ),
      );

      expect(response, isA<HttpStreamResponse>());
      expect(executor.streamedRequests, hasLength(1));
      expect(executor.bufferedRequests, isEmpty);

      final id = executor.streamedRequests.single.request.requestId;
      final done = Completer<void>();
      (response as HttpStreamResponse).body.listen(null, onDone: done.complete);
      demux.push(doneChunk(id));
      await done.future;
    });
  });

  group('upload pump', () {
    late StreamController<List<int>> source;
    late List<String> transitions;
    late Completer<RawResponse> response;

    setUp(() {
      transitions = <String>[];
      source = StreamController<List<int>>(
        onPause: () => transitions.add('pause'),
        onResume: () => transitions.add('resume'),
      );
      response = Completer<RawResponse>();
      executor.onSendBuffered = (_, _) => response.future;
    });

    Future<int> startUpload() async {
      unawaited(
        runnerWith().sendBuffered(
          fakeRequest(
            method: HttpMethod.post,
            body: HttpBody.stream(source.stream),
          ),
        ),
      );
      await pumpEventQueue();
      return executor.bufferedRequests.single.request.requestId;
    }

    test('feeds chunk by chunk and declares an unknown length', () async {
      final id = await startUpload();

      expect(
        executor.bufferedRequests.single.request.bodyKind,
        RawBodyKind.streamed,
      );
      expect(
        executor.bufferedRequests.single.request.options.uploadContentLength,
        kInherit,
      );

      source
        ..add(<int>[1, 2])
        ..add(<int>[3]);
      await pumpEventQueue();

      expect(executor.uploadChunks.map((c) => c.requestId), <int>[id, id]);
      expect(executor.uploadChunks.map((c) => c.bytes.toList()), <List<int>>[
        <int>[1, 2],
        <int>[3],
      ]);
      expect(transitions, isEmpty);

      await source.close();
      await pumpEventQueue();
      expect(executor.finishedUploads, <int>[id]);

      response.complete(rawResponse());
      await pumpEventQueue();
    });

    test('pauses above the high-water mark and resumes on a drain event', () async {
      final id = await startUpload();
      executor.onFeedUploadChunk = (_, chunk) =>
          chunk.length > 1 ? kUploadHighWaterMark : 0;

      source.add(<int>[1]);
      await pumpEventQueue();
      expect(transitions, isEmpty);

      source.add(<int>[1, 2]);
      await pumpEventQueue();
      expect(transitions, <String>['pause']);

      // A drain still above the mark must not resume the source.
      demux.pushEvent(drainEvent(id, kUploadHighWaterMark));
      await pumpEventQueue();
      expect(transitions, <String>['pause']);

      demux.pushEvent(drainEvent(id, 1024));
      await pumpEventQueue();
      expect(transitions, <String>['pause', 'resume']);

      response.complete(rawResponse());
      await pumpEventQueue();
    });

    test('a failing source aborts the upload instead of truncating it', () async {
      final id = await startUpload();

      source
        ..add(<int>[1])
        ..addError(StateError('disk went away'));
      await pumpEventQueue();

      expect(executor.finishedUploads, isEmpty);
      expect(executor.failedUploads, hasLength(1));
      expect(executor.failedUploads.single.requestId, id);
      expect(
        executor.failedUploads.single.message,
        contains('disk went away'),
      );

      response.complete(rawResponse());
      await pumpEventQueue();
      await source.close();
    });

    test('a multipart body is composed and pumped as a stream', () async {
      unawaited(
        runnerWith().sendBuffered(
          fakeRequest(
            method: HttpMethod.post,
            body: const HttpBody.multipart(
              <MultipartItem>[MultipartItem.text('a', 'x')],
              boundary: 'B',
            ),
          ),
        ),
      );
      await pumpEventQueue();

      final raw = executor.bufferedRequests.single.request;
      expect(raw.bodyKind, RawBodyKind.streamed);
      expect(
        raw.options.uploadContentLength,
        executor.uploadedBytes,
        reason: 'the declared length must match what was actually fed',
      );
      expect(
        utf8.decode(<int>[
          for (final c in executor.uploadChunks) ...c.bytes,
        ]),
        '--B\r\n'
        'Content-Disposition: form-data; name="a"\r\n'
        '\r\n'
        'x\r\n'
        '--B--\r\n',
      );

      // `source` is unused by this test: a multipart body brings its own
      // stream, and closing an unlistened controller would never complete.
      response.complete(rawResponse());
      await pumpEventQueue();
    });

    test('progress wiring and the pump share the request event stream', () async {
      // Both consumers subscribe to `demux.events(id)`. A single-subscription
      // event stream would blow up here, which is exactly how the real bug
      // showed itself: an upload with a progress callback threw instead of
      // uploading.
      final sent = <(int, int?)>[];
      final received = <(int, int?)>[];

      unawaited(
        runnerWith().sendBuffered(
          HttpRequest(
            url: Uri.parse('https://example.com/'),
            method: HttpMethod.post,
            body: HttpBody.stream(source.stream),
            onSendProgress: (t, total) => sent.add((t, total)),
            onReceiveProgress: (t, total) => received.add((t, total)),
          ),
        ),
      );
      await pumpEventQueue();

      final id = executor.bufferedRequests.single.request.requestId;
      expect(
        executor.bufferedRequests.single.request.options.reportProgress,
        isTrue,
      );

      // The pump still feeds.
      executor.onFeedUploadChunk = (_, chunk) =>
          chunk.length > 1 ? kUploadHighWaterMark : 0;
      source.add(<int>[1]);
      await pumpEventQueue();
      expect(executor.uploadChunks.single.bytes, <int>[1]);
      expect(transitions, isEmpty);

      // Progress events still reach the callbacks.
      demux
        ..pushEvent(progressEvent(id, transferred: 1, total: 4, upload: true))
        ..pushEvent(progressEvent(id, transferred: 2, total: 8));
      await pumpEventQueue();
      expect(sent, <(int, int?)>[(1, 4)]);
      expect(received, <(int, int?)>[(2, 8)]);

      // The high-water mark still pauses, and a drain still resumes — even
      // though the progress listener sees the same drain event.
      source.add(<int>[2, 3]);
      await pumpEventQueue();
      expect(transitions, <String>['pause']);

      demux.pushEvent(drainEvent(id, 0));
      await pumpEventQueue();
      expect(transitions, <String>['pause', 'resume']);

      await source.close();
      await pumpEventQueue();
      expect(executor.finishedUploads, <int>[id]);

      response.complete(rawResponse(body: _bytes('abc')));
      await pumpEventQueue();
      expect(received.last, (3, 3));
    });
  });

  group('cancellation', () {
    test('cancelling the token cancels the in-flight request', () async {
      final token = CancelToken();
      final held = Completer<RawResponse>();
      executor.onSendBuffered = (_, _) {
        token.cancel('user left');
        return held.future;
      };

      final future = runnerWith().sendBuffered(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          cancelToken: token,
        ),
      );
      await pumpEventQueue();

      final id = executor.bufferedRequests.single.request.requestId;
      expect(executor.cancelled, <int>[id]);

      held.complete(
        rawResponse(kind: RawErrorKind.cancelled, message: 'aborted'),
      );
      await expectLater(future, throwsA(isA<NitroHttpCancelException>()));
    });

    test('a token cancelled before the send still cancels the request', () async {
      final token = CancelToken()..cancel();
      executor.bufferedResponses.add(
        rawResponse(kind: RawErrorKind.cancelled, message: 'aborted'),
      );

      await expectLater(
        runnerWith().sendBuffered(
          HttpRequest(
            url: Uri.parse('https://example.com/'),
            cancelToken: token,
          ),
        ),
        throwsA(isA<NitroHttpCancelException>()),
      );
      expect(executor.cancelled, hasLength(1));
    });

    test('a completed request unsubscribes from its token', () async {
      final token = CancelToken();
      executor.bufferedResponses.add(rawResponse());

      await runnerWith().sendBuffered(
        HttpRequest(url: Uri.parse('https://example.com/'), cancelToken: token),
      );
      token.cancel();

      expect(executor.cancelled, isEmpty);
    });
  });

  group('progress', () {
    test('reportProgress is only set when a callback was supplied', () async {
      executor.bufferedResponses
        ..add(rawResponse())
        ..add(rawResponse());
      final runner = runnerWith();

      await runner.send(fakeRequest());
      await runner.send(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          onReceiveProgress: (_, _) {},
        ),
      );

      expect(
        executor.bufferedRequests.map((r) => r.request.options.reportProgress),
        <bool>[false, true],
      );
    });

    test('engine events reach the send and receive callbacks', () async {
      final sent = <(int, int?)>[];
      final received = <(int, int?)>[];
      final held = Completer<RawResponse>();
      executor.onSendBuffered = (_, _) => held.future;

      final future = runnerWith().sendBuffered(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          onSendProgress: (t, total) => sent.add((t, total)),
          onReceiveProgress: (t, total) => received.add((t, total)),
        ),
      );
      await pumpEventQueue();
      final id = executor.bufferedRequests.single.request.requestId;

      demux
        ..pushEvent(progressEvent(id, transferred: 10, total: 100, upload: true))
        ..pushEvent(progressEvent(id, transferred: 5, total: 50))
        ..pushEvent(progressEvent(id, transferred: 7))
        ..pushEvent(
          RawEvent(
            requestId: id,
            kind: RawEventKind.notice,
            a: 0,
            b: 0,
            message: 'ignored',
          ),
        );
      await pumpEventQueue();

      expect(sent, <(int, int?)>[(10, 100)]);
      expect(received, <(int, int?)>[(5, 50), (7, null)]);

      held.complete(rawResponse(body: _bytes('abcd')));
      await future;

      // The engine's progress stream is lossy, so completion synthesises 100 %.
      expect(received.last, (4, 4));
    });

    test('the streamed path reports bytes as chunks arrive', () async {
      final received = <(int, int?)>[];
      executor.streamedHeads.add(rawHead(contentLength: 3));
      final response = await runnerWith().sendStreamed(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          expectedBody: HttpExpectedBody.stream,
          onReceiveProgress: (t, total) => received.add((t, total)),
        ),
      );
      final id = executor.streamedRequests.single.request.requestId;
      final done = Completer<void>();
      response.body.listen(null, onDone: done.complete);

      demux
        ..push(chunk(id, <int>[1, 2]))
        ..push(chunk(id, <int>[3]))
        ..push(doneChunk(id));
      await done.future;

      expect(received, <(int, int?)>[(2, null), (3, null)]);
    });
  });

  group('lifecycle', () {
    test('configure pushes a new wire configuration and updates settings', () {
      final runner = runnerWith();
      const settings = ClientSettings(userAgent: 'ua/2');

      runner.configure(settings);

      expect(runner.settings, same(settings));
      expect(executor.configs.single.userAgent, 'ua/2');
    });

    test('cookie calls pass straight through', () {
      final runner = runnerWith();
      executor.jar = const <RawCookie>[
        RawCookie(
          name: 'sid',
          value: '1',
          domain: 'a.test',
          path: '/',
          expiresEpochMs: 0,
          secure: false,
          httpOnly: false,
        ),
      ];

      expect(runner.rawCookies('https://a.test/'), executor.jar);
      expect(executor.cookieQueries, <String>['https://a.test/']);

      runner
        ..setRawCookie(executor.jar.single)
        ..clearCookies()
        ..flushCookies()
        ..cancelAll();

      expect(executor.cookiesSet, hasLength(1));
      expect(executor.clearCookiesCount, 1);
      expect(executor.flushCookiesCount, 1);
      expect(executor.cancelAllCount, 1);
    });

    test('dispose cancels everything, disposes once, and refuses later work', () {
      final runner = runnerWith()
        ..dispose()
        ..dispose();

      expect(executor.cancelAllCount, 1);
      expect(executor.disposeCount, 1);
      expect(
        () => runner.send(fakeRequest()),
        throwsA(isA<NitroHttpDisposedException>()),
      );
      expect(
        () => runner.configure(const ClientSettings()),
        throwsA(isA<NitroHttpDisposedException>()),
      );
      expect(
        () => runner.rawCookies(''),
        throwsA(isA<NitroHttpDisposedException>()),
      );
      // cancelAll after disposal is a no-op rather than a failure.
      runner.cancelAll();
      expect(executor.cancelAllCount, 1);
    });
  });

  group('demux subscription shape', () {
    test('a chunk stream refuses a second listener', () {
      final chunks = demux.chunks(1)..listen(null);

      // Single-subscription on purpose: a broadcast chunk controller would
      // silently drop everything posted before the body listener attaches,
      // which is the race the runner avoids by subscribing before it starts
      // the transfer.
      expect(() => chunks.listen(null), throwsStateError);
      expect(chunks.isBroadcast, isFalse);
    });

    test('an event stream serves two listeners at once', () async {
      final events = demux.events(1);
      final first = <RawEventKind>[];
      final second = <RawEventKind>[];

      events.listen((e) => first.add(e.kind));
      events.listen((e) => second.add(e.kind));
      demux
        ..pushEvent(progressEvent(1, transferred: 1))
        ..pushEvent(drainEvent(1, 0));
      await pumpEventQueue();

      expect(events.isBroadcast, isTrue);
      expect(first, <RawEventKind>[
        RawEventKind.downloadProgress,
        RawEventKind.uploadDrain,
      ]);
      expect(second, first);
    });

    test('a response body may only be consumed once', () async {
      executor.streamedHeads.add(rawHead());
      final response = await runnerWith().sendStreamed(
        HttpRequest(
          url: Uri.parse('https://example.com/'),
          expectedBody: HttpExpectedBody.stream,
        ),
      );
      final id = executor.streamedRequests.single.request.requestId;
      final done = Completer<void>();

      response.body.listen(null, onDone: done.complete);
      expect(() => response.body.listen(null), throwsStateError);

      demux.push(doneChunk(id));
      await done.future;
    });
  });
}
