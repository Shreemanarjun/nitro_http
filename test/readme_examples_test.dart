/// Every Dart snippet in README.md, compiled and — wherever the fakes allow —
/// executed. This file is what lets the README claim its examples cannot rot:
/// an API change that breaks a documented snippet breaks this file first.
///
/// Layout mirrors the README. Each test is named after the section its snippet
/// lives under, and the snippet bodies are kept verbatim except for:
///
///   * free variables the prose implies (`token`, `source`, `certPem`, …),
///     declared immediately above their use;
///   * network calls, which run against [FakeRequestExecutor] /
///     [FakeStreamDemux] instead of a socket — the same seam every other unit
///     test uses;
///   * the cancellation timer, shortened from 2 s to 1 ms so the suite stays
///     fast.
///
/// Deliberately absent, with reasons:
///
///   * "Why there is no web build" — imports `package:http/browser_client.dart`,
///     which only compiles for the web; a VM test file cannot contain it.
///   * the `dio` snippet — compiled and run by
///     `test/dio/dio_readme_example_test.dart`, which owns the adapter seam it
///     needs.
///   * `NitroHttp.init` — it constructs a real [NitroHttpClient], and that
///     constructor configures the native executor, so there is no seam to pass
///     a fake through. Covered against the real engine by the `NitroHttp.init`
///     group in `native_smoke_test.dart`, which is also the only place its
///     replace-and-dispose behaviour can actually be observed.
///   * `void main() => runApp(...)` in the hot-restart snippet — it is Flutter's
///     API, not this package's, and the whole point of that snippet is that it
///     contains NO recovery call. There is nothing here to execute; the
///     behaviour it claims is proven against the real engine by
///     `native_smoke_test.dart` and `example/integration_test/cancellation_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'package:nitro_http/src/internal/ws_runner.dart' show WsOpcode;

import 'support/fakes.dart';

void main() {
  late FakeRequestExecutor executor;
  late FakeStreamDemux demux;

  NitroHttpClient makeClient({
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

  // The snippet directly under the badges — the first code anyone reads, and
  // the one most likely to be copied verbatim, so it is held to the same
  // standard as the rest.
  group('Header', () {
    test('hero snippet', () async {
      final defaultClient = makeClient();
      NitroHttp.overrideDefaultClientForTesting(defaultClient);
      addTearDown(() => NitroHttp.overrideDefaultClientForTesting(null));
      executor.bufferedResponses.add(
        rawResponse(body: Uint8List.fromList(utf8.encode('{"name":"Ada"}'))),
      );

      final res = await fetch('https://api.example.com/users/42');

      expect(res.bodyToJson(), {'name': 'Ada'});
      // The snippet's comment claims this prints a protocol label, so check it
      // is one rather than merely non-null.
      expect(res.version.label, matches(r'^HTTP/'));
    });
  });

  group('Quick start', () {
    test('client per API: get, post, dispose', () async {
      final client = NitroHttpClient(
        settings: const ClientSettings(
          baseUrl: 'https://api.example.com',
          userAgent: 'my_app/1.0',
        ),
        executor: executor,
        demux: demux,
      );

      executor.bufferedResponses
        ..add(rawResponse(body: Uint8List.fromList(utf8.encode('{"name":"Ada"}'))))
        ..add(rawResponse(status: 201));

      final user = await client.get('/users/42');
      expect((user.bodyToJson() as Map)['name'], 'Ada');

      final created = await client.post(
        '/users',
        body: HttpBody.json({'name': 'Ada'}),
      );
      // The snippet's comment says 201, so assert 201 and not merely success.
      expect(created.statusCode, 201);

      client.dispose();
      expect(executor.disposeCount, 1);
    });

    test('fetch() one-liner', () async {
      final defaultClient = makeClient();
      NitroHttp.overrideDefaultClientForTesting(defaultClient);
      addTearDown(() => NitroHttp.overrideDefaultClientForTesting(null));
      executor.bufferedResponses.add(
        rawResponse(body: Uint8List.fromList(utf8.encode('ok'))),
      );

      final res = await fetch('https://api.example.com/health');
      expect(res.statusCode, 200);
      expect(res.body, 'ok');
    });

    test('configured client', () async {
      final client = NitroHttpClient(
        settings: const ClientSettings(
          baseUrl: 'https://api.example.com/v1',
          timeout: Duration(seconds: 30),
          connectTimeout: Duration(seconds: 10),
          httpVersionPref: HttpVersionPref.http2,
          cookieSettings: CookieSettings(storeCookies: true),
        ),
        interceptors: [RetryInterceptor(maxRetries: 3)],
        executor: executor,
        demux: demux,
      );

      executor.bufferedResponses.add(
        rawResponse(body: Uint8List.fromList(utf8.encode('[{"id": 1}]'))),
      );
      final res = await client.get('/users', query: {
        'page': '2',
        'tag': ['a', 'b'],
      });
      final users = res.bodyToJson();
      expect(users, [
        {'id': 1},
      ]);
      expect(
        executor.bufferedRequests.single.request.url,
        'https://api.example.com/v1/users?page=2&tag=a&tag=b',
      );

      client.dispose();
      expect(executor.disposeCount, 1);
    });
  });

  group('Feature tour', () {
    test('Verbs', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      for (var i = 0; i < 9; i++) {
        executor.bufferedResponses.add(rawResponse());
      }

      await client.get('/users');
      await client.head('/users');
      await client.post('/users', body: HttpBody.json({'name': 'Ada'}));
      await client.put('/users/1', body: HttpBody.json({'name': 'Ada'}));
      await client.patch('/users/1', body: HttpBody.json({'name': 'Grace'}));
      await client.delete('/users/1');
      await client.options_('/users');
      await client.trace('/users');

      await client.requestText(
        HttpMethod.custom,
        '/graph',
        customMethod: 'PURGE',
      );

      expect(executor.bufferedRequests, hasLength(9));
      expect(executor.bufferedRequests.last.request.customMethod, 'PURGE');
    });

    test('Verbs: a non-standard method through request', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses.add(rawResponse());

      await client.requestText(HttpMethod.custom, '/graph', customMethod: 'PURGE');

      final sent = executor.bufferedRequests.single.request;
      expect(sent.method, RawMethod.custom);
      expect(sent.customMethod, 'PURGE');
    });

    // NitroHttp.init itself cannot be exercised here — it constructs a real
    // NitroHttpClient, whose constructor configures the native executor, so
    // there is no seam to inject a fake through. It is covered against the real
    // engine in native_smoke_test.dart ('NitroHttp.init'). What IS checkable
    // here is the rest of the snippet: that the static verbs and getStream go
    // to whatever client the default is set to.
    test('The default client: static verbs and getStream', () async {
      final defaultClient = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      NitroHttp.overrideDefaultClientForTesting(defaultClient);
      addTearDown(() => NitroHttp.overrideDefaultClientForTesting(null));

      executor.bufferedResponses
        ..add(rawResponse(body: Uint8List.fromList(utf8.encode('{"name":"Ada"}'))))
        ..add(rawResponse(status: 201));

      final user = await NitroHttp.get('/users/42');
      expect((user.bodyToJson() as Map)['name'], 'Ada');

      final posted = await NitroHttp.post(
        '/users',
        body: HttpBody.json({'name': 'Ada'}),
      );
      expect(posted.statusCode, 201);

      // baseUrl came from the default client, so the relative paths resolved.
      expect(
        executor.bufferedRequests.map((r) => r.request.url),
        ['https://api.example.com/users/42', 'https://api.example.com/users'],
      );

      executor.onStartStreamed = (request, body) {
        scheduleMicrotask(() {
          demux.push(chunk(request.requestId, utf8.encode('a,b\n1,2\n')));
          demux.push(doneChunk(request.requestId));
        });
        return rawHead(requestId: request.requestId);
      };

      final report = await NitroHttp.getStream('/reports/2026.csv');
      final sink = BytesBuilder();
      await for (final c in report.body) {
        sink.add(c);
      }
      expect(utf8.decode(sink.takeBytes()), 'a,b\n1,2\n');
    });

    test('Query parameters and per-call headers', () async {
      const token = 'a-refresh-token';
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses.add(rawResponse());

      final res = await client.get(
        '/search',
        query: {'q': 'flutter', 'limit': '20'},
        headers: HttpHeaders.fromMap({'Authorization': 'Bearer $token'}),
      );

      final sent = executor.bufferedRequests.single.request;
      expect(sent.url, 'https://api.example.com/search?q=flutter&limit=20');
      expect(
        sent.headers.any(
          (h) =>
              h.name.toLowerCase() == 'authorization' &&
              h.value == 'Bearer $token',
        ),
        isTrue,
      );
      expect(res.statusCode, 200);
    });

    test('Request bodies', () {
      const token = 'a-refresh-token';
      final source = Stream<Uint8List>.fromIterable([Uint8List(4096)]);

      final bodies = <HttpBody>[
        // UTF-8 text.
        HttpBody.text('hello', contentType: 'text/plain; charset=utf-8'),

        // jsonEncode-ed, with application/json; charset=utf-8.
        HttpBody.json({
          'name': 'Ada',
          'roles': ['admin'],
        }),

        // Raw bytes.
        HttpBody.bytes(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])),

        // application/x-www-form-urlencoded.
        HttpBody.form({'grant_type': 'refresh_token', 'token': token}),

        // multipart/form-data; file parts stream off disk.
        HttpBody.multipart([
          MultipartItem.text('caption', 'Sunset'),
          MultipartItem.file('photo', '/tmp/sunset.jpg',
              contentType: 'image/jpeg'),
        ]),

        // A Dart stream, chunked when the length is unknown.
        HttpBody.stream(source, contentLength: 4096),

        // A path handed straight to the engine.
        HttpBody.file('/tmp/backup.zip'),
      ];
      expect(bodies, hasLength(7));
    });

    test('Responses: sealed switch and metadata', () async {
      String describe(HttpResponse res) => switch (res) {
        HttpTextResponse(:final body) => 'text: ${body.length} chars',
        HttpBytesResponse(:final bodyBytes) => 'bytes: ${bodyBytes.length}',
        HttpStreamResponse(:final contentLength) =>
          'stream: ${contentLength ?? -1}',
      };

      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses.add(rawResponse(
        body: Uint8List.fromList(utf8.encode('[]')),
        version: RawHttpVersion.http2,
        finalUrl: 'https://api.example.com/users',
        headers: const [
          RawHeader(name: 'Set-Cookie', value: 'a=1'),
          RawHeader(name: 'Set-Cookie', value: 'b=2'),
        ],
      ));

      final res = await client.get('/users');
      expect(describe(res), 'text: 2 chars');
      expect(res.version.label, 'HTTP/2');
      expect(res.finalUrl.toString(), 'https://api.example.com/users');
      expect(res.redirectCount, 0);
      expect(res.primaryIp, isNotEmpty);
      expect(res.fromCache, isFalse);
      expect(res.headers.getAll('set-cookie'), ['a=1', 'b=2']);
    });

    test('Errors: the sealed exception switch', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses.add(rawResponse(
        kind: RawErrorKind.timeoutRequest,
        message: 'request timed out',
      ));

      String? detail;
      try {
        await client.get('/users');
      } on NitroHttpException catch (e) {
        detail = switch (e) {
          NitroHttpTimeoutException(:final stage) => 'timeout at ${stage.name}',
          NitroHttpCancelException(:final reason) =>
            'cancelled: ${reason ?? ''}',
          NitroHttpStatusCodeException(:final statusCode) =>
            'status $statusCode',
          NitroHttpCertificateException(:final isPinMismatch) =>
            isPinMismatch ? 'pin mismatch' : 'bad certificate',
          NitroHttpTlsException() => 'no shared TLS version or cipher',
          NitroHttpConfigurationException() =>
            'these settings cannot be satisfied',
          NitroHttpConnectionException(:final failure) =>
            'connection ${failure.name}',
          NitroHttpRedirectException(:final redirectCount) =>
            '$redirectCount hops',
          NitroHttpProtocolException() => 'protocol error',
          NitroHttpDecodingException() => 'undecodable body',
          NitroHttpResponseTooLargeException() => 'body too large',
          NitroHttpCacheMissException() => 'nothing cached',
          NitroHttpDisposedException() => 'client disposed',
          NitroHttpUnknownException(:final engineErrorCode) =>
            'CURLcode $engineErrorCode',
        };
      }
      expect(detail, startsWith('timeout at'));
    });

    test('Streaming downloads', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.onStartStreamed = (request, body) {
        scheduleMicrotask(() {
          demux.push(chunk(request.requestId, utf8.encode('{"row":1}\n')));
          demux.push(doneChunk(request.requestId));
        });
        return rawHead(requestId: request.requestId);
      };

      final sink = BytesBuilder();
      final res = await client.requestStream(HttpMethod.get, '/dataset.ndjson');

      await for (final chunk in res.body) {
        sink.add(chunk); // a slow consumer stalls the socket, not the heap
      }
      expect(utf8.decode(sink.takeBytes()), '{"row":1}\n');
    });

    test('Stream chunk batching settings', () {
      final client = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: 'https://api.example.com',
          streamChunks: const StreamChunkSettings.adaptive(), // the default
        ),
        executor: executor,
        demux: demux,
      );
      client.dispose();

      const immediate = ClientSettings(
        streamChunks: StreamChunkSettings.immediate(),
      );
      const fixed = ClientSettings(
        streamChunks: StreamChunkSettings.fixed(64 * 1024),
      );
      expect(immediate.streamChunks.bytes, -1);
      expect(fixed.streamChunks.bytes, 64 * 1024);
    });

    test('Streaming uploads', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.onSendBuffered = (request, body) async {
        // A real server answers after the body arrives; hold the response
        // until the upload pump has fed every chunk.
        while (executor.finishedUploads.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        return rawResponse(requestId: request.requestId);
      };
      const totalBytes = 8;
      final source = Stream<Uint8List>.fromIterable([
        Uint8List.fromList([1, 2, 3, 4]),
        Uint8List.fromList([5, 6, 7, 8]),
      ]);

      await client.post(
        '/ingest',
        body: HttpBody.stream(source, contentLength: totalBytes),
      );

      expect(
        executor.uploadChunks.fold<int>(0, (n, c) => n + c.bytes.length),
        totalBytes,
      );
      expect(executor.finishedUploads, hasLength(1));
    });

    test('File body', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://backups.example.com'),
      );
      executor.bufferedResponses.add(rawResponse());

      await client.put(
        '/backups/nightly.zip',
        body: HttpBody.file('/var/tmp/nightly.zip'),
      );

      expect(
        executor.bufferedRequests.single.request.bodyFilePath,
        '/var/tmp/nightly.zip',
      );
    });

    test('Downloading to a file', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://backups.example.com'),
      );
      executor.bufferedResponses.add(rawResponse());

      final response = await client.downloadToFile(
        '/backups/nightly.zip',
        '/var/tmp/nightly.zip',
        onReceiveProgress: (received, total) => '$received / $total',
      );

      // The destination travels with the request, and the response comes back
      // with no body because the bytes went to disk.
      expect(
        executor.bufferedRequests.single.request.responseFilePath,
        '/var/tmp/nightly.zip',
      );
      expect(response.bodyBytes, isEmpty);
    });

    test('Limiting response size', () async {
      final client = makeClient(
        settings: const ClientSettings(maxResponseBytes: 8 * 1024 * 1024),
      );
      executor.bufferedResponses.add(rawResponse());

      await client.get('https://api.example.com/report');

      expect(
        executor.configs.last.maxResponseBytes,
        8 * 1024 * 1024,
      );
    });

    test('Cancellation', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      // The engine's contract: a cancel still posts exactly one completion,
      // carrying the cancelled error kind. The fake plays the engine here.
      final held = Completer<RawResponse>();
      executor.onSendBuffered = (request, body) => held.future;

      final token = CancelToken();
      // README uses 2 seconds; 1 ms keeps the suite fast.
      Timer(const Duration(milliseconds: 1), () {
        token.cancel('user navigated away');
        held.complete(
          rawResponse(kind: RawErrorKind.cancelled, message: 'aborted'),
        );
      });

      try {
        await client.get('/slow', cancelToken: token);
        fail('must not complete');
      } on NitroHttpCancelException catch (e) {
        expect(e.reason, 'user navigated away'); // user navigated away
      }
    });

    test('Cancellation: one token, any number of requests', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses
        ..add(rawResponse())
        ..add(rawResponse())
        ..add(rawResponse());

      final screen = CancelToken();

      final results = await Future.wait([
        client.get('/profile', cancelToken: screen),
        client.get('/feed', cancelToken: screen),
        client.get('/notifications', cancelToken: screen),
      ]);

      expect(results, hasLength(3));

      // The `dispose()` half of the snippet, minus the widget it lives in.
      screen.cancel('screen closed');

      // Three requests, ONE native call — the property the README claims.
      expect(executor.cancelledTokens, hasLength(1));
      expect(executor.cancelledTokens.single.$2, 'screen closed');
    });

    test('Cancellation: cancelling early keeps it off the network', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      // The engine refuses a pre-cancelled request before it opens a socket;
      // the fake stands in for that verdict. `cancellation_test.dart` proves
      // the real engine never reaches the server, which a fake cannot show.
      executor.bufferedResponses.add(
        rawResponse(kind: RawErrorKind.cancelled, message: 'aborted'),
      );

      final token = CancelToken()..cancel('never mind');

      var refused = false;
      try {
        await client.get('/expensive', cancelToken: token);
      } on NitroHttpCancelException {
        // Fails straight away: no socket was opened and the server saw nothing.
        refused = true;
      }
      expect(refused, isTrue);
    });

    test('Cancellation: cancelling twice or late is a no-op', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses.add(rawResponse());

      final token = CancelToken();
      await client.get('/done', cancelToken: token);

      token.cancel('first');
      token.cancel('second');

      expect(token.reason, 'first', reason: 'the first cancel wins');
      expect(executor.cancelledTokens, hasLength(1));
    });

    test('File body: straight from disk', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses.add(rawResponse());

      await client.put('/backups/nightly.zip', body: HttpBody.file('/var/tmp/nightly.zip'));

      // The path travels to the engine; no bytes pass through the Dart heap.
      final sent = executor.bufferedRequests.single;
      expect(sent.request.bodyKind, RawBodyKind.filePath);
      expect(sent.request.bodyFilePath, '/var/tmp/nightly.zip');
      expect(sent.body, isEmpty);
    });

    test('Progress callbacks', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      final log = <String>[];
      executor.onSendBuffered = (request, body) async {
        demux.pushEvent(RawEvent(
          requestId: request.requestId,
          kind: RawEventKind.downloadProgress,
          a: 512,
          b: 1024,
          message: '',
        ));
        // Let the event delivery beat the response.
        await Future<void>.delayed(Duration.zero);
        return rawResponse(requestId: request.requestId);
      };

      await client.post(
        '/upload',
        body: HttpBody.file('/tmp/video.mp4'),
        onSendProgress: (sent, total) => log.add('$sent / ${total ?? -1}'),
        onReceiveProgress: (received, total) => log.add('down $received'),
      );
      expect(log, contains('down 512'));
    });

    test('Timings', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
      );
      executor.bufferedResponses.add(rawResponse(
        timings: const RawTimings(
          queueMs: 0.01,
          dnsMs: 1,
          connectMs: 2,
          tlsMs: 3,
          firstByteMs: 9,
          redirectMs: 0,
          totalMs: 12,
        ),
      ));

      final res = await client.get('/ping');
      expect(res.timings.dns, const Duration(milliseconds: 1));
      expect(res.timings.tls, const Duration(milliseconds: 3));
      expect(res.timings.firstByte, const Duration(milliseconds: 9));
      expect(res.timings.total, const Duration(milliseconds: 12));
    });

    test('TLS settings', () async {
      const certPem = '-----BEGIN CERTIFICATE-----\n…\n-----END CERTIFICATE-----';
      const keyPem = '-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----';

      final client = NitroHttpClient(
        settings: ClientSettings(
          tlsSettings: TlsSettings(
            minVersion: TlsVersion.tls13,
            rootCaSource: RootCaSource.platform,
            pinnedSpkiSha256: const [
              'YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg=',
            ],
            clientCertificate: ClientCertificate(
              certificatePem: certPem,
              privateKeyPem: keyPem,
            ),
          ),
        ),
        executor: executor,
        demux: demux,
      );
      expect(executor.configs.single.tls.minTlsVersion, isNot(0));

      executor.bufferedResponses.add(rawResponse());
      await client.post(
        '/payments',
        options: const RequestOptions(
          pinnedSpkiSha256: 'YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg=',
        ),
      );
      expect(
        executor.bufferedRequests.single.request.options.pinnedSpkiOverride,
        isNotEmpty,
      );
    });

    test('Proxy settings', () {
      const system = ClientSettings(proxySettings: ProxySettings.system());
      const none = ClientSettings(proxySettings: ProxySettings.noProxy());

      final corp = ClientSettings(
        proxySettings: const ProxySettings.http(
          'proxy.corp.example:3128',
          username: 'svc',
          password: 'hunter2',
          noProxy: 'localhost,127.0.0.1,*.internal',
        ),
      );

      const socks = ProxySettings.socks5('127.0.0.1:1080');
      const socksRemote = ProxySettings.socks5Hostname('127.0.0.1:1080');

      expect(system, isNot(none));
      expect(corp.proxySettings, isNotNull);
      expect(socks, isNot(socksRemote));
    });

    test('Timeouts: three separate deadlines', () {
      const settings = ClientSettings(
        connectTimeout: Duration(seconds: 10),
        timeout: Duration(seconds: 30),
        idleTimeout: Duration(seconds: 90),
      );

      // The snippet's whole point is that these are three DISTINCT deadlines,
      // so assert each landed on its own field rather than that it constructs.
      expect(settings.connectTimeout, const Duration(seconds: 10));
      expect(settings.timeout, const Duration(seconds: 30));
      expect(settings.idleTimeout, const Duration(seconds: 90));
    });

    test('HTTP versions and the connection pool', () {
      const settings = ClientSettings(
        httpVersionPref: HttpVersionPref.http2,
        poolSettings: PoolSettings(
          maxConnections: 64,
          maxConnectionsPerHost: 6,
          idleTimeout: Duration(seconds: 90),
          maxLifetime: Duration(minutes: 10),
        ),
      );

      expect(settings.httpVersionPref, HttpVersionPref.http2);
      expect(settings.poolSettings.maxConnections, 64);
      expect(settings.poolSettings.maxConnectionsPerHost, 6);
      expect(settings.poolSettings.idleTimeout, const Duration(seconds: 90));
      expect(settings.poolSettings.maxLifetime, const Duration(minutes: 10));
    });

    test('DNS settings', () {
      final pinned = ClientSettings(
        dnsSettings: DnsSettings.static({
          'api.example.com': ['203.0.113.10', '2001:db8::10'],
        }, port: 443),
      );

      const doh = ClientSettings(
        dnsSettings: DnsSettings.doh('https://cloudflare-dns.com/dns-query'),
      );

      expect(pinned.dnsSettings, isNotNull);
      expect(doh.dnsSettings, isNotNull);
    });

    test('Cookies', () async {
      const appSupportDir = '/tmp/app-support';
      final client = NitroHttpClient(
        settings: ClientSettings(
          cookieSettings: CookieSettings(
            storeCookies: true,
            persistPath: '$appSupportDir/cookies.txt', // Netscape jar
          ),
        ),
        executor: executor,
        demux: demux,
      );

      executor.jar = const [
        RawCookie(
          name: 'session',
          value: 'abc123',
          domain: 'api.example.com',
          path: '/',
          expiresEpochMs: 0,
          secure: true,
          httpOnly: true,
        ),
      ];

      final lines = <String>[];
      for (final c in client.cookiesFor(Uri.parse('https://api.example.com/'))) {
        lines.add('${c.name}=${c.value} (${c.domain}${c.path})');
      }
      expect(lines, ['session=abc123 (api.example.com/)']);

      client.setCookie(const Cookie(
        name: 'consent',
        value: 'granted',
        domain: 'api.example.com',
      ));
      client.flushCookies(); // also happens automatically on dispose()

      expect(executor.cookiesSet.single.name, 'consent');
      expect(executor.flushCookiesCount, 1);
    });

    test('Interceptors', () async {
      final tokens = TokenStore();
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
        interceptors: [AuthInterceptor(tokens)],
      );

      executor.bufferedResponses.add(rawResponse());
      await client.get('/users');
      final sent = executor.bufferedRequests.single.request;
      expect(
        sent.headers.any(
          (h) => h.name == 'authorization' && h.value == 'Bearer at-1',
        ),
        isTrue,
      );

      // The DelegatingInterceptor shorthand.
      final seen = <String>[];
      final logger = DelegatingInterceptor(
        onResponse: (res) async {
          seen.add('${res.statusCode} ${res.finalUrl} in ${res.timings.total}');
          return Interceptor.next();
        },
      );
      final logged = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
        interceptors: [logger],
      );
      executor.bufferedResponses.add(rawResponse());
      await logged.get('/users');
      expect(seen.single, startsWith('200 '));
    });

    test('The prebuilt interceptors', () async {
      final lines = <String>[];
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
        interceptors: [
          LogInterceptor(level: HttpLogLevel.headers, sink: lines.add),
          RetryInterceptor(maxRetries: 3),
        ],
      );

      executor.bufferedResponses.add(rawResponse());
      await client.get('/users/7');

      // The two lines the README prints.
      expect(lines.first, '--> GET https://api.example.com/users/7');
      expect(lines.any((l) => l.startsWith('<-- 200 ')), isTrue);
    });

    test('Keeping interceptors cheap: a synchronous hook', () async {
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
        interceptors: [const TraceHeader()],
      );

      executor.bufferedResponses.add(rawResponse());
      await client.get('/users');
      final sent = executor.bufferedRequests.single.request;
      expect(sent.headers.any((h) => h.name == 'x-trace-id'), isTrue);
    });

    test('ParallelInterceptors groups independent observers', () async {
      final seen = <String>[];
      final client = makeClient(
        settings: const ClientSettings(baseUrl: 'https://api.example.com'),
        interceptors: [
          ParallelInterceptors([
            DelegatingInterceptor(
              onResponse: (r) async {
                seen.add('log ${r.statusCode}');
                return Interceptor.next();
              },
            ),
            DelegatingInterceptor(
              onResponse: (r) async {
                seen.add('metrics ${r.statusCode}');
                return Interceptor.next();
              },
            ),
          ]),
        ],
      );

      executor.bufferedResponses.add(rawResponse());
      await client.get('/users');
      expect(seen, containsAll(<String>['log 200', 'metrics 200']));
    });

    test('Retry', () {
      final client = NitroHttpClient(
        interceptors: [
          RetryInterceptor(
            maxRetries: 4,
            baseDelay: const Duration(milliseconds: 250),
            maxDelay: const Duration(seconds: 10),
            respectRetryAfter: true,
          ),
        ],
        executor: executor,
        demux: demux,
      );
      client.dispose();

      final custom = RetryInterceptor(
        shouldRetry: (response, error, attempt) =>
            response?.statusCode == 503 ||
            RetryPolicy.isRetryableByDefault(response, error),
      );
      expect(custom, isA<Interceptor>());
    });

    test('Disk cache and prefetch', () async {
      final engine = FakeEngineExecutor();
      NitroHttp.overrideEngineExecutorForTesting(engine);
      addTearDown(() => NitroHttp.overrideEngineExecutorForTesting(null));

      const cacheDir = '/tmp/nitro-http-cache';
      NitroHttp.configureCache(HttpCacheConfig(
        directory: cacheDir,
        maxSizeBytes: 128 * 1024 * 1024,
        maxEntryBytes: 8 * 1024 * 1024,
      ));
      expect(engine.cacheConfigs.single.maxSizeBytes, 128 * 1024 * 1024);

      final client = NitroHttpClient(
        settings: const ClientSettings(
          cacheSettings: CacheSettings(enabled: true),
        ),
        executor: executor,
        demux: demux,
      );

      await NitroHttp.prefetchOnAppStart([
        'https://api.example.com/v1/feed',
        'https://api.example.com/v1/me',
      ]);
      expect(engine.prefetched, hasLength(2));

      executor.bufferedResponses
        ..add(rawResponse(fromCache: true))
        ..add(rawResponse());
      await client.get(
        '/feed',
        options: const RequestOptions(cacheMode: CacheMode.onlyIfCached),
      );
      await client.get(
        '/feed',
        options: const RequestOptions(cacheMode: CacheMode.refresh),
      );

      final stats = NitroHttp.cacheStats();
      expect('${stats.entryCount} entries, hit rate ${stats.hitRate}',
          isNotEmpty);
      NitroHttp.clearCache();
      expect(engine.clearCacheCount, 1);
    });

    test('WebSockets', () async {
      final wsExecutor = FakeWsExecutor();
      final wsDemux = FakeWsFrameDemux();
      addTearDown(wsDemux.closeAll);

      final ws = await NitroWebSocket.connect(
        Uri.parse('wss://echo.example.com/socket'),
        protocols: ['chat'],
        pingInterval: const Duration(seconds: 30),
        executor: wsExecutor,
        demux: wsDemux,
      );

      final log = <String>[];
      final done = Completer<void>();
      ws.events.listen((event) {
        switch (event) {
          case TextDataReceived(:final text):
            log.add('text $text');
          case BinaryDataReceived(:final data):
            log.add('binary ${data.length}');
          case CloseReceived(:final code, :final reason):
            log.add('closed $code $reason');
            done.complete();
        }
      });

      ws.sendText('hello');
      wsDemux.push(wsFrame(1, WsOpcode.text, utf8.encode('hi back')));

      final closing = ws.close(1000, 'done');
      wsDemux.push(wsCloseFrame(1, 1000, 'done'));
      await closing;
      await done.future;

      expect(wsExecutor.sent.single.payload, utf8.encode('hello'));
      expect(log, ['text hi back', 'closed 1000 done']);
    });

    test('package:http adapter', () async {
      // The README's default constructor loads the native library; the test
      // seam is `.wrap`, which is the same object over an injected client.
      final client = NitroHttpCompatClient.wrap(makeClient(
        settings: const ClientSettings(throwOnStatusCode: false),
      ));
      executor.onStartStreamed = (request, body) {
        scheduleMicrotask(() {
          demux.push(chunk(request.requestId, utf8.encode('hello')));
          demux.push(doneChunk(request.requestId));
        });
        return rawHead(requestId: request.requestId);
      };

      final res = await client.get(Uri.parse('https://example.com/'));
      expect(res.statusCode, 200);
      client.close();
    });

    test('Runtime capabilities and hot restart', () {
      final engine = FakeEngineExecutor();
      NitroHttp.overrideEngineExecutorForTesting(engine);
      addTearDown(() => NitroHttp.overrideEngineExecutorForTesting(null));

      // The README snippet prints all five. Reading each is the part that can
      // rot, and every one is read below; `print` itself is not under test.
      expect(NitroHttp.engineVersion, startsWith('libcurl/'));
      expect(NitroHttp.supportsHttp3, isTrue);
      expect(NitroHttp.supportsWebSockets, isTrue);
      expect(NitroHttp.supportsBrotli, isTrue);
      expect(NitroHttp.supportsZstd, isFalse);

      // The hot-restart snippet is now `void main() { runApp(...); }` — the
      // whole point is that it contains no recovery call, so there is nothing
      // here to execute. Reconciliation happens on first native touch, and
      // `native_smoke_test.dart` / `cancellation_test.dart` prove it against
      // the real engine, which a fake executor cannot.
      expect(engine.resetCount, 0);
    });
  });
}

// ── Support types the README's prose implies ─────────────────────────────────

/// The token store the interceptor snippet injects.
final class TokenStore {
  int _issued = 0;

  Future<String> access() async => 'at-${++_issued}';

  Future<void> refresh() async {}
}

/// Verbatim from the README's "Keeping them cheap" table.
class TraceHeader extends Interceptor {
  const TraceHeader();

  @override
  FutureOr<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) {
    request.headers.set('x-trace-id', 'trace-1');
    return Interceptor.proceedRequest;
  }
}

/// Verbatim from the README's "Interceptors" section.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this.tokens);

  final TokenStore tokens;

  @override
  Future<InterceptorResult<HttpRequest>> beforeRequest(
    HttpRequest request,
  ) async {
    request.headers.set('authorization', 'Bearer ${await tokens.access()}');
    return Interceptor.next();
  }

  @override
  Future<InterceptorResult<HttpResponse>> onError(
    NitroHttpException exception,
  ) async {
    if (exception is NitroHttpStatusCodeException &&
        exception.statusCode == 401) {
      await tokens.refresh();
    }
    return Interceptor.next();
  }
}
