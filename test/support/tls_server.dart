// A local HTTPS server with a freshly generated CA, for testing the TLS
// settings the engine is supposed to honour.
//
// WHY THIS EXISTS. Until now every TLS setting was covered only by
// configuration tests: they proved a value reached the engine, never that the
// engine did anything with it. That is exactly how `RootCaSource.platform`
// shipped broken in 0.0.1-0.0.3 — the config test passed while no HTTPS request
// could succeed on Apple at all. `TlsSettings.sniHostname` is a second, still
// unfixed instance, documented in the changelog.
//
// A public host cannot test any of this: it will not demand a client
// certificate, will not restrict itself to TLS 1.2, and its private key is not
// available to derive an expected pin from. So the certificates are generated
// per run, which also means nothing here expires or needs checking in.
//
// Requires `openssl` on PATH. [TlsTestServer.unavailableReason] returns a skip
// reason rather than failing when it is missing.
import 'dart:convert';
import 'dart:io';

/// A generated certificate authority plus the leaf certificates it signs.
class TlsFixture {
  TlsFixture._(this.dir);
  final Directory dir;

  String get caPem => File('${dir.path}/ca.crt').readAsStringSync();
  String get serverCertPem => File('${dir.path}/server.crt').readAsStringSync();
  String get serverKeyPem => File('${dir.path}/server.key').readAsStringSync();
  String get clientCertPem => File('${dir.path}/client.crt').readAsStringSync();
  String get clientKeyPem => File('${dir.path}/client.key').readAsStringSync();

  /// The server leaf's SPKI SHA-256, base64 — the value
  /// `TlsSettings.pinnedSpkiSha256` expects.
  ///
  /// Derived from the certificate rather than hardcoded, so the pin is correct
  /// by construction and a regenerated fixture cannot silently invalidate it.
  late final String serverSpkiSha256 = _spkiOf('${dir.path}/server.crt');

  String _spkiOf(String certPath) {
    final pubPath = '${dir.path}/server.pub';
    final derPath = '${dir.path}/server.spki.der';
    File(pubPath).writeAsStringSync(
        _run('openssl', ['x509', '-in', certPath, '-pubkey', '-noout']));
    _run('openssl', [
      'pkey', '-pubin', '-in', pubPath, '-outform', 'der', '-out', derPath,
    ]);
    // Binary digest, so stdout must not be decoded as text.
    final digest = Process.runSync(
      'openssl',
      ['dgst', '-sha256', '-binary', derPath],
      stdoutEncoding: null,
    );
    return base64Encode(digest.stdout as List<int>);
  }

  void dispose() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

String _run(String exe, List<String> args) {
  final r = Process.runSync(exe, args);
  if (r.exitCode != 0) {
    throw StateError('$exe ${args.join(' ')} failed:\n${r.stderr}');
  }
  return r.stdout as String;
}

/// A local HTTPS server, optionally demanding a client certificate.
class TlsTestServer {
  TlsTestServer._(this._server, this.fixture);

  final HttpServer _server;
  final TlsFixture fixture;

  int get port => _server.port;

  /// `localhost`, not `127.0.0.1`: the certificate's SAN is a DNS name, and
  /// hostname verification is one of the things under test.
  String url(String path) => 'https://localhost:$port$path';

  static String? unavailableReason() {
    try {
      final r = Process.runSync('openssl', ['version']);
      return r.exitCode == 0 ? null : 'openssl not usable';
    } on ProcessException {
      return 'openssl not on PATH — needed to generate TLS test certificates';
    }
  }

  /// Generates a CA, a server leaf for `localhost`, and a client leaf.
  static TlsFixture generate() {
    final dir = Directory.systemTemp.createTempSync('nitro_http_tls');
    final p = dir.path;

    // CA
    _run('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', '$p/ca.key', '-out', '$p/ca.crt', '-days', '2',
      '-subj', '/CN=nitro_http test CA']);

    // Names only, deliberately no `IP:127.0.0.1`. Connecting by address then
    // fails verification unless something supplies a name, which is what makes
    // the `sniHostname` tests discriminate: with the override a request to
    // 127.0.0.1 succeeds, without it the same request is rejected.
    //
    // `sni-only.invalid` resolves nowhere, so validating against it proves the
    // name and the address came from different places.
    File('$p/server.ext').writeAsStringSync(
        'subjectAltName=DNS:localhost,DNS:sni-only.invalid\n');
    _run('openssl', ['req', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', '$p/server.key', '-out', '$p/server.csr',
      '-subj', '/CN=localhost']);
    _run('openssl', ['x509', '-req', '-in', '$p/server.csr',
      '-CA', '$p/ca.crt', '-CAkey', '$p/ca.key', '-CAcreateserial',
      '-out', '$p/server.crt', '-days', '2', '-extfile', '$p/server.ext']);

    // Client leaf for the mTLS test.
    _run('openssl', ['req', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', '$p/client.key', '-out', '$p/client.csr',
      '-subj', '/CN=nitro_http test client']);
    _run('openssl', ['x509', '-req', '-in', '$p/client.csr',
      '-CA', '$p/ca.crt', '-CAkey', '$p/ca.key', '-CAcreateserial',
      '-out', '$p/client.crt', '-days', '2']);

    return TlsFixture._(dir);
  }

  /// Starts the server. [requireClientCertificate] turns on mutual TLS.
  static Future<TlsTestServer> start(
    TlsFixture fixture, {
    bool requireClientCertificate = false,
  }) async {
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain('${fixture.dir.path}/server.crt')
      ..usePrivateKey('${fixture.dir.path}/server.key');
    if (requireClientCertificate) {
      // Both calls are needed: one advertises the acceptable issuer, the other
      // makes the handshake actually verify what the client sends.
      ctx.setClientAuthorities('${fixture.dir.path}/ca.crt');
      ctx.setTrustedCertificates('${fixture.dir.path}/ca.crt');
    }

    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      ctx,
      requestClientCertificate: requireClientCertificate,
    );

    server.listen((request) async {
      // WebSocket upgrade over TLS. Nothing can reach this yet — RawWsConfig
      // carries no TLS block, so NitroWebSocket cannot be told to trust this
      // server's generated CA — but the endpoint exists so the skipped wss test
      // in tls_settings_e2e_test.dart becomes a real test the day it can.
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen(socket.add, onError: (_) {}, onDone: () {});
        return;
      }

      final cert = request.certificate;
      // `bindSecure` can only REQUEST a client certificate, so "required" is
      // enforced here: no certificate means 403. That still distinguishes the
      // two cases the mTLS test cares about — and if the engine ignored
      // `clientCertificate` entirely, this is what would catch it.
      request.response
        ..statusCode = (requireClientCertificate && cert == null) ? 403 : 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'path': request.uri.path,
          'clientCertificate': cert?.subject,
        }));
      await request.response.close();
    });

    return TlsTestServer._(server, fixture);
  }

  Future<void> stop() => _server.close(force: true);
}
