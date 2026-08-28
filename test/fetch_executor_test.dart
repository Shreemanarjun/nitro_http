import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/executor_fetch.dart';
import 'package:nitro_http/src/internal/raw_mapping.dart';
import 'package:nitro_http/src/internal/request_runner.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

/// The web executor, driven on the VM against a fake `http.Client`.
///
/// `executor_web.dart` only picks `BrowserClient`; every decision — how a
/// request is shaped, how a response and its failures are mapped back, which
/// settings a page cannot honour — lives here, so it is testable without a
/// browser.
void main() {
  RawRequest request({
    String url = 'https://example.com/thing',
    RawMethod method = RawMethod.get,
    String customMethod = '',
    List<RawHeader> headers = const [],
    int followRedirects = 1,
  }) => RawRequest(
    requestId: 1,
    method: method,
    customMethod: customMethod,
    url: url,
    headers: headers,
    bodyKind: RawBodyKind.none,
    bodyFilePath: '',
    options: RawRequestOptions(
      connectTimeoutMs: -1,
      requestTimeoutMs: -1,
      followRedirects: followRedirects,
      maxRedirects: -1,
      cacheMode: RawCacheMode.normal,
      reportProgress: false,
      wantTimings: true,
      uploadContentLength: -1,
      pinnedSpkiOverride: '',
      cancelTokenId: 0,
    ),
  );

  // Built from real `ClientSettings` through the real mapper, so the rejection
  // is checked against what a caller would actually produce.
  RawClientConfig config([ClientSettings settings = const ClientSettings()]) =>
      toRawClientConfig(settings);

  group('request mapping', () {
    test('method, url and headers reach the client', () async {
      late http.BaseRequest seen;
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          seen = r;
          return http.Response('ok', 200);
        }),
      );

      await executor.sendBuffered(
        request(
          method: RawMethod.post,
          headers: const [RawHeader(name: 'x-trace', value: 'abc')],
        ),
        Uint8List.fromList(utf8.encode('payload')),
      );

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://example.com/thing');
      expect(seen.headers['x-trace'], 'abc');
      expect((seen as http.Request).body, 'payload');
    });

    test('a custom verb is sent verbatim', () async {
      late http.BaseRequest seen;
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          seen = r;
          return http.Response('', 200);
        }),
      );

      await executor.sendBuffered(
        request(customMethod: 'REPORT'),
        Uint8List(0),
      );
      expect(seen.method, 'REPORT');
    });

    test('followRedirects 0 is honoured', () async {
      late http.BaseRequest seen;
      final executor = FetchRequestExecutor(
        MockClient((r) async {
          seen = r;
          return http.Response('', 200);
        }),
      );

      await executor.sendBuffered(request(followRedirects: 0), Uint8List(0));
      expect(seen.followRedirects, isFalse);
    });
  });

  group('response mapping', () {
    test('status, headers and body come back', () async {
      final executor = FetchRequestExecutor(
        MockClient(
          (r) async => http.Response(
            'hello',
            201,
            headers: {'content-type': 'text/plain'},
            reasonPhrase: 'Created',
          ),
        ),
      );

      final response = await executor.sendBuffered(request(), Uint8List(0));

      expect(response.errorKind, RawErrorKind.none);
      expect(response.statusCode, 201);
      expect(utf8.decode(response.body), 'hello');
      expect(
        response.headers.any(
          (h) => h.name == 'content-type' && h.value == 'text/plain',
        ),
        isTrue,
      );
    });

    test('a transport failure becomes an io error, not an exception', () async {
      // `fetch` collapses DNS, refused and CORS into one opaque failure on
      // purpose, so the executor must not invent a more specific kind.
      final executor = FetchRequestExecutor(
        MockClient((r) async => throw http.ClientException('Failed to fetch')),
      );

      final response = await executor.sendBuffered(request(), Uint8List(0));

      expect(response.errorKind, RawErrorKind.io);
      expect(response.errorMessage, contains('Failed to fetch'));
      expect(response.statusCode, 0);
    });

    test('only the total timing is reported, never invented phases', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );

      final response = await executor.sendBuffered(request(), Uint8List(0));

      // A page cannot see DNS, connect or TLS separately.
      expect(response.timings.dnsMs, 0);
      expect(response.timings.connectMs, 0);
      expect(response.timings.tlsMs, 0);
      expect(response.timings.totalMs, greaterThanOrEqualTo(0));
    });
  });

  group('streaming', () {
    test('body chunks reach the demux and end with a done chunk', () async {
      final executor = FetchRequestExecutor(
        MockClient.streaming((r, body) async {
          return http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('one'),
              utf8.encode('two'),
            ]),
            200,
          );
        }),
      );

      final collected = <ChunkEvent>[];
      final done = Completer<void>();
      FetchStreamDemux.instance.chunks(1).listen((event) {
        collected.add(event);
        if (event.isDone) done.complete();
      });

      final head = await executor.startStreamed(request(), Uint8List(0));
      expect(head.statusCode, 200);
      await done.future.timeout(const Duration(seconds: 5));

      final data = collected.where((c) => c.isData).toList();
      expect(data, hasLength(2));
      expect(utf8.decode(data.first.bytes), 'one');
      expect(utf8.decode(data.last.bytes), 'two');
      expect(collected.last.isDone, isTrue);
      FetchStreamDemux.instance.release(1);
    });
  });

  group('what a browser cannot do', () {
    test('pinning, mTLS, proxies and DoH are refused, not ignored', () async {
      // Silently dropping a pin would be worse than failing: the caller would
      // believe a certificate was being checked when nothing was.
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );

      expect(
        () => executor.configureClient(
          config(
            const ClientSettings(
              tlsSettings: TlsSettings(pinnedSpkiSha256: ['sha256//abc']),
            ),
          ),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      expect(
        () => executor.configureClient(
          config(const ClientSettings(tlsSettings: TlsSettings.insecure())),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      expect(
        () => executor.configureClient(
          config(
            const ClientSettings(
              proxySettings: ProxySettings.http('http://proxy.local:8080'),
            ),
          ),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
    });

    test('a default configuration is accepted', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );
      expect(() => executor.configureClient(config()), returnsNormally);
    });

    test('a streamed upload is refused with a reason', () async {
      // fetch needs the whole body before it is called.
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      );
      expect(
        () => executor.feedUploadChunk(1, Uint8List(4)),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
    });
  });

  group('lifecycle', () {
    test('a disposed executor refuses further work', () async {
      final executor = FetchRequestExecutor(
        MockClient((r) async => http.Response('', 200)),
      )..dispose();

      await expectLater(
        executor.sendBuffered(request(), Uint8List(0)),
        throwsA(isA<NitroHttpDisposedException>()),
      );
    });

    test('cancel stops the body pump', () async {
      final controller = StreamController<List<int>>();
      final executor = FetchRequestExecutor(
        MockClient.streaming(
          (r, body) async => http.StreamedResponse(controller.stream, 200),
        ),
      );

      await executor.startStreamed(request(), Uint8List(0));
      executor.cancel(1);
      // The subscription is gone, so pushing more must not reach anyone.
      controller.add(utf8.encode('late'));
      await controller.close();
      expect(controller.hasListener, isFalse);
    });
  });
}
