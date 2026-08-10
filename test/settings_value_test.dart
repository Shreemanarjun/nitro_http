// Value semantics for the settings tree: named constructors, `==`, `hashCode`
// and `toString` on every variant.
//
// `settings_test.dart` covers behaviour — what each setting does to a request.
// This covers the value types themselves, which matter because settings are
// compared (a client rebuilds its native config when they change) and printed
// (they land in logs and error messages).

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  group('TlsSettings', () {
    test('the insecure constructor disables verification', () {
      const settings = TlsSettings.insecure();

      expect(settings.verifyCertificates, isFalse);
    });

    test('toString reports verification, roots, pin count and mTLS', () {
      const settings = TlsSettings(
        rootCaSource: RootCaSource.bundled,
        pinnedSpkiSha256: ['a', 'b'],
        clientCertificate: ClientCertificate(
          certificatePem: 'cert',
          privateKeyPem: 'key',
        ),
      );

      expect(
        settings.toString(),
        'TlsSettings(verify: true, roots: bundled, pins: 2, mTLS: true)',
      );
    });

    test('toString says mTLS false without a client certificate', () {
      expect(const TlsSettings().toString(), contains('mTLS: false'));
      expect(const TlsSettings().toString(), contains('pins: 0'));
    });
  });

  group('ProxySettings', () {
    test('system compares equal to any other system variant', () {
      expect(const SystemProxySettings(), const ProxySettings.system());
      expect(
        const SystemProxySettings().hashCode,
        const SystemProxySettings().hashCode,
      );
      expect(const SystemProxySettings(), isNot(const NoProxySettings()));
      expect(const SystemProxySettings(), isNot(Object()));
    });

    test('noProxy compares equal to any other noProxy variant', () {
      expect(const NoProxySettings(), const ProxySettings.noProxy());
      expect(
        const NoProxySettings().hashCode,
        const NoProxySettings().hashCode,
      );
      expect(const NoProxySettings(), isNot(const SystemProxySettings()));
      expect(const NoProxySettings(), isNot(Object()));
    });

    test('the variants render their factory call', () {
      expect(const SystemProxySettings().toString(), 'ProxySettings.system()');
      expect(const NoProxySettings().toString(), 'ProxySettings.noProxy()');
    });

    test('socks5Hostname resolves the host at the proxy', () {
      const proxy = ManualProxySettings.socks5Hostname(
        'proxy.test:1080',
        username: 'u',
        password: 'p',
        noProxy: 'localhost',
      );

      expect(proxy.mode, ProxyKind.socks5Hostname);
      expect(proxy.url, 'proxy.test:1080');
      expect(proxy.username, 'u');
      expect(proxy.password, 'p');
      expect(proxy.noProxy, 'localhost');
    });

    test('manual proxies compare on every field', () {
      const base = ManualProxySettings(ProxyKind.http, 'p.test:8080');

      expect(base, const ManualProxySettings(ProxyKind.http, 'p.test:8080'));
      expect(
        base.hashCode,
        const ManualProxySettings(ProxyKind.http, 'p.test:8080').hashCode,
      );
      expect(base, isNot(const ManualProxySettings(ProxyKind.socks5, 'p.test:8080')));
      expect(base, isNot(const ManualProxySettings(ProxyKind.http, 'other:8080')));
      expect(
        base,
        isNot(const ManualProxySettings(
          ProxyKind.http,
          'p.test:8080',
          username: 'u',
        )),
      );
      expect(
        base,
        isNot(const ManualProxySettings(
          ProxyKind.http,
          'p.test:8080',
          password: 'p',
        )),
      );
      expect(
        base,
        isNot(const ManualProxySettings(
          ProxyKind.http,
          'p.test:8080',
          noProxy: 'x',
        )),
      );
      expect(base, isNot(const SystemProxySettings()));
    });
  });

  group('DnsSettings', () {
    test('system compares equal to any other system variant', () {
      expect(const SystemDnsSettings(), const DnsSettings.system());
      expect(
        const SystemDnsSettings().hashCode,
        const SystemDnsSettings().hashCode,
      );
      expect(const SystemDnsSettings(), isNot(const DohDnsSettings('https://d')));
      expect(const SystemDnsSettings(), isNot(Object()));
      expect(const SystemDnsSettings().toString(), 'DnsSettings.system()');
    });

    test('static overrides render as curl resolve entries', () {
      const dns = StaticDnsSettings({
        'example.test': ['1.2.3.4'],
      });

      expect(dns.toString(), contains('DnsSettings.static('));
      expect(dns.toString(), contains('example.test'));
      expect(dns.toString(), contains('1.2.3.4'));
    });

    test('doh compares on its url and renders it', () {
      const a = DohDnsSettings('https://dns.test/q');

      expect(a, const DohDnsSettings('https://dns.test/q'));
      expect(a, same(a));
      expect(a, isNot(const DohDnsSettings('https://other.test/q')));
      expect(a, isNot(Object()));
      expect(a.toString(), 'DnsSettings.doh(https://dns.test/q)');
    });
  });

  test('CookieSettings.toString reports storage and persistence', () {
    expect(
      const CookieSettings().toString(),
      'CookieSettings(store: true, persistent: false)',
    );
    expect(
      const CookieSettings(persistPath: '/tmp/jar').toString(),
      'CookieSettings(store: true, persistent: true)',
    );
  });

  group('RedirectSettings', () {
    test('follow compares equal to any other follow variant', () {
      expect(const FollowRedirects(), const RedirectSettings.follow());
      expect(
        const FollowRedirects().hashCode,
        const FollowRedirects().hashCode,
      );
      expect(const FollowRedirects(), isNot(const NoRedirects()));
      expect(const FollowRedirects(), isNot(Object()));
      expect(const FollowRedirects().toString(), 'RedirectSettings.follow()');
    });

    test('limited compares on the hop count', () {
      const five = LimitedRedirects(5);

      expect(five, const LimitedRedirects(5));
      expect(five.hashCode, const LimitedRedirects(5).hashCode);
      expect(five, isNot(const LimitedRedirects(6)));
      expect(five, isNot(const FollowRedirects()));
      expect(five, same(five));
      expect(five.toString(), 'RedirectSettings.limited(5)');
      expect(five.maxRedirects, 5);
    });

    test('none compares equal to any other none variant and allows no hops', () {
      expect(const NoRedirects(), const RedirectSettings.none());
      expect(const NoRedirects().hashCode, const NoRedirects().hashCode);
      expect(const NoRedirects(), isNot(const FollowRedirects()));
      expect(const NoRedirects(), isNot(Object()));
      expect(const NoRedirects().toString(), 'RedirectSettings.none()');
      expect(const NoRedirects().maxRedirects, 0);
    });
  });

  test('PoolSettings.toString reports every limit', () {
    const pool = PoolSettings(
      maxConnections: 10,
      maxConnectionsPerHost: 5,
      idleTimeout: Duration(seconds: 30),
      maxLifetime: Duration(minutes: 5),
      keepAlivePingInterval: Duration(seconds: 15),
    );

    final rendered = pool.toString();

    expect(rendered, contains('max: 10'));
    expect(rendered, contains('perHost: 5'));
    expect(rendered, contains('idle:'));
    expect(rendered, contains('lifetime:'));
    expect(rendered, contains('ping:'));
  });

  test('CacheSettings.toString reports whether it is enabled', () {
    expect(const CacheSettings().toString(), 'CacheSettings(enabled: false)');
    expect(
      const CacheSettings(enabled: true).toString(),
      'CacheSettings(enabled: true)',
    );
  });

  group('ClientSettings', () {
    test('toString names every setting', () {
      const settings = ClientSettings(
        baseUrl: 'http://example.test',
        altSvcCachePath: '/tmp/altsvc',
      );

      final rendered = settings.toString();

      for (final field in [
        'baseUrl: http://example.test',
        'timeout:',
        'connectTimeout:',
        'idleTimeout:',
        'httpVersionPref:',
        'redirects:',
        'throwOnStatusCode:',
        'compression:',
        'tls:',
        'proxy:',
        'dns:',
        'cookies:',
        'pool:',
        'cache:',
        'altSvcCachePath: /tmp/altsvc',
      ]) {
        expect(rendered, contains(field), reason: field);
      }
    });

    test('default headers take part in equality', () {
      final a = ClientSettings(headers: HttpHeaders()..set('x-a', '1'));
      final b = ClientSettings(headers: HttpHeaders()..set('x-a', '1'));
      final c = ClientSettings(headers: HttpHeaders()..set('x-a', '2'));
      final d = ClientSettings(headers: HttpHeaders()..set('x-b', '1'));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c), reason: 'same name, different value');
      expect(a, isNot(d), reason: 'different name');
    });

    test('a header collection differing in size is unequal', () {
      final one = ClientSettings(headers: HttpHeaders()..set('x-a', '1'));
      final two = ClientSettings(
        headers: HttpHeaders()
          ..set('x-a', '1')
          ..set('x-b', '2'),
      );

      expect(one, isNot(two));
    });

    test('headers on one side only is unequal', () {
      final withHeaders = ClientSettings(
        headers: HttpHeaders()..set('x-a', '1'),
      );

      expect(withHeaders, isNot(const ClientSettings()));
      expect(const ClientSettings(), isNot(withHeaders));
    });

    test('the same header instance short-circuits to equal', () {
      final headers = HttpHeaders()..set('x-a', '1');

      expect(
        ClientSettings(headers: headers),
        ClientSettings(headers: headers),
      );
    });

    test('identical settings are equal and hash alike', () {
      const a = ClientSettings(baseUrl: 'http://x');

      expect(a, const ClientSettings(baseUrl: 'http://x'));
      expect(a.hashCode, const ClientSettings(baseUrl: 'http://x').hashCode);
      expect(a, same(a));
      expect(a, isNot(Object()));
    });
  });
}
