import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'support/fakes.dart';

final Uri _url = Uri.parse('https://api.test/resource');

late FakeRequestExecutor executor;
late FakeStreamDemux demux;

NitroHttpCompatClient compatWith({bool throwOnStatusCode = false}) =>
    NitroHttpCompatClient.wrap(
      NitroHttpClient(
        // The default constructor forces this off, because `package:http`'s
        // contract is that a 404 is an ordinary response.
        settings: ClientSettings(throwOnStatusCode: throwOnStatusCode),
        executor: executor,
        demux: demux,
      ),
    );

/// The id of the single request under test. Top level because a getter cannot
/// be declared inside a function body.
int get requestId => executor.streamedRequests.single.request.requestId;

void main() {
  setUp(() {
    executor = FakeRequestExecutor();
    demux = FakeStreamDemux();
  });

  tearDown(() => demux.closeAll());

  test('a GET becomes a StreamedResponse with status, headers and body', () async {
    final client = compatWith();
    executor.streamedHeads.add(
      rawHead(
        status: 200,
        contentLength: 5,
        redirectCount: 1,
        headers: const <RawHeader>[
          RawHeader(name: 'Content-Type', value: 'text/plain'),
          RawHeader(name: 'Set-Cookie', value: 'a=1'),
          RawHeader(name: 'set-cookie', value: 'b=2'),
        ],
      ),
    );

    final request = http.Request('GET', _url);
    final response = await client.send(request);
    final body = response.stream.bytesToString();

    demux
      ..push(chunk(requestId, utf8.encode('hello')))
      ..push(doneChunk(requestId));

    expect(await body, 'hello');
    expect(response.statusCode, 200);
    expect(response.contentLength, 5);
    expect(response.reasonPhrase, 'OK');
    // A hop was followed, but *this* response is the 200 at the end of it, and
    // `package:http` reads `isRedirect` as "this response is a redirect".
    expect(response.isRedirect, isFalse);
    expect(response.request, same(request));
    expect(response.headers, <String, String>{
      // `BaseResponse.headers` is contracted to be lower-case keyed, with
      // duplicates folded on `', '`.
      'content-type': 'text/plain',
      'set-cookie': 'a=1, b=2',
    });

    final raw = executor.streamedRequests.single.request;
    expect(raw.method, RawMethod.get);
    expect(raw.url, _url.toString());
    expect(raw.bodyKind, RawBodyKind.none);
    expect(raw.options.followRedirects, 1);
    expect(raw.options.maxRedirects, 5);
  });

  test('an unfollowed 3xx reports itself as a redirect', () async {
    final client = compatWith();
    executor.streamedHeads.add(rawHead(status: 302, reasonPhrase: 'Found'));

    final response = await client.send(
      http.Request('GET', _url)..followRedirects = false,
    );
    demux.push(doneChunk(requestId));
    await response.stream.drain<void>();

    expect(response.isRedirect, isTrue);
    expect(executor.streamedRequests.single.request.options.followRedirects, 0);
  });

  test('a protocol without reason phrases reports null, not empty', () async {
    final client = compatWith();
    executor.streamedHeads.add(
      rawHead(reasonPhrase: '', version: RawHttpVersion.http2),
    );

    final response = await client.send(http.Request('GET', _url));
    demux.push(doneChunk(requestId));
    await response.stream.drain<void>();

    expect(response.reasonPhrase, isNull);
  });

  test('a redirect overflow becomes the ClientException package:http names', () async {
    final client = compatWith();
    executor.streamedHeads.add(
      rawHead(kind: RawErrorKind.tooManyRedirects, message: 'too many'),
    );

    await expectLater(
      client.send(http.Request('GET', _url)),
      throwsA(
        isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          'Redirect limit exceeded',
        ),
      ),
    );
  });

  test('a body failure after the head becomes a ClientException', () async {
    final client = compatWith();
    executor.streamedHeads.add(rawHead());

    final response = await client.send(http.Request('GET', _url));
    final body = response.stream.drain<void>();
    demux.push(errorChunk(requestId, RawErrorKind.receiveFailure, 'truncated'));

    await expectLater(body, throwsA(isA<http.ClientException>()));
  });

  group('abortable requests', () {
    test('a trigger that fires before the head aborts the send', () async {
      final client = compatWith();
      final trigger = Completer<void>();
      final held = Completer<RawResponseHead>();
      executor.onStartStreamed = (_, _) => held.future;

      final future = client.send(
        http.AbortableRequest('GET', _url, abortTrigger: trigger.future),
      );
      await pumpEventQueue();
      trigger.complete();
      await pumpEventQueue();

      expect(executor.cancelledTokens, hasLength(1));
      expect(executor.cancelledTokens.single.$2, 'aborted by abortTrigger');
      held.complete(rawHead(kind: RawErrorKind.cancelled, message: 'aborted'));

      await expectLater(future, throwsA(isA<http.RequestAbortedException>()));
    });

    test('a trigger that fires while streaming aborts the body', () async {
      final client = compatWith();
      final trigger = Completer<void>();
      executor.streamedHeads.add(rawHead());

      final response = await client.send(
        http.AbortableRequest('GET', _url, abortTrigger: trigger.future),
      );
      final body = response.stream.drain<void>();
      trigger.complete();
      await pumpEventQueue();
      demux.push(errorChunk(requestId, RawErrorKind.cancelled, 'aborted'));

      await expectLater(body, throwsA(isA<http.RequestAbortedException>()));
    });
  });

  test('request headers are forwarded', () async {
    final client = compatWith();
    executor.streamedHeads.add(rawHead());

    final request = http.Request('GET', _url)
      ..headers['X-Token'] = 'abc'
      ..headers['Accept'] = 'application/json';
    final response = await client.send(request);
    demux.push(doneChunk(requestId));
    await response.stream.drain<void>();

    expect(
      executor.streamedRequests.single.request.headers
          .map((h) => '${h.name}: ${h.value}')
          .toList(),
      containsAll(<String>['X-Token: abc', 'Accept: application/json']),
    );
  });

  test('a 404 is an ordinary response, not an exception', () async {
    final client = compatWith();
    executor.streamedHeads.add(rawHead(status: 404));

    final response = await client.send(http.Request('GET', _url));
    final body = response.stream.bytesToString();
    demux
      ..push(chunk(requestId, utf8.encode('not found')))
      ..push(doneChunk(requestId));

    expect(response.statusCode, 404);
    expect(await body, 'not found');
  });

  test('a wrapped client that throws on status codes surfaces a ClientException', () async {
    // `.wrap` keeps the caller's settings, so the throwing behaviour is theirs
    // to own — this is exactly what the default constructor turns off.
    final client = compatWith(throwOnStatusCode: true);
    executor.streamedHeads.add(rawHead(status: 404));

    final future = client.send(http.Request('GET', _url));
    await pumpEventQueue();
    demux.push(doneChunk(requestId));

    await expectLater(
      future,
      throwsA(
        isA<http.ClientException>()
            .having((e) => e.message, 'message', contains('404'))
            .having((e) => e.uri, 'uri', _url),
      ),
    );
  });

  group('request bodies', () {
    test('a small known length is buffered', () async {
      final client = compatWith();
      executor.streamedHeads.add(rawHead());

      final response = await client.send(
        http.Request('POST', _url)..body = 'hello',
      );
      demux.push(doneChunk(requestId));
      await response.stream.drain<void>();

      final sent = executor.streamedRequests.single;
      expect(sent.request.bodyKind, RawBodyKind.bytes);
      expect(sent.request.method, RawMethod.post);
      expect(utf8.decode(sent.body), 'hello');
      expect(sent.request.options.uploadContentLength, 5);
      expect(executor.uploadChunks, isEmpty);
    });

    test('a large known length is streamed', () async {
      final client = compatWith();
      executor.streamedHeads.add(rawHead());

      final payload = Uint8List(300 * 1024);
      final future = client.send(http.Request('POST', _url)..bodyBytes = payload);
      await pumpEventQueue();
      demux.push(doneChunk(requestId));
      final response = await future;
      await response.stream.drain<void>();

      final sent = executor.streamedRequests.single;
      expect(sent.request.bodyKind, RawBodyKind.streamed);
      expect(sent.body, isEmpty);
      expect(sent.request.options.uploadContentLength, payload.length);
      expect(executor.uploadedBytes, payload.length);
      expect(executor.finishedUploads, <int>[requestId]);
    });

    test('an unknown length is streamed with a chunked upload', () async {
      final client = compatWith();
      executor.streamedHeads.add(rawHead());

      final request = http.StreamedRequest('POST', _url);
      final future = client.send(request);
      request.sink
        ..add(<int>[1, 2, 3])
        ..add(<int>[4]);
      unawaited(request.sink.close());

      await pumpEventQueue();
      demux.push(doneChunk(requestId));
      final response = await future;
      await response.stream.drain<void>();

      final sent = executor.streamedRequests.single;
      expect(sent.request.bodyKind, RawBodyKind.streamed);
      expect(
        sent.request.options.uploadContentLength,
        -1,
        reason: 'an unknown length forces Transfer-Encoding: chunked',
      );
      expect(
        executor.uploadChunks.map((c) => c.bytes.toList()),
        <List<int>>[
          <int>[1, 2, 3],
          <int>[4],
        ],
      );
      expect(executor.finishedUploads, <int>[requestId]);
    });

    test('an empty body sends no payload at all', () async {
      final client = compatWith();
      executor.streamedHeads.add(rawHead());

      final response = await client.send(http.Request('POST', _url));
      demux.push(doneChunk(requestId));
      await response.stream.drain<void>();

      expect(executor.streamedRequests.single.request.bodyKind, RawBodyKind.none);
    });
  });

  test('an unrecognised verb travels as a custom method', () async {
    final client = compatWith();
    executor.streamedHeads.add(rawHead());

    final response = await client.send(http.Request('PURGE', _url));
    demux.push(doneChunk(requestId));
    await response.stream.drain<void>();

    final raw = executor.streamedRequests.single.request;
    expect(raw.method, RawMethod.custom);
    expect(raw.customMethod, 'PURGE');
  });

  test('a transport failure becomes a ClientException', () async {
    final client = compatWith();
    executor.streamedHeads.add(
      rawHead(kind: RawErrorKind.connectionRefused, message: 'refused'),
    );

    await expectLater(
      client.send(http.Request('GET', _url)),
      throwsA(
        isA<http.ClientException>()
            .having((e) => e.message, 'message', contains('Connection refused'))
            .having((e) => e.uri, 'uri', _url),
      ),
    );
  });

  group('close', () {
    test('cancels every in-flight request', () async {
      final client = compatWith();
      final held = Completer<RawResponseHead>();
      executor.onStartStreamed = (_, _) => held.future;

      final future = client.send(http.Request('GET', _url));
      await pumpEventQueue();

      client.close();

      expect(executor.cancelledTokens, hasLength(1));
      expect(executor.cancelledTokens.single.$2, 'client closed');

      held.complete(
        rawHead(kind: RawErrorKind.cancelled, message: 'client closed'),
      );
      await expectLater(future, throwsA(isA<http.ClientException>()));
    });

    test('is idempotent and refuses later requests', () async {
      final client = compatWith()
        ..close()
        ..close();

      await expectLater(
        client.send(http.Request('GET', _url)),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('already closed'),
          ),
        ),
      );
      expect(executor.streamedRequests, isEmpty);
    });

    test('a wrapped client is not disposed by close', () {
      compatWith().close();

      expect(executor.disposeCount, 0);
      expect(executor.cancelAllCount, 0);
    });

    test('inner exposes the wrapped client', () {
      final inner = NitroHttpClient(executor: executor, demux: demux);

      expect(NitroHttpCompatClient.wrap(inner).inner, same(inner));
    });
  });
}
