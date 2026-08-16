// The check matrix — the whole httpbin.io surface, one row per behaviour.
//
// Each entry asserts something real against a live server, so DNS, TLS,
// redirects and content negotiation are all exercised; an in-process loopback
// server cannot do that. A check fails by throwing.
//
// Two things about httpbin.io shape what is testable:
//
//   * It speaks HTTP/1.1 ONLY, so protocol negotiation is checked against
//     Cloudflare instead — see the `protocol` group.
//   * It serves genuine `Content-Encoding: br` and `zstd`. Those are the most
//     valuable rows here: a `dart:io`-based client cannot decode them at all,
//     and they are the first thing to disappear when a build silently falls
//     back to a system libcurl.
import 'dart:convert';
import 'dart:io' show Directory;

import 'package:nitro_http/nitro_http.dart';

const httpbin = 'https://httpbin.io';

/// One row of the matrix. [run] returns a human-readable detail line; throwing
/// marks the check failed.
class Check {
  const Check(this.group, this.name, this.run);
  final String group;
  final String name;
  final Future<String> Function(NitroHttpClient client) run;
}

Map<String, dynamic> _json(HttpTextResponse r) =>
    r.bodyToJson()! as Map<String, dynamic>;

void _expect(bool ok, String message) {
  if (!ok) throw message;
}

String _size(HttpTextResponse r) => '${r.bodyBytes.length}B';

final checks = <Check>[
  // ── Engine ────────────────────────────────────────────────────────────────
  Check('engine', 'capabilities', (_) async {
    final h3 = NitroHttp.supportsHttp3;
    return 'h3=$h3 ws=${NitroHttp.supportsWebSockets} '
        'brotli=${NitroHttp.supportsBrotli} zstd=${NitroHttp.supportsZstd}'
        '${h3 ? '' : '   (no HTTP/3 — system libcurl?)'}';
  }),
  Check('engine', 'version', (_) async => NitroHttp.engineVersion),

  // ── Methods ───────────────────────────────────────────────────────────────
  Check('methods', 'GET /get + query', (c) async {
    final r = await c.get('/get', query: {'a': '1', 'b': 'two'});
    final args = _json(r)['args'] as Map<String, dynamic>;
    _expect(args.containsKey('a') && args.containsKey('b'), 'query lost: $args');
    return 'args=$args';
  }),
  Check('methods', 'POST /post json', (c) async {
    final r = await c.post('/post', body: HttpBody.json({'name': 'Ada'}));
    _expect(_json(r)['json'] != null, 'no json echoed');
    return 'echoed ${_json(r)['json']}';
  }),
  Check('methods', 'POST /post form', (c) async {
    final r = await c.post('/post', body: HttpBody.form({'x': '1', 'y': '2'}));
    _expect(r.body.contains('"x"'), 'form field missing');
    return 'form round-tripped';
  }),
  Check('methods', 'PUT /put', (c) async {
    final r = await c.put('/put', body: HttpBody.text('payload'));
    _expect(r.statusCode == 200, 'status ${r.statusCode}');
    return 'status 200, ${_size(r)}';
  }),
  Check('methods', 'PATCH /patch', (c) async {
    final r = await c.patch('/patch', body: HttpBody.text('payload'));
    _expect(r.statusCode == 200, 'status ${r.statusCode}');
    return 'status 200';
  }),
  Check('methods', 'DELETE /delete', (c) async {
    final r = await c.delete('/delete');
    _expect(r.statusCode == 200, 'status ${r.statusCode}');
    return 'status 200';
  }),
  Check('methods', 'HEAD /head (no body)', (c) async {
    final r = await c.head('/head');
    _expect(r.bodyBytes.isEmpty, 'HEAD returned ${r.bodyBytes.length}B');
    return 'status ${r.statusCode}, empty body';
  }),

  // ── Request inspection ────────────────────────────────────────────────────
  Check('inspect', '/anything echoes everything', (c) async {
    final r = await c.post('/anything/probe',
        query: {'q': '1'}, body: HttpBody.json({'k': 'v'}));
    final m = _json(r);
    _expect(m['method'] == 'POST', 'method was ${m['method']}');
    return 'method=${m['method']} url echoed';
  }),
  Check('inspect', '/headers echoes request headers', (c) async {
    final r = await c.get('/headers',
        headers: HttpHeaders.fromMap({'X-Nitro-Probe': 'hello'}));
    _expect(r.body.toLowerCase().contains('x-nitro-probe'), 'header not echoed');
    return 'X-Nitro-Probe round-tripped';
  }),
  Check('inspect', '/user-agent matches settings', (c) async {
    final r = await c.get('/user-agent');
    final ua = _json(r)['user-agent']?.toString() ?? '';
    _expect(ua.contains('nitro_http_minimal'), 'unexpected UA: $ua');
    return ua;
  }),
  Check('inspect', '/ip', (c) async => '${_json(await c.get('/ip'))['origin']}'),
  Check('inspect', '/hostname',
      (c) async => '${_json(await c.get('/hostname'))['hostname']}'),
  Check('inspect', '/dump/request (wire form)', (c) async {
    final r = await c.get('/dump/request');
    _expect(r.body.contains('GET'), 'no request line in dump');
    return r.body.split('\n').first.trim();
  }),

  // ── Response formats ──────────────────────────────────────────────────────
  Check('formats', '/json', (c) async {
    final r = await c.get('/json');
    return 'keys=${_json(r).keys.take(3).join(",")}';
  }),
  Check('formats', '/xml', (c) async {
    final r = await c.get('/xml');
    _expect(r.body.contains('<'), 'not XML');
    return '${r.headers['content-type']} ${_size(r)}';
  }),
  Check('formats', '/html', (c) async {
    final r = await c.get('/html');
    _expect(r.body.toLowerCase().contains('<html'), 'not HTML');
    return _size(r);
  }),
  Check('formats', '/html/schema', (c) async =>
      _size(await c.get('/html/schema'))),
  Check('formats', '/links/10', (c) async {
    final r = await c.get('/links/10');
    return '${'href'.allMatches(r.body).length} hrefs';
  }),
  Check('formats', '/forms/post', (c) async {
    final r = await c.get('/forms/post');
    _expect(r.body.contains('<form'), 'no form element');
    return 'form page ${_size(r)}';
  }),
  Check('formats', '/encoding/utf8', (c) async {
    final r = await c.get('/encoding/utf8');
    // Decoded with the response charset, so multi-byte text must survive.
    _expect(r.body.runes.any((x) => x > 127), 'no multi-byte characters');
    return '${_size(r)}, non-ASCII preserved';
  }),
  Check('formats', '/robots.txt', (c) async {
    final r = await c.get('/robots.txt');
    _expect(r.body.contains('User-agent'), 'not a robots file');
    return r.body.split('\n').first;
  }),
  Check('formats', '/deny', (c) async => 'status ${(await c.get('/deny')).statusCode}'),

  // ── Images (binary bodies) ────────────────────────────────────────────────
  Check('images', '/image via Accept', (c) async {
    final r = await c.get('/image',
        headers: HttpHeaders.fromMap({'Accept': 'image/png'}));
    return '${r.headers['content-type']} ${_size(r)}';
  }),
  for (final kind in ['jpeg', 'png', 'svg', 'webp'])
    Check('images', '/image/$kind', (c) async {
      final r = await c.get('/image/$kind');
      _expect(r.bodyBytes.isNotEmpty, 'empty image');
      return '${r.headers['content-type']} ${_size(r)}';
    }),

  // ── Content decoding: the differentiator ──────────────────────────────────
  for (final coding in ['gzip', 'deflate', 'brotli', 'zstd'])
    Check('decoding', coding, (c) async {
      final r = await c.get('/$coding');
      final map = _json(r);
      _expect(map.isNotEmpty, 'empty body after $coding decode');
      return '${_size(r)} decoded, keys=${map.keys.take(2).join(",")}';
    }),

  // ── Status codes ──────────────────────────────────────────────────────────
  for (final code in [200, 301, 404, 418, 500])
    Check('status', '/status/$code', (c) async {
      final r = await c.get('/status/$code',
          options: const RequestOptions(followRedirects: false));
      _expect(r.statusCode == code, 'got ${r.statusCode}');
      return 'statusCode=$code isSuccess=${r.isSuccess}';
    }),

  // ── Redirects ─────────────────────────────────────────────────────────────
  Check('redirects', '/redirect/3 followed', (c) async {
    final r = await c.get('/redirect/3');
    _expect(r.redirectCount >= 1, 'redirectCount=${r.redirectCount}');
    return 'hops=${r.redirectCount} final=${r.finalUrl}';
  }),
  Check('redirects', '/absolute-redirect/2', (c) async {
    final r = await c.get('/absolute-redirect/2');
    return 'hops=${r.redirectCount} status=${r.statusCode}';
  }),
  Check('redirects', '/relative-redirect/2', (c) async {
    final r = await c.get('/relative-redirect/2');
    return 'hops=${r.redirectCount} status=${r.statusCode}';
  }),
  Check('redirects', '/redirect-to 307', (c) async {
    final r = await c.get('/redirect-to',
        query: {'url': '$httpbin/get', 'status_code': '307'});
    _expect(r.statusCode == 200, 'ended at ${r.statusCode}');
    return 'followed 307 to ${r.finalUrl}';
  }),
  Check('redirects', 'followRedirects:false stops', (c) async {
    final r = await c.get('/redirect/1',
        options: const RequestOptions(followRedirects: false));
    _expect(r.statusCode ~/ 100 == 3, 'expected 3xx, got ${r.statusCode}');
    return 'stopped at ${r.statusCode}';
  }),

  // ── Base64 ────────────────────────────────────────────────────────────────
  Check('base64', 'encode then decode round-trip', (c) async {
    const plain = 'nitro_http';
    final enc = (await c.get('/base64/encode/$plain')).body.trim();
    final dec = (await c.get('/base64/decode/$enc')).body.trim();
    _expect(dec == plain, 'round-trip gave "$dec"');
    return '$plain -> $enc -> $dec';
  }),
  Check('base64', '/base64/:value implicit decode', (c) async {
    final v = base64Encode(utf8.encode('hi'));
    return (await c.get('/base64/$v')).body.trim();
  }),

  // ── Cookies ───────────────────────────────────────────────────────────────
  Check('cookies', 'set then replayed', (c) async {
    await c.get('/cookies/set', query: {'nitro': 'yes'});
    final r = await c.get('/cookies');
    _expect(r.body.contains('nitro'), 'cookie not replayed: ${r.body}');
    return 'jar replayed nitro=yes';
  }),
  Check('cookies', 'delete removes it', (c) async {
    await c.get('/cookies/set', query: {'gone': '1'});
    await c.get('/cookies/delete', query: {'gone': ''});
    final r = await c.get('/cookies');
    _expect(!r.body.contains('"gone"'), 'cookie survived deletion: ${r.body}');
    return 'cookie deleted';
  }),

  // ── Auth ──────────────────────────────────────────────────────────────────
  Check('auth', 'basic: 401 then 200', (c) async {
    final denied = await c.get('/basic-auth/u/p');
    final token = base64Encode(utf8.encode('u:p'));
    final ok = await c.get('/basic-auth/u/p',
        headers: HttpHeaders.fromMap({'Authorization': 'Basic $token'}));
    _expect(ok.statusCode == 200, 'authorised call gave ${ok.statusCode}');
    return 'unauth=${denied.statusCode} auth=200';
  }),
  Check('auth', 'hidden-basic is 404 when unauthorised', (c) async {
    final r = await c.get('/hidden-basic-auth/u/p');
    _expect(r.statusCode == 404, 'expected 404, got ${r.statusCode}');
    return 'status 404 (hidden)';
  }),
  Check('auth', 'bearer: 401 without, 200 with', (c) async {
    final without = await c.get('/bearer');
    final with_ = await c.get('/bearer',
        headers: HttpHeaders.fromMap({'Authorization': 'Bearer tkn'}));
    return 'without=${without.statusCode} with=${with_.statusCode}';
  }),
  Check('auth', 'digest challenges', (c) async {
    final r = await c.get('/digest-auth/auth/u/p');
    _expect(r.statusCode == 401, 'expected a 401 challenge, got ${r.statusCode}');
    final h = r.headers['www-authenticate'] ?? '';
    _expect(h.toLowerCase().contains('digest'), 'no Digest challenge: $h');
    return '401 with Digest challenge';
  }),

  // ── Dynamic data ──────────────────────────────────────────────────────────
  Check('dynamic', '/bytes/65536 exact length', (c) async {
    final r = await c.get('/bytes/65536');
    _expect(r.bodyBytes.length == 65536, 'got ${r.bodyBytes.length}B');
    return '65536B';
  }),
  Check('dynamic', '/bytes seeded is reproducible', (c) async {
    final a = await c.get('/bytes/1024', query: {'seed': '42'});
    final b = await c.get('/bytes/1024', query: {'seed': '42'});
    _expect(
      const ListEquality().equals(a.bodyBytes, b.bodyBytes),
      'same seed produced different bytes',
    );
    return 'seed=42 reproducible';
  }),
  Check('dynamic', '/uuid', (c) async {
    final v = '${_json(await c.get('/uuid'))['uuid']}';
    _expect(v.length == 36, 'not a uuid: $v');
    return v;
  }),
  Check('dynamic', '/stream/20 lines', (c) async {
    final r = await c.requestStream(HttpMethod.get, '/stream/20');
    final text = StringBuffer();
    await for (final chunk in r.body) {
      text.write(utf8.decode(chunk, allowMalformed: true));
    }
    final lines = text.toString().trim().split('\n').where((l) => l.isNotEmpty);
    _expect(lines.length == 20, 'got ${lines.length} lines');
    return '20 NDJSON lines';
  }),
  Check('dynamic', '/range with Range header', (c) async {
    final r = await c.get('/range/1024',
        headers: HttpHeaders.fromMap({'Range': 'bytes=0-99'}));
    _expect(r.statusCode == 206, 'expected 206, got ${r.statusCode}');
    _expect(r.bodyBytes.length == 100, 'got ${r.bodyBytes.length}B');
    return '206 partial, 100B';
  }),
  Check('dynamic', '/unstable with failure_rate=0', (c) async {
    final r = await c.get('/unstable', query: {'failure_rate': '0', 'seed': '1'});
    _expect(r.statusCode == 200, 'got ${r.statusCode}');
    return 'deterministic 200';
  }),
  Check('dynamic', '/response-headers echoes', (c) async {
    final r = await c.get('/response-headers', query: {'X-Set-By': 'httpbin'});
    _expect(r.headers['x-set-by'] == 'httpbin', 'header not set');
    return 'x-set-by=${r.headers['x-set-by']}';
  }),

  // ── Streaming ─────────────────────────────────────────────────────────────
  Check('streaming', 'stream-bytes (server caps at 100 KiB)', (c) async {
    // httpbin.io truncates /stream-bytes to 102400 no matter what is asked
    // for — verified with curl, so this is the server's limit, not ours.
    const want = 102400;
    final r = await c.requestStream(HttpMethod.get, '/stream-bytes/$want');
    var seen = 0, chunks = 0;
    await for (final chunk in r.body) {
      seen += chunk.length;
      chunks++;
    }
    _expect(seen == want, 'got $seen of $want bytes');
    return '$seen bytes in $chunks chunks';
  }),
  Check('streaming', 'drip (slow body)', (c) async {
    final r = await c.requestStream(
        HttpMethod.get, '/drip?numbytes=2048&duration=2&delay=0');
    var seen = 0;
    await for (final chunk in r.body) {
      seen += chunk.length;
    }
    _expect(seen == 2048, 'got $seen of 2048 bytes');
    return '2048B dripped over ~2s';
  }),

  // ── Timeouts and cancellation ─────────────────────────────────────────────
  Check('control', 'timeout fires', (c) async {
    try {
      await c.get('/delay/5',
          options: const RequestOptions(timeout: Duration(seconds: 2)));
      throw 'no timeout raised';
    } on NitroHttpTimeoutException catch (e) {
      return 'NitroHttpTimeoutException (${e.stage})';
    }
  }),
  Check('control', 'cancel aborts in flight', (c) async {
    final token = CancelToken();
    Future<void>.delayed(
        const Duration(milliseconds: 400), () => token.cancel('probe'));
    try {
      await c.get('/delay/5', cancelToken: token);
      throw 'no cancellation raised';
    } on NitroHttpCancelException catch (e) {
      return 'cancelled: ${e.reason}';
    }
  }),
  Check('control', 'pre-cancelled never opens a socket', (c) async {
    final token = CancelToken()..cancel('before send');
    try {
      await c.get('/get', cancelToken: token);
      throw 'request ran despite a cancelled token';
    } on NitroHttpCancelException catch (e) {
      return 'refused up front: ${e.reason}';
    }
  }),

  // ── Timings ───────────────────────────────────────────────────────────────
  Check('timings', 'phases reported', (c) async {
    final t = (await c.get('/get')).timings;
    _expect(t.total > Duration.zero, 'total timing is zero');
    return 'dns=${t.dns.inMilliseconds}ms tls=${t.tls.inMilliseconds}ms '
        'ttfb=${t.firstByte.inMilliseconds}ms total=${t.total.inMilliseconds}ms';
  }),

  // ── Caching ───────────────────────────────────────────────────────────────
  Check('cache', '/cache/60 second read is a hit', (c) async {
    final dir = Directory.systemTemp.createTempSync('nitro_http_cache');
    NitroHttp.configureCache(HttpCacheConfig(directory: dir.path));
    await c.get('/cache/60');
    final second = await c.get('/cache/60');
    _expect(second.fromCache, 'second read went to the network');
    return 'first=network second=cache';
  }),
  Check('cache', '/etag revalidates', (c) async {
    final first = await c.get('/etag/probe-etag');
    final tag = first.headers['etag'];
    _expect(tag != null, 'no ETag returned');
    final second = await c.get('/etag/probe-etag',
        headers: HttpHeaders.fromMap({'If-None-Match': tag!}));
    _expect(second.statusCode == 304 || second.fromCache,
        'expected 304/cache hit, got ${second.statusCode}');
    return 'etag=$tag -> ${second.statusCode}';
  }),
  Check('cache', '/cache 304 on If-Modified-Since', (c) async {
    final r = await c.get('/cache',
        headers: HttpHeaders.fromMap(
            {'If-Modified-Since': 'Sat, 01 Jan 2028 00:00:00 GMT'}));
    _expect(r.statusCode == 304, 'expected 304, got ${r.statusCode}');
    return 'status 304';
  }),

  // ── Protocol negotiation ──────────────────────────────────────────────────
  // Not httpbin.io: it serves HTTP/1.1 only and can never show an upgrade.
  Check('protocol', 'negotiates h2/h3 (cloudflare)', (_) async {
    final c = NitroHttpClient(
      settings: const ClientSettings(timeout: Duration(seconds: 20)),
    );
    try {
      final r = await c.get('https://cloudflare-quic.com/');
      _expect(r.version != HttpVersion.http11,
          'still HTTP/1.1 — no h2/h3 negotiated');
      return 'negotiated ${r.version.label}';
    } finally {
      c.dispose();
    }
  }),
  // ── TLS trust diagnostics ─────────────────────────────────────────────────
  // Isolates a certificate failure: does TLS work at all, and which root source
  // can verify a public host?
  Check('tls', 'platform roots (default)', (_) async {
    final c = NitroHttpClient(settings: const ClientSettings(
      timeout: Duration(seconds: 20),
      tlsSettings: TlsSettings(rootCaSource: RootCaSource.platform)));
    try {
      return 'status ${(await c.get('$httpbin/get')).statusCode}';
    } finally { c.dispose(); }
  }),
  Check('tls', 'bundled roots', (_) async {
    final c = NitroHttpClient(settings: const ClientSettings(
      timeout: Duration(seconds: 20),
      tlsSettings: TlsSettings(rootCaSource: RootCaSource.bundled)));
    try {
      return 'status ${(await c.get('$httpbin/get')).statusCode}';
    } finally { c.dispose(); }
  }),
  Check('tls', 'verification OFF (transport sanity)', (_) async {
    final c = NitroHttpClient(settings: const ClientSettings(
      timeout: Duration(seconds: 20),
      tlsSettings: TlsSettings.insecure()));
    try {
      return 'status ${(await c.get('$httpbin/get')).statusCode}';
    } finally { c.dispose(); }
  }),
];

/// Minimal list comparison — avoids a dependency just to compare two byte lists.
class ListEquality {
  const ListEquality();
  bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}