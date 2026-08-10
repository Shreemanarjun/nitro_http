/// End-to-end request semantics against the in-process `shelf` server.
///
/// Hermetic on purpose: no DNS, no TLS to a third party, no rate limits. Every
/// assertion here is either about a value the client produced or about what the
/// server observed — never merely "it did not throw".
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

/// HTTP/2 and HTTP/3 need a peer that speaks them. `dart:io`'s `HttpServer` is
/// HTTP/1.1 only, so those cases target public endpoints and are therefore not
/// hermetic — exactly what default CI must not depend on. Run them explicitly
/// with `--dart-define=REMOTE_H3=true`.
const bool runRemoteVersionTests = bool.fromEnvironment('REMOTE_H3');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUp(() async {
    server = await LocalServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  NitroHttpClient client({
    bool throwOnStatusCode = true,
    RedirectSettings redirects = const RedirectSettings.follow(),
    Duration? timeout,
    Duration? connectTimeout,
    Duration? idleTimeout,
    bool enableCompression = true,
    String? baseUrl,
  }) {
    final created = NitroHttpClient(
      settings: ClientSettings(
        baseUrl: baseUrl ?? server.baseUrl,
        throwOnStatusCode: throwOnStatusCode,
        redirectSettings: redirects,
        timeout: timeout,
        connectTimeout: connectTimeout,
        idleTimeout: idleTimeout,
        enableCompression: enableCompression,
      ),
    );
    addTearDown(created.dispose);
    return created;
  }

  group('verbs', () {
    testWidgets('every method reaches the server with its own token', (_) async {
      final http = client(throwOnStatusCode: false);

      for (final method in const [
        HttpMethod.get,
        HttpMethod.head,
        HttpMethod.post,
        HttpMethod.put,
        HttpMethod.patch,
        HttpMethod.delete,
        HttpMethod.options,
        HttpMethod.trace,
      ]) {
        final response = await http.requestText(
          method,
          '/echo',
          body: const [HttpMethod.post, HttpMethod.put, HttpMethod.patch]
                  .contains(method)
              ? const HttpBody.text('payload')
              : null,
        );
        expect(response.statusCode, 200, reason: '${method.name} status');
        expect(
          server.hits.last.method,
          method.name.toUpperCase(),
          reason: '${method.name} arrived as a different token',
        );
      }
    });

    testWidgets('a custom method token goes out verbatim', (_) async {
      final http = client(throwOnStatusCode: false);
      await http.requestText(HttpMethod.custom, '/status/200',
          customMethod: 'PURGE');
      expect(server.hits.last.method, 'PURGE');
    });
  });

  group('round trips', () {
    testWidgets('query parameters and headers survive the trip', (_) async {
      final http = client();
      final response = await http.get(
        '/echo',
        query: {'a': ['1', '2'], 'b': 'x', 'dropped': null},
        headers: HttpHeaders.fromMap({'X-Trace': 'abc123'}),
      );

      final decoded = response.bodyToJson() as Map<String, Object?>;
      final query = decoded['query'] as Map<String, Object?>;
      expect(query['a'], ['1', '2']);
      expect(query['b'], ['x']);
      expect(query.containsKey('dropped'), isFalse);

      final headers = decoded['headers'] as Map<String, Object?>;
      expect(headers['x-trace'], 'abc123');
      expect(server.receivedHeaderNames, contains('x-trace'));
    });

    testWidgets('text, json, bytes, form, multipart and file bodies', (_) async {
      final http = client();

      final text = await http.post('/echo', body: const HttpBody.text('héllo'));
      expect(text.body, 'héllo');
      expect(text.headers.contentType, contains('text/plain'));

      final json = await http.post(
        '/echo',
        body: const HttpBody.json({'k': 1, 'nested': [true, null]}),
      );
      expect(jsonDecode(json.body), {'k': 1, 'nested': [true, null]});
      expect(json.headers.contentType, contains('application/json'));

      final payload = deterministicBytes(4096);
      final bytes = await http.requestBytes(
        HttpMethod.post,
        '/echo',
        body: HttpBody.bytes(payload),
      );
      expect(bytes.bodyBytes, payload);

      final form = await http.post(
        '/echo',
        body: const HttpBody.form({'a': '1', 'b': 'hello world'}),
      );
      expect(form.body, 'a=1&b=hello+world');
      expect(form.headers.contentType, contains('x-www-form-urlencoded'));

      final multipart = HttpBody.multipart([
        const MultipartItem.text('note', 'from the suite'),
        MultipartItem.bytes(
          'blob',
          Uint8List.fromList(const [1, 2, 3, 4]),
          filename: 'blob.bin',
        ),
      ], boundary: 'nitroBoundary42');
      final parts = await http.post('/echo', body: multipart);
      expect(parts.headers.contentType, contains('boundary=nitroBoundary42'));
      expect(parts.body, contains('--nitroBoundary42'));
      expect(parts.body, contains('name="note"'));
      expect(parts.body, contains('filename="blob.bin"'));
      expect(parts.body, contains('from the suite'));

      final dir = await Directory.systemTemp.createTemp('nitro_http_file_body');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/payload.txt');
      await file.writeAsString('read straight off disk');
      final fromFile = await http.post(
        '/echo',
        body: HttpBody.file(file.path),
      );
      expect(fromFile.body, 'read straight off disk');
    });
  });

  group('redirects', () {
    testWidgets('a three-hop chain lands on /echo and counts the hops',
        (_) async {
      final http = client();
      final response = await http.get('/redirect/3');

      expect(response.statusCode, 200);
      expect(response.redirectCount, 3);
      expect(response.finalUrl.path, '/echo');
      expect(server.requestsFor('/echo'), 1);
      expect(server.requestsFor('/redirect/3'), 1);
      expect(server.requestsFor('/redirect/1'), 1);
    });

    testWidgets('RedirectSettings.none() returns the 3xx untouched', (_) async {
      final http = client(
        throwOnStatusCode: false,
        redirects: const RedirectSettings.none(),
      );
      final response = await http.get('/redirect/1');

      expect(response.statusCode, 302);
      expect(response.headers.location, '/echo');
      expect(response.redirectCount, 0);
      expect(server.requestsFor('/echo'), 0, reason: 'must not have followed');
    });

    testWidgets('a chain longer than the limit fails', (_) async {
      final http = client(redirects: const RedirectSettings.limited(2));
      await expectLater(
        http.get('/redirect/5'),
        throwsA(isA<NitroHttpRedirectException>()),
      );
    });
  });

  group('timeouts', () {
    testWidgets('the overall deadline reports TimeoutStage.request', (_) async {
      final http = client(timeout: const Duration(milliseconds: 300));
      await expectLater(
        http.get('/slow/5000'),
        throwsA(
          isA<NitroHttpTimeoutException>().having(
            (e) => e.stage,
            'stage',
            TimeoutStage.request,
          ),
        ),
      );
    });

    testWidgets('a stalled TLS handshake reports TimeoutStage.connect',
        (_) async {
      // The black-hole listener accepts the TCP connection and then says
      // nothing, so the request dies inside libcurl's connect phase — which is
      // what distinguishes a connect timeout from a request timeout.
      final http = client(
        baseUrl: server.blackHoleUrl,
        connectTimeout: const Duration(milliseconds: 700),
        timeout: const Duration(seconds: 30),
      );
      await expectLater(
        http.get('/echo'),
        throwsA(
          isA<NitroHttpTimeoutException>().having(
            (e) => e.stage,
            'stage',
            TimeoutStage.connect,
          ),
        ),
      );
    });

    testWidgets('a body that stops moving reports TimeoutStage.idle', (_) async {
      // Headers arrive at once, then the server waits 5 s before the second
      // chunk. Only the idle timeout can see that.
      final http = client(idleTimeout: const Duration(milliseconds: 400));
      await expectLater(
        http.get('/drip/3/5000'),
        throwsA(
          isA<NitroHttpTimeoutException>().having(
            (e) => e.stage,
            'stage',
            TimeoutStage.idle,
          ),
        ),
      );
    });
  });

  group('status codes', () {
    testWidgets('throwOnStatusCode: true raises with the body attached',
        (_) async {
      final http = client();
      await expectLater(
        http.get('/status/500'),
        throwsA(
          isA<NitroHttpStatusCodeException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having(
                (e) => jsonDecode(utf8.decode(e.body)),
                'body',
                {'status': 500},
              ),
        ),
      );
    });

    testWidgets('throwOnStatusCode: false returns the 500 normally', (_) async {
      final http = client(throwOnStatusCode: false);
      final response = await http.get('/status/500');
      expect(response.statusCode, 500);
      expect(response.isSuccess, isFalse);
      expect(response.bodyToJson(), {'status': 500});
    });
  });

  group('content encodings', () {
    testWidgets('gzip is decoded transparently', (_) async {
      final http = client();
      final response = await http.get('/gzip');

      expect(response.body, compressiblePayload);
      expect(
        server.receivedHeaderNames,
        contains('accept-encoding'),
        reason: 'compression must be advertised, not just tolerated',
      );
      expect(
        response.headers['content-encoding'],
        isNull,
        reason: 'the header describes bytes the caller never sees',
      );
    });

    testWidgets('Accept-Encoding advertises exactly what the engine can inflate',
        (_) async {
      final http = client();
      // The engine advertises the codings `ContentDecoder` is linked against,
      // never whatever the local libcurl happens to know. gzip and deflate are
      // unconditional (zlib is everywhere); brotli and zstd depend on a
      // vendored slice being present in this build, which is precisely what
      // these two capability getters report.
      final decoded = (await http.get('/echo')).bodyToJson()
          as Map<String, Object?>;
      final headers = decoded['headers'] as Map<String, Object?>;
      final advertised = (headers['accept-encoding'] as String)
          .split(',')
          .map((token) => token.trim())
          .toSet();

      expect(advertised, containsAll(<String>['gzip', 'deflate']));
      expect(advertised.contains('br'), NitroHttp.supportsBrotli);
      expect(advertised.contains('zstd'), NitroHttp.supportsZstd);
    });

    testWidgets('brotli is decoded when this build has it, and passed through '
        'byte-for-byte when it does not', (_) async {
      final http = client();
      final response = await http.requestBytes(HttpMethod.get, '/brotli');

      if (NitroHttp.supportsBrotli) {
        expect(utf8.decode(response.bodyBytes), compressiblePayload);
        expect(response.headers['content-encoding'], isNull);
        return;
      }

      // The honest degraded behaviour, and the documented one: an unrecognised
      // coding is never an error and is never touched. The body is the wire
      // bytes and `Content-Encoding` stays, so the caller can still decode it.
      // Losing either half would be the real bug — libcurl's own
      // `CURLE_BAD_CONTENT_ENCODING` fails the whole transfer instead.
      expect(response.headers['content-encoding'], 'br');
      expect(
        response.bodyBytes,
        brotliStoredContainer(utf8.encode(compressiblePayload)),
        reason: 'an undecodable body must arrive exactly as it was sent',
      );
    });

    testWidgets('compression off stops the advertisement, not the decoding',
        (_) async {
      final http = client(enableCompression: false);
      final response = await http.get('/gzip');

      expect(server.receivedHeaderNames, isNot(contains('accept-encoding')));
      // `enableCompression: false` omits `Accept-Encoding`; it does not turn
      // decoding off. A server that compresses anyway is still inflated, and
      // both headers that describe the encoded bytes are dropped, because
      // neither is true of the body the caller receives.
      expect(response.body, compressiblePayload);
      expect(response.headers['content-encoding'], isNull);
      expect(response.headers['content-length'], isNull);
    });
  });

  group('cancellation', () {
    testWidgets('cancelling mid-transfer throws NitroHttpCancelException',
        (_) async {
      final http = client();
      final token = CancelToken();

      // 64 MiB with a 5 ms gap between chunks: guaranteed still in flight when
      // the token fires.
      final pending = http.requestBytes(
        HttpMethod.get,
        '/drip/4096/5',
        cancelToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      token.cancel('test asked to stop');

      await expectLater(
        pending,
        throwsA(
          isA<NitroHttpCancelException>().having(
            (e) => e.reason,
            'reason',
            'test asked to stop',
          ),
        ),
      );
    });

    testWidgets('cancelAll aborts every in-flight request', (_) async {
      final http = client();
      // Both matchers are attached BEFORE the cancel. `expectLater` returns a
      // future that already has an error handler on it; attaching after
      // `cancelAll` leaves the second request's rejection unhandled for a turn,
      // and an unhandled async error fails the whole test binding rather than
      // this one expectation.
      final first = expectLater(
        http.get('/slow/5000'),
        throwsA(isA<NitroHttpCancelException>()),
      );
      final second = expectLater(
        http.get('/slow/5000'),
        throwsA(isA<NitroHttpCancelException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      http.cancelAll();

      await first;
      await second;
    });
  });

  group('progress', () {
    testWidgets('receive progress is monotonic and ends at 100 %', (_) async {
      const total = 4 * 1024 * 1024;
      final samples = <ProgressSnapshot>[];
      final http = client();

      final response = await http.requestBytes(
        HttpMethod.get,
        '/bytes/$total',
        onReceiveProgress: (transferred, expected) =>
            samples.add(ProgressSnapshot(transferred: transferred, total: expected)),
      );

      expect(response.bodyBytes, hasLength(total));
      expect(samples, isNotEmpty);
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i].transferred,
          greaterThanOrEqualTo(samples[i - 1].transferred),
          reason: 'progress went backwards at sample $i',
        );
      }
      expect(samples.last.transferred, total);
      expect(samples.last.total, total);
      expect(samples.last.isComplete, isTrue);
      expect(samples.last.fraction, 1.0);
    });

    testWidgets('send progress reaches the full body length', (_) async {
      const total = 512 * 1024;
      final samples = <int>[];
      final http = client();

      await http.post(
        '/upload',
        body: HttpBody.bytes(deterministicBytes(total)),
        onSendProgress: (transferred, _) => samples.add(transferred),
      );

      expect(samples, isNotEmpty);
      expect(samples.last, total);
      expect(server.lastUploadBytes, total);
    });
  });

  group('protocol reporting', () {
    testWidgets('a cleartext request reports HTTP/1.1', (_) async {
      final http = client();
      final response = await http.get('/echo');

      expect(response.version, HttpVersion.http11);
      expect(response.version.label, 'HTTP/1.1');
      expect(response.primaryIp, '127.0.0.1');
      expect(response.primaryPort, greaterThan(0));
    });

    testWidgets('http11Only still reports HTTP/1.1', (_) async {
      final only = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: server.baseUrl,
          httpVersionPref: HttpVersionPref.http11Only,
        ),
      );
      addTearDown(only.dispose);
      expect((await only.get('/echo')).version, HttpVersion.http11);
    });

    testWidgets('HTTP/2 against a public endpoint', (_) async {
      final remote = NitroHttpClient(
        settings: const ClientSettings(httpVersionPref: HttpVersionPref.http2),
      );
      addTearDown(remote.dispose);
      final response = await remote.get('https://cloudflare.com/cdn-cgi/trace');
      expect(response.version, HttpVersion.http2);
    }, skip: !runRemoteVersionTests);

    testWidgets('HTTP/3 against a public endpoint', (_) async {
      expect(NitroHttp.supportsHttp3, isTrue);
      final remote = NitroHttpClient(
        settings: const ClientSettings(
          httpVersionPref: HttpVersionPref.http3Only,
        ),
      );
      addTearDown(remote.dispose);
      final response = await remote.get('https://cloudflare.com/cdn-cgi/trace');
      expect(response.version, HttpVersion.http3);
    }, skip: !runRemoteVersionTests);
  });

  group('timings', () {
    testWidgets('phase timings are on by default and wantTimings: false turns '
        'them off', (_) async {
      final http = client();

      // `RequestOptions.wantTimings` is a tri-state override, and the engine
      // default is ON: `toRawOptions` sends `wantTimings: true` for an absent
      // override, and `test/raw_mapping_test.dart` pins that. Collection is one
      // `curl_easy_getinfo` per phase off a handle that is about to be torn
      // down, so paying for it always is the better default than surprising a
      // caller with an empty record.
      final byDefault = await http.get('/slow/120');
      expect(byDefault.timings.isEmpty, isFalse);
      expect(
        byDefault.timings.total,
        greaterThanOrEqualTo(const Duration(milliseconds: 100)),
      );
      expect(
        byDefault.timings.firstByte,
        lessThanOrEqualTo(byDefault.timings.total),
        reason: 'firstByte is a prefix of total',
      );

      final explicit = await http.get(
        '/slow/120',
        options: const RequestOptions(wantTimings: true),
      );
      expect(explicit.timings.isEmpty, isFalse);

      final off = await http.get(
        '/echo',
        options: const RequestOptions(wantTimings: false),
      );
      expect(
        off.timings.isEmpty,
        isTrue,
        reason: 'opting out must produce an empty record, not a partial one',
      );
      expect(off.timings.total, Duration.zero);
      expect(off.timings.dns, Duration.zero);
    });
  });
}
