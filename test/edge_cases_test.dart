import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

/// Edges that are easy to get wrong and expensive to get wrong: a redirect that
/// must keep its body, a server that lies about how much it will send, and user
/// data reaching a header.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dylib = 'build/lib/libnitro_http.dylib';
  final available = File(dylib).existsSync();
  final skipReason = available ? null : 'build the engine first: tool/build-cpp.sh';

  late HttpServer server;
  late String base;
  final received = <String, ({String method, String body})>{};
  NitroHttpClient? client;

  setUpAll(() async {
    if (!available) return;
    DynamicLibrary.open(dylib);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      final body = await utf8.decoder.bind(request).join();
      received[path] = (method: request.method, body: body);
      final response = request.response;

      switch (path) {
        case '/redirect307':
          response
            ..statusCode = 307
            ..headers.set('location', '/landing');
        case '/redirect-relative':
          // No leading slash: it has to resolve against the request URL.
          response
            ..statusCode = 302
            ..headers.set('location', 'landing');
        case '/landing':
          response
            ..statusCode = 200
            ..write('landed');
        case '/no-content':
          response.statusCode = 204;
        case '/many-headers':
          response.statusCode = 200;
          for (var i = 0; i < 60; i++) {
            response.headers.add('x-h$i', 'v$i');
          }
          response.write('ok');
        default:
          response
            ..statusCode = 200
            ..write('ok $path');
      }
      await response.close();
    });
  });

  tearDown(() {
    client?.dispose();
    client = null;
  });

  tearDownAll(() async {
    if (available) await server.close(force: true);
  });

  NitroHttpClient make() => client = NitroHttpClient(
    settings: const ClientSettings(
      timeout: Duration(seconds: 20),
      throwOnStatusCode: false,
    ),
  );

  group('header injection', () {
    test('a newline in a value is refused before it reaches the wire', () {
      // Without this, a caller who puts user input in a header hands an
      // attacker request splitting: everything after the line break is read by
      // the server as another header. Verified against a raw socket — these
      // values previously arrived as a separate `X-Injected` header.
      final crlf = String.fromCharCodes([0x0D, 0x0A]);
      final lf = String.fromCharCode(0x0A);
      final cr = String.fromCharCode(0x0D);
      final nul = String.fromCharCode(0x00);

      for (final evil in <String>[
        'a${crlf}X-Injected: yes',
        'b${lf}X-Injected: yes',
        'c${cr}X-Injected: yes',
        'd${nul}e',
      ]) {
        expect(
          () => HttpHeaders.fromMap({'x-trace': evil}),
          throwsA(isA<ArgumentError>()),
          reason: 'accepted ${evil.codeUnits}',
        );
      }
    });

    test('a header name is checked the same way', () {
      final crlf = String.fromCharCodes([0x0D, 0x0A]);
      expect(
        () => HttpHeaders()..set('x-bad${crlf}X-Injected', 'v'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('add is checked too, not only set', () {
      final crlf = String.fromCharCodes([0x0D, 0x0A]);
      expect(
        () => HttpHeaders()..add('x-trace', 'a${crlf}X-Injected: yes'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('ordinary values with punctuation and spaces still pass', () {
      final headers = HttpHeaders.fromMap({
        'authorization': 'Bearer abc.def-ghi_jkl',
        'user-agent': 'app/1.0 (macOS; test)',
        'x-json': '{"a":1,"b":[2,3]}',
      });
      expect(headers['x-json'], '{"a":1,"b":[2,3]}');
    });
  });

  group('redirects', () {
    test('credentials are not carried to another origin', () async {
      // The classic redirect leak: a 302 to a host you did not authenticate to
      // must not take the Authorization header or the cookies with it.
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => other.close(force: true));
      String? sawAuth;
      String? sawCookie;
      other.listen((request) async {
        sawAuth = request.headers.value('authorization');
        sawCookie = request.headers.value('cookie');
        request.response
          ..statusCode = 200
          ..write('other');
        await request.response.close();
      });

      final redirector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => redirector.close(force: true));
      redirector.listen((request) async {
        request.response
          ..statusCode = 302
          ..headers.set(
            'location',
            'http://127.0.0.1:${other.port}/landing',
          );
        await request.response.close();
      });

      final response = await make().get(
        'http://127.0.0.1:${redirector.port}/go',
        headers: HttpHeaders.fromMap({
          'authorization': 'Bearer SECRET',
          'cookie': 'session=SECRET',
        }),
      );

      expect(response.statusCode, 200);
      expect(sawAuth, isNull, reason: 'Authorization leaked across origins');
      expect(sawCookie, isNull, reason: 'Cookie leaked across origins');
    }, skip: skipReason);

    test('a redirect loop reports the hops it followed, not an error code',
        () async {
      // `redirectCount` used to be filled with the CURLcode — always 47,
      // whatever the cap was — which is worse than useless on an exception
      // whose whole job is to say how far it got.
      final looper = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => looper.close(force: true));
      looper.listen((request) async {
        request.response
          ..statusCode = 302
          ..headers.set('location', '/loop');
        await request.response.close();
      });

      await expectLater(
        make().get('http://127.0.0.1:${looper.port}/loop'),
        throwsA(
          isA<NitroHttpRedirectException>().having(
            (e) => e.redirectCount,
            'redirectCount',
            const RedirectSettings.limited(30).maxRedirects,
          ),
        ),
      );
    }, skip: skipReason);

    test('307 keeps the method and the body', () async {
      // The whole point of 307 over 302: a POST stays a POST and keeps its
      // payload, so a redirected write is not silently downgraded to a GET.
      final response = await make().post(
        '$base/redirect307',
        body: HttpBody.text('payload'),
      );

      expect(response.statusCode, 200);
      expect(received['/landing']?.method, 'POST');
      expect(received['/landing']?.body, 'payload');
    }, skip: skipReason);

    test('a relative Location resolves against the request URL', () async {
      final response = await make().get('$base/redirect-relative');
      expect(response.statusCode, 200);
      expect(response.body, 'landed');
      expect(response.finalUrl.path, '/landing');
    }, skip: skipReason);
  });

  group('response shapes', () {
    test('204 arrives as 204 with an empty body', () async {
      final response = await make().get('$base/no-content');
      expect(response.statusCode, 204);
      expect(response.bodyBytes, isEmpty);
    }, skip: skipReason);

    test('a body shorter than Content-Length fails instead of truncating',
        () async {
      // A raw socket, because `dart:io` refuses to close a response that wrote
      // fewer bytes than it promised — the misbehaviour under test cannot be
      // expressed through HttpServer at all.
      final rude = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(rude.close);
      rude.listen((socket) async {
        await socket.first;
        socket.add(
          'HTTP/1.1 200 OK'
                  '${String.fromCharCodes([0x0D, 0x0A])}'
                  'Content-Length: 100'
                  '${String.fromCharCodes([0x0D, 0x0A, 0x0D, 0x0A])}'
              .codeUnits,
        );
        socket.add(List<int>.filled(10, 65));
        await socket.flush();
        await socket.close();
      });

      // The dangerous outcome is a short body reported as success: the caller
      // parses half a document and never learns it was cut off.
      await expectLater(
        make().get('http://127.0.0.1:${rude.port}/short'),
        throwsA(isA<NitroHttpConnectionException>()),
      );
    }, skip: skipReason);

    test('a large header set survives intact', () async {
      final response = await make().get('$base/many-headers');
      expect(response.statusCode, 200);
      for (var i = 0; i < 60; i++) {
        expect(response.headers['x-h$i'], 'v$i', reason: 'lost x-h$i');
      }
    }, skip: skipReason);
  });

  group('urls', () {
    test('a newline in the path is encoded, never sent raw', () async {
      // Unlike a header value, this one is safe already: curl percent-encodes
      // the URL, so the request line stays a single line. Asserted so it stays
      // that way.
      final crlf = String.fromCharCodes([0x0D, 0x0A]);
      final response = await make().get('$base/edge${crlf}X-Injected: yes');
      expect(response.statusCode, 200);
      expect(response.body, contains('%0D%0A'));
      expect(response.body, isNot(contains(crlf)));
    }, skip: skipReason);

    test('a percent-encoded path is sent verbatim, not re-encoded', () async {
      // Re-encoding would turn %C3%A9 into %25C3%25A9 and quietly request a
      // different resource.
      final response = await make().get('$base/caf%C3%A9/%E4%B8%96');
      expect(response.statusCode, 200);
      expect(response.body, 'ok /caf%C3%A9/%E4%B8%96');
    }, skip: skipReason);
  });

  group('concurrency', () {
    test('twenty requests on one client do not cross responses', () async {
      // One client multiplexes over a shared engine, so a demux slip would show
      // up as two futures resolving with the same body.
      final c = make();
      final responses = await Future.wait([
        for (var i = 0; i < 20; i++) c.get('$base/c$i'),
      ]);

      expect(responses.every((r) => r.statusCode == 200), isTrue);
      expect(
        responses.map((r) => r.body).toSet(),
        hasLength(20),
        reason: 'responses were crossed between requests',
      );
      for (var i = 0; i < 20; i++) {
        expect(responses[i].body, 'ok /c$i');
      }
    }, skip: skipReason);
  });
}
