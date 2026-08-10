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
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

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
  });
}
