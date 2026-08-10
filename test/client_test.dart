import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'support/fakes.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

RawCookie _cookie({
  required String name,
  String domain = 'example.com',
  String path = '/',
  bool secure = false,
}) => RawCookie(
  name: name,
  value: '1',
  domain: domain,
  path: path,
  expiresEpochMs: 0,
  secure: secure,
  httpOnly: false,
);

void main() {
  late FakeRequestExecutor executor;
  late FakeStreamDemux demux;

  NitroHttpClient clientWith({
    ClientSettings settings = const ClientSettings(),
    List<Interceptor> interceptors = const <Interceptor>[],
  }) => NitroHttpClient(
    settings: settings,
    interceptors: interceptors,
    executor: executor,
    demux: demux,
  );

  setUp(() {
    executor = FakeRequestExecutor();
    demux = FakeStreamDemux();
  });

  tearDown(() => demux.closeAll());

  group('verbs', () {
    test('each helper sends its own method against the resolved URL', () async {
      final client = clientWith(
        settings: const ClientSettings(baseUrl: 'https://api.test/v1'),
      );
      for (var i = 0; i < 8; i++) {
        executor.bufferedResponses.add(rawResponse());
      }

      await client.get('/users', query: <String, dynamic>{'page': '2'});
      await client.head('users');
      await client.post('/users', body: const HttpBody.text('x'));
      await client.put('/users/1');
      await client.patch('/users/1');
      await client.delete('/users/1');
      await client.options_('/users');
      await client.trace('/users');

      expect(
        executor.bufferedRequests
            .map((r) => '${r.request.method.name} ${r.request.url}')
            .toList(),
        <String>[
          'get https://api.test/v1/users?page=2',
          'head https://api.test/v1/users',
          'post https://api.test/v1/users',
          'put https://api.test/v1/users/1',
          'patch https://api.test/v1/users/1',
          'delete https://api.test/v1/users/1',
          'options https://api.test/v1/users',
          'trace https://api.test/v1/users',
        ],
      );
    });

    test('requestBytes and download return raw bytes', () async {
      final client = clientWith();
      executor.bufferedResponses
        ..add(rawResponse(body: Uint8List.fromList(<int>[1, 2])))
        ..add(rawResponse(body: Uint8List.fromList(<int>[3])));

      final response = await client.requestBytes(
        HttpMethod.get,
        'https://a.test/',
      );
      expect(response.bodyBytes, <int>[1, 2]);

      expect(await client.download('https://a.test/'), <int>[3]);
      expect(executor.bufferedRequests.last.request.method, RawMethod.get);
    });

    test('requestStream takes the streamed path', () async {
      final client = clientWith();
      executor.streamedHeads.add(rawHead());

      final response = await client.requestStream(
        HttpMethod.get,
        'https://a.test/',
      );
      final id = executor.streamedRequests.single.request.requestId;
      final done = Completer<void>();
      final collected = <int>[];
      response.body.listen(collected.addAll, onDone: done.complete);

      demux
        ..push(chunk(id, <int>[7]))
        ..push(doneChunk(id));
      await done.future;

      expect(collected, <int>[7]);
    });

    test('a custom method carries its token', () async {
      final client = clientWith();
      executor.bufferedResponses.add(rawResponse());

      await client.requestText(
        HttpMethod.custom,
        'https://a.test/',
        customMethod: 'PURGE',
      );

      expect(executor.bufferedRequests.single.request.method, RawMethod.custom);
      expect(executor.bufferedRequests.single.request.customMethod, 'PURGE');
    });
  });

  group('configuration', () {
    test('the engine is configured once at construction', () {
      const settings = ClientSettings(userAgent: 'ua/1');
      final client = clientWith(settings: settings);

      expect(executor.configs, hasLength(1));
      expect(executor.configs.single.userAgent, 'ua/1');
      expect(client.settings, same(settings));
    });

    test('reconfigure pushes a second configuration and swaps the settings', () {
      final client = clientWith();
      const replacement = ClientSettings(userAgent: 'ua/2', enableCompression: false);

      client.reconfigure(replacement);

      expect(executor.configs, hasLength(2));
      expect(executor.configs.last.userAgent, 'ua/2');
      expect(executor.configs.last.enableCompression, isFalse);
      expect(client.settings, same(replacement));
    });

    test('the base URL and query are resolved before the request is built', () async {
      final client = clientWith(
        settings: const ClientSettings(baseUrl: 'https://api.test/v1/'),
      );
      executor.bufferedResponses.add(rawResponse());

      await client.get(
        'search',
        query: <String, dynamic>{
          'q': 'a b',
          'tag': <String>['x', 'y'],
          'skip': null,
        },
      );

      final url = Uri.parse(executor.bufferedRequests.single.request.url);
      expect(url.path, '/v1/search');
      expect(url.queryParameters['q'], 'a b');
      expect(url.queryParametersAll['tag'], <String>['x', 'y']);
      expect(url.queryParameters.containsKey('skip'), isFalse);
    });
  });

  group('interceptors', () {
    test('the chain wraps the runner on the way in and out', () async {
      final log = <String>[];
      final client = clientWith(
        interceptors: <Interceptor>[
          DelegatingInterceptor(
            onRequest: (request) async {
              log.add('before');
              return Interceptor.next(
                request.copyWith(url: Uri.parse('https://rewritten.test/')),
              );
            },
            onResponse: (response) async {
              log.add('after ${response.statusCode}');
              return Interceptor.next();
            },
          ),
        ],
      );
      executor.bufferedResponses.add(rawResponse(status: 200));

      final response = await client.get('https://original.test/');

      expect(log, <String>['before', 'after 200']);
      expect(
        executor.bufferedRequests.single.request.url,
        'https://rewritten.test/',
      );
      expect(response.statusCode, 200);
    });

    test('beforeRequest may answer without reaching the engine', () async {
      final canned = fakeTextResponse(status: 200, body: 'cached');
      final client = clientWith(
        interceptors: <Interceptor>[
          DelegatingInterceptor(onRequest: (_) async => Interceptor.resolve(canned)),
        ],
      );

      expect(await client.get('https://a.test/'), same(canned));
      expect(executor.bufferedRequests, isEmpty);
    });

    test('onError may turn a transport failure into a response', () async {
      final canned = fakeTextResponse(status: 200, body: 'recovered');
      final client = clientWith(
        interceptors: <Interceptor>[
          DelegatingInterceptor(onFailure: (_) async => Interceptor.resolve(canned)),
        ],
      );
      executor.bufferedResponses.add(
        rawResponse(kind: RawErrorKind.connectionRefused, message: 'refused'),
      );

      expect(await client.get('https://a.test/'), same(canned));
    });

    test('an unrecovered failure propagates', () async {
      final client = clientWith(
        interceptors: <Interceptor>[const DelegatingInterceptor()],
      );
      executor.bufferedResponses.add(
        rawResponse(kind: RawErrorKind.connectionRefused, message: 'refused'),
      );

      await expectLater(
        client.get('https://a.test/'),
        throwsA(isA<NitroHttpConnectionException>()),
      );
    });
  });

  group('retries', () {
    RetryInterceptor fastRetry({int maxRetries = 1}) => RetryInterceptor(
      maxRetries: maxRetries,
      delay: (_) => Duration.zero,
      sleep: (_) async {},
    );

    test('a retryable status is re-sent, and the last response is returned', () async {
      final client = clientWith(
        settings: const ClientSettings(throwOnStatusCode: false),
        interceptors: <Interceptor>[fastRetry()],
      );
      executor.bufferedResponses
        ..add(rawResponse(status: 503, body: _bytes('first')))
        ..add(rawResponse(status: 200, body: _bytes('second')));

      final response = await client.get('https://a.test/');

      expect(executor.bufferedRequests, hasLength(2));
      expect(response.statusCode, 200);
      expect(response.body, 'second');
    });

    test('retrying stops at maxRetries and surfaces the last failure', () async {
      final client = clientWith(
        settings: const ClientSettings(throwOnStatusCode: false),
        interceptors: <Interceptor>[fastRetry(maxRetries: 2)],
      );
      for (var i = 0; i < 3; i++) {
        executor.bufferedResponses.add(rawResponse(status: 503));
      }

      final response = await client.get('https://a.test/');

      expect(executor.bufferedRequests, hasLength(3));
      expect(response.statusCode, 503);
    });

    test('a transport failure is retried and rethrown once the budget runs out', () async {
      final client = clientWith(
        interceptors: <Interceptor>[fastRetry()],
      );
      for (var i = 0; i < 2; i++) {
        executor.bufferedResponses.add(
          rawResponse(kind: RawErrorKind.connectionReset, message: 'reset'),
        );
      }

      await expectLater(
        client.get('https://a.test/'),
        throwsA(isA<NitroHttpConnectionException>()),
      );
      expect(executor.bufferedRequests, hasLength(2));
    });

    test('a cancellation is never retried', () async {
      final client = clientWith(
        interceptors: <Interceptor>[fastRetry(maxRetries: 5)],
      );
      executor.bufferedResponses.add(
        rawResponse(kind: RawErrorKind.cancelled, message: 'aborted'),
      );

      await expectLater(
        client.get('https://a.test/'),
        throwsA(isA<NitroHttpCancelException>()),
      );
      expect(executor.bufferedRequests, hasLength(1));
    });

    test('a streamed request body refuses to be replayed', () async {
      final client = clientWith(
        settings: const ClientSettings(throwOnStatusCode: false),
        interceptors: <Interceptor>[fastRetry(maxRetries: 3)],
      );
      executor.bufferedResponses
        ..add(rawResponse(status: 503, body: _bytes('truncated')))
        ..add(rawResponse(status: 200));

      final response = await client.post(
        'https://a.test/',
        body: HttpBody.stream(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2, 3],
          ]),
        ),
      );

      expect(
        executor.bufferedRequests,
        hasLength(1),
        reason: 'a consumed body cannot be sent twice',
      );
      expect(response.statusCode, 503);
    });

    test('a streamed body also refuses to replay after a transport failure', () async {
      final client = clientWith(interceptors: <Interceptor>[fastRetry(maxRetries: 3)]);
      executor.bufferedResponses.add(
        rawResponse(kind: RawErrorKind.connectionReset, message: 'reset'),
      );

      await expectLater(
        client.post(
          'https://a.test/',
          body: HttpBody.stream(const Stream<List<int>>.empty()),
        ),
        throwsA(isA<NitroHttpConnectionException>()),
      );
      expect(executor.bufferedRequests, hasLength(1));
    });

    test('beforeRetry returning null gives up with the original response', () async {
      final client = clientWith(
        settings: const ClientSettings(throwOnStatusCode: false),
        interceptors: <Interceptor>[
          RetryInterceptor(
            delay: (_) => Duration.zero,
            sleep: (_) async {},
            beforeRetry: (_, _) => null,
          ),
        ],
      );
      executor.bufferedResponses.add(rawResponse(status: 503));

      final response = await client.get('https://a.test/');

      expect(executor.bufferedRequests, hasLength(1));
      expect(response.statusCode, 503);
    });

    test('without a retry interceptor nothing is re-sent', () async {
      final client = clientWith(
        settings: const ClientSettings(throwOnStatusCode: false),
      );
      executor.bufferedResponses.add(rawResponse(status: 503));

      await client.get('https://a.test/');

      expect(executor.bufferedRequests, hasLength(1));
    });
  });

  group('cookies', () {
    test('cookiesFor filters by domain, path and scheme; allCookies does not', () {
      final client = clientWith();
      executor.jar = <RawCookie>[
        _cookie(name: 'root'),
        _cookie(name: 'scoped', path: '/api'),
        _cookie(name: 'elsewhere', path: '/admin'),
        _cookie(name: 'otherhost', domain: 'other.test'),
        _cookie(name: 'secureOnly', secure: true),
      ];

      expect(
        client
            .cookiesFor(Uri.parse('http://example.com/api/v1'))
            .map((c) => c.name),
        <String>['root', 'scoped'],
      );
      expect(
        client
            .cookiesFor(Uri.parse('https://example.com/api/v1'))
            .map((c) => c.name),
        <String>['root', 'scoped', 'secureOnly'],
      );
      expect(client.allCookies().map((c) => c.name), <String>[
        'root',
        'scoped',
        'elsewhere',
        'otherhost',
        'secureOnly',
      ]);
      expect(executor.cookieQueries.last, '');
    });

    test('setCookie, clearCookies and flushCookies reach the engine', () {
      final client = clientWith()
        ..setCookie(const Cookie(name: 'a', value: '1', domain: 'x.test'))
        ..clearCookies()
        ..flushCookies()
        ..cancelAll();

      expect(client.isDisposed, isFalse);
      expect(executor.cookiesSet.single.name, 'a');
      expect(executor.cookiesSet.single.path, '/');
      expect(executor.clearCookiesCount, 1);
      expect(executor.flushCookiesCount, 1);
      expect(executor.cancelAllCount, 1);
    });
  });

  group('disposal', () {
    test('dispose cancels in-flight work, disposes the executor, and is idempotent', () {
      final client = clientWith()
        ..dispose()
        ..dispose();

      expect(client.isDisposed, isTrue);
      expect(executor.cancelAllCount, 1);
      expect(executor.disposeCount, 1);
    });

    test('every entry point refuses to work after disposal', () async {
      final client = clientWith()..dispose();

      await expectLater(
        client.get('https://a.test/'),
        throwsA(isA<NitroHttpDisposedException>()),
      );
      expect(
        () => client.cookiesFor(Uri.parse('https://a.test/')),
        throwsA(isA<NitroHttpDisposedException>()),
      );
      expect(client.allCookies, throwsA(isA<NitroHttpDisposedException>()));
      expect(
        () => client.setCookie(const Cookie(name: 'a', value: '1')),
        throwsA(isA<NitroHttpDisposedException>()),
      );
      expect(executor.bufferedRequests, isEmpty);
    });
  });
}
