import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  group('ClientSettings.resolve', () {
    const based = ClientSettings(baseUrl: 'https://api.example.com/v1');

    test('an absolute URL ignores the base entirely', () {
      expect(
        based.resolve('https://other.test/x').toString(),
        'https://other.test/x',
      );
      expect(
        based.resolve('//cdn.test/x').toString(),
        '//cdn.test/x',
      );
    });

    test('joins with exactly one slash regardless of either side', () {
      const withSlash = ClientSettings(baseUrl: 'https://api.example.com/v1/');

      expect(based.resolve('users').toString(), 'https://api.example.com/v1/users');
      expect(based.resolve('/users').toString(), 'https://api.example.com/v1/users');
      expect(
        withSlash.resolve('users').toString(),
        'https://api.example.com/v1/users',
      );
      expect(
        withSlash.resolve('/users').toString(),
        'https://api.example.com/v1/users',
      );
    });

    test('a leading slash does not discard the base path, unlike Uri.resolve', () {
      expect(
        Uri.parse('https://api.example.com/v1').resolve('/users').toString(),
        'https://api.example.com/users',
      );
      expect(based.resolve('/users').toString(), 'https://api.example.com/v1/users');
    });

    test('an empty path yields the base without a trailing slash', () {
      expect(based.resolve('').toString(), 'https://api.example.com/v1');
      expect(based.resolve('/').toString(), 'https://api.example.com/v1');
    });

    test('without a base the path is returned as-is', () {
      expect(const ClientSettings().resolve('/users').toString(), '/users');
      expect(
        const ClientSettings(baseUrl: '').resolve('users').toString(),
        'users',
      );
    });

    test('a List value becomes repeated query keys', () {
      final uri = based.resolve(
        '/search',
        query: <String, dynamic>{
          'tag': <String>['a', 'b'],
          'page': 2,
        },
      );

      expect(uri.queryParametersAll['tag'], <String>['a', 'b']);
      expect(uri.queryParametersAll['page'], <String>['2']);
    });

    test('query merges over a query already present in the path', () {
      final uri = based.resolve(
        '/search?a=1&b=2',
        query: <String, dynamic>{'b': '9'},
      );

      expect(uri.queryParametersAll, <String, List<String>>{
        'a': <String>['1'],
        'b': <String>['9'],
      });
    });

    test('a null value drops the key, as does an empty Iterable', () {
      final uri = based.resolve(
        '/search?a=1&b=2',
        query: <String, dynamic>{'a': null, 'b': <String>[]},
      );

      expect(uri.hasQuery, isFalse);
      expect(uri.toString(), 'https://api.example.com/v1/search');
    });

    test('nulls inside an Iterable are skipped, not stringified', () {
      final uri = based.resolve(
        '/s',
        query: <String, dynamic>{
          'k': <String?>['a', null, 'b'],
        },
      );

      expect(uri.queryParametersAll['k'], <String>['a', 'b']);
    });

    test('an empty query map leaves the URL untouched', () {
      expect(
        based.resolve('/users', query: const <String, dynamic>{}).toString(),
        'https://api.example.com/v1/users',
      );
    });
  });

  group('copyWith round trips', () {
    test('ClientSettings', () {
      final headers = HttpHeaders()..add('X-A', '1');
      const original = ClientSettings();
      final copy = original.copyWith(
        baseUrl: 'https://a.test',
        timeout: const Duration(seconds: 5),
        connectTimeout: const Duration(seconds: 2),
        idleTimeout: const Duration(seconds: 3),
        httpVersionPref: HttpVersionPref.http3Only,
        headers: headers,
        userAgent: 'ua/1',
        redirectSettings: const RedirectSettings.none(),
        throwOnStatusCode: false,
        enableCompression: false,
        tlsSettings: const TlsSettings.insecure(),
        proxySettings: const ProxySettings.noProxy(),
        dnsSettings: const DnsSettings.doh('https://doh.test/q'),
        cookieSettings: const CookieSettings(storeCookies: false),
        poolSettings: const PoolSettings(maxConnections: 7),
        cacheSettings: const CacheSettings(enabled: true),
        altSvcCachePath: '/tmp/altsvc',
      );

      expect(copy.baseUrl, 'https://a.test');
      expect(copy.timeout, const Duration(seconds: 5));
      expect(copy.connectTimeout, const Duration(seconds: 2));
      expect(copy.idleTimeout, const Duration(seconds: 3));
      expect(copy.httpVersionPref, HttpVersionPref.http3Only);
      expect(copy.headers, same(headers));
      expect(copy.userAgent, 'ua/1');
      expect(copy.redirectSettings, const RedirectSettings.none());
      expect(copy.throwOnStatusCode, isFalse);
      expect(copy.enableCompression, isFalse);
      expect(copy.tlsSettings, const TlsSettings.insecure());
      expect(copy.proxySettings, const ProxySettings.noProxy());
      expect(copy.dnsSettings, const DnsSettings.doh('https://doh.test/q'));
      expect(copy.cookieSettings, const CookieSettings(storeCookies: false));
      expect(copy.poolSettings, const PoolSettings(maxConnections: 7));
      expect(copy.cacheSettings, const CacheSettings(enabled: true));
      expect(copy.altSvcCachePath, '/tmp/altsvc');

      expect(copy.copyWith(), copy);
      expect(copy, isNot(original));
      expect(copy.copyWith().hashCode, copy.hashCode);
    });

    test('TlsSettings', () {
      const cert = ClientCertificate(
        certificatePem: 'CERT',
        privateKeyPem: 'KEY',
        password: 'pw',
      );
      const original = TlsSettings();
      final copy = original.copyWith(
        verifyCertificates: false,
        rootCaSource: RootCaSource.bundled,
        trustedRootsPem: 'ROOTS',
        clientCertificate: cert,
        pinnedSpkiSha256: const <String>['pin'],
        minVersion: TlsVersion.tls12,
        maxVersion: TlsVersion.tls13,
        sniHostname: 'sni.test',
      );

      expect(copy.verifyCertificates, isFalse);
      expect(copy.rootCaSource, RootCaSource.bundled);
      expect(copy.trustedRootsPem, 'ROOTS');
      expect(copy.clientCertificate, cert);
      expect(copy.pinnedSpkiSha256, <String>['pin']);
      expect(copy.minVersion, TlsVersion.tls12);
      expect(copy.maxVersion, TlsVersion.tls13);
      expect(copy.sniHostname, 'sni.test');
      expect(copy.copyWith(), copy);
      expect(copy.copyWith().hashCode, copy.hashCode);
    });

    test('ClientCertificate', () {
      const original = ClientCertificate(
        certificatePem: 'C',
        privateKeyPem: 'K',
      );
      final copy = original.copyWith(
        certificatePem: 'C2',
        privateKeyPem: 'K2',
        password: 'p',
      );

      expect(copy.certificatePem, 'C2');
      expect(copy.privateKeyPem, 'K2');
      expect(copy.password, 'p');
      expect(copy.copyWith(), copy);
      expect(copy.toString(), 'ClientCertificate(<redacted>)');
    });

    test('ManualProxySettings', () {
      const original = ManualProxySettings.http('proxy:8080');
      final copy = original.copyWith(
        mode: ProxyKind.socks5,
        url: 'socks:1080',
        username: 'u',
        password: 'p',
        noProxy: 'localhost',
      );

      expect(copy.mode, ProxyKind.socks5);
      expect(copy.url, 'socks:1080');
      expect(copy.username, 'u');
      expect(copy.password, 'p');
      expect(copy.noProxy, 'localhost');
      expect(copy.copyWith(), copy);
      expect(copy.toString(), isNot(contains('p')));
    });

    test('StaticDnsSettings', () {
      const original = StaticDnsSettings(<String, List<String>>{
        'a.test': <String>['1.2.3.4'],
      });
      final copy = original.copyWith(
        overrides: const <String, List<String>>{
          'b.test': <String>['5.6.7.8'],
        },
        port: 8443,
      );

      expect(copy.port, 8443);
      expect(copy.toResolveEntries(), <String>['b.test:8443:5.6.7.8']);
      expect(copy.copyWith(), copy);
      expect(copy.copyWith().hashCode, copy.hashCode);
    });

    test('CookieSettings, PoolSettings and CacheSettings', () {
      const cookies = CookieSettings();
      final cookieCopy = cookies.copyWith(
        storeCookies: false,
        persistPath: '/tmp/jar',
      );
      expect(cookieCopy.storeCookies, isFalse);
      expect(cookieCopy.persistPath, '/tmp/jar');
      expect(cookieCopy.copyWith(), cookieCopy);

      const pool = PoolSettings();
      final poolCopy = pool.copyWith(
        maxConnections: 8,
        maxConnectionsPerHost: 2,
        idleTimeout: const Duration(seconds: 1),
        maxLifetime: const Duration(seconds: 2),
        keepAlivePingInterval: const Duration(seconds: 3),
      );
      expect(poolCopy.maxConnections, 8);
      expect(poolCopy.maxConnectionsPerHost, 2);
      expect(poolCopy.idleTimeout, const Duration(seconds: 1));
      expect(poolCopy.maxLifetime, const Duration(seconds: 2));
      expect(poolCopy.keepAlivePingInterval, const Duration(seconds: 3));
      expect(poolCopy.copyWith(), poolCopy);
      expect(poolCopy.copyWith().hashCode, poolCopy.hashCode);

      const cache = CacheSettings();
      expect(cache.copyWith(enabled: true), const CacheSettings(enabled: true));
      expect(cache.copyWith(), cache);
    });

    test('HttpCacheConfig', () {
      const original = HttpCacheConfig(directory: '/tmp/a');
      final copy = original.copyWith(
        directory: '/tmp/b',
        enabled: false,
        maxSizeBytes: 1,
        maxEntryBytes: 2,
      );

      expect(copy.directory, '/tmp/b');
      expect(copy.enabled, isFalse);
      expect(copy.maxSizeBytes, 1);
      expect(copy.maxEntryBytes, 2);
      expect(copy.copyWith(), copy);
      expect(copy.copyWith().hashCode, copy.hashCode);
    });
  });

  group('RedirectSettings', () {
    test('follow allows 30 hops', () {
      const settings = RedirectSettings.follow();
      expect(settings.follow, isTrue);
      expect(settings.maxRedirects, 30);
    });

    test('limited follows exactly the requested number of hops', () {
      expect(const RedirectSettings.limited(3).follow, isTrue);
      expect(const RedirectSettings.limited(3).maxRedirects, 3);
      // A limit of zero is indistinguishable from not following.
      expect(const RedirectSettings.limited(0).follow, isFalse);
    });

    test('none refuses to follow and reports no budget', () {
      const settings = RedirectSettings.none();
      expect(settings.follow, isFalse);
      expect(settings.maxRedirects, 0);
    });
  });

  group('DnsSettings.toResolveEntries', () {
    test('renders host:port:ip1,ip2 per host', () {
      const settings = StaticDnsSettings(<String, List<String>>{
        'a.test': <String>['1.2.3.4', '::1'],
        'b.test': <String>['5.6.7.8'],
      }, port: 8443);

      expect(settings.toResolveEntries(), <String>[
        'a.test:8443:1.2.3.4,::1',
        'b.test:8443:5.6.7.8',
      ]);
    });

    test('defaults to port 443 and skips hosts with no addresses', () {
      const settings = StaticDnsSettings(<String, List<String>>{
        'a.test': <String>['1.2.3.4'],
        // An empty list would tell libcurl to *block* the host, not redirect it.
        'blocked.test': <String>[],
      });

      expect(settings.toResolveEntries(), <String>['a.test:443:1.2.3.4']);
    });

    test('the system and DoH variants render nothing', () {
      expect(const SystemDnsSettings().toResolveEntries(), isEmpty);
      expect(const DohDnsSettings('https://d.test/q').toResolveEntries(), isEmpty);
    });
  });

  test('TlsVersion.wireValue matches the engine encoding', () {
    expect(TlsVersion.tls12.wireValue, 12);
    expect(TlsVersion.tls13.wireValue, 13);
  });

  test('RootCaSource.wireValue matches the documented discriminator', () {
    expect(RootCaSource.platform.wireValue, 0);
    expect(RootCaSource.bundled.wireValue, 1);
    expect(RootCaSource.custom.wireValue, 2);
    expect(RootCaSource.none.wireValue, 3);
  });
}
