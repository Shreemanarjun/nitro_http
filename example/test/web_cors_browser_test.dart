// The only test that can see CORS: the web executor's own tests run on the VM
// against a fake client. In a real browser a credentialed request is refused by
// a server that answers `Access-Control-Allow-Origin: *`, which is why
// cross-origin credentials are opt-in.
//
//   cd example && flutter test --platform chrome test/web_cors_browser_test.dart
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  late String base;

  setUpAll(() async {
    final channel = spawnHybridCode(r'''
      import 'dart:convert';
      import 'dart:io';
      import 'package:stream_channel/stream_channel.dart';

      Future<void> hybridMain(StreamChannel<Object?> channel) async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          // /wild answers every origin; /named names the caller and allows credentials.
          final named = req.uri.path.startsWith('/named');
          req.response.headers
            ..set('Access-Control-Allow-Origin', named ? (req.headers.value('origin') ?? '') : '*')
            ..set('Access-Control-Allow-Headers', 'content-type')
            ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
          if (named) req.response.headers.set('Access-Control-Allow-Credentials', 'true');
          if (req.method == 'OPTIONS') {
            await req.response.close();
            return;
          }
          final body = await req.fold<int>(0, (n, c) => n + c.length);
          req.response.write(jsonEncode({'method': req.method, 'bytes': body}));
          await req.response.close();
        });
        channel.sink.add(server.port);
        await channel.stream.drain<void>();
      }
    ''');
    base = 'http://127.0.0.1:${((await channel.stream.first)! as num).toInt()}';
  });

  test('default settings reach a wildcard-CORS server', () async {
    final client = NitroHttpClient(settings: ClientSettings(baseUrl: base));
    addTearDown(client.dispose);
    expect((await client.get('/wild')).bodyToJson(), {'method': 'GET', 'bytes': 0});
    final post = await client.post('/wild', body: HttpBody.bytes(Uint8List(70000)));
    expect(post.bodyToJson(), {'method': 'POST', 'bytes': 70000});
  });

  test('with crossOriginCredentials the browser refuses a wildcard server', () async {
    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: base, crossOriginCredentials: true),
    );
    addTearDown(client.dispose);
    await expectLater(client.get('/wild'), throwsA(isA<NitroHttpException>()));
  });

  test('with crossOriginCredentials a server that names the origin is reached', () async {
    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: base, crossOriginCredentials: true),
    );
    addTearDown(client.dispose);
    expect((await client.get('/named')).statusCode, 200);
  });
}
