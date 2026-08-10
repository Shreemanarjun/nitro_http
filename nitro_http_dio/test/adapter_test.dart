@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
// `HttpHeaders` here always means `nitro_http`'s ordered multimap, never the
// abstract `dart:io` class of the same name.
import 'dart:io' hide HttpHeaders;
import 'dart:typed_data';

import 'package:dio/dio.dart';
// `RequestOptions`, `CancelToken` and `ProgressCallback` exist in both
// packages; in this suite every one of them means dio's.
import 'package:nitro_http/nitro_http.dart'
    hide CancelToken, ProgressCallback, RequestOptions;
// ignore: implementation_imports — the parent's documented test seam.
import 'package:nitro_http/src/nitro_http.native.dart';
import 'package:nitro_http_dio/nitro_http_dio.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/fakes.dart';

/// An adapter wired to the fake transport, plus the fakes themselves.
class Harness {
  /// Builds an adapter over fakes.
  ///
  /// [owned] routes construction through
  /// [NitroHttpDioAdapter.clientFactoryForTesting], so the owned-client branch
  /// — forced settings and disposal on close — is exercised without an engine.
  ///
  /// The default settings carry `throwOnStatusCode: false`, which is what the
  /// adapter forces on a client it owns and what its documentation requires of
  /// a borrowed one.
  Harness({
    ClientSettings settings = const ClientSettings(throwOnStatusCode: false),
    bool owned = false,
  }) {
    demux = FakeStreamDemux();
    executor = FakeRequestExecutor(demux);
    if (owned) {
      NitroHttpDioAdapter.clientFactoryForTesting = (forced) {
        settingsGivenToFactory = forced;
        return NitroHttpClient(
          settings: forced,
          executor: executor,
          demux: demux,
        );
      };
      adapter = NitroHttpDioAdapter(settings: settings);
      NitroHttpDioAdapter.clientFactoryForTesting = null;
    } else {
      adapter = NitroHttpDioAdapter(
        client: NitroHttpClient(
          settings: settings,
          executor: executor,
          demux: demux,
        ),
      );
    }
  }

  /// The fake demux backing [adapter].
  late final FakeStreamDemux demux;

  /// The fake executor backing [adapter].
  late final FakeRequestExecutor executor;

  /// The adapter under test.
  late final NitroHttpDioAdapter adapter;

  /// The settings the owned-client factory was handed, when [owned] was set.
  ClientSettings? settingsGivenToFactory;
}

/// A dio [RequestOptions] with the fields these tests care about.
RequestOptions opts({
  String method = 'GET',
  String path = 'https://api.test/v1/users',
  Map<String, dynamic>? queryParameters,
  Map<String, dynamic>? headers,
  Map<String, dynamic>? extra,
  Duration? connectTimeout,
  Duration? receiveTimeout,
  bool followRedirects = true,
  int maxRedirects = 5,
}) => RequestOptions(
  path: path,
  method: method,
  queryParameters: queryParameters,
  headers: headers,
  extra: extra,
  connectTimeout: connectTimeout,
  receiveTimeout: receiveTimeout,
  followRedirects: followRedirects,
  maxRedirects: maxRedirects,
);

/// Drains a [ResponseBody] into a string.
Future<String> readBody(ResponseBody body) async =>
    utf8.decode(await body.stream.expand((chunk) => chunk).toList());

void main() {
  tearDown(() {
    // A leaked factory would silently redirect every later test's engine.
    NitroHttpDioAdapter.clientFactoryForTesting = null;
  });

  group('request mapping', () {
    test('maps the standard verbs onto HttpMethod', () async {
      const expected = <String, RawMethod>{
        'GET': RawMethod.get,
        'HEAD': RawMethod.head,
        'POST': RawMethod.post,
        'PUT': RawMethod.put,
        'DELETE': RawMethod.delete,
        'PATCH': RawMethod.patch,
        'OPTIONS': RawMethod.options,
        'TRACE': RawMethod.trace,
      };

      for (final MapEntry(key: verb, value: raw) in expected.entries) {
        final h = Harness();
        await readBody(await h.adapter.fetch(opts(method: verb), null, null));
        expect(h.executor.lastRequest.method, raw, reason: verb);
        expect(h.executor.lastRequest.customMethod, isEmpty, reason: verb);
      }
    });

    test('lower-cased verbs still resolve to the standard method', () async {
      final h = Harness();
      await readBody(await h.adapter.fetch(opts(method: 'post'), null, null));
      expect(h.executor.lastRequest.method, RawMethod.post);
    });

    test('an unknown verb becomes a custom method carrying the token', () async {
      final h = Harness();
      await readBody(
        await h.adapter.fetch(opts(method: 'PROPFIND'), null, null),
      );
      expect(h.executor.lastRequest.method, RawMethod.custom);
      expect(h.executor.lastRequest.customMethod, 'PROPFIND');
    });

    test('sends the absolute uri dio built, ignoring ClientSettings.baseUrl',
        () async {
      // dio has already applied its own baseUrl and query. Re-resolving here
      // would produce https://engine.test/base/https://api.test/... nonsense.
      final h = Harness(
        settings: const ClientSettings(baseUrl: 'https://engine.test/base'),
      );
      await readBody(
        await h.adapter.fetch(
          opts(
            path: 'https://api.test/v1/users',
            queryParameters: <String, dynamic>{'page': '2'},
          ),
          null,
          null,
        ),
      );
      expect(h.executor.lastRequest.url, 'https://api.test/v1/users?page=2');
    });

    test('copies headers, stringifying values the way dio does', () async {
      final h = Harness();
      final when = DateTime.utc(2026, 8, 8, 12, 30);
      await readBody(
        await h.adapter.fetch(
          opts(
            headers: <String, dynamic>{
              'Authorization': 'Bearer t',
              'X-Retry': 3,
              'If-Modified-Since': when,
              'X-Skipped': null,
            },
          ),
          null,
          null,
        ),
      );

      expect(h.executor.lastHeaders, <(String, String)>[
        ('Authorization', 'Bearer t'),
        ('X-Retry', '3'),
        ('If-Modified-Since', 'Sat, 08 Aug 2026 12:30:00 GMT'),
      ]);
    });

    test('an Iterable header value becomes one field per element', () async {
      final h = Harness();
      await readBody(
        await h.adapter.fetch(
          opts(
            headers: <String, dynamic>{
              'Cookie': <String>['a=1', 'b=2'],
            },
          ),
          null,
          null,
        ),
      );
      expect(h.executor.lastHeaders, <(String, String)>[
        ('Cookie', 'a=1'),
        ('Cookie', 'b=2'),
      ]);
    });

    test('no request stream means no body', () async {
      final h = Harness();
      await readBody(await h.adapter.fetch(opts(), null, null));
      expect(h.executor.lastRequest.bodyKind, RawBodyKind.none);
      expect(h.executor.lastOptions.uploadContentLength, -1);
    });

    test('a request stream becomes a streamed body with the declared length',
        () async {
      final h = Harness();
      final body = await h.adapter.fetch(
        opts(
          method: 'POST',
          headers: <String, dynamic>{
            Headers.contentLengthHeader: '5',
            Headers.contentTypeHeader: 'text/plain',
          },
        ),
        Stream<Uint8List>.value(Uint8List.fromList(utf8.encode('hello'))),
        null,
      );
      await readBody(body);

      expect(h.executor.lastRequest.bodyKind, RawBodyKind.streamed);
      expect(h.executor.lastOptions.uploadContentLength, 5);
      expect(h.executor.uploaded.single, utf8.encode('hello'));
      expect(h.executor.finishUploadCount, 1);
    });

    test('an undeclared length leaves the upload chunked', () async {
      final h = Harness();
      await readBody(
        await h.adapter.fetch(
          opts(method: 'POST'),
          Stream<Uint8List>.value(Uint8List.fromList(<int>[1, 2, 3])),
          null,
        ),
      );
      expect(h.executor.lastOptions.uploadContentLength, -1);
    });

    test('maps connect and receive timeouts onto the engine deadlines',
        () async {
      final h = Harness();
      await readBody(
        await h.adapter.fetch(
          opts(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 12),
          ),
          null,
          null,
        ),
      );
      expect(h.executor.lastOptions.connectTimeoutMs, 3000);
      expect(h.executor.lastOptions.requestTimeoutMs, 12000);
    });

    test('a zero or absent timeout inherits from the client', () async {
      final h = Harness();
      await readBody(
        await h.adapter.fetch(
          opts(connectTimeout: Duration.zero),
          null,
          null,
        ),
      );
      expect(h.executor.lastOptions.connectTimeoutMs, -1);
      expect(h.executor.lastOptions.requestTimeoutMs, -1);
    });

    test('maps followRedirects and maxRedirects', () async {
      final follow = Harness();
      await readBody(
        await follow.adapter.fetch(opts(maxRedirects: 7), null, null),
      );
      expect(follow.executor.lastOptions.followRedirects, 1);
      expect(follow.executor.lastOptions.maxRedirects, 7);

      final stay = Harness();
      await readBody(
        await stay.adapter.fetch(
          opts(followRedirects: false, maxRedirects: 0),
          null,
          null,
        ),
      );
      expect(stay.executor.lastOptions.followRedirects, 0);
      expect(stay.executor.lastOptions.maxRedirects, 0);
    });

    test('never asks the engine for progress events', () async {
      // dio wraps the request stream with its own send-progress transformer and
      // the returned response stream with its own receive-progress handler.
      // Wiring the engine's callbacks too would fire every user callback twice,
      // once with a null total. Leaving them unset also keeps the engine from
      // emitting XFERINFO events at all.
      final h = Harness();
      var reported = false;
      final options = opts(method: 'POST')
        ..onSendProgress = ((_, _) => reported = true)
        ..onReceiveProgress = ((_, _) => reported = true);

      await readBody(
        await h.adapter.fetch(
          options,
          Stream<Uint8List>.value(Uint8List.fromList(<int>[1])),
          null,
        ),
      );

      expect(reported, isFalse, reason: 'the adapter must not report progress');
      expect(h.executor.lastOptions.reportProgress, isFalse);
    });
  });

  group('cache mode', () {
    test('defaults to normal when extra says nothing', () async {
      final h = Harness();
      await readBody(await h.adapter.fetch(opts(), null, null));
      expect(h.executor.lastOptions.cacheMode, RawCacheMode.normal);
    });

    test('accepts a CacheMode value', () async {
      final h = Harness();
      await readBody(
        await h.adapter.fetch(
          opts(
            extra: <String, dynamic>{
              nitroHttpCacheModeKey: CacheMode.onlyIfCached,
            },
          ),
          null,
          null,
        ),
      );
      expect(h.executor.lastOptions.cacheMode, RawCacheMode.onlyIfCached);
    });

    test('accepts a CacheMode name as a String', () async {
      final h = Harness();
      await readBody(
        await h.adapter.fetch(
          opts(extra: <String, dynamic>{nitroHttpCacheModeKey: 'refresh'}),
          null,
          null,
        ),
      );
      expect(h.executor.lastOptions.cacheMode, RawCacheMode.refresh);
    });

    test('rejects an unknown name instead of silently ignoring a typo',
        () async {
      final h = Harness();
      await expectLater(
        h.adapter.fetch(
          opts(extra: <String, dynamic>{nitroHttpCacheModeKey: 'no-store'}),
          null,
          null,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(h.executor.requests, isEmpty);
    });

    test('rejects a value that is neither a CacheMode nor a String', () async {
      final h = Harness();
      await expectLater(
        h.adapter.fetch(
          opts(extra: <String, dynamic>{nitroHttpCacheModeKey: 3}),
          null,
          null,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('response mapping', () {
    test('delivers the body bytes dio asked for', () async {
      final h = Harness()
        ..executor.responseChunks = <List<int>>[
          utf8.encode('{"ok"'),
          utf8.encode(':true}'),
        ];
      final body = await h.adapter.fetch(opts(), null, null);
      expect(await readBody(body), '{"ok":true}');
    });

    test('preserves duplicate response headers', () async {
      // toMap() would join these with ', ', and an Expires attribute contains a
      // comma, so the two cookies could never be split apart again.
      final h = Harness()
        ..executor.headBuilder = (request) => makeHead(
          requestId: request.requestId,
          headers: const <RawHeader>[
            RawHeader(
              name: 'Set-Cookie',
              value: 'a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT',
            ),
            RawHeader(name: 'set-cookie', value: 'b=2; Path=/'),
            RawHeader(name: 'Content-Type', value: 'application/json'),
          ],
        );

      final body = await h.adapter.fetch(opts(), null, null);
      await readBody(body);

      expect(body.headers['set-cookie'], <String>[
        'a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT',
        'b=2; Path=/',
      ]);
      expect(body.headers['content-type'], <String>['application/json']);
    });

    test('a 500 is a normal response, not a failure', () async {
      // errorKind == none means the transfer succeeded; dio's validateStatus is
      // what decides whether a 500 is an error.
      final h = Harness()
        ..executor.responseChunks = <List<int>>[utf8.encode('boom')]
        ..executor.headBuilder = (request) =>
            makeHead(requestId: request.requestId, statusCode: 500);

      final body = await h.adapter.fetch(opts(), null, null);
      expect(body.statusCode, 500);
      expect(await readBody(body), 'boom');
    });

    test('marks a followed redirect', () async {
      final h = Harness()
        ..executor.headBuilder = (request) =>
            makeHead(requestId: request.requestId, redirectCount: 2);
      final body = await h.adapter.fetch(opts(), null, null);
      await readBody(body);
      expect(body.isRedirect, isTrue);
    });

    test('marks an unfollowed 302 as a redirect', () async {
      final h = Harness()
        ..executor.headBuilder = (request) => makeHead(
          requestId: request.requestId,
          statusCode: 302,
          headers: const <RawHeader>[
            RawHeader(name: 'Location', value: 'https://api.test/moved'),
          ],
        );
      final body = await h.adapter.fetch(
        opts(followRedirects: false),
        null,
        null,
      );
      await readBody(body);
      expect(body.isRedirect, isTrue);
    });

    test('a plain 200 is not a redirect', () async {
      final h = Harness();
      final body = await h.adapter.fetch(opts(), null, null);
      await readBody(body);
      expect(body.isRedirect, isFalse);
    });

    test('forwards the status line reason phrase', () async {
      final h = Harness()
        ..executor.headBuilder = (request) => makeHead(
          requestId: request.requestId,
          statusCode: 404,
          reasonPhrase: 'Nope',
        );
      final body = await h.adapter.fetch(opts(), null, null);
      await readBody(body);
      expect(body.statusMessage, 'Nope');
    });

    test('an absent reason phrase is null so dio derives one', () async {
      // HTTP/2 and HTTP/3 removed the reason phrase from the protocol, so the
      // engine reports '' for every response negotiated over either.
      final h = Harness()
        ..executor.headBuilder = (request) => makeHead(
          requestId: request.requestId,
          version: RawHttpVersion.http2,
          reasonPhrase: '',
        );
      final body = await h.adapter.fetch(opts(), null, null);
      await readBody(body);
      expect(body.statusMessage, isNull);
    });
  });

  group('cancellation', () {
    test('cancelFuture trips the engine token', () async {
      final h = Harness()..executor.holdBodyOpen = true;
      final cancelled = Completer<void>();

      final body = await h.adapter.fetch(opts(), null, cancelled.future);
      final requestId = h.executor.lastRequest.requestId;
      final drained = readBody(body);

      expect(h.executor.cancelled, isEmpty);
      cancelled.complete();
      await pumpEventQueue();

      expect(h.executor.cancelled, contains(requestId));

      // Let the transfer settle the way the engine would after an abort.
      h.demux.pushError(requestId, RawErrorKind.cancelled, 'aborted');
      await expectLater(drained, throwsA(isA<DioException>()));
    });

    test('close(force: true) cancels this adapter\'s in-flight transfers',
        () async {
      final h = Harness()..executor.holdBodyOpen = true;
      final body = await h.adapter.fetch(opts(), null, null);
      final requestId = h.executor.lastRequest.requestId;
      unawaited(readBody(body).catchError((Object _) => ''));
      await pumpEventQueue();

      h.adapter.close(force: true);
      await pumpEventQueue();

      expect(h.executor.cancelled, contains(requestId));
    });
  });

  group('lifecycle', () {
    test('a borrowed client survives close', () async {
      final h = Harness();
      await readBody(await h.adapter.fetch(opts(), null, null));

      h.adapter.close(force: true);

      expect(h.adapter.ownsClient, isFalse);
      expect(h.executor.disposeCount, 0);
      expect(h.adapter.client.isDisposed, isFalse);
    });

    test('an owned client is disposed on close', () async {
      final h = Harness(owned: true);
      await readBody(await h.adapter.fetch(opts(), null, null));

      expect(h.adapter.ownsClient, isTrue);
      h.adapter.close();

      expect(h.executor.disposeCount, 1);
    });

    test('a non-forced close waits for an in-flight transfer', () async {
      final h = Harness(owned: true)..executor.holdBodyOpen = true;
      final body = await h.adapter.fetch(opts(), null, null);
      final requestId = h.executor.lastRequest.requestId;
      final drained = readBody(body);
      await pumpEventQueue();

      h.adapter.close();
      expect(h.executor.disposeCount, 0, reason: 'transfer still running');

      h.demux.pushDone(requestId);
      await drained;

      expect(h.executor.disposeCount, 1);
    });

    test('an owned client is forced onto throwOnStatusCode: false', () {
      // Otherwise the engine would raise before dio's validateStatus ran, and
      // would buffer every error body out of the streamed path.
      final h = Harness(
        settings: const ClientSettings(throwOnStatusCode: true),
        owned: true,
      );
      expect(h.settingsGivenToFactory?.throwOnStatusCode, isFalse);
      expect(h.adapter.client.settings.throwOnStatusCode, isFalse);
    });

    test('other settings survive the forced flag', () {
      final h = Harness(
        settings: const ClientSettings(
          baseUrl: 'https://engine.test',
          userAgent: 'nitro/1',
        ),
        owned: true,
      );
      expect(h.settingsGivenToFactory?.baseUrl, 'https://engine.test');
      expect(h.settingsGivenToFactory?.userAgent, 'nitro/1');
    });

    test('fetching after close is a StateError', () async {
      final h = Harness();
      h.adapter.close();
      await expectLater(
        h.adapter.fetch(opts(), null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('useNitroHttp installs the adapter', () {
      final demux = FakeStreamDemux();
      final executor = FakeRequestExecutor(demux);
      NitroHttpDioAdapter.clientFactoryForTesting = (settings) =>
          NitroHttpClient(
            settings: settings,
            executor: executor,
            demux: demux,
          );

      final dio = Dio()..useNitroHttp();

      expect(dio.httpClientAdapter, isA<NitroHttpDioAdapter>());
      expect((dio.httpClientAdapter as NitroHttpDioAdapter).ownsClient, isTrue);
    });
  });

  group('error mapping', () {
    final table = <String, (NitroHttpException, DioExceptionType)>{
      'connect timeout': (
        NitroHttpTimeoutException(stage: TimeoutStage.connect),
        DioExceptionType.connectionTimeout,
      ),
      'request timeout': (
        NitroHttpTimeoutException(stage: TimeoutStage.request),
        DioExceptionType.receiveTimeout,
      ),
      'idle timeout': (
        NitroHttpTimeoutException(stage: TimeoutStage.idle),
        DioExceptionType.receiveTimeout,
      ),
      'cancellation': (
        NitroHttpCancelException(),
        DioExceptionType.cancel,
      ),
      'certificate': (
        NitroHttpCertificateException(
          isPinMismatch: false,
          isClientAuthFailure: false,
        ),
        DioExceptionType.badCertificate,
      ),
      'pin mismatch': (
        NitroHttpCertificateException(
          isPinMismatch: true,
          isClientAuthFailure: false,
        ),
        DioExceptionType.badCertificate,
      ),
      'connection': (
        NitroHttpConnectionException(failure: ConnectionFailure.dns),
        DioExceptionType.connectionError,
      ),
      'status code': (
        NitroHttpStatusCodeException(
          statusCode: 404,
          headers: HttpHeaders(),
          body: Uint8List(0),
        ),
        DioExceptionType.badResponse,
      ),
      'redirect': (
        NitroHttpRedirectException(redirectCount: 31),
        DioExceptionType.unknown,
      ),
      'protocol': (
        NitroHttpProtocolException(),
        DioExceptionType.unknown,
      ),
      'decoding': (
        NitroHttpDecodingException(),
        DioExceptionType.unknown,
      ),
      'cache miss': (
        NitroHttpCacheMissException(),
        DioExceptionType.unknown,
      ),
      'disposed': (
        NitroHttpDisposedException(),
        DioExceptionType.unknown,
      ),
      'unclassified': (
        NitroHttpUnknownException(),
        DioExceptionType.unknown,
      ),
    };

    table.forEach((name, entry) {
      final (error, expected) = entry;
      test('$name maps to ${expected.name}', () {
        expect(dioExceptionTypeOf(error), expected);
      });
    });

    test('a failed head surfaces as a typed DioException', () async {
      final h = Harness()
        ..executor.headBuilder = (request) => makeHead(
          requestId: request.requestId,
          errorKind: RawErrorKind.timeoutConnect,
          errorMessage: 'connect timed out',
          engineErrorCode: 28,
        );

      final options = opts();
      await expectLater(
        h.adapter.fetch(options, null, null),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.connectionTimeout)
              .having((e) => e.error, 'error', isA<NitroHttpTimeoutException>())
              .having((e) => e.requestOptions, 'requestOptions', same(options)),
        ),
      );
    });

    test('a certificate failure keeps the original as error', () async {
      final h = Harness()
        ..executor.headBuilder = (request) => makeHead(
          requestId: request.requestId,
          errorKind: RawErrorKind.certificatePinMismatch,
          errorMessage: 'pin mismatch',
        );

      await expectLater(
        h.adapter.fetch(opts(), null, null),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badCertificate)
              .having(
                (e) => (e.error! as NitroHttpCertificateException).isPinMismatch,
                'isPinMismatch',
                isTrue,
              ),
        ),
      );
    });

    test('a borrowed client left throwing degrades to badResponse', () async {
      // The adapter forces `throwOnStatusCode: false` on a client it owns, but
      // it must not mutate a shared one. A caller who leaves the flag on gets a
      // documented, typed failure rather than a raw NitroHttpException.
      final h = Harness(
        settings: const ClientSettings(throwOnStatusCode: true),
      )..executor.headBuilder = (request) =>
          makeHead(requestId: request.requestId, statusCode: 404);

      await expectLater(
        h.adapter.fetch(opts(), null, null),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having(
                (e) => (e.error! as NitroHttpStatusCodeException).statusCode,
                'statusCode',
                404,
              ),
        ),
      );
    });

    test('a mid-stream failure errors the body stream as a DioException',
        () async {
      final h = Harness()
        ..executor.responseChunks = <List<int>>[utf8.encode('partial')]
        ..executor.bodyFailure = RawErrorKind.connectionReset;

      final body = await h.adapter.fetch(opts(), null, null);
      await expectLater(
        body.stream.drain<void>(),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.connectionError,
          ),
        ),
      );
    });
  });

  group('end-to-end', () {
    test('drives a real request through the native engine', () async {
      if (!_nativeEngineAvailable()) {
        markTestSkipped(
          'the nitro_http native library is not loadable here — run this suite '
          'with `flutter test` on a platform where the engine has been built.',
        );
        return;
      }

      Future<shelf.Response> handler(shelf.Request request) async {
        final body = await request.readAsString();
        return shelf.Response.ok(
          jsonEncode(<String, Object?>{
            'method': request.method,
            'path': '/${request.url.path}',
            'echo': body,
            'agent': request.headers['x-agent'],
          }),
          headers: <String, Object>{
            'content-type': 'application/json',
            'set-cookie': <String>['a=1; Path=/', 'b=2; Path=/'],
          },
        );
      }

      final server = await shelf_io.serve(handler, 'localhost', 0);
      addTearDown(() => server.close(force: true));

      final dio = Dio(
        BaseOptions(baseUrl: 'http://localhost:${server.port}'),
      )..useNitroHttp();
      addTearDown(dio.close);

      final response = await dio.post<Map<String, dynamic>>(
        '/echo',
        data: 'ping',
        options: Options(headers: <String, dynamic>{'x-agent': 'nitro'}),
      );

      expect(response.statusCode, 200);
      expect(response.data?['method'], 'POST');
      expect(response.data?['path'], '/echo');
      expect(response.data?['echo'], 'ping');
      expect(response.data?['agent'], 'nitro');
      expect(response.headers['set-cookie'], <String>[
        'a=1; Path=/',
        'b=2; Path=/',
      ]);
    });

    test('decodes a gzip response and strips the headers that would lie',
        () async {
      if (!_nativeEngineAvailable()) {
        markTestSkipped(
          'the nitro_http native library is not loadable here — run this suite '
          'with `flutter test` on a platform where the engine has been built.',
        );
        return;
      }

      const plain = '{"compressed":true}';
      final encoded = gzip.encode(utf8.encode(plain));

      shelf.Response handler(shelf.Request request) => shelf.Response.ok(
        encoded,
        headers: <String, Object>{
          'content-type': 'application/json',
          'content-encoding': 'gzip',
          'content-length': '${encoded.length}',
        },
      );

      final server = await shelf_io.serve(handler, 'localhost', 0);
      addTearDown(() => server.close(force: true));

      final dio = Dio(
        BaseOptions(baseUrl: 'http://localhost:${server.port}'),
      )..useNitroHttp();
      addTearDown(dio.close);

      final response = await dio.get<Map<String, dynamic>>('/gz');

      // The contract that always holds: the caller sees plaintext.
      expect(response.data?['compressed'], isTrue);

      // The engine — not libcurl — did the inflating, and it drops both headers
      // on the way out. They describe the ENCODED bytes, which nothing above
      // the engine ever sees, so leaving them would put a compressed
      // `content-length` next to a plaintext body and let `HttpCache` replay
      // decoded bytes beside a header claiming they are gzipped.
      expect(
        response.headers['content-encoding'],
        isNull,
        reason: 'a decoded body is not encoded any more',
      );
      expect(
        response.headers['content-length'],
        isNull,
        reason: 'the compressed length does not describe the decoded body',
      );
      // Only the two headers that would lie are removed.
      expect(response.headers['content-type'], <String>['application/json']);
    });
  });
}

/// Whether the `nitro_http` native library can be reached from this process.
///
/// Reading a capability is the cheapest call that actually binds the FFI
/// symbols, so it fails exactly when the engine is missing.
bool _nativeEngineAvailable() {
  try {
    // On Apple platforms Nitro resolves symbols with `DynamicLibrary.process()`,
    // so the plugin has to already be loaded into this process. In a host test
    // run nothing loads it, hence the explicit open against the artifact
    // `cmake --build build/lib` produces in the parent package.
    for (final candidate in <String>[
      Platform.environment['NITRO_HTTP_DYLIB'] ?? '',
      '../build/lib/libnitro_http.dylib',
      '../build/lib/libnitro_http.so',
      '../build/lib/nitro_http.dll',
    ]) {
      if (candidate.isEmpty || !File(candidate).existsSync()) continue;
      ffi.DynamicLibrary.open(File(candidate).absolute.path);
      break;
    }
    return NitroHttp.engineVersion.isNotEmpty;
  } on Object {
    return false;
  }
}
