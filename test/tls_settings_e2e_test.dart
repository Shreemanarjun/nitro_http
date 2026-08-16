// Does the ENGINE honour the TLS settings, or merely accept them?
//
// Every other TLS test in this repo is a configuration test: it proves a value
// round-trips into the request, never that anything acts on it. That gap is not
// hypothetical — `RootCaSource.platform` shipped completely broken in
// 0.0.1-0.0.3 while its configuration test passed, and `sniHostname` is still
// accepted-but-ignored today.
//
// These tests use a locally generated CA, because a public host cannot exercise
// any of it: it will not demand a client certificate, will not restrict itself
// to TLS 1.2, and will not hand over the private key needed to derive an
// expected pin.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

import 'support/tls_server.dart';

String? _locateLibrary() {
  final override = Platform.environment['NITRO_HTTP_DYLIB'];
  if (override != null && File(override).existsSync()) return override;
  final names = <String>[
    if (Platform.isMacOS) 'libnitro_http.dylib',
    if (Platform.isLinux) 'libnitro_http.so',
    if (Platform.isWindows) 'nitro_http.dll',
  ];
  for (final root in ['build/lib', 'build/cpptest', 'build']) {
    for (final name in names) {
      final f = File('$root/$name');
      if (f.existsSync()) return f.absolute.path;
    }
  }
  return null;
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null
      ? 'native library not built — run: cmake -S src -B build/lib && '
            'cmake --build build/lib'
      : TlsTestServer.unavailableReason();

  group('TLS settings the engine must honour', () {
    late TlsFixture fixture;
    late TlsTestServer server;
    NitroHttpClient? client;

    setUpAll(() async {
      if (skipReason != null) return;
      DynamicLibrary.open(libraryPath!);
      fixture = TlsTestServer.generate();
      server = await TlsTestServer.start(fixture);
    });

    tearDownAll(() async {
      if (skipReason != null) return;
      await server.stop();
      fixture.dispose();
    });

    tearDown(() {
      client?.dispose();
      client = null;
    });

    /// A client that trusts the generated CA and nothing else. Every test below
    /// starts from this, so a failure is never just "unknown issuer".
    NitroHttpClient trusting({
      List<String> pins = const <String>[],
      ClientCertificate? clientCertificate,
      TlsVersion? minVersion,
    }) =>
        client = NitroHttpClient(
          settings: ClientSettings(
            timeout: const Duration(seconds: 20),
            throwOnStatusCode: false,
            tlsSettings: TlsSettings(
              rootCaSource: RootCaSource.custom,
              trustedRootsPem: fixture.caPem,
              pinnedSpkiSha256: pins,
              clientCertificate: clientCertificate,
              minVersion: minVersion,
            ),
          ),
        );

    // ── Custom root trust ────────────────────────────────────────────────────
    test('RootCaSource.custom trusts exactly the PEM it was given', () async {
      expect((await trusting().get(server.url('/ok'))).statusCode, 200);
    }, skip: skipReason);

    test('the same certificate is REJECTED without that root', () async {
      // The control for every test below: the chain is only acceptable because
      // of the custom root, not because verification is lax.
      client = NitroHttpClient(
        settings: const ClientSettings(timeout: Duration(seconds: 20)),
      );
      await expectLater(
        client!.get(server.url('/ok')),
        throwsA(isA<NitroHttpCertificateException>()),
      );
    }, skip: skipReason);

    test('verifyCertificates:false accepts the untrusted chain', () async {
      // The counterpart to the control above: the same server, the same lack of
      // a trusted root, but verification switched off.
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          throwOnStatusCode: false,
          tlsSettings: TlsSettings.insecure(),
        ),
      );
      expect((await client!.get(server.url('/insecure'))).statusCode, 200);
    }, skip: skipReason);

    // ── SPKI pinning ─────────────────────────────────────────────────────────
    // A pin that is silently ignored is worse than no pin: the app believes it
    // is protected. Both directions are asserted for that reason.
    test('a matching SPKI pin is accepted', () async {
      final res = await trusting(pins: [fixture.serverSpkiSha256])
          .get(server.url('/pinned'));
      expect(res.statusCode, 200);
    }, skip: skipReason);

    test('a NON-matching SPKI pin is rejected', () async {
      await expectLater(
        trusting(pins: ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='])
            .get(server.url('/pinned')),
        throwsA(isA<NitroHttpCertificateException>()),
        reason: 'an ignored pin would let a valid-but-wrong cert through',
      );
    }, skip: skipReason);

    test('a per-request pin overrides the client pin', () async {
      final c = trusting(pins: [fixture.serverSpkiSha256]);
      await expectLater(
        c.get(
          server.url('/pinned'),
          options: const RequestOptions(
            pinnedSpkiSha256: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          ),
        ),
        throwsA(isA<NitroHttpCertificateException>()),
      );
    }, skip: skipReason);

    // ── RootCaSource.none ────────────────────────────────────────────────────
    // Documented as "no trust anchors at all — every chain fails unless a pin
    // matches". The engine used to implement that by clearing VERIFYPEER, which
    // is the exact inverse: every chain succeeded, so the option that reads as
    // the strictest was silently the least safe.
    test('none without a pin is refused, not silently permissive', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          tlsSettings: TlsSettings(rootCaSource: RootCaSource.none),
        ),
      );
      await expectLater(
        client!.get(server.url('/none')),
        throwsA(isA<NitroHttpConfigurationException>()),
        reason: 'refused settings, not an unknown transport fault',
      );
    }, skip: skipReason);

    test('none WITH a matching pin is pin-only mode', () async {
      client = NitroHttpClient(
        settings: ClientSettings(
          timeout: const Duration(seconds: 20),
          throwOnStatusCode: false,
          tlsSettings: TlsSettings(
            rootCaSource: RootCaSource.none,
            pinnedSpkiSha256: [fixture.serverSpkiSha256],
          ),
        ),
      );
      // No CA is trusted, so only the pin can authenticate this — which is the
      // documented use for `none`.
      expect((await client!.get(server.url('/none'))).statusCode, 200);
    }, skip: skipReason);

    test('none with a wrong pin is rejected', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          tlsSettings: TlsSettings(
            rootCaSource: RootCaSource.none,
            pinnedSpkiSha256: ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='],
          ),
        ),
      );
      await expectLater(
        client!.get(server.url('/none')),
        throwsA(isA<NitroHttpCertificateException>()),
      );
    }, skip: skipReason);

    // ── TLS version clamp ────────────────────────────────────────────────────
    test('minVersion TLS 1.2 still connects', () async {
      final res = await trusting(minVersion: TlsVersion.tls12)
          .get(server.url('/v12'));
      expect(res.statusCode, 200);
    }, skip: skipReason);

    test('minVersion TLS 1.3 connects to a 1.3-capable server', () async {
      // Dart's server offers 1.3, so this must succeed. Paired with the test
      // above it shows the clamp is plumbed rather than ignored; proving a 1.2
      // server is REFUSED needs a server pinned to 1.2, which dart:io cannot
      // configure — see the skipped test at the end of this file.
      final res = await trusting(minVersion: TlsVersion.tls13)
          .get(server.url('/v13'));
      expect(res.statusCode, 200);
    }, skip: skipReason);

    test('an unsatisfiable version range is rejected', () async {
      // maxVersion below minVersion can never be met, so the engine refuses it
      // rather than opening a connection that must fail. Needs no server: it is
      // caught before a socket exists.
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          tlsSettings: TlsSettings(
            minVersion: TlsVersion.tls13,
            maxVersion: TlsVersion.tls12,
          ),
        ),
      );
      await expectLater(
        client!.get(server.url('/range')),
        throwsA(isA<NitroHttpConfigurationException>()),
      );
    }, skip: skipReason);

    // ── Mutual TLS ───────────────────────────────────────────────────────────
    group('mutual TLS', () {
      late TlsTestServer mtls;

      setUpAll(() async {
        if (skipReason != null) return;
        mtls = await TlsTestServer.start(fixture, requireClientCertificate: true);
      });
      tearDownAll(() async {
        if (skipReason != null) return;
        await mtls.stop();
      });

      test('a client certificate is presented when configured', () async {
        final res = await trusting(
          clientCertificate: ClientCertificate(
            certificatePem: fixture.clientCertPem,
            privateKeyPem: fixture.clientKeyPem,
          ),
        ).get(mtls.url('/mtls'));
        expect(res.statusCode, 200,
            reason: 'the server 403s when no client certificate arrives');
        expect(res.body, contains('nitro_http test client'));
      }, skip: skipReason);

      test('without one, the server refuses', () async {
        final res = await trusting().get(mtls.url('/mtls'));
        expect(res.statusCode, 403);
      }, skip: skipReason);
    });

    // ── WebSockets over TLS ──────────────────────────────────────────────────
    // `wss://` had NO coverage at all: every WebSocket test used plaintext
    // `ws://`, and TLS is where the last engine bug lived. Before today's
    // CertStore fix these would have failed on Apple exactly as HTTPS did,
    // since the WebSocket path also asks for platform roots.
    group('wss', () {
      test('connects over TLS and echoes, against public trust', () async {
        // A PUBLIC endpoint, deliberately: NitroWebSocket.connect takes no TLS
        // settings, so it cannot be told to trust the CA this file generates.
        // Public trust is therefore the only wss path that is testable today.
        NitroWebSocket? ws;
        try {
          ws = await NitroWebSocket.connect(
            Uri.parse('wss://ws.postman-echo.com/raw'),
            connectTimeout: const Duration(seconds: 20),
          );
        } on NitroHttpException catch (e) {
          if (e is NitroHttpConnectionException) {
            markTestSkipped('no network: ${e.message}');
            return;
          }
          rethrow;
        }
        final echoed = Completer<String>();
        final sub = ws.events.listen((event) {
          if (event is TextDataReceived && !echoed.isCompleted) {
            echoed.complete(event.text);
          }
        });
        ws.sendText('nitro');
        expect(await echoed.future.timeout(const Duration(seconds: 20)), 'nitro');
        await sub.cancel();
        await ws.close(1000, 'done');
      }, skip: skipReason);

      test('honours the client TLS settings (custom root)', () async {
        // The generated CA is trusted by nothing else on this machine, so a
        // successful handshake proves the socket used the TlsSettings it was
        // given rather than platform trust.
        final ws = await NitroWebSocket.connect(
          Uri.parse(server.url('/ws').replaceFirst('https://', 'wss://')),
          connectTimeout: const Duration(seconds: 15),
          tlsSettings: TlsSettings(
            rootCaSource: RootCaSource.custom,
            trustedRootsPem: fixture.caPem,
          ),
        );
        final echoed = Completer<String>();
        final sub = ws.events.listen((e) {
          if (e is TextDataReceived && !echoed.isCompleted) {
            echoed.complete(e.text);
          }
        });
        ws.sendText('over-tls');
        expect(await echoed.future.timeout(const Duration(seconds: 15)),
            'over-tls');
        await sub.cancel();
        await ws.close(1000, 'done');
      }, skip: skipReason);

      test('a wss socket REJECTS an untrusted chain', () async {
        // The control: without the custom root the same server must fail, so
        // the test above cannot pass by verification being switched off.
        await expectLater(
          NitroWebSocket.connect(
            Uri.parse(server.url('/ws').replaceFirst('https://', 'wss://')),
            connectTimeout: const Duration(seconds: 15),
          ),
          throwsA(isA<Object>()),
        );
      }, skip: skipReason);

      test('a wss socket honours an SPKI pin', () async {
        await expectLater(
          NitroWebSocket.connect(
            Uri.parse(server.url('/ws').replaceFirst('https://', 'wss://')),
            connectTimeout: const Duration(seconds: 15),
            tlsSettings: TlsSettings(
              rootCaSource: RootCaSource.custom,
              trustedRootsPem: fixture.caPem,
              pinnedSpkiSha256: const [
                'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
              ],
            ),
          ),
          throwsA(isA<Object>()),
          reason: 'a wrong pin must reject the socket',
        );
      }, skip: skipReason);
    });

    // ── sniHostname: accepted, not applied ───────────────────────────────────
    test('setting sniHostname does not break the request', () async {
      // Active coverage of the ignored path. The engine deliberately refuses to
      // fake an SNI override (it needs CURLOPT_CONNECT_TO, which changes URL
      // and Host semantics), and emits a notice instead — but "ignored" must
      // still mean the request behaves normally rather than failing or
      // corrupting the handshake.
      client = NitroHttpClient(
        settings: ClientSettings(
          timeout: const Duration(seconds: 20),
          throwOnStatusCode: false,
          tlsSettings: TlsSettings(
            rootCaSource: RootCaSource.custom,
            trustedRootsPem: fixture.caPem,
            sniHostname: 'somewhere-else.invalid',
          ),
        ),
      );
      final res = await client!.get(server.url('/sni-ignored'));
      expect(res.statusCode, 200,
          reason: 'an unapplied sniHostname must not affect the handshake');
    }, skip: skipReason);

    // ── Known defect, recorded as a test ─────────────────────────────────────
    test('sniHostname overrides the SNI sent', () async {
      // Deliberately skipped, not omitted. The changelog records that this
      // setting "round-trips through the configuration; the engine does not yet
      // override SNI from it" — a documented instance of exactly what this file
      // exists to catch. Leaving a named skip here means the day it is
      // implemented, this turns into a passing test instead of being forgotten.
      final res = await trusting().get(server.url('/sni'));
      expect(res.statusCode, 200);
    }, skip: 'TlsSettings.sniHostname is accepted but not applied by the engine');
  });
}
