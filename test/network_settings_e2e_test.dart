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
  int live = 0;
  int peakConcurrent = 0;

  int get port => _server.port;

  static Future<_Origin> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _Origin(s);
    s.listen((request) async {
      origin.hits++;
      origin.live++;
      if (origin.live > origin.peakConcurrent) {
        origin.peakConcurrent = origin.live;
      }
      final path = request.uri.path;
      final response = request.response;
      if (path.startsWith('/loop/')) {
        // Redirects forever, so only a cap can end it.
        final n = int.parse(path.split('/').last);
        response
          ..statusCode = 302
          ..headers.set('location', '/loop/${n + 1}');
      } else if (path == '/setcookie') {
        response
          ..statusCode = 200
          ..headers.add('set-cookie', 'sid=abc; Path=/')
          ..write('ok');
      } else if (path == '/readcookie') {
        response
          ..statusCode = 200
          ..write(request.headers.value('cookie') ?? '');
      } else if (path == '/stall') {
        // Answers, then goes quiet: the total timeout would not fire in time,
        // so this isolates the idle deadline.
        response..statusCode = 200..headers.contentType = ContentType.binary;
        response.add([1]);
        await response.flush();
        await Future<void>.delayed(const Duration(seconds: 8));
      } else if (path == '/echohdr') {
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(
              {'ae': request.headers.value('accept-encoding') ?? ''}));
      } else if (path.startsWith('/slow')) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        response..statusCode = 200..write('ok');
      } else {
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'host': request.headers.value('host'),
            'path': path,
          }));
      }
      await response.close();
      origin.live--;
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

  // ── Settings that were configuration-tested only ───────────────────────────
  // Each of these could be accepted and then ignored without any existing test
  // noticing — the failure mode that shipped twice already.
  group('settings the engine must honour', () {
    late _Origin origin;
    NitroHttpClient? client;

    setUp(() async => origin = await _Origin.start());
    tearDown(() async {
      client?.dispose();
      client = null;
      await origin.stop();
    });

    test('maxRedirects caps a redirect chain', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          redirectSettings: RedirectSettings.limited(3),
        ),
      );
      // /loop/N redirects forever, so an uncapped client would spin.
      await expectLater(
        client!.get('http://127.0.0.1:${origin.port}/loop/0'),
        throwsA(isA<NitroHttpRedirectException>()),
      );
    }, skip: skipReason);

    test('storeCookies:false does not replay a cookie', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          cookieSettings: CookieSettings(storeCookies: false),
        ),
      );
      await client!.get('http://127.0.0.1:${origin.port}/setcookie');
      final r = await client!.get('http://127.0.0.1:${origin.port}/readcookie');
      expect(r.body, isNot(contains('sid=')));
    }, skip: skipReason);

    test('idleTimeout fires on a body that stalls mid-transfer', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 30),
          idleTimeout: Duration(seconds: 2),
        ),
      );
      // Distinct from the total timeout: the response starts promptly and then
      // goes quiet, so only an idle deadline can catch it.
      await expectLater(
        client!.get('http://127.0.0.1:${origin.port}/stall'),
        throwsA(isA<NitroHttpTimeoutException>()),
      );
    }, skip: skipReason);

    test('enableCompression controls Accept-Encoding', () async {
      for (final on in [true, false]) {
        final c = NitroHttpClient(
          settings: ClientSettings(
            timeout: const Duration(seconds: 20),
            enableCompression: on,
          ),
        );
        try {
          final r = await c.get('http://127.0.0.1:${origin.port}/echohdr');
          final ae = (r.bodyToJson()! as Map)['ae'] as String;
          expect(ae.isNotEmpty, on, reason: 'enableCompression=$on');
        } finally {
          c.dispose();
        }
      }
    }, skip: skipReason);

    test('maxConnectionsPerHost bounds concurrency', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 30),
          poolSettings: PoolSettings(maxConnectionsPerHost: 2),
        ),
      );
      origin.peakConcurrent = 0;
      await Future.wait([
        for (var i = 0; i < 10; i++)
          client!.get('http://127.0.0.1:${origin.port}/slow$i'),
      ]);
      expect(origin.peakConcurrent, lessThanOrEqualTo(2));
    }, skip: skipReason);

    test('a SOCKS5 proxy is routed through, not bypassed', () async {
      // Port 1 accepts nothing. If the setting were ignored the request would
      // reach the origin instead of failing.
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 10),
          proxySettings: ProxySettings.socks5('127.0.0.1:1'),
        ),
      );
      await expectLater(
        client!.get('http://127.0.0.1:${origin.port}/direct'),
        throwsA(isA<NitroHttpException>()),
      );
      expect(origin.hits, 0);
    }, skip: skipReason);
  });

  // ── TLS version clamp ──────────────────────────────────────────────────────
  // Needs a server that speaks ONE version, which dart:io cannot configure, so
  // this is the one clamp assertion that has to leave the loopback.
  group('TLS version clamp', () {
    NitroHttpClient? client;
    tearDown(() {
      client?.dispose();
      client = null;
    });

    test('minVersion tls13 refuses a TLS-1.2-only server', () async {
      await skipIfOffline(() async {
        client = NitroHttpClient(
          settings: const ClientSettings(
            timeout: Duration(seconds: 20),
            tlsSettings: TlsSettings(minVersion: TlsVersion.tls13),
          ),
        );
        await expectLater(
          client!.get('https://tls-v1-2.badssl.com:1012/'),
          throwsA(isA<NitroHttpException>()),
          reason: 'an ignored clamp would connect over TLS 1.2',
        );
      });
    }, skip: netSkip);

    test('the same server is reachable without the clamp', () async {
      // Control: proves the refusal above is the clamp, not an unreachable host.
      await skipIfOffline(() async {
        client = NitroHttpClient(
          settings: const ClientSettings(
            timeout: Duration(seconds: 20),
            throwOnStatusCode: false,
          ),
        );
        expect((await client!.get('https://tls-v1-2.badssl.com:1012/')).statusCode, 200);
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
