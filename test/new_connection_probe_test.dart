/// What a NEW https connection costs, and how much of it is the trust store.
/// Every request here opens its own connection (the server closes each one), to
/// a loopback server whose certificate chains to a generated CA.
///
///   cmake --build build/lib && flutter test --run-skipped test/new_connection_probe_test.dart
@Tags(['benchmark'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

import 'support/tls_server.dart';

double _p50(List<double> ms) => (ms..sort())[ms.length ~/ 2];

void main() {
  test('new https connections', () async {
    DynamicLibrary.open('build/lib/libnitro_http.dylib');
    final fixture = TlsTestServer.generate();
    addTearDown(fixture.dispose);

    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain('${fixture.dir.path}/server.crt')
      ..usePrivateKey('${fixture.dir.path}/server.key');
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    addTearDown(() => server.close(force: true));
    var close = true;
    server.listen((request) async {
      request.response.persistentConnection = !close;
      request.response.write('ok');
      await request.response.close();
    });
    final url = 'https://localhost:${server.port}/';

    // A real root list (~140 certificates) plus the generated CA.
    final systemBundle = File('/etc/ssl/cert.pem').readAsStringSync();
    final bigRoots = '${fixture.caPem}\n$systemBundle';

    Future<double> run(NitroHttpClient client, {int n = 150}) async {
      addTearDown(client.dispose);
      for (var i = 0; i < 5; i++) {
        await client.get(url);
      }
      final ms = <double>[];
      for (var i = 0; i < n; i++) {
        final sw = Stopwatch()..start();
        final r = await client.get(url);
        ms.add(sw.elapsedMicroseconds / 1000);
        expect(r.statusCode, 200);
      }
      return _p50(ms);
    }

    NitroHttpClient withRoots(String pem) => NitroHttpClient(
      settings: ClientSettings(tlsSettings: TlsSettings(rootCaSource: RootCaSource.custom(pem))),
    );

    final out = StringBuffer()
      ..writeln('roots: ${(bigRoots.length / 1024).toStringAsFixed(0)} KiB, '
          '${'-----BEGIN CERTIFICATE-----'.allMatches(bigRoots).length} certificates');
    for (var round = 0; round < 3; round++) {
      close = true;
      final small = await run(withRoots(fixture.caPem));
      final big = await run(withRoots(bigRoots));
      close = false;
      final reused = await run(withRoots(bigRoots));
      out.writeln('round $round  new conn, 1 root: ${small.toStringAsFixed(2)} ms   '
          'new conn, full list: ${big.toStringAsFixed(2)} ms   '
          'kept alive, full list: ${reused.toStringAsFixed(3)} ms');
    }
    // ignore: avoid_print
    print('NEW_CONNECTION_PROBE\n$out');
  },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: File('build/lib/libnitro_http.dylib').existsSync()
          ? null
          : 'build/lib/libnitro_http.dylib missing');
}
