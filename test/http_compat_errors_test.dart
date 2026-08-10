// The `package:http` adapter's error mapping and its declared-length fallback.
//
// `http_compat_test.dart` covers the happy paths and the abort semantics the
// conformance suite exercises. These are the branches it does not reach: every
// `NitroHttpException` variant that has to become a `ClientException`, and the
// body assembler's behaviour when `Content-Length` lies.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'support/fakes.dart';

final Uri _url = Uri.parse('https://api.test/resource');

void main() {
  late FakeRequestExecutor executor;
  late FakeStreamDemux demux;

  NitroHttpCompatClient compatClient() => NitroHttpCompatClient.wrap(
    NitroHttpClient(
      settings: const ClientSettings(),
      executor: executor,
      demux: demux,
    ),
  );

  setUp(() {
    executor = FakeRequestExecutor();
    demux = FakeStreamDemux();
  });

  tearDown(() => demux.closeAll());

  group('error mapping', () {
    /// Fails `startStreamed` with a transport error of [kind].
    void failWith(RawErrorKind kind, {String message = 'engine said no'}) {
      executor.onStartStreamed = (request, body) async => rawHead(
        requestId: request.requestId,
        kind: kind,
        message: message,
      );
    }

    test('a redirect overflow reports the de facto wording', () async {
      // `dart:io`, `cronet_http` and `cupertino_http` all say exactly this, and
      // the conformance suite matches on it.
      failWith(RawErrorKind.tooManyRedirects);

      await expectLater(
        compatClient().get(_url),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            'Redirect limit exceeded',
          ),
        ),
      );
    });

    test('every other transport failure becomes a ClientException', () async {
      // The mapping is a `switch` over a sealed hierarchy: if a variant is
      // added and not handled, this is what catches it.
      const kinds = <RawErrorKind>[
        RawErrorKind.timeoutConnect,
        RawErrorKind.timeoutRequest,
        RawErrorKind.timeoutIdle,
        RawErrorKind.dnsFailure,
        RawErrorKind.connectionRefused,
        RawErrorKind.connectionReset,
        RawErrorKind.connectionFailed,
        RawErrorKind.tlsHandshake,
        RawErrorKind.certificateInvalid,
        RawErrorKind.certificatePinMismatch,
        RawErrorKind.proxyFailure,
        RawErrorKind.protocolError,
        RawErrorKind.unsupportedScheme,
        RawErrorKind.sendFailure,
        RawErrorKind.receiveFailure,
        RawErrorKind.decompressionFailure,
        RawErrorKind.io,
        RawErrorKind.cacheMiss,
        RawErrorKind.engineError,
        RawErrorKind.badRequest,
        RawErrorKind.unknown,
      ];

      for (final kind in kinds) {
        executor = FakeRequestExecutor();
        demux = FakeStreamDemux();
        failWith(kind);

        await expectLater(
          compatClient().get(_url),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.uri,
              'uri',
              _url,
            ),
          ),
          reason: '$kind',
        );
        demux.closeAll();
      }
    });

    test('the exception carries the engine message', () async {
      failWith(RawErrorKind.connectionRefused, message: 'connection refused');

      await expectLater(
        compatClient().get(_url),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('refused'),
          ),
        ),
      );
    });
  });

  group('declared-length body assembly', () {
    /// Answers with a head declaring [contentLength], then feeds [chunks].
    Future<http.Response> respondWith({
      required int contentLength,
      required List<List<int>> chunks,
    }) async {
      executor.onStartStreamed = (request, body) async => rawHead(
        requestId: request.requestId,
        headers: [
          RawHeader(name: 'content-length', value: '$contentLength'),
        ],
        contentLength: contentLength,
      );

      final pending = compatClient().get(_url);
      // The runner subscribes before the head resolves, so the id exists by the
      // time the future has been handed out.
      await Future<void>.delayed(Duration.zero);
      final id = executor.streamedRequests.single.request.requestId;
      for (final chunkBytes in chunks) {
        demux.push(chunk(id, chunkBytes));
      }
      demux.push(doneChunk(id));
      return pending;
    }

    test('assembles a body that matches the declared length', () async {
      final response = await respondWith(
        contentLength: 6,
        chunks: [
          [1, 2, 3],
          [4, 5, 6],
        ],
      );

      expect(response.bodyBytes, [1, 2, 3, 4, 5, 6]);
    });

    test('keeps the whole body when the server declared too little', () async {
      // Truncating would silently corrupt the response; growing is the only
      // safe answer to a lying Content-Length.
      final response = await respondWith(
        contentLength: 3,
        chunks: [
          [1, 2, 3],
          [4, 5, 6],
          [7],
        ],
      );

      expect(response.bodyBytes, [1, 2, 3, 4, 5, 6, 7]);
    });

    test('trims the buffer when the server declared too much', () async {
      final response = await respondWith(
        contentLength: 10,
        chunks: [
          [1, 2, 3],
        ],
      );

      expect(response.bodyBytes, [1, 2, 3]);
    });

    test('handles an empty body against a declared length', () async {
      final response = await respondWith(contentLength: 4, chunks: []);

      expect(response.bodyBytes, isEmpty);
    });
  });
}
