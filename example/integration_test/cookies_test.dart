/// Cookie storage and replay, including a jar that outlives the client.
///
/// The jar lives in the native engine, so "the cookie was stored" is only proven
/// by the server seeing it come back on the *next* request — which is what these
/// tests assert, via `LocalServer.lastCookieHeader`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http_example/server/local_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;

  setUp(() async {
    server = await LocalServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  NitroHttpClient newClient({String? persistPath, bool storeCookies = true}) {
    final client = NitroHttpClient(
      settings: ClientSettings(
        baseUrl: server.baseUrl,
        cookieSettings: CookieSettings(
          storeCookies: storeCookies,
          persistPath: persistPath,
        ),
      ),
    );
    addTearDown(client.dispose);
    return client;
  }

  /// Parses the `cookies` map out of `GET /readcookie`.
  Map<String, Object?> readCookies(HttpTextResponse response) =>
      (response.bodyToJson() as Map<String, Object?>)['cookies']
          as Map<String, Object?>;

  testWidgets('a Set-Cookie is stored and replayed on the next request',
      (_) async {
    final client = newClient();

    final set = await client.get('/setcookie');
    expect(
      set.headers.setCookie,
      hasLength(2),
      reason: 'both Set-Cookie lines must survive as separate fields',
    );

    final read = await client.get('/readcookie');
    expect(readCookies(read), containsPair('sid', 'local-session'));
    expect(readCookies(read), containsPair('flavour', 'vanilla'));
    expect(server.lastCookieHeader, contains('sid=local-session'));
  });

  testWidgets('the jar is visible from Dart and scoped to the request host',
      (_) async {
    final client = newClient();
    await client.get('/setcookie?name=scoped&value=abc');

    final all = client.allCookies();
    expect(all.map((c) => c.name), contains('scoped'));

    final matching = client.cookiesFor(server.uri('/anything'));
    expect(matching.map((c) => c.name), contains('scoped'));

    final elsewhere = client.cookiesFor(Uri.parse('http://example.invalid/'));
    expect(
      elsewhere,
      isEmpty,
      reason: 'a 127.0.0.1 cookie must not be offered to another host',
    );
  });

  testWidgets('a cookie set from Dart goes out on the wire', (_) async {
    final client = newClient();
    client.setCookie(
      Cookie(
        name: 'from-dart',
        value: 'hand-written',
        domain: '127.0.0.1',
        path: '/',
      ),
    );

    final read = await client.get('/readcookie');
    expect(readCookies(read), containsPair('from-dart', 'hand-written'));
  });

  testWidgets('storeCookies: false neither stores nor sends', (_) async {
    final client = newClient(storeCookies: false);

    await client.get('/setcookie');
    expect(client.allCookies(), isEmpty);

    await client.get('/readcookie');
    expect(server.lastCookieHeader, isNull);
  });

  testWidgets('a persistent jar survives disposal and reloads in a new client',
      (_) async {
    final dir = await Directory.systemTemp.createTemp('nitro_http_cookie_jar');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Nothing to salvage; a stray temp directory is not a test failure.
      }
    });
    final jarPath = '${dir.path}/cookies.txt';

    final first = NitroHttpClient(
      settings: ClientSettings(
        baseUrl: server.baseUrl,
        // A session cookie is not persisted by design, so ask for one with an
        // expiry far enough out that the jar has to write it down.
        cookieSettings: CookieSettings(persistPath: jarPath),
      ),
    );
    await first.get('/setcookie?name=persisted&value=on-disk&maxAge=3600');
    expect(first.allCookies().map((c) => c.name), contains('persisted'));
    first.flushCookies();
    first.dispose();

    expect(
      File(jarPath).existsSync(),
      isTrue,
      reason: 'flushCookies must have written the Netscape jar',
    );

    final second = newClient(persistPath: jarPath);
    expect(
      second.allCookies().map((c) => c.name),
      contains('persisted'),
      reason: 'the new client must have loaded the jar from disk',
    );

    final read = await second.get('/readcookie');
    expect(readCookies(read), containsPair('persisted', 'on-disk'));
  });

  testWidgets('clearCookies empties the jar and stops the header going out',
      (_) async {
    final client = newClient();
    await client.get('/setcookie');
    expect(client.allCookies(), isNotEmpty);

    client.clearCookies();
    expect(client.allCookies(), isEmpty);

    await client.get('/readcookie');
    expect(
      server.lastCookieHeader,
      isNull,
      reason: 'a cleared jar must send no Cookie header at all',
    );
  });

  testWidgets('an expired replacement deletes a cookie', (_) async {
    final client = newClient();
    await client.get('/setcookie?name=doomed&value=x&maxAge=3600');
    expect(client.allCookies().map((c) => c.name), contains('doomed'));

    // The wire-level delete: store it again with an expiry in the past, exactly
    // what a server does with `Max-Age=0`.
    //
    // NOT `DateTime.utc(1970)`. The jar is Netscape-format, where the expiry
    // column is epoch SECONDS and 0 is the format's own encoding of "session
    // cookie". An expiry of exactly the epoch is therefore indistinguishable
    // from "no expiry", and curl would keep the cookie rather than drop it.
    client.setCookie(
      Cookie(
        name: 'doomed',
        value: '',
        domain: '127.0.0.1',
        path: '/',
        expires: DateTime.utc(2000),
      ),
    );

    final read = await client.get('/readcookie');
    expect(readCookies(read).containsKey('doomed'), isFalse);
    expect(
      client.allCookies().map((c) => c.name),
      isNot(contains('doomed')),
      reason: 'the jar itself must have dropped it, not just this request',
    );
  });

  testWidgets('two clients keep separate jars', (_) async {
    final a = newClient();
    final b = newClient();

    await a.get('/setcookie?name=only-a&value=1');
    expect(a.allCookies().map((c) => c.name), contains('only-a'));
    expect(b.allCookies(), isEmpty);

    await b.get('/readcookie');
    expect(server.lastCookieHeader, isNull);
  });
}
