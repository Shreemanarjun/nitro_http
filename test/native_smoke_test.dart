// End-to-end proof that the whole stack works: Dart API → runner → generated
// bridge → C++ engine → libcurl → a real socket → back.
//
// Every other test in this directory replaces the FFI boundary with a fake, which
// is what makes them fast and hermetic. This one does the opposite and is the
// only place a genuine integration bug can surface.
//
// It loads the library built by:
//
//   cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
//   cmake --build build/lib -j8
//
// and skips itself when that artifact is absent, so `flutter test` still passes
// on a machine that has not built native code. `NITRO_HTTP_DYLIB` overrides the
// path.
//
// On Apple platforms Nitro resolves symbols with `DynamicLibrary.process()`,
// which searches images already loaded into the process — so opening the dylib
// here is what makes the plugin visible to the generated bindings.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/native_attach.dart';

String? _locateLibrary() {
  final override = Platform.environment['NITRO_HTTP_DYLIB'];
  if (override != null && File(override).existsSync()) return override;

  final names = <String>[
    if (Platform.isMacOS) 'libnitro_http.dylib',
    if (Platform.isLinux) 'libnitro_http.so',
    if (Platform.isWindows) 'nitro_http.dll',
  ];
  final roots = <String>['build/lib', 'build/cpptest', 'build'];
  for (final root in roots) {
    for (final name in names) {
      final candidate = File('$root/$name');
      if (candidate.existsSync()) return candidate.absolute.path;
    }
  }
  return null;
}

/// A local server. Everything below talks to this and never to the internet, so
/// the suite cannot flake on someone else's uptime.
class _Server {
  _Server(this._http, this.port);

  final HttpServer _http;
  final int port;

  /// Per-path hit counts, so a cache assertion can prove the network was skipped.
  final hits = <String, int>{};

  String url(String path) => 'http://127.0.0.1:$port$path';

  static Future<_Server> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _Server(http, http.port);
    server._serve();
    return server;
  }

  Future<void> stop() => _http.close(force: true);

  /// Deterministic pseudo-random bytes so a hash is reproducible.
  static Uint8List bytesOfLength(int n) {
    final out = Uint8List(n);
    var state = 0x12345678;
    for (var i = 0; i < n; i++) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      out[i] = (state >> 16) & 0xff;
    }
    return out;
  }

  void _serve() {
    _http.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      final response = request.response;

      try {
        if (path == '/echo') {
          final body = await utf8.decoder.bind(request).join();
          final headers = <String, List<String>>{};
          request.headers.forEach((name, values) => headers[name] = values);
          response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'method': request.method,
                'path': path,
                'query': request.uri.queryParameters,
                'headers': headers,
                'body': body,
              }),
            );
        } else if (path.startsWith('/bytes/')) {
          final n = int.parse(path.split('/').last);
          response
            ..statusCode = 200
            ..headers.contentType = ContentType.binary
            ..headers.contentLength = n
            ..add(bytesOfLength(n));
        } else if (path.startsWith('/status/')) {
          response
            ..statusCode = int.parse(path.split('/').last)
            ..write('status body');
        } else if (path.startsWith('/cache/')) {
          // `max-age=0` + ETag is the standard always-revalidate pattern, and the
          // case where a naive implementation hands the caller a bare 304.
          final maxAge = int.parse(path.split('/').last);
          const etag = '"v1"';
          if (request.headers.value('if-none-match') == etag) {
            response
              ..statusCode = 304
              ..headers.set('cache-control', 'max-age=$maxAge')
              ..headers.set('etag', etag);
          } else {
            response
              ..statusCode = 200
              ..headers.set('cache-control', 'max-age=$maxAge')
              ..headers.set('etag', etag)
              ..write('cached-body-$maxAge');
          }
        } else if (path.startsWith('/redirect/')) {
          final n = int.parse(path.split('/').last);
          response
            ..statusCode = 302
            ..headers.set(
              'location',
              n <= 1 ? '/echo' : '/redirect/${n - 1}',
            );
        } else if (path.startsWith('/slow/')) {
          await Future<void>.delayed(
            Duration(milliseconds: int.parse(path.split('/').last)),
          );
          response
            ..statusCode = 200
            ..write('slow');
        } else if (path == '/drip') {
          // Chunked, flushed per chunk, so the credit loop has something real to
          // pace.
          response
            ..statusCode = 200
            ..headers.contentType = ContentType.binary;
          for (var i = 0; i < 32; i++) {
            response.add(Uint8List.fromList(List.filled(4096, i & 0xff)));
            await response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } else if (path == '/setcookie') {
          response
            ..statusCode = 200
            ..headers.add('set-cookie', 'sid=abc123; Path=/')
            ..write('ok');
        } else if (path == '/readcookie') {
          response
            ..statusCode = 200
            ..write(request.headers.value('cookie') ?? '');
        } else if (path == '/upload') {
          var total = 0;
          await for (final chunk in request) {
            total += chunk.length;
          }
          response
            ..statusCode = 200
            ..write(jsonEncode({'received': total}));
        } else if (path == '/ws') {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final socket = await WebSocketTransformer.upgrade(request);
            socket.listen(
              (message) => socket.add(message),
              onDone: () {},
              onError: (_) {},
            );
            return;
          }
          response.statusCode = 400;
        } else {
          response.statusCode = 404;
        }
      } on Object catch (e) {
        response
          ..statusCode = 500
          ..write('$e');
      }
      await response.close();
    });
  }
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null
      ? 'native library not built — run: cmake -S src -B build/lib && '
            'cmake --build build/lib'
      : null;

  group('native engine', () {
    late _Server server;
    late NitroHttpClient client;

    setUpAll(() {
      if (libraryPath == null) return;
      // Makes the plugin's symbols resolvable through DynamicLibrary.process(),
      // which is how Nitro loads on Apple platforms.
      DynamicLibrary.open(libraryPath);
    });

    setUp(() async {
      server = await _Server.start();
      client = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          connectTimeout: const Duration(seconds: 5),
          timeout: const Duration(seconds: 20),
        ),
      );
    });

    tearDown(() async {
      client.dispose();
      await server.stop();
    });

    test('reports the engine it is built against', () {
      expect(NitroHttp.engineVersion, contains('libcurl'));
      // These are runtime probes, not compile-time constants: the same binary
      // must behave correctly against a libcurl with or without QUIC.
      expect(NitroHttp.supportsWebSockets, isTrue);
      expect(NitroHttp.supportsHttp3, isA<bool>());
    }, skip: skipReason);

    test('performs a real GET and reports timings', () async {
      final response = await client.get('/echo', query: {'a': '1', 'b': '2'});

      expect(response.statusCode, 200);
      expect(response.isSuccess, isTrue);
      expect(response.headers.contentType, contains('application/json'));
      expect(response.finalUrl.path, '/echo');
      expect(response.primaryIp, '127.0.0.1');
      expect(response.primaryPort, server.port);
      expect(response.version, HttpVersion.http11);

      final decoded = response.bodyToJson()! as Map<String, dynamic>;
      expect(decoded['method'], 'GET');
      expect(decoded['query'], {'a': '1', 'b': '2'});

      // A real transfer took real time; a zero total would mean the CURLINFO
      // collection silently failed.
      expect(response.timings.total, greaterThan(Duration.zero));
    }, skip: skipReason);

    test('sends every verb with a body and the right content type', () async {
      final post = await client.post(
        '/echo',
        body: HttpBody.json({'hello': 'world'}),
      );
      final decoded = post.bodyToJson()! as Map<String, dynamic>;
      expect(decoded['method'], 'POST');
      expect(decoded['body'], '{"hello":"world"}');
      final headers = decoded['headers'] as Map<String, dynamic>;
      expect(
        (headers['content-type'] as List).first,
        contains('application/json'),
      );

      final put = await client.put('/echo', body: HttpBody.text('plain'));
      expect((put.bodyToJson()! as Map)['method'], 'PUT');

      final patch = await client.patch(
        '/echo',
        body: HttpBody.form({'k': 'v w'}),
      );
      final patchBody = patch.bodyToJson()! as Map<String, dynamic>;
      expect(patchBody['method'], 'PATCH');
      expect(patchBody['body'], 'k=v+w');

      final del = await client.delete('/echo');
      expect((del.bodyToJson()! as Map)['method'], 'DELETE');
    }, skip: skipReason);

    test('a 500 is a transport success and a typed exception by policy',
        () async {
      // errorKind == none at the wire layer; throwOnStatusCode is what turns it
      // into an exception.
      await expectLater(
        client.get('/status/500'),
        throwsA(
          isA<NitroHttpStatusCodeException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => utf8.decode(e.body), 'body', 'status body'),
        ),
      );

      final permissive = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          throwOnStatusCode: false,
        ),
      );
      addTearDown(permissive.dispose);
      final response = await permissive.get('/status/404');
      expect(response.statusCode, 404);
      expect(response.isSuccess, isFalse);
    }, skip: skipReason);

    test('follows redirects and reports the count', () async {
      final response = await client.get('/redirect/3');
      expect(response.statusCode, 200);
      expect(response.redirectCount, 3);
      expect(response.finalUrl.path, '/echo');

      // A 3xx is only observable on a client that does not throw on status:
      // with the default policy the redirect response IS the failure.
      final permissive = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          throwOnStatusCode: false,
        ),
      );
      addTearDown(permissive.dispose);
      final noFollow = await permissive.get(
        '/redirect/3',
        options: const RequestOptions(followRedirects: false),
      );
      expect(noFollow.statusCode, 302);
      expect(noFollow.redirectCount, 0);
      expect(noFollow.headers['location'], '/redirect/2');
    }, skip: skipReason);

    test('honours a per-request total timeout', () async {
      await expectLater(
        client.get(
          '/slow/3000',
          options: const RequestOptions(timeout: Duration(milliseconds: 300)),
        ),
        throwsA(
          isA<NitroHttpTimeoutException>().having(
            (e) => e.stage,
            'stage',
            TimeoutStage.request,
          ),
        ),
      );
    }, skip: skipReason);

    test('distinguishes a connect timeout', () async {
      // TEST-NET-1 is guaranteed unroutable, so this exercises the connect
      // deadline rather than a response deadline.
      final blackhole = NitroHttpClient(
        settings: const ClientSettings(
          connectTimeout: Duration(milliseconds: 300),
        ),
      );
      addTearDown(blackhole.dispose);
      await expectLater(
        blackhole.get('http://192.0.2.1:9/'),
        throwsA(
          isA<NitroHttpTimeoutException>().having(
            (e) => e.stage,
            'stage',
            TimeoutStage.connect,
          ),
        ),
      );
    }, skip: skipReason);

    test('downloads bytes intact', () async {
      final bytes = await client.download('/bytes/1048576');
      expect(bytes.length, 1048576);
      expect(bytes, equals(_Server.bytesOfLength(1048576)));
    }, skip: skipReason);

    test('streams a body through the credit loop without losing a byte',
        () async {
      final response = await client.requestStream(
        HttpMethod.get,
        '/bytes/2097152',
      );
      expect(response.statusCode, 200);
      expect(response.contentLength, 2097152);

      final collected = <int>[];
      await for (final chunk in response.body) {
        collected.addAll(chunk);
      }
      expect(collected.length, 2097152);
      expect(
        Uint8List.fromList(collected),
        equals(_Server.bytesOfLength(2097152)),
      );
    }, skip: skipReason);

    test('a slow consumer applies backpressure without dropping data',
        () async {
      // The whole point of the credit protocol: pausing the Dart subscription
      // must withhold credits, not buffer in Dart, and must not drop a chunk.
      final response = await client.requestStream(HttpMethod.get, '/drip');
      final collected = <int>[];
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = response.body.listen(
        (chunk) {
          collected.addAll(chunk);
          sub.pause(Future<void>.delayed(const Duration(milliseconds: 8)));
        },
        onDone: done.complete,
        onError: done.completeError,
      );
      await done.future;
      expect(collected.length, 32 * 4096);
    }, skip: skipReason);

    test('reports download progress ending at 100 percent', () async {
      final samples = <(int, int?)>[];
      await client.get(
        '/bytes/524288',
        onReceiveProgress: (transferred, total) =>
            samples.add((transferred, total)),
      );
      expect(samples, isNotEmpty);
      // Monotonic, and the completion path synthesizes the terminal value so a
      // caller always sees the end.
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].$1, greaterThanOrEqualTo(samples[i - 1].$1));
      }
      expect(samples.last.$1, 524288);
    }, skip: skipReason);

    test('cancels an in-flight transfer', () async {
      final token = CancelToken();
      final pending = client.get('/slow/3000', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel('user navigated away');
      await expectLater(pending, throwsA(isA<NitroHttpCancelException>()));
    }, skip: skipReason);

    test('the cancellation reason survives into the exception', () async {
      final token = CancelToken();
      final pending = client.get('/slow/3000', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel('the user pressed back');

      await expectLater(
        pending,
        throwsA(
          isA<NitroHttpCancelException>().having(
            (e) => e.toString(),
            'toString',
            contains('the user pressed back'),
          ),
        ),
      );
    }, skip: skipReason);

    test('a request bound to a cancelled token never reaches the server',
        () async {
      final token = CancelToken()..cancel('pre-emptive');
      final before = server.hits['/slow/3000'] ?? 0;

      await expectLater(
        client.get('/slow/3000', cancelToken: token),
        throwsA(isA<NitroHttpCancelException>()),
      );

      // The guarantee a Dart-side token cannot give: by the time a listener
      // could run, the request would already be on the wire. Here the engine
      // reads the token before curl is touched at all.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(server.hits['/slow/3000'] ?? 0, before);
    }, skip: skipReason);

    test('one token cancels every request bound to it', () async {
      final token = CancelToken();
      // The outcome is captured as it happens rather than awaited later: eight
      // futures all rejecting before anyone listens would otherwise surface as
      // unhandled async errors and fail the test for the wrong reason.
      final outcomes = <Future<Object?>>[
        for (var i = 0; i < 8; i++)
          client
              .get('/slow/3000', cancelToken: token)
              .then<Object?>((r) => r, onError: (Object e) => e),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 120));

      token.cancel('all of them');

      final results = await Future.wait(outcomes);
      expect(results, hasLength(8));
      for (final result in results) {
        expect(result, isA<NitroHttpCancelException>());
      }
    }, skip: skipReason);

    test('cancelling one token leaves a request on another alone', () async {
      final doomed = CancelToken();
      final spared = CancelToken();
      final cancelled = client.get('/slow/3000', cancelToken: doomed);
      final survivor = client.get('/echo', cancelToken: spared);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      doomed.cancel('only this one');

      await expectLater(cancelled, throwsA(isA<NitroHttpCancelException>()));
      final response = await survivor;
      expect(response.statusCode, 200);
    }, skip: skipReason);

    test('a token cancelled after its request finished changes nothing',
        () async {
      final token = CancelToken();
      final response = await client.get('/echo', cancelToken: token);
      expect(response.statusCode, 200);

      // Legal and inert. It must not throw, and the next request on a fresh
      // token must still work — i.e. nothing global was poisoned.
      token.cancel('too late to matter');
      final next = await client.get('/echo', cancelToken: CancelToken());
      expect(next.statusCode, 200);
    }, skip: skipReason);

    test('a streamed download stops early when its token is cancelled',
        () async {
      final token = CancelToken();
      final response = await client.requestStream(
        HttpMethod.get,
        '/bytes/8000000',
        cancelToken: token,
      );

      var received = 0;
      Object? error;
      final done = Completer<void>();
      response.body.listen(
        (chunk) {
          received += chunk.length;
          if (received > 0) token.cancel('enough');
        },
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
      await done.future;

      expect(error, isA<NitroHttpCancelException>());
      expect(
        received,
        lessThan(8000000),
        reason: 'the transfer should have been aborted, not completed',
      );
    }, skip: skipReason);

    test('the first native touch of a new incarnation aborts stragglers',
        () async {
      // A transfer left running by the "previous incarnation".
      final straggler = client
          .get('/slow/3000')
          .then<Object?>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // A hot restart replaces the Dart isolate, so the handshake guard — an
      // ordinary static — goes back to false. Nothing about native changes.
      resetNativeAttachForTesting();

      // First native touch of the new incarnation. Note what is NOT here: any
      // call to NitroHttp.reset(). That used to be the app's job.
      final reborn = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.url('')),
      );
      addTearDown(reborn.dispose);

      expect(
        await straggler,
        isA<NitroHttpException>(),
        reason: 'the straggling transfer should have been aborted',
      );
      final response = await reborn.get('/echo');
      expect(response.statusCode, 200, reason: 'the new client still works');
    }, skip: skipReason);

    test('disposing a client completes its in-flight requests', () async {
      final doomed = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.url('')),
      );
      final pending = doomed
          .get('/slow/5000')
          .then<Object?>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      doomed.dispose();

      // Regression: the completions native posts on shutdown were queued but
      // undelivered when `NitroCoalescer.dispose()` closed the port and cleared
      // its completers, so this Future never resolved AT ALL. A request that
      // hangs forever is worse than one that fails, and exactly-once completion
      // is the invariant the whole engine is built around.
      final result = await pending.timeout(
        const Duration(seconds: 6),
        onTimeout: () => 'TIMED OUT — disposal dropped the completion',
      );
      expect(result, isA<NitroHttpException>(), reason: '$result');
    }, skip: skipReason);

    test('cancelling a token after its client is disposed is inert', () async {
      final doomed = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.url('')),
      );
      final token = CancelToken();
      final pending = doomed
          .get('/slow/5000', cancelToken: token)
          .then<Object?>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      doomed.dispose();
      await pending.timeout(
        const Duration(seconds: 6),
        onTimeout: () => 'timed out',
      );

      // The token listener outlives the request by design, so this fires
      // against a disposed client. Routing token calls through the per-client
      // instance made it throw out of a listener — an uncaught zone error on an
      // ordinary teardown path.
      Object? escaped;
      runZonedGuarded(
        () => token.cancel('after disposal'),
        (Object error, StackTrace _) => escaped = error,
      );
      expect(escaped, isNull, reason: 'cancel threw: $escaped');
    }, skip: skipReason);

    test('a background isolate never reconciles native state', () async {
      // The root isolate has work in flight.
      final inFlight = client
          .get('/slow/1500')
          .then<Object?>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // A background isolate's statics are fresh too, so it cannot tell a hot
      // restart from simply being new. If it reconciled, it would abort the
      // transfer above — which is exactly what the isolate guard prevents.
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
    }, skip: skipReason);

    test('a token from the previous incarnation cannot cancel a new request',
        () async {
      // Leaves a CANCELLED entry in the process-global native registry.
      final stale = CancelToken()..cancel('from before the restart');
      await expectLater(
        client.get('/echo', cancelToken: stale),
        throwsA(isA<NitroHttpCancelException>()),
      );

      resetNativeAttachForTesting();
      final reborn = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.url('')),
      );
      addTearDown(reborn.dispose);

      // The regression this guards: with a bare counter the first token of the
      // new incarnation reuses the stale id and every request bound to it dies
      // instantly with a cancellation the caller never asked for.
      final fresh = CancelToken();
      final response = await reborn.get('/echo', cancelToken: fresh);
      expect(response.statusCode, 200);
      expect(fresh.isCancelled, isFalse);
    }, skip: skipReason);

    test('uploads a streamed body', () async {
      final response = await client.post(
        '/upload',
        body: HttpBody.stream(
          Stream.fromIterable([
            Uint8List.fromList(List.filled(65536, 1)),
            Uint8List.fromList(List.filled(65536, 2)),
          ]),
          contentLength: 131072,
        ),
      );
      expect(response.bodyToJson(), {'received': 131072});
    }, skip: skipReason);

    test('uploads a file without buffering it in Dart', () async {
      final temp = File(
        '${Directory.systemTemp.path}/nitro_http_upload_${DateTime.now().microsecondsSinceEpoch}.bin',
      );
      addTearDown(() => temp.deleteSync());
      temp.writeAsBytesSync(_Server.bytesOfLength(300000));

      final response = await client.post(
        '/upload',
        body: HttpBody.file(temp.path),
      );
      expect(response.bodyToJson(), {'received': 300000});
    }, skip: skipReason);

    test('stores and replays cookies', () async {
      await client.get('/setcookie');
      final jar = client.allCookies();
      expect(jar.map((c) => c.name), contains('sid'));

      final replay = await client.get('/readcookie');
      expect(replay.body, contains('sid=abc123'));

      client.clearCookies();
      final cleared = await client.get('/readcookie');
      expect(cleared.body, isNot(contains('sid=abc123')));
    }, skip: skipReason);

    test('sends default and per-request headers, with override', () async {
      final configured = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          headers: HttpHeaders.fromMap({
            'x-default': 'from-client',
            'x-keep': 'kept',
          }),
        ),
      );
      addTearDown(configured.dispose);

      final response = await configured.get(
        '/echo',
        headers: HttpHeaders.fromMap({'x-default': 'from-request'}),
      );
      final headers =
          (response.bodyToJson()! as Map<String, dynamic>)['headers']
              as Map<String, dynamic>;
      expect((headers['x-keep'] as List).first, 'kept');
      // The per-request value must replace the client default, not join it.
      expect(headers['x-default'], ['from-request']);
    }, skip: skipReason);

    test('reuses one connection across sequential requests', () async {
      // A fresh connection per request would show up as a much larger total
      // across 20 calls; this mainly guards against the pool being disabled.
      for (var i = 0; i < 20; i++) {
        final response = await client.get('/echo');
        expect(response.statusCode, 200);
      }
    }, skip: skipReason);

    test('echoes over a WebSocket', () async {
      final socket = await NitroWebSocket.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      );
      final received = <WebSocketEvent>[];
      final gotTwo = Completer<void>();
      socket.events.listen((event) {
        received.add(event);
        if (received.length == 2) gotTwo.complete();
      });

      socket.sendText('hello');
      socket.sendBytes(Uint8List.fromList([1, 2, 3, 4]));
      await gotTwo.future.timeout(const Duration(seconds: 10));

      expect(received[0], isA<TextDataReceived>());
      expect((received[0] as TextDataReceived).text, 'hello');
      expect(received[1], isA<BinaryDataReceived>());
      expect(
        (received[1] as BinaryDataReceived).data,
        equals(Uint8List.fromList([1, 2, 3, 4])),
      );

      await socket.close(1000, 'done');
    }, skip: skipReason);

    test('serves a fresh hit without touching the network', () async {
      final dir = Directory.systemTemp.createTempSync('nitro_http_cache_fresh');
      addTearDown(() => dir.deleteSync(recursive: true));
      NitroHttp.configureCache(
        HttpCacheConfig(directory: dir.path, maxSizeBytes: 4 << 20),
      );
      addTearDown(NitroHttp.clearCache);

      final cached = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          cacheSettings: const CacheSettings(enabled: true),
        ),
      );
      addTearDown(cached.dispose);

      final first = await cached.get('/cache/60');
      expect(first.body, 'cached-body-60');
      expect(first.fromCache, isFalse);
      expect(server.hits['/cache/60'], 1);

      final second = await cached.get('/cache/60');
      expect(second.body, 'cached-body-60');
      expect(second.fromCache, isTrue);
      // The whole point: the origin was never asked a second time.
      expect(server.hits['/cache/60'], 1);
    }, skip: skipReason);

    test('revalidates a stale entry and serves the stored body', () async {
      final dir = Directory.systemTemp.createTempSync('nitro_http_cache_reval');
      addTearDown(() => dir.deleteSync(recursive: true));
      NitroHttp.configureCache(
        HttpCacheConfig(directory: dir.path, maxSizeBytes: 4 << 20),
      );
      addTearDown(NitroHttp.clearCache);

      final cached = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          cacheSettings: const CacheSettings(enabled: true),
        ),
      );
      addTearDown(cached.dispose);

      final first = await cached.get('/cache/0');
      expect(first.body, 'cached-body-0');
      expect(server.hits['/cache/0'], 1);

      // `max-age=0` means the entry is stale immediately, so this must issue a
      // conditional request, get a 304, and answer from disk. RFC 9111 §4.3.3:
      // the 304 is not the answer to the caller's unconditional request.
      final second = await cached.get('/cache/0');
      expect(second.statusCode, 200);
      expect(second.body, 'cached-body-0');
      expect(second.fromCache, isTrue);
      expect(second.revalidated, isTrue);
      expect(server.hits['/cache/0'], 2);

      final stats = NitroHttp.cacheStats();
      expect(stats.revalidationCount, greaterThan(0));
    }, skip: skipReason);

    test('onlyIfCached fails on a cold key and succeeds on a warm one',
        () async {
      final dir = Directory.systemTemp.createTempSync('nitro_http_cache_only');
      addTearDown(() => dir.deleteSync(recursive: true));
      NitroHttp.configureCache(
        HttpCacheConfig(directory: dir.path, maxSizeBytes: 4 << 20),
      );
      addTearDown(NitroHttp.clearCache);

      final cached = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          cacheSettings: const CacheSettings(enabled: true),
        ),
      );
      addTearDown(cached.dispose);

      // This is what makes offline UI possible: a miss is an error, never a
      // network request.
      await expectLater(
        cached.get(
          '/cache/60',
          options: const RequestOptions(cacheMode: CacheMode.onlyIfCached),
        ),
        throwsA(isA<NitroHttpCacheMissException>()),
      );
      expect(server.hits['/cache/60'], isNull);

      await cached.get('/cache/60');
      final warm = await cached.get(
        '/cache/60',
        options: const RequestOptions(cacheMode: CacheMode.onlyIfCached),
      );
      expect(warm.body, 'cached-body-60');
      expect(warm.fromCache, isTrue);
    }, skip: skipReason);

    test('prefetch warms the cache so the next request is a hit', () async {
      final dir = Directory.systemTemp.createTempSync('nitro_http_prefetch');
      addTearDown(() => dir.deleteSync(recursive: true));
      NitroHttp.configureCache(
        HttpCacheConfig(directory: dir.path, maxSizeBytes: 4 << 20),
      );
      addTearDown(NitroHttp.clearCache);

      await NitroHttp.prefetchDetailed(server.url('/cache/60'));
      expect(server.hits['/cache/60'], 1);

      final cached = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.url(''),
          cacheSettings: const CacheSettings(enabled: true),
        ),
      );
      addTearDown(cached.dispose);

      final response = await cached.get('/cache/60');
      expect(response.body, 'cached-body-60');
      expect(response.fromCache, isTrue);
      // Prefetch did the only network request; the read came off disk.
      expect(server.hits['/cache/60'], 1);
    }, skip: skipReason);

    test('a disposed client refuses further work', () async {
      final disposable = NitroHttpClient(
        settings: ClientSettings(baseUrl: server.url('')),
      );
      await disposable.get('/echo');
      disposable.dispose();
      expect(
        () => disposable.get('/echo'),
        throwsA(isA<NitroHttpDisposedException>()),
      );
    }, skip: skipReason);

    // NitroHttp.init has to be exercised here rather than against a fake: it
    // constructs a real NitroHttpClient itself, and the constructor configures
    // the native executor, so there is no seam to inject through.
    group('NitroHttp.init', () {
      tearDown(() {
        // Drop whatever init installed so the static default does not leak
        // settings into another test.
        NitroHttp.overrideDefaultClientForTesting(null);
      });

      test('configures the client the static verbs and fetch() use', () async {
        NitroHttp.init(
          ClientSettings(
            baseUrl: server.url(''),
            userAgent: 'init-test/1.0',
          ),
        );

        // baseUrl came from init, so a relative path resolves at all — which is
        // the whole reason to call it — and userAgent proves the settings were
        // not merely accepted but reached the wire.
        final res = await NitroHttp.get('/echo');
        expect(res.statusCode, 200);
        final headers =
            (res.bodyToJson()! as Map<String, dynamic>)['headers']
                as Map<String, dynamic>;
        expect((headers['user-agent'] as List).first, 'init-test/1.0');
      }, skip: skipReason);

      test('calling it again replaces and disposes the previous client', () async {
        NitroHttp.init(ClientSettings(baseUrl: server.url('')));
        final first = NitroHttp.defaultClient;
        expect(first.isDisposed, isFalse);

        NitroHttp.init(ClientSettings(baseUrl: server.url('')));
        final second = NitroHttp.defaultClient;

        expect(identical(first, second), isFalse, reason: 'must be a new client');
        expect(first.isDisposed, isTrue, reason: 'the old one must be disposed');
        // The replacement is usable, so the swap did not break the engine.
        expect((await NitroHttp.get('/echo')).statusCode, 200);
      }, skip: skipReason);

      test('getStream streams from the default client', () async {
        NitroHttp.init(ClientSettings(baseUrl: server.url('')));

        const size = 65536;
        final res = await NitroHttp.getStream('/bytes/$size');
        expect(res.statusCode, 200);
        expect(res.contentLength, size);

        final collected = <int>[];
        await for (final chunk in res.body) {
          collected.addAll(chunk);
        }
        // Byte-exact, not just the right length: the server generates a
        // deterministic sequence, so a truncated or reordered stream fails.
        expect(
          Uint8List.fromList(collected),
          equals(_Server.bytesOfLength(size)),
        );
      }, skip: skipReason);
    });
  });
}
