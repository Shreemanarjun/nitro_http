// Does the engine honour the proxy, DNS and protocol settings — or only accept
// them?
//
// The same audit that produced tls_settings_e2e_test.dart found these covered
// exclusively by configuration tests. That is the pattern which let
// `RootCaSource.platform` ship broken and `sniHostname` ship inert: the value
// reaches the wire, and nothing checks that anything acts on it.
//
// Proxy and DNS are testable hermetically, because "did the request go
// somewhere else" is observable from a local server. Protocol negotiation is
// not: no local server here speaks HTTP/2 or HTTP/3, so those tests use the
// network and skip when it is absent.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/request_runner.dart'
    show NativeRequestExecutor;

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

/// Answers every request with a marker instead of forwarding.
///
/// A real forwarding proxy would prove less: if the marker comes back, the
/// request demonstrably went through the proxy rather than to the origin, and
/// the origin's own hit count confirms it never arrived there.
class _MarkerProxy {
  _MarkerProxy(this._server);
  final HttpServer _server;
  int hits = 0;
  final absoluteUris = <String>[];

  int get port => _server.port;

  static Future<_MarkerProxy> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _MarkerProxy(s);
    s.listen((request) async {
      proxy.hits++;
      // A proxied request carries the ABSOLUTE url in the request line, which
      // is the wire-level proof that curl treated this as a proxy hop.
      proxy.absoluteUris.add(request.uri.toString());
      request.response
        ..statusCode = 200
        ..write('via-proxy');
      await request.response.close();
    });
    return proxy;
  }

  Future<void> stop() => _server.close(force: true);
}

/// The origin. Counts hits so a proxy test can prove it was bypassed.
class _Origin {
  _Origin(this._server);
  final HttpServer _server;
  int hits = 0;

  int get port => _server.port;

  static Future<_Origin> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _Origin(s);
    s.listen((request) async {
      origin.hits++;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'host': request.headers.value('host'),
          'path': request.uri.path,
        }));
      await request.response.close();
    });
    return origin;
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null
      ? 'native library not built — run: cmake -S src -B build/lib && '
            'cmake --build build/lib'
      : null;

  final netSkip = skipReason ??
      (Platform.environment['NITRO_HTTP_NO_NETWORK_TESTS'] == '1'
          ? 'NITRO_HTTP_NO_NETWORK_TESTS=1'
          : null);

  /// Skips instead of failing when the machine has no network. A connection
  /// failure is an excuse; anything else is the defect under test.
  Future<void> skipIfOffline(Future<void> Function() body) async {
    try {
      await body();
    } on NitroHttpConnectionException catch (e) {
      markTestSkipped('no network: ${e.message}');
    }
  }

  setUpAll(() {
    if (libraryPath != null) DynamicLibrary.open(libraryPath);
  });

  // ── Proxy ──────────────────────────────────────────────────────────────────
  group('proxy settings', () {
    late _MarkerProxy proxy;
    late _Origin origin;
    NitroHttpClient? client;

    setUp(() async {
      proxy = await _MarkerProxy.start();
      origin = await _Origin.start();
    });
    tearDown(() async {
      client?.dispose();
      client = null;
      await proxy.stop();
      await origin.stop();
    });

    test('a manual HTTP proxy actually carries the request', () async {
      client = NitroHttpClient(
        settings: ClientSettings(
          timeout: const Duration(seconds: 15),
          proxySettings: ProxySettings.http('127.0.0.1:${proxy.port}'),
        ),
      );
      final res = await client!.get('http://127.0.0.1:${origin.port}/direct');

      expect(res.body, 'via-proxy');
      expect(proxy.hits, 1, reason: 'the proxy must have seen the request');
      expect(origin.hits, 0, reason: 'the origin must have been bypassed');
      expect(proxy.absoluteUris.single, contains('${origin.port}/direct'),
          reason: 'a proxied request carries an absolute URI');
    }, skip: skipReason);

    test('ProxySettings.noProxy() goes direct', () async {
      // The control. Without it, a proxy test can pass because the URL happened
      // to reach the marker server by some other route.
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 15),
          proxySettings: ProxySettings.noProxy(),
        ),
      );
      final res = await client!.get('http://127.0.0.1:${origin.port}/direct');

      expect(res.statusCode, 200);
      expect(origin.hits, 1);
      expect(proxy.hits, 0);
    }, skip: skipReason);

    test('noProxyHosts exempts a host from the proxy', () async {
      client = NitroHttpClient(
        settings: ClientSettings(
          timeout: const Duration(seconds: 15),
          proxySettings: ProxySettings.http(
            '127.0.0.1:${proxy.port}',
            noProxy: '127.0.0.1',
          ),
        ),
      );
      final res = await client!.get('http://127.0.0.1:${origin.port}/exempt');

      expect(origin.hits, 1, reason: 'the exemption must bypass the proxy');
      expect(proxy.hits, 0);
      expect(res.statusCode, 200);
    }, skip: skipReason);
  });

  // ── DNS ────────────────────────────────────────────────────────────────────
  group('DNS settings', () {
    late _Origin origin;
    NitroHttpClient? client;

    setUp(() async => origin = await _Origin.start());
    tearDown(() async {
      client?.dispose();
      client = null;
      await origin.stop();
    });

    test('a static override resolves a name the resolver cannot', () async {
      // `.invalid` is reserved by RFC 2606 and can never resolve, so reaching
      // the origin at all proves CURLOPT_RESOLVE was applied.
      client = NitroHttpClient(
        settings: ClientSettings(
          timeout: const Duration(seconds: 15),
          dnsSettings: DnsSettings.static(
            {'nitro-http.invalid': const ['127.0.0.1']},
            port: origin.port,
          ),
        ),
      );
      final res =
          await client!.get('http://nitro-http.invalid:${origin.port}/dns');

      expect(res.statusCode, 200);
      expect(origin.hits, 1);
      // The Host header must still be the NAME, not the address: an override
      // that rewrote the URL would break virtual hosting and TLS SNI.
      expect(res.body, contains('nitro-http.invalid'));
    }, skip: skipReason);

    test('without the override the same name fails to resolve', () async {
      // The control that makes the test above meaningful.
      client = NitroHttpClient(
        settings: const ClientSettings(timeout: Duration(seconds: 15)),
      );
      await expectLater(
        client!.get('http://nitro-http.invalid:${origin.port}/dns'),
        throwsA(isA<NitroHttpException>()),
      );
      expect(origin.hits, 0);
    }, skip: skipReason);

    test('DNS-over-HTTPS resolves a public name', () async {
      await skipIfOffline(() async {
        client = NitroHttpClient(
          settings: const ClientSettings(
            timeout: Duration(seconds: 25),
            dnsSettings: DnsSettings.doh('https://cloudflare-dns.com/dns-query'),
          ),
        );
        final res = await client!.get('https://example.com/');
        expect(res.statusCode, 200);
      });
    }, skip: netSkip);
  });

  // ── Protocol negotiation ───────────────────────────────────────────────────
  group('protocol negotiation', () {
    NitroHttpClient? client;
    tearDown(() {
      client?.dispose();
      client = null;
    });

    test('negotiates HTTP/2 by default against an h2 host', () async {
      await skipIfOffline(() async {
        client = NitroHttpClient(
          settings: const ClientSettings(timeout: Duration(seconds: 25)),
        );
        final res = await client!.get('https://cloudflare-quic.com/');
        expect(res.version, isNot(HttpVersion.http11),
            reason: 'ALPN should have upgraded this connection');
      });
    }, skip: netSkip);

    test('http11Only pins the connection to HTTP/1.1', () async {
      await skipIfOffline(() async {
        client = NitroHttpClient(
          settings: const ClientSettings(
            timeout: Duration(seconds: 25),
            httpVersionPref: HttpVersionPref.http11Only,
          ),
        );
        final res = await client!.get('https://cloudflare-quic.com/');
        expect(res.version, HttpVersion.http11,
            reason: 'the preference must override ALPN');
      });
    }, skip: netSkip);

    test('HTTP/3 is negotiated when the engine and host support it', () async {
      if (!NitroHttp.supportsHttp3) {
        markTestSkipped('this build has no QUIC backend');
        return;
      }
      await skipIfOffline(() async {
        client = NitroHttpClient(
          settings: const ClientSettings(
            timeout: Duration(seconds: 30),
            httpVersionPref: HttpVersionPref.http3,
          ),
        );
        final res = await client!.get('https://cloudflare-quic.com/');
        expect(res.statusCode, 200);
        expect(res.version, HttpVersion.http3,
            reason: 'cloudflare-quic.com advertises h3');
      });
    }, skip: netSkip);
  });

  // ── The coalescer fallback ─────────────────────────────────────────────────
  group('completion coalescing', () {
    late _Origin origin;
    NitroHttpClient? client;

    setUp(() async => origin = await _Origin.start());
    tearDown(() async {
      client?.dispose();
      client = null;
      NativeRequestExecutor.coalesceCompletions = true;
      await origin.stop();
    });

    test('requests still complete with coalescing OFF', () async {
      // The fallback path for a feature that is on by default, so nothing
      // exercised it. If the non-coalesced branch ever rots, every consumer who
      // turns the optimisation off gets a client that never completes — and no
      // test would have noticed.
      NativeRequestExecutor.coalesceCompletions = false;
      client = NitroHttpClient(
        settings: const ClientSettings(timeout: Duration(seconds: 15)),
      );
      final results = await Future.wait([
        for (var i = 0; i < 8; i++)
          client!.get('http://127.0.0.1:${origin.port}/n$i'),
      ]);
      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(origin.hits, 8);
    }, skip: skipReason);

    test('and with coalescing ON, for comparison', () async {
      NativeRequestExecutor.coalesceCompletions = true;
      client = NitroHttpClient(
        settings: const ClientSettings(timeout: Duration(seconds: 15)),
      );
      final results = await Future.wait([
        for (var i = 0; i < 8; i++)
          client!.get('http://127.0.0.1:${origin.port}/n$i'),
      ]);
      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(origin.hits, 8);
    }, skip: skipReason);
  });
}
