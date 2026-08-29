import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
// `HttpRequest` and `HttpHeaders` exist in both libraries; the handler below
// wants the `dart:io` ones.
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

import 'support/tls_server.dart';

/// The response size ceiling, downloads that bypass the Dart heap, and the
/// three connection settings that decide which socket a request leaves on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dylib = 'build/lib/libnitro_http.dylib';
  final available = File(dylib).existsSync();
  final skipReason = available ? null : 'build the engine first: tool/build-cpp.sh';

  late HttpServer server;
  late String base;
  late Directory scratch;
  NitroHttpClient? client;

  setUpAll(() async {
    if (!available) return;
    DynamicLibrary.open(dylib);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen(_handle);
  });

  setUp(() {
    if (available) scratch = Directory.systemTemp.createTempSync('nitro_dl');
  });

  tearDown(() {
    client?.dispose();
    client = null;
    if (available && scratch.existsSync()) {
      scratch.deleteSync(recursive: true);
    }
  });

  tearDownAll(() async {
    if (available) await server.close(force: true);
  });

  NitroHttpClient make({
    int? maxResponseBytes,
    String? hstsCachePath,
    String? unixSocketPath,
    String? networkInterface,
    bool throwOnStatusCode = false,
  }) => client = NitroHttpClient(
    settings: ClientSettings(
      timeout: const Duration(seconds: 20),
      throwOnStatusCode: throwOnStatusCode,
      maxResponseBytes: maxResponseBytes,
      hstsCachePath: hstsCachePath,
      unixSocketPath: unixSocketPath,
      networkInterface: networkInterface,
    ),
  );

  group('response size ceiling', () {
    test('a declared Content-Length over the limit fails before the body',
        () async {
      // `CURLE_FILESIZE_EXCEEDED` (63) is curl's own refusal, which for a
      // declared length happens before the transfer starts. The bytes are not
      // directly observable — a 4 KiB body sits in a socket buffer whether or
      // not anyone reads it — so the code is what pins which check ran.
      await expectLater(
        make(maxResponseBytes: 1024).get('$base/size/4096'),
        throwsA(
          isA<NitroHttpResponseTooLargeException>()
              .having((e) => e.engineErrorCode, 'engineErrorCode', 63),
        ),
      );
    }, skip: skipReason);

    test('a chunked body over the limit is caught while it arrives', () async {
      // No declaration to check up front. curl applies `MAXFILESIZE` to the
      // running total as well, so it still reports this one itself.
      await expectLater(
        make(maxResponseBytes: 1024).get('$base/chunked/8192'),
        throwsA(isA<NitroHttpResponseTooLargeException>()),
      );
    }, skip: skipReason);

    test('a body of exactly the limit is allowed through', () async {
      // The boundary is "larger than", not "at least" — a limit of N must
      // accept N or the setting is unusable for an API with a known size.
      final response = await make(maxResponseBytes: 1024).get('$base/size/1024');
      expect(response.statusCode, 200);
      expect(response.bodyBytes, hasLength(1024));
    }, skip: skipReason);

    test('one byte over the limit is refused', () async {
      await expectLater(
        make(maxResponseBytes: 1024).get('$base/chunked/1025'),
        throwsA(isA<NitroHttpResponseTooLargeException>()),
      );
    }, skip: skipReason);

    test('the decoded size is what counts, not the compressed size', () async {
      // 64 KiB of one repeated byte is a few hundred bytes on the wire, and the
      // engine decodes rather than curl, so curl's own `MAXFILESIZE` never sees
      // a number over the limit. Engine code 0 says the running count caught it
      // — which is exactly the case curl cannot cover, and the same hole the
      // decompression cap exists to close.
      await expectLater(
        make(maxResponseBytes: 4096).get('$base/gzip/65536'),
        throwsA(
          isA<NitroHttpResponseTooLargeException>()
              .having((e) => e.engineErrorCode, 'engineErrorCode', 0),
        ),
      );
    }, skip: skipReason);

    test('no ceiling means no ceiling', () async {
      final response = await make().get('$base/size/65536');
      expect(response.bodyBytes, hasLength(65536));
    }, skip: skipReason);

    test('a redirect body does not count toward the final one', () async {
      // The counter has to reset on each hop. If a 4 KiB 302 body were still
      // being counted, this 2 KiB response would fail against a 4 KiB ceiling —
      // and the failure would look like the server sending too much.
      final response = await make(
        maxResponseBytes: 4096,
      ).get('$base/fat-redirect-to/size/2048');

      expect(response.statusCode, 200);
      expect(response.bodyBytes, hasLength(2048));
    }, skip: skipReason);

    test('a HEAD response has no body to exceed the limit', () async {
      // `Content-Length` describes a body that is never sent, so refusing on the
      // declaration alone would make HEAD unusable with any ceiling.
      final response = await make(
        maxResponseBytes: 16,
      ).head('$base/size/65536');

      expect(response.statusCode, 200);
    }, skip: skipReason);

    test('a one byte ceiling still permits an empty body', () async {
      final response = await make(maxResponseBytes: 1).get('$base/size/0');
      expect(response.statusCode, 200);
      expect(response.bodyBytes, isEmpty);
    }, skip: skipReason);

    test('a streamed response under the limit is untouched', () async {
      // The control for the refusal below: proves the ceiling is not simply
      // breaking every streamed response.
      final stream = await make(maxResponseBytes: 8192).requestStream(
        HttpMethod.get,
        '$base/chunked/4096',
      );
      final received = await stream.body.fold<int>(0, (n, c) => n + c.length);
      expect(received, 4096);
    }, skip: skipReason);

    test('two clients keep their own ceilings', () async {
      // The limit is copied onto each transfer when it is prepared, so a client
      // configured loosely must not inherit a stricter neighbour's ceiling — or
      // the other way round, which is the dangerous direction.
      final strict = NitroHttpClient(
        settings: const ClientSettings(maxResponseBytes: 1024),
      );
      final loose = NitroHttpClient(
        settings: const ClientSettings(maxResponseBytes: 65536),
      );
      addTearDown(() {
        strict.dispose();
        loose.dispose();
      });

      await expectLater(
        strict.get('$base/size/4096'),
        throwsA(isA<NitroHttpResponseTooLargeException>()),
      );
      expect((await loose.get('$base/size/4096')).bodyBytes, hasLength(4096));
    }, skip: skipReason);

    test('a streamed response is held to the same limit', () async {
      final stream = await make(maxResponseBytes: 1024).requestStream(
        HttpMethod.get,
        '$base/chunked/8192',
      );
      await expectLater(
        stream.body.drain<void>(),
        throwsA(isA<NitroHttpResponseTooLargeException>()),
      );
    }, skip: skipReason);
  });

  group('downloadToFile', () {
    test('the body lands on disk and never in the response', () async {
      final path = '${scratch.path}/payload.bin';
      final response = await make().downloadToFile('$base/size/65536', path);

      expect(response.statusCode, 200);
      expect(File(path).lengthSync(), 65536);
      // The point of the whole feature: the bytes did not come back through the
      // bridge, so the response carries none.
      expect(response.bodyBytes, isEmpty);
      // Everything that is not the body is still there.
      expect(response.headers['content-type'], isNotNull);
    }, skip: skipReason);

    test('a 404 leaves no file behind and returns the error body', () async {
      // Otherwise a failed download leaves an error page under the name the
      // caller chose, and nothing about the file says it is not the download.
      final path = '${scratch.path}/missing.bin';
      final response = await make().downloadToFile('$base/status/404', path);

      expect(response.statusCode, 404);
      expect(File(path).existsSync(), isFalse);
      expect(utf8.decode(response.bodyBytes), contains('not found'));
    }, skip: skipReason);

    test('an existing file is replaced, not appended to', () async {
      final path = '${scratch.path}/existing.bin';
      File(path).writeAsBytesSync(List<int>.filled(4096, 0x5A));

      await make().downloadToFile('$base/size/16', path);
      expect(File(path).lengthSync(), 16);
    }, skip: skipReason);

    test('a redirect writes only the body it landed on', () async {
      // A 302 whose own body reached the file would sit in front of the real
      // one, and the file would be silently wrong rather than missing.
      final path = '${scratch.path}/redirected.bin';
      final response = await make().downloadToFile(
        '$base/redirect-to/size/2048',
        path,
      );

      expect(response.statusCode, 200);
      expect(File(path).lengthSync(), 2048);
    }, skip: skipReason);

    test('a body over the ceiling leaves no partial file', () async {
      final path = '${scratch.path}/toobig.bin';
      await expectLater(
        make(maxResponseBytes: 1024).downloadToFile('$base/chunked/8192', path),
        throwsA(isA<NitroHttpResponseTooLargeException>()),
      );
      expect(File(path).existsSync(), isFalse);
    }, skip: skipReason);

    test('a redirect that carried its own body still writes only the last',
        () async {
      // The engine opens the file before the first hop, so a 302 with a body
      // writes 4 KiB that is not part of the download. Rewinding on the next
      // status line is what keeps it from being glued in front of the real body
      // — and the file would be silently wrong rather than missing.
      final path = '${scratch.path}/fat.bin';
      final response = await make().downloadToFile(
        '$base/fat-redirect-to/size/2048',
        path,
      );

      expect(response.statusCode, 200);
      expect(File(path).lengthSync(), 2048);
      // 0x41 is the body; 0x5A is what the redirect hop sent.
      expect(File(path).readAsBytesSync().every((b) => b == 0x41), isTrue);
    }, skip: skipReason);

    test('a redirect that lands on a 404 leaves no file', () async {
      // The destination is already open and may already have been written to by
      // the hop, so the removal has to happen on the final status, not the first.
      final path = '${scratch.path}/gone.bin';
      final response = await make().downloadToFile(
        '$base/fat-redirect-to/status/404',
        path,
      );

      expect(response.statusCode, 404);
      expect(File(path).existsSync(), isFalse);
    }, skip: skipReason);

    test('a compressed body is written decoded', () async {
      // The file is what the caller asked for, not what was on the wire — a
      // gzip stream on disk under a .bin name would be a silent corruption.
      final path = '${scratch.path}/decoded.bin';
      await make().downloadToFile('$base/gzip/4096', path);

      final bytes = File(path).readAsBytesSync();
      expect(bytes, hasLength(4096));
      expect(bytes.every((b) => b == 0x41), isTrue);
    }, skip: skipReason);

    test('a 204 produces an empty file rather than none', () async {
      // A successful response with no body is still a successful download, so
      // the file must exist — a caller checking `existsSync` should not have to
      // special-case it.
      final path = '${scratch.path}/empty.bin';
      final response = await make().downloadToFile('$base/status/204', path);

      expect(response.statusCode, 204);
      expect(File(path).existsSync(), isTrue);
      expect(File(path).lengthSync(), 0);
    }, skip: skipReason);

    test('concurrent downloads on one client do not cross', () async {
      // One client multiplexes over a shared engine, and each transfer now
      // carries its own `FILE*` — a slip would show up as bytes in the wrong
      // file, which no status code would reveal.
      final c = make();
      final paths = [for (var i = 0; i < 6; i++) '${scratch.path}/c$i.bin'];
      await Future.wait([
        for (var i = 0; i < 6; i++)
          c.downloadToFile('$base/size/${(i + 1) * 1024}', paths[i]),
      ]);

      for (var i = 0; i < 6; i++) {
        expect(File(paths[i]).lengthSync(), (i + 1) * 1024, reason: paths[i]);
      }
    }, skip: skipReason);

    test('throwOnStatusCode still leaves no file behind', () async {
      // The removal is the engine's, not the client's, so it has to happen
      // whether or not the status turns into an exception.
      final path = '${scratch.path}/thrown.bin';
      await expectLater(
        make(throwOnStatusCode: true).downloadToFile('$base/status/404', path),
        throwsA(isA<NitroHttpStatusCodeException>()),
      );
      expect(File(path).existsSync(), isFalse);
    }, skip: skipReason);

    test('an ordinary request after a download is unaffected', () async {
      // The destination belongs to one transfer. A handle or task that carried
      // it into the next request would send the body to a file nobody asked
      // about, and the caller would see an empty response with no explanation.
      final c = make();
      final path = '${scratch.path}/first.bin';
      await c.downloadToFile('$base/size/512', path);

      final response = await c.get('$base/size/256');
      expect(response.bodyBytes, hasLength(256));
      expect(File(path).lengthSync(), 512, reason: 'the first file changed');
    }, skip: skipReason);

    test('a failed download does not poison the next one', () async {
      // The failure path closes and removes the file. Doing that twice, or
      // leaving the handle believing it still has one, would take the following
      // download with it.
      final c = make(maxResponseBytes: 1024);
      await expectLater(
        c.downloadToFile('$base/chunked/8192', '${scratch.path}/bad.bin'),
        throwsA(isA<NitroHttpResponseTooLargeException>()),
      );

      final good = '${scratch.path}/good.bin';
      final response = await c.downloadToFile('$base/size/512', good);
      expect(response.statusCode, 200);
      expect(File(good).lengthSync(), 512);
    }, skip: skipReason);

    test('a directory in place of the destination fails cleanly', () async {
      // `fopen` on a directory fails, and the failure must arrive as an ordinary
      // exception rather than taking the engine down.
      final dir = Directory('${scratch.path}/adir')..createSync();
      await expectLater(
        make().downloadToFile('$base/size/16', dir.path),
        throwsA(isA<NitroHttpException>()),
      );
    }, skip: skipReason);

    test('a save path on a streamed request is refused', () async {
      // `downloadToFile` always asks for a buffered response, but nothing stops
      // a caller building the request by hand. The engine writes the body to
      // one place or the other, never both, so this has to be refused rather
      // than silently picking one.
      final path = '${scratch.path}/streamed.bin';
      await expectLater(
        make().request(
          HttpRequest(
            url: Uri.parse('$base/size/1024'),
            expectedBody: HttpExpectedBody.stream,
            saveToPath: path,
          ),
        ),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
      expect(File(path).existsSync(), isFalse);
    }, skip: skipReason);

    test('a path that cannot be opened fails before the request', () async {
      await expectLater(
        make().downloadToFile('$base/size/16', '${scratch.path}/no/such/dir/x'),
        throwsA(isA<NitroHttpException>()),
      );
    }, skip: skipReason);

    test('a cancelled download leaves no file', () async {
      final path = '${scratch.path}/cancelled.bin';
      final token = CancelToken();
      final pending = make().downloadToFile(
        '$base/slow/1048576',
        path,
        cancelToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      token.cancel('enough');

      await expectLater(pending, throwsA(isA<NitroHttpCancelException>()));
      expect(File(path).existsSync(), isFalse);
    }, skip: skipReason);
  });

  group('binding the outgoing socket', () {
    test('binding to the loopback address still reaches a loopback server',
        () async {
      final response = await make(networkInterface: '127.0.0.1').get('$base/ok');
      expect(response.statusCode, 200);
    }, skip: skipReason);

    test('an interface that does not exist fails rather than falling back',
        () async {
      // Silently ignoring this would be the dangerous outcome: a caller pinning
      // traffic to a VPN would believe it was bound when it was not.
      await expectLater(
        make(networkInterface: 'nitro-http-no-such-if0').get('$base/ok'),
        throwsA(isA<NitroHttpException>()),
      );
    }, skip: skipReason);

    test('a unix socket that does not exist fails rather than using TCP',
        () async {
      // Falling back to TCP would send a request meant for a local daemon out
      // over the network, which is the one outcome a unix socket exists to
      // prevent.
      await expectLater(
        make(
          unixSocketPath: '${scratch.path}/nothing-here.sock',
        ).get('http://daemon.local/status'),
        throwsA(isA<NitroHttpException>()),
      );
    }, skip: Platform.isWindows ? 'no unix sockets on Windows' : skipReason);

    test('a unix socket carries the request and the URL supplies the Host',
        () async {
      final path = '${scratch.path}/engine.sock';
      final unix = await HttpServer.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      addTearDown(() async {
        await unix.close(force: true);
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      });
      unix.listen((request) async {
        request.response
          ..statusCode = 200
          ..write('host=${request.headers.value('host')}');
        await request.response.close();
      });

      // The socket replaces the transport only — the host in the URL is still
      // what the daemon is told it was asked for.
      final response = await make(
        unixSocketPath: path,
      ).get('http://daemon.local/status');

      expect(response.statusCode, 200);
      expect(response.body, 'host=daemon.local');
    }, skip: Platform.isWindows ? 'no unix sockets on Windows' : skipReason);
  });

  group('on-disk caches', () {
    late TlsFixture fixture;
    late HttpServer secure;
    late String cachePath;
    late String altSvcPath;
    final tlsSkip = TlsTestServer.unavailableReason() ?? skipReason;

    setUp(() async {
      if (tlsSkip != null) return;
      fixture = TlsTestServer.generate();
      final ctx = SecurityContext(withTrustedRoots: false)
        ..useCertificateChain('${fixture.dir.path}/server.crt')
        ..usePrivateKey('${fixture.dir.path}/server.key');
      secure = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ctx,
      );
      secure.listen((request) async {
        request.response
          ..statusCode = 200
          ..headers.set('strict-transport-security', 'max-age=31536000')
          ..headers.set('alt-svc', 'h3=":8443"; ma=86400, h2=":8444"; ma=86400')
          ..write('secure');
        await request.response.close();
      });
      cachePath = '${scratch.path}/hsts.txt';
      altSvcPath = '${scratch.path}/altsvc.txt';
    });

    tearDown(() async {
      if (tlsSkip != null) return;
      await secure.close(force: true);
      fixture.dispose();
    });

    NitroHttpClient trusting({bool altSvc = false}) => client = NitroHttpClient(
      settings: ClientSettings(
        timeout: const Duration(seconds: 20),
        hstsCachePath: altSvc ? null : cachePath,
        altSvcCachePath: altSvc ? altSvcPath : null,
        tlsSettings: TlsSettings(
          rootCaSource: RootCaSource.custom,
          trustedRootsPem: fixture.caPem,
        ),
      ),
    );

    /// Waits for [path] to appear. Both caches are written when curl cleans the
    /// handle up, which the engine does on its own thread after the response has
    /// already been delivered.
    Future<bool> appears(String path) async {
      final file = File(path);
      for (var i = 0; i < 50 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      return file.existsSync();
    }

    test('a host that sent the header is remembered in the cache file',
        () async {
      final c = trusting();
      final first = await c.get('https://localhost:${secure.port}/');
      expect(first.statusCode, 200);
      c.dispose();

      expect(
        await appears(cachePath),
        isTrue,
        reason: 'no HSTS cache was written',
      );
      expect(File(cachePath).readAsStringSync(), contains('localhost'));
    }, skip: tlsSkip);

    test('a plaintext URL for a known host is upgraded, not sent in the clear',
        () async {
      // The whole reason HSTS exists. Without the upgrade this request goes to
      // a TLS port speaking HTTP and fails; succeeding is the proof.
      await trusting().get('https://localhost:${secure.port}/');
      client!.dispose();

      final response = await trusting().get('http://localhost:${secure.port}/');
      expect(response.statusCode, 200);
      expect(response.finalUrl.scheme, 'https');
    }, skip: tlsSkip);

    test('a cache file written by a previous launch is honoured on the first '
        'request', () async {
      // The save half is tested above; this is the load half, and the only one
      // that matters on the request that actually leaks. Seeded by hand so no
      // in-memory state from an earlier client can account for the upgrade.
      File(cachePath).writeAsStringSync(
        '# Your HSTS cache. https://curl.se/docs/hsts.html\n'
        'localhost "20370101 00:00:00"\n',
      );

      final response = await trusting().get(
        'http://localhost:${secure.port}/',
      );

      expect(response.statusCode, 200);
      expect(response.finalUrl.scheme, 'https',
          reason: 'the seeded cache was not read');
    }, skip: tlsSkip);

    test('an Alt-Svc advertisement is written to its cache file', () async {
      // Regression test for a bug this file found: pooled easy handles were
      // recycled with `curl_easy_reset`, which drops what the handle learned
      // without saving it. curl only writes either cache from
      // `curl_easy_cleanup`, so the Alt-Svc file was never written at all and
      // HTTP/3 discovery could not survive a launch.
      final c = trusting(altSvc: true);
      expect((await c.get('https://localhost:${secure.port}/')).statusCode, 200);
      c.dispose();

      expect(
        await appears(altSvcPath),
        isTrue,
        reason: 'no Alt-Svc cache was written',
      );
      expect(File(altSvcPath).readAsStringSync(), contains('localhost'));
    }, skip: tlsSkip);
  });
}

Future<void> _handle(io.HttpRequest request) async {
  final response = request.response;
  final segments = request.uri.pathSegments;

  Future<void> writeFilled(int count) async {
    response.headers.contentType = ContentType.binary;
    response.contentLength = count;
    response.add(List<int>.filled(count, 0x41));
  }

  switch (segments) {
    case ['size', final n]:
      await writeFilled(int.parse(n));
    case ['chunked', final n]:
      // No Content-Length, so only a running count can enforce a ceiling.
      response.headers.contentType = ContentType.binary;
      response.headers.chunkedTransferEncoding = true;
      final total = int.parse(n);
      for (var sent = 0; sent < total; sent += 512) {
        final size = sent + 512 > total ? total - sent : 512;
        response.add(List<int>.filled(size, 0x41));
        await response.flush();
      }
    case ['gzip', final n]:
      response.headers
        ..contentType = ContentType.binary
        ..set('content-encoding', 'gzip');
      response.add(gzip.encode(List<int>.filled(int.parse(n), 0x41)));
    case ['slow', final n]:
      response.headers.chunkedTransferEncoding = true;
      final total = int.parse(n);
      for (var sent = 0; sent < total; sent += 4096) {
        response.add(List<int>.filled(4096, 0x41));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    case ['status', final code]:
      final status = int.parse(code);
      response.statusCode = status;
      // 204 must not carry one, and `dart:io` refuses to send a body with it.
      if (status != 204) response.write('not found');
    case ['redirect-to', ...final rest]:
      response
        ..statusCode = 302
        ..headers.set('location', '/${rest.join('/')}');
    case ['fat-redirect-to', ...final rest]:
      // A 302 that carries a real body. Most servers send an empty one, which
      // is why the engine's handling of a non-empty hop is easy to get wrong
      // and never notice.
      response
        ..statusCode = 302
        ..headers.set('location', '/${rest.join('/')}')
        ..add(List<int>.filled(4096, 0x5A));
    default:
      response
        ..statusCode = 200
        ..write('ok');
  }
  await response.close();
}
