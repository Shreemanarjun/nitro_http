import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';
import 'package:nitro_http/src/internal/raw_mapping.dart';
import 'package:nitro_http/src/nitro_http.native.dart';

import 'support/fakes.dart';

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  group('toRawClientConfig', () {
    test('carries every field of a fully populated ClientSettings', () {
      final headers = HttpHeaders()
        ..add('X-A', '1')
        ..add('x-a', '2');
      final settings = ClientSettings(
        baseUrl: 'https://api.test',
        timeout: const Duration(seconds: 30),
        connectTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(seconds: 7),
        httpVersionPref: HttpVersionPref.http2Only,
        headers: headers,
        userAgent: 'ua/9',
        redirectSettings: const RedirectSettings.limited(4),
        throwOnStatusCode: false,
        enableCompression: false,
        tlsSettings: const TlsSettings(rootCaSource: RootCaSource.bundled),
        proxySettings: const ProxySettings.socks5(
          'p:1080',
          username: 'u',
          password: 'pw',
          noProxy: 'localhost',
        ),
        dnsSettings: const DnsSettings.static(<String, List<String>>{
          'a.test': <String>['1.2.3.4'],
        }, port: 8443),
        cookieSettings: const CookieSettings(
          storeCookies: false,
          persistPath: '/tmp/jar',
        ),
        poolSettings: const PoolSettings(
          maxConnections: 3,
          maxConnectionsPerHost: 2,
          idleTimeout: Duration(seconds: 11),
          maxLifetime: Duration(seconds: 12),
          keepAlivePingInterval: Duration(seconds: 13),
        ),
        cacheSettings: const CacheSettings(enabled: true),
        altSvcCachePath: '/tmp/altsvc',
      );

      final config = toRawClientConfig(settings);

      expect(config.httpVersion, RawHttpVersionPref.http2Only);
      expect(config.connectTimeoutMs, 5000);
      expect(config.requestTimeoutMs, 30000);
      expect(config.idleTimeoutMs, 7000);
      expect(config.followRedirects, isTrue);
      expect(config.maxRedirects, 4);
      expect(config.enableCompression, isFalse);
      expect(config.enableCache, isTrue);
      expect(config.userAgent, 'ua/9');
      expect(config.altSvcCachePath, '/tmp/altsvc');
      expect(
        config.defaultHeaders.map((h) => '${h.name}=${h.value}'),
        <String>['X-A=1', 'x-a=2'],
        reason: 'duplicate default headers must survive the crossing',
      );
      expect(config.tls.rootCaSource, 1);
      expect(config.proxy.mode, RawProxyMode.socks5);
      expect(config.proxy.url, 'p:1080');
      expect(config.proxy.username, 'u');
      expect(config.proxy.password, 'pw');
      expect(config.proxy.noProxyHosts, 'localhost');
      expect(config.dns.staticOverrides, <String>['a.test:8443:1.2.3.4']);
      expect(config.dns.dohUrl, '');
      expect(config.cookies.enabled, isFalse);
      expect(config.cookies.persistPath, '/tmp/jar');
      expect(config.pool.maxConnections, 3);
      expect(config.pool.maxConnectionsPerHost, 2);
      expect(config.pool.idleTimeoutMs, 11000);
      expect(config.pool.maxLifetimeMs, 12000);
      expect(config.pool.keepAlivePingMs, 13000);
    });

    test('uses the documented sentinels for a default ClientSettings', () {
      final config = toRawClientConfig(const ClientSettings());

      expect(config.httpVersion, RawHttpVersionPref.auto);
      // 0 means "use the engine default" for connect/idle and "unlimited" for
      // the total-request budget.
      expect(config.connectTimeoutMs, 0);
      expect(config.requestTimeoutMs, 0);
      expect(config.idleTimeoutMs, 0);
      expect(config.followRedirects, isTrue);
      expect(config.maxRedirects, 30);
      expect(config.enableCompression, isTrue);
      expect(config.enableCache, isFalse);
      expect(config.userAgent, defaultUserAgent);
      expect(config.altSvcCachePath, '');
      expect(config.defaultHeaders, isEmpty);
      expect(config.tls.verifyCertificates, isTrue);
      expect(config.tls.rootCaSource, 0);
      expect(config.tls.trustedRootsPem, '');
      expect(config.tls.clientCertPem, '');
      expect(config.tls.clientKeyPem, '');
      expect(config.tls.clientKeyPassword, '');
      expect(config.tls.pinnedSpkiSha256, isEmpty);
      expect(config.tls.minTlsVersion, 0);
      expect(config.tls.maxTlsVersion, 0);
      expect(config.tls.sniHostname, '');
      expect(config.proxy.mode, RawProxyMode.system);
      expect(config.proxy.url, '');
      expect(config.dns.staticOverrides, isEmpty);
      expect(config.dns.dohUrl, '');
      expect(config.cookies.enabled, isTrue);
      expect(config.cookies.persistPath, '');
      expect(config.pool.maxConnections, 64);
      expect(config.pool.maxConnectionsPerHost, 6);
      expect(config.pool.idleTimeoutMs, 90000);
      expect(config.pool.maxLifetimeMs, 600000);
      expect(config.pool.keepAlivePingMs, 0);
    });

    test('maps every HTTP version preference', () {
      const expected = <HttpVersionPref, RawHttpVersionPref>{
        HttpVersionPref.auto: RawHttpVersionPref.auto,
        HttpVersionPref.http11Only: RawHttpVersionPref.http11Only,
        HttpVersionPref.http2: RawHttpVersionPref.http2,
        HttpVersionPref.http2Only: RawHttpVersionPref.http2Only,
        HttpVersionPref.http3: RawHttpVersionPref.http3,
        HttpVersionPref.http3Only: RawHttpVersionPref.http3Only,
      };

      expect(expected.keys, HttpVersionPref.values);
      for (final MapEntry(key: pref, value: raw) in expected.entries) {
        expect(
          toRawClientConfig(ClientSettings(httpVersionPref: pref)).httpVersion,
          raw,
        );
      }
    });

    test('a no-follow redirect policy disables following', () {
      final config = toRawClientConfig(
        const ClientSettings(redirectSettings: RedirectSettings.none()),
      );

      expect(config.followRedirects, isFalse);
      expect(config.maxRedirects, 0);
    });
  });

  group('toRawTls', () {
    test('maps every root CA source to its discriminator', () {
      const expected = <RootCaSource, int>{
        RootCaSource.platform: 0,
        RootCaSource.bundled: 1,
        RootCaSource.custom: 2,
        RootCaSource.none: 3,
      };

      expect(expected.keys, RootCaSource.values);
      for (final MapEntry(key: source, value: wire) in expected.entries) {
        expect(toRawTls(TlsSettings(rootCaSource: source)).rootCaSource, wire);
      }
    });

    test('carries the custom root bundle', () {
      final tls = toRawTls(
        const TlsSettings(
          rootCaSource: RootCaSource.custom,
          trustedRootsPem: '-----BEGIN CERTIFICATE-----',
        ),
      );

      expect(tls.rootCaSource, 2);
      expect(tls.trustedRootsPem, '-----BEGIN CERTIFICATE-----');
    });

    test('carries mTLS material, including an empty passphrase', () {
      final withPassword = toRawTls(
        const TlsSettings(
          clientCertificate: ClientCertificate(
            certificatePem: 'CERT',
            privateKeyPem: 'KEY',
            password: 'pw',
          ),
        ),
      );
      final withoutPassword = toRawTls(
        const TlsSettings(
          clientCertificate: ClientCertificate(
            certificatePem: 'CERT',
            privateKeyPem: 'KEY',
          ),
        ),
      );

      expect(withPassword.clientCertPem, 'CERT');
      expect(withPassword.clientKeyPem, 'KEY');
      expect(withPassword.clientKeyPassword, 'pw');
      expect(withoutPassword.clientKeyPassword, '');
    });

    test('carries pins, version bounds and an SNI override', () {
      final tls = toRawTls(
        const TlsSettings(
          verifyCertificates: false,
          pinnedSpkiSha256: <String>['aaa=', 'bbb='],
          minVersion: TlsVersion.tls12,
          maxVersion: TlsVersion.tls13,
          sniHostname: 'real.host',
        ),
      );

      expect(tls.verifyCertificates, isFalse);
      expect(tls.pinnedSpkiSha256, <String>['aaa=', 'bbb=']);
      expect(tls.minTlsVersion, 12);
      expect(tls.maxTlsVersion, 13);
      expect(tls.sniHostname, 'real.host');
    });

    test('the pin list is copied, not aliased', () {
      final pins = <String>['aaa='];
      final tls = toRawTls(TlsSettings(pinnedSpkiSha256: pins));

      pins.add('bbb=');

      expect(tls.pinnedSpkiSha256, <String>['aaa=']);
      expect(() => tls.pinnedSpkiSha256.add('ccc='), throwsUnsupportedError);
    });
  });

  group('toRawProxy', () {
    test('system and direct carry no endpoint', () {
      for (final proxy in const <ProxySettings>[
        ProxySettings.system(),
        ProxySettings.noProxy(),
      ]) {
        final raw = toRawProxy(proxy);
        expect(raw.url, '');
        expect(raw.username, '');
        expect(raw.password, '');
        expect(raw.noProxyHosts, '');
      }
      expect(toRawProxy(const ProxySettings.system()).mode, RawProxyMode.system);
      expect(toRawProxy(const ProxySettings.noProxy()).mode, RawProxyMode.none);
    });

    test('maps every manual proxy kind', () {
      const expected = <ProxyKind, RawProxyMode>{
        ProxyKind.http: RawProxyMode.http,
        ProxyKind.socks5: RawProxyMode.socks5,
        ProxyKind.socks5Hostname: RawProxyMode.socks5Hostname,
      };

      expect(expected.keys, ProxyKind.values);
      for (final MapEntry(key: kind, value: mode) in expected.entries) {
        expect(toRawProxy(ManualProxySettings(kind, 'p:1')).mode, mode);
      }
    });

    test('unset credentials become empty strings, not nulls', () {
      final raw = toRawProxy(const ProxySettings.http('p:8080'));

      expect(raw.url, 'p:8080');
      expect(raw.username, '');
      expect(raw.password, '');
      expect(raw.noProxyHosts, '');
    });
  });

  group('toRawDns', () {
    test('system resolves through the platform', () {
      final raw = toRawDns(const DnsSettings.system());
      expect(raw.staticOverrides, isEmpty);
      expect(raw.dohUrl, '');
    });

    test('static renders CURLOPT_RESOLVE entries', () {
      final raw = toRawDns(
        const DnsSettings.static(<String, List<String>>{
          'a.test': <String>['1.2.3.4', '::1'],
        }),
      );

      expect(raw.staticOverrides, <String>['a.test:443:1.2.3.4,::1']);
      expect(raw.dohUrl, '');
    });

    test('doh carries the endpoint and no overrides', () {
      final raw = toRawDns(const DnsSettings.doh('https://d.test/q'));

      expect(raw.staticOverrides, isEmpty);
      expect(raw.dohUrl, 'https://d.test/q');
    });
  });

  group('encodeBody', () {
    test('a null body is the none kind', () async {
      final encoded = await encodeBody(null);

      expect(encoded.kind, RawBodyKind.none);
      expect(encoded.bytes, isEmpty);
      expect(encoded.contentLength, isNull);
      expect(encoded.contentType, isNull);
      expect(encoded.stream, isNull);
      expect(encoded.filePath, '');
    });

    test('text is UTF-8 with a text/plain default', () async {
      final encoded = await encodeBody(const HttpBody.text('héllo'));

      expect(encoded.kind, RawBodyKind.bytes);
      expect(encoded.bytes, utf8.encode('héllo'));
      expect(encoded.contentLength, 6);
      expect(encoded.contentType, 'text/plain; charset=utf-8');

      final overridden = await encodeBody(
        const HttpBody.text('x', contentType: 'text/csv'),
      );
      expect(overridden.contentType, 'text/csv');
    });

    test('json is encoded with dart:convert', () async {
      final encoded = await encodeBody(
        const HttpBody.json(<String, Object>{'a': 1}),
      );

      expect(encoded.kind, RawBodyKind.bytes);
      expect(utf8.decode(encoded.bytes), '{"a":1}');
      expect(encoded.contentLength, 7);
      expect(encoded.contentType, 'application/json; charset=utf-8');
    });

    test('bytes pass through untouched', () async {
      final bytes = Uint8List.fromList(<int>[1, 2, 3]);
      final encoded = await encodeBody(HttpBody.bytes(bytes));

      expect(encoded.kind, RawBodyKind.bytes);
      expect(encoded.bytes, same(bytes));
      expect(encoded.contentLength, 3);
      expect(encoded.contentType, 'application/octet-stream');
    });

    test('a form body is url-encoded', () async {
      final encoded = await encodeBody(
        const HttpBody.form(<String, String>{'a': 'x y'}),
      );

      expect(encoded.kind, RawBodyKind.bytes);
      expect(utf8.decode(encoded.bytes), 'a=x+y');
      expect(encoded.contentLength, 5);
      expect(encoded.contentType, 'application/x-www-form-urlencoded');
    });

    test('multipart becomes a stream with a declared length', () async {
      const body = HttpBody.multipart(
        <MultipartItem>[MultipartItem.text('a', 'value')],
        boundary: 'BOUND',
      );
      final encoded = await encodeBody(body);

      expect(encoded.kind, RawBodyKind.streamed);
      expect(encoded.bytes, isEmpty);
      expect(encoded.contentType, 'multipart/form-data; boundary=BOUND');
      expect(encoded.stream, isNotNull);
      expect(await _collect(encoded.stream!), hasLength(encoded.contentLength));
    });

    test('a stream body is forwarded verbatim', () async {
      final source = Stream<List<int>>.fromIterable(<List<int>>[
        <int>[1],
      ]);
      final encoded = await encodeBody(
        HttpBody.stream(source, contentLength: 1, contentType: 'application/x-x'),
      );

      expect(encoded.kind, RawBodyKind.streamed);
      expect(encoded.bytes, isEmpty);
      expect(encoded.stream, same(source));
      expect(encoded.contentLength, 1);
      expect(encoded.contentType, 'application/x-x');
    });

    test('a stream body of unknown length declares none', () async {
      final encoded = await encodeBody(
        HttpBody.stream(const Stream<List<int>>.empty()),
      );

      expect(encoded.contentLength, isNull);
      expect(encoded.contentType, isNull);
    });

    test('a file body carries only the path, never the bytes', () async {
      final encoded = await encodeBody(const HttpBody.file('/tmp/photo.png'));

      expect(encoded.kind, RawBodyKind.filePath);
      expect(
        encoded.bytes,
        isEmpty,
        reason: 'curl reads the file itself; Dart must not buffer it',
      );
      expect(encoded.filePath, '/tmp/photo.png');
      expect(encoded.contentType, 'image/png');
      expect(encoded.contentLength, isNull);
    });
  });

  group('toRawOptions', () {
    test('absent overrides become the inherit sentinel', () {
      final raw = toRawOptions(
        const RequestOptions(),
        reportProgress: false,
        uploadContentLength: kInherit,
      );

      expect(kInherit, -1);
      expect(raw.connectTimeoutMs, -1);
      expect(raw.requestTimeoutMs, -1);
      expect(raw.followRedirects, -1);
      expect(raw.maxRedirects, -1);
      expect(raw.cacheMode, RawCacheMode.normal);
      expect(raw.reportProgress, isFalse);
      expect(raw.wantTimings, isTrue);
      expect(raw.uploadContentLength, -1);
      expect(raw.pinnedSpkiOverride, '');
    });

    test('followRedirects is a tri-state', () {
      int wire(bool? value) => toRawOptions(
        RequestOptions(followRedirects: value),
        reportProgress: false,
        uploadContentLength: 0,
      ).followRedirects;

      expect(wire(null), -1);
      expect(wire(false), 0);
      expect(wire(true), 1);
    });

    test('present overrides are carried', () {
      final raw = toRawOptions(
        const RequestOptions(
          connectTimeout: Duration(milliseconds: 250),
          timeout: Duration(seconds: 4),
          maxRedirects: 2,
          cacheMode: CacheMode.onlyIfCached,
          wantTimings: false,
          pinnedSpkiSha256: 'pin=',
        ),
        reportProgress: true,
        uploadContentLength: 99,
      );

      expect(raw.connectTimeoutMs, 250);
      expect(raw.requestTimeoutMs, 4000);
      expect(raw.maxRedirects, 2);
      expect(raw.cacheMode, RawCacheMode.onlyIfCached);
      expect(raw.wantTimings, isFalse);
      expect(raw.reportProgress, isTrue);
      expect(raw.uploadContentLength, 99);
      expect(raw.pinnedSpkiOverride, 'pin=');
    });

    test('toRawCacheMode maps every mode, and null is normal', () {
      const expected = <CacheMode, RawCacheMode>{
        CacheMode.normal: RawCacheMode.normal,
        CacheMode.noStore: RawCacheMode.noStore,
        CacheMode.bypass: RawCacheMode.bypass,
        CacheMode.onlyIfCached: RawCacheMode.onlyIfCached,
        CacheMode.refresh: RawCacheMode.refresh,
      };

      expect(expected.keys, CacheMode.values);
      for (final MapEntry(key: mode, value: raw) in expected.entries) {
        expect(toRawCacheMode(mode), raw);
      }
      expect(toRawCacheMode(null), RawCacheMode.normal);
    });
  });

  group('toRawRequest', () {
    test('renders the method, url, headers and body discriminators', () async {
      final headers = HttpHeaders()
        ..add('Accept', 'a')
        ..add('accept', 'b');
      final request = HttpRequest(
        url: Uri.parse('https://example.com/x?q=1'),
        method: HttpMethod.post,
        options: const RequestOptions(maxRedirects: 3),
      );
      final body = await encodeBody(const HttpBody.text('hi'));

      final raw = toRawRequest(
        requestId: 42,
        request: request,
        headers: headers,
        body: body,
        reportProgress: true,
      );

      expect(raw.requestId, 42);
      expect(raw.method, RawMethod.post);
      expect(raw.customMethod, '');
      expect(raw.url, 'https://example.com/x?q=1');
      expect(
        raw.headers.map((h) => '${h.name}: ${h.value}'),
        <String>['Accept: a', 'accept: b'],
      );
      expect(raw.bodyKind, RawBodyKind.bytes);
      expect(raw.bodyFilePath, '');
      expect(raw.options.uploadContentLength, 2);
      expect(raw.options.maxRedirects, 3);
      expect(raw.options.reportProgress, isTrue);
    });

    test('a custom method carries its token, and other methods do not', () async {
      final body = await encodeBody(null);
      final custom = toRawRequest(
        requestId: 1,
        request: HttpRequest(
          url: Uri.parse('https://a.test/'),
          method: HttpMethod.custom,
          customMethod: 'PURGE',
        ),
        headers: HttpHeaders(),
        body: body,
        reportProgress: false,
      );

      expect(custom.method, RawMethod.custom);
      expect(custom.customMethod, 'PURGE');
      expect(custom.options.uploadContentLength, kInherit);
    });

    test('a file body sends the path and an inherit length', () async {
      final raw = toRawRequest(
        requestId: 1,
        request: HttpRequest(url: Uri.parse('https://a.test/')),
        headers: HttpHeaders(),
        body: await encodeBody(const HttpBody.file('/tmp/a.bin')),
        reportProgress: false,
      );

      expect(raw.bodyKind, RawBodyKind.filePath);
      expect(raw.bodyFilePath, '/tmp/a.bin');
      expect(raw.options.uploadContentLength, kInherit);
    });

    test('toRawMethod maps every method', () {
      const expected = <HttpMethod, RawMethod>{
        HttpMethod.get: RawMethod.get,
        HttpMethod.head: RawMethod.head,
        HttpMethod.post: RawMethod.post,
        HttpMethod.put: RawMethod.put,
        HttpMethod.delete: RawMethod.delete,
        HttpMethod.patch: RawMethod.patch,
        HttpMethod.options: RawMethod.options,
        HttpMethod.trace: RawMethod.trace,
        HttpMethod.custom: RawMethod.custom,
      };

      expect(expected.keys, HttpMethod.values);
      for (final MapEntry(key: method, value: raw) in expected.entries) {
        expect(toRawMethod(method), raw);
      }
    });
  });

  group('mapError', () {
    // Explicit rather than derived: a new RawErrorKind must fail this test
    // instead of silently falling into whatever the switch does with it.
    final expectations = <RawErrorKind, void Function(NitroHttpException)>{
      RawErrorKind.cancelled: (e) => expect(e, isA<NitroHttpCancelException>()),
      RawErrorKind.timeoutConnect: (e) => expect(
        e,
        isA<NitroHttpTimeoutException>().having(
          (x) => x.stage,
          'stage',
          TimeoutStage.connect,
        ),
      ),
      RawErrorKind.timeoutRequest: (e) => expect(
        e,
        isA<NitroHttpTimeoutException>().having(
          (x) => x.stage,
          'stage',
          TimeoutStage.request,
        ),
      ),
      RawErrorKind.timeoutIdle: (e) => expect(
        e,
        isA<NitroHttpTimeoutException>().having(
          (x) => x.stage,
          'stage',
          TimeoutStage.idle,
        ),
      ),
      RawErrorKind.dnsFailure: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.dns,
        ),
      ),
      RawErrorKind.connectionRefused: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.refused,
        ),
      ),
      RawErrorKind.connectionReset: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.reset,
        ),
      ),
      RawErrorKind.connectionFailed: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.failed,
        ),
      ),
      RawErrorKind.proxyFailure: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.proxy,
        ),
      ),
      RawErrorKind.unsupportedScheme: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.unsupportedScheme,
        ),
      ),
      RawErrorKind.sendFailure: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.send,
        ),
      ),
      RawErrorKind.receiveFailure: (e) => expect(
        e,
        isA<NitroHttpConnectionException>().having(
          (x) => x.failure,
          'failure',
          ConnectionFailure.receive,
        ),
      ),
      // A handshake that never reached a certificate is NOT a certificate
      // failure: no shared version or cipher is a different problem with a
      // different fix, and conflating them sends the reader to the wrong place.
      RawErrorKind.tlsHandshake: (e) => expect(e, isA<NitroHttpTlsException>()),
      RawErrorKind.certificateInvalid: (e) => expect(
        e,
        isA<NitroHttpCertificateException>()
            .having((x) => x.isPinMismatch, 'isPinMismatch', false)
            .having((x) => x.isClientAuthFailure, 'isClientAuthFailure', false),
      ),
      RawErrorKind.certificatePinMismatch: (e) => expect(
        e,
        isA<NitroHttpCertificateException>()
            .having((x) => x.isPinMismatch, 'isPinMismatch', true)
            .having((x) => x.isClientAuthFailure, 'isClientAuthFailure', false),
      ),
      RawErrorKind.certificateClientAuth: (e) => expect(
        e,
        isA<NitroHttpCertificateException>()
            .having((x) => x.isPinMismatch, 'isPinMismatch', false)
            .having((x) => x.isClientAuthFailure, 'isClientAuthFailure', true),
      ),
      // `redirectCount` is the hops actually followed, which this table does
      // not supply — it used to be filled with the engine error code, so a
      // caller reading it got a CURLcode dressed up as a hop count.
      RawErrorKind.tooManyRedirects: (e) => expect(
        e,
        isA<NitroHttpRedirectException>().having(
          (x) => x.redirectCount,
          'redirectCount',
          0,
        ),
      ),
      RawErrorKind.protocolError: (e) =>
          expect(e, isA<NitroHttpProtocolException>()),
      RawErrorKind.decompressionFailure: (e) =>
          expect(e, isA<NitroHttpDecodingException>()),
      RawErrorKind.responseTooLarge: (e) =>
          expect(e, isA<NitroHttpResponseTooLargeException>()),
      RawErrorKind.cacheMiss: (e) =>
          expect(e, isA<NitroHttpCacheMissException>()),
      RawErrorKind.io: (e) => expect(e, isA<NitroHttpUnknownException>()),
      RawErrorKind.engineError: (e) =>
          expect(e, isA<NitroHttpUnknownException>()),
      // Settings the engine refused: a programming error, not a transient
      // fault, so it must not read as "unknown" and invite a retry.
      RawErrorKind.badRequest: (e) =>
          expect(e, isA<NitroHttpConfigurationException>()),
      RawErrorKind.unknown: (e) => expect(e, isA<NitroHttpUnknownException>()),
    };

    test('an over-size failure carries the ceiling the engine named', () {
      // The number lives in the engine's message rather than a field of its
      // own: the caller configured the limit and already has it, so parsing it
      // back out would only duplicate what they set.
      final error = mapError(
        kind: RawErrorKind.responseTooLarge,
        message: 'response body exceeds the configured limit of 1048576 bytes',
        engineErrorCode: 0,
      );

      expect(error, isA<NitroHttpResponseTooLargeException>());
      expect(error.message, contains('1048576'));
    });

    test('none is a programming error, not a failure', () {
      expect(
        () => mapError(kind: RawErrorKind.none, message: '', engineErrorCode: 0),
        throwsStateError,
      );
    });

    test('the expectation table covers RawErrorKind exactly', () {
      expect(
        expectations.keys.toSet(),
        RawErrorKind.values.toSet()..remove(RawErrorKind.none),
      );
    });

    test('every kind maps to its specific exception', () {
      final request = fakeRequest();

      for (final MapEntry(key: kind, value: check) in expectations.entries) {
        final error = mapError(
          kind: kind,
          message: 'boom',
          engineErrorCode: 7,
          request: request,
        );

        check(error);
        expect(error.engineMessage, 'boom', reason: '$kind');
        expect(error.engineErrorCode, 7, reason: '$kind');
        expect(error.request, same(request), reason: '$kind');
        expect(error.message, contains('boom'), reason: '$kind');
      }
    });
  });

  group('response mapping', () {
    test('fromRawVersion maps every negotiated version', () {
      const expected = <RawHttpVersion, HttpVersion>{
        RawHttpVersion.unknown: HttpVersion.unknown,
        RawHttpVersion.http10: HttpVersion.http10,
        RawHttpVersion.http11: HttpVersion.http11,
        RawHttpVersion.http2: HttpVersion.http2,
        RawHttpVersion.http3: HttpVersion.http3,
      };

      expect(expected.keys, RawHttpVersion.values);
      for (final MapEntry(key: raw, value: version) in expected.entries) {
        expect(fromRawVersion(raw), version);
      }
    });

    test('fromRawHeaders preserves duplicates and order', () {
      final headers = fromRawHeaders(const <RawHeader>[
        RawHeader(name: 'Set-Cookie', value: 'a=1'),
        RawHeader(name: 'Date', value: 'now'),
        RawHeader(name: 'set-cookie', value: 'b=2'),
      ]);

      expect(headers.setCookie, <String>['a=1', 'b=2']);
      expect(headers.entries, <(String, String)>[
        ('Set-Cookie', 'a=1'),
        ('Date', 'now'),
        ('set-cookie', 'b=2'),
      ]);
    });

    test('fromRawTimings converts milliseconds to rounded microseconds', () {
      final timings = fromRawTimings(
        const RawTimings(
          queueMs: 0.5,
          dnsMs: 1.5,
          connectMs: 0.0625,
          tlsMs: 0,
          firstByteMs: 12.25,
          redirectMs: 0.001,
          totalMs: 1024,
        ),
      );

      expect(timings.queue.inMicroseconds, 500);
      expect(timings.dns.inMicroseconds, 1500);
      // 62.5 µs rounds away from zero, not toward it.
      expect(timings.connect.inMicroseconds, 63);
      expect(timings.tls, Duration.zero);
      expect(timings.firstByte.inMicroseconds, 12250);
      expect(timings.redirect.inMicroseconds, 1);
      expect(timings.total, const Duration(seconds: 1, milliseconds: 24));
      expect(timings.isEmpty, isFalse);
    });

    test('fromRawTimings treats non-finite values as zero', () {
      final timings = fromRawTimings(
        const RawTimings(
          queueMs: double.infinity,
          dnsMs: double.nan,
          connectMs: double.negativeInfinity,
          tlsMs: 0,
          firstByteMs: 0,
          redirectMs: 0,
          totalMs: 0,
        ),
      );

      expect(timings.queue, Duration.zero);
      expect(timings.dns, Duration.zero);
      expect(timings.connect, Duration.zero);
      expect(timings.isEmpty, isTrue);
    });

    test('metadataFrom builds the shared metadata', () {
      final request = fakeRequest(url: 'https://example.com/start');
      final meta = metadataFrom(
        request: request,
        statusCode: 301,
        reasonPhrase: 'Moved Permanently',
        version: RawHttpVersion.http2,
        headers: const <RawHeader>[RawHeader(name: 'Location', value: '/next')],
        finalUrl: 'https://example.com/next',
        redirectCount: 2,
        fromCache: true,
        revalidated: true,
        primaryIp: '198.51.100.9',
        primaryPort: 8443,
        timings: const RawTimings(
          queueMs: 0,
          dnsMs: 0,
          connectMs: 0,
          tlsMs: 0,
          firstByteMs: 0,
          redirectMs: 0,
          totalMs: 2,
        ),
      );

      expect(meta.request, same(request));
      expect(meta.statusCode, 301);
      expect(meta.version, HttpVersion.http2);
      expect(meta.headers.location, '/next');
      expect(meta.finalUrl, Uri.parse('https://example.com/next'));
      expect(meta.redirectCount, 2);
      expect(meta.fromCache, isTrue);
      expect(meta.revalidated, isTrue);
      expect(meta.primaryIp, '198.51.100.9');
      expect(meta.primaryPort, 8443);
      expect(meta.timings.total, const Duration(milliseconds: 2));
    });

    test('an empty finalUrl falls back to the request URL', () {
      final request = fakeRequest(url: 'https://example.com/start');
      final meta = metadataFrom(
        request: request,
        statusCode: 200,
        reasonPhrase: 'OK',
        version: RawHttpVersion.http11,
        headers: const <RawHeader>[],
        finalUrl: '',
        redirectCount: 0,
        fromCache: false,
        revalidated: false,
        primaryIp: '',
        primaryPort: 0,
        timings: zeroTimings,
      );

      expect(meta.finalUrl, request.url);
    });
  });

  group('cookies', () {
    test('fromRawCookie treats a zero expiry as a session cookie', () {
      final cookie = fromRawCookie(
        const RawCookie(
          name: 'sid',
          value: 'abc',
          domain: 'example.com',
          path: '/x',
          expiresEpochMs: 0,
          secure: true,
          httpOnly: true,
        ),
      );

      expect(cookie.name, 'sid');
      expect(cookie.value, 'abc');
      expect(cookie.domain, 'example.com');
      expect(cookie.path, '/x');
      expect(cookie.expires, isNull);
      expect(cookie.isSessionCookie, isTrue);
      expect(cookie.secure, isTrue);
      expect(cookie.httpOnly, isTrue);
    });

    test('toRawCookie writes zero for a session cookie and / for no path', () {
      final raw = toRawCookie(
        const Cookie(name: 'sid', value: '1', domain: 'a.test', path: ''),
      );

      expect(raw.expiresEpochMs, 0);
      expect(raw.path, '/');
    });

    test('an expiring cookie round trips through the wire form', () {
      final expires = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final original = Cookie(
        name: 'sid',
        value: '1',
        domain: 'a.test',
        path: '/p',
        expires: expires,
        secure: true,
        httpOnly: true,
      );

      final raw = toRawCookie(original);
      expect(raw.expiresEpochMs, 1700000000000);
      expect(fromRawCookie(raw), original);
    });
  });

  group('cache', () {
    test('toRawCacheConfig carries every field', () {
      final raw = toRawCacheConfig(
        const HttpCacheConfig(
          directory: '/tmp/c',
          enabled: false,
          maxSizeBytes: 10,
          maxEntryBytes: 5,
        ),
      );

      expect(raw.enabled, isFalse);
      expect(raw.directory, '/tmp/c');
      expect(raw.maxSizeBytes, 10);
      expect(raw.maxEntryBytes, 5);
    });

    test('fromRawCacheStats carries every counter', () {
      final stats = fromRawCacheStats(
        const RawCacheStats(
          entryCount: 1,
          sizeBytes: 2,
          hitCount: 3,
          missCount: 1,
          revalidationCount: 5,
          evictionCount: 6,
        ),
      );

      expect(stats.entryCount, 1);
      expect(stats.sizeBytes, 2);
      expect(stats.hitCount, 3);
      expect(stats.missCount, 1);
      expect(stats.revalidationCount, 5);
      expect(stats.evictionCount, 6);
      expect(stats.hitRate, 0.75);
    });
  });
}
