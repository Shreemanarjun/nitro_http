/// An in-process HTTP + WebSocket server on `127.0.0.1`, shared by the demo UI
/// and the integration suite.
///
/// Everything the example and the tests exercise is served from here, so the
/// app works with the radio off and the suite cannot flake on somebody's DNS,
/// captive portal or rate limiter. The port is ephemeral (`:0`), so several
/// copies can run side by side.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Size of one page of the deterministic byte generator, in bytes.
///
/// Pages are keyed by index rather than produced by one long sequential
/// generator, so a chunk at any offset can be regenerated without replaying
/// everything before it. That is what lets a test hash a 100 MB body it never
/// holds in memory.
const int deterministicPageBytes = 64 * 1024;

/// The default chunk size of the `/drip` route, in bytes.
///
/// Above `dart:io`'s 8 KiB outgoing buffer on purpose: a smaller chunk would be
/// coalesced with its successors and the route would stop demonstrating
/// anything about backpressure.
const int defaultDripChunkBytes = 16 * 1024;

/// The plain-text payload behind `/gzip` and `/brotli`.
///
/// Deliberately repetitive so both encodings actually shrink it, and short
/// enough that an assertion failure prints something readable.
const String compressiblePayload =
    '{"codec":"test","note":"nitro_http compressed response fixture",'
    '"filler":"0123456789012345678901234567890123456789012345678901234567890123'
    '4567890123456789012345678901234567890123456789012345678901234567890123456789"}';

/// Writes page [pageIndex] of the deterministic stream into [out].
void _fillPage(Uint8List out, int pageIndex, int seed) {
  // xorshift32 seeded from the page index: cheap, and every page is a different
  // sequence, so a duplicated or reordered page changes the hash.
  var state = (pageIndex * 0x9E3779B1 + seed) & 0xFFFFFFFF;
  if (state == 0) state = 0x1F123BB5;
  for (var i = 0; i < out.length; i++) {
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >>> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    out[i] = state & 0xFF;
  }
}

/// The deterministic body `/bytes/<length>` serves, as one buffer.
///
/// Only for lengths small enough to hold in memory; use
/// [deterministicByteStream] for anything large.
Uint8List deterministicBytes(int length, {int seed = 0}) {
  final out = Uint8List(length);
  final page = Uint8List(deterministicPageBytes);
  var offset = 0;
  var index = 0;
  while (offset < length) {
    _fillPage(page, index, seed);
    final take = length - offset < page.length ? length - offset : page.length;
    out.setRange(offset, offset + take, page);
    offset += take;
    index++;
  }
  return out;
}

/// The deterministic body `/bytes/<length>` serves, page by page.
///
/// Never allocates more than [deterministicPageBytes] at a time, so both sides
/// of a 100 MB transfer can produce and verify it without buffering.
Stream<Uint8List> deterministicByteStream(int length, {int seed = 0}) async* {
  var offset = 0;
  var index = 0;
  while (offset < length) {
    final remaining = length - offset;
    final size = remaining < deterministicPageBytes
        ? remaining
        : deterministicPageBytes;
    final page = Uint8List(size);
    _fillPage(page, index, seed);
    yield page;
    offset += size;
    index++;
  }
}

/// The SHA-256 of the first [length] bytes of the deterministic stream,
/// hex-encoded.
///
/// Computed page by page, so asking for the digest of a 100 MB body costs
/// 64 KiB of memory.
Future<String> deterministicDigest(int length, {int seed = 0}) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  await for (final page in deterministicByteStream(length, seed: seed)) {
    input.add(page);
  }
  input.close();
  return sink.value;
}

/// Wraps [payload] in a brotli stream made of one *uncompressed* meta-block.
///
/// Dart has no brotli encoder and pulling in a native one for a 200-byte
/// fixture is absurd, so the container is written by hand. RFC 7932 §9.2 allows
/// a non-final meta-block to carry raw bytes, which every conforming decoder —
/// including the one libcurl links — must accept. A final empty meta-block
/// (`0x03`) terminates the stream.
Uint8List brotliStoredContainer(List<int> payload) {
  if (payload.isEmpty || payload.length > 0x10000) {
    throw ArgumentError.value(
      payload.length,
      'payload.length',
      'must be 1..65536: a single 4-nibble MLEN field encodes the length',
    );
  }
  final mlen = payload.length - 1;
  final out = Uint8List(payload.length + 4);
  // Bit layout, LSB-first: WBITS=0 (window 16), ISLAST=0, MNIBBLES=00 (4
  // nibbles), MLEN-1 (16 bits), ISUNCOMPRESSED=1, then pad to a byte boundary.
  out[0] = (mlen & 0x0F) << 4;
  out[1] = (mlen >> 4) & 0xFF;
  out[2] = ((mlen >> 12) & 0x0F) | 0x10;
  out.setRange(3, 3 + payload.length, payload);
  out[3 + payload.length] = 0x03; // ISLAST=1, ISLASTEMPTY=1.
  return out;
}

/// A record of one request the server handled.
final class ServerHit {
  /// Creates a hit record.
  const ServerHit({
    required this.method,
    required this.path,
    required this.headerNames,
    required this.cookieHeader,
  });

  /// The request method, upper-cased.
  final String method;

  /// The request path, including the leading slash and excluding the query.
  final String path;

  /// Every header name the request carried, lower-cased, in arrival order.
  final List<String> headerNames;

  /// The raw `Cookie` header, or `null` when the request carried none.
  final String? cookieHeader;

  @override
  String toString() => 'ServerHit($method $path)';
}

/// The local test server.
///
/// Start it with [start], read [baseUrl] (or [uri] / [wsUri]), and stop it with
/// [stop]. The introspection getters exist so a test can assert what the server
/// *did not* see — a cache hit is only proven by the request never arriving.
final class LocalServer {
  LocalServer._(this._http, this._blackHole);

  final HttpServer _http;
  final ServerSocket _blackHole;
  final List<ServerHit> _hits = [];
  final List<Socket> _blackHoleSockets = [];

  /// Monotonic counter behind `/cache/<maxAge>`, so a test can tell a body that
  /// came off the wire from a body that came out of the cache.
  int _cacheSerial = 0;

  /// Bytes of the most recent `POST /upload` request body.
  int _lastUploadBytes = 0;

  /// SHA-256 of the most recent `POST /upload` request body, hex-encoded.
  String _lastUploadDigest = '';

  /// Whether the most recent `POST /upload` request body ended prematurely.
  bool _lastUploadTruncated = false;

  /// Length and hex SHA-256 of the last message the `/ws` echo endpoint saw.
  int _lastWebSocketMessageBytes = 0;
  String _lastWebSocketMessageDigest = '';

  /// Binds the server on an ephemeral loopback port and starts serving.
  static Future<LocalServer> start() async {
    // backlog 1024 rather than the default: the benchmark's burst scenario opens
    // 512 connections at once, and a listen queue shorter than that answers the
    // overflow with ECONNREFUSED. That failure then looks like a client defect
    // when it is really the server refusing to queue.
    final http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      backlog: 1024,
    );
    // A listener that accepts TCP connections and then says nothing, ever.
    // Requesting `https://` against it stalls in the TLS handshake, which is
    // inside libcurl's connect phase — the only way to provoke a genuine
    // `TimeoutStage.connect` without depending on a black-holed route.
    final blackHole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = LocalServer._(http, blackHole);
    server._serve();
    return server;
  }

  /// `http://127.0.0.1:<port>` with no trailing slash.
  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  /// `ws://127.0.0.1:<port>` with no trailing slash.
  String get webSocketUrl => 'ws://127.0.0.1:${_http.port}';

  /// A URL that accepts a connection and then never speaks TLS.
  ///
  /// Use it with a short `connectTimeout` to observe
  /// `TimeoutStage.connect`.
  String get blackHoleUrl => 'https://127.0.0.1:${_blackHole.port}';

  /// [baseUrl] joined with [path], which must start with `/`.
  Uri uri(String path) => Uri.parse('$baseUrl$path');

  /// [webSocketUrl] joined with [path], which must start with `/`.
  Uri wsUri(String path) => Uri.parse('$webSocketUrl$path');

  /// Every request handled since the last [resetCounters], oldest first.
  List<ServerHit> get hits => List<ServerHit>.unmodifiable(_hits);

  /// How many requests the server has handled since the last [resetCounters].
  int get totalRequests => _hits.length;

  /// How many requests hit exactly [path].
  int requestsFor(String path) =>
      _hits.where((hit) => hit.path == path).length;

  /// The header names of the most recent request, lower-cased.
  ///
  /// Empty before the first request. This is how a test proves the client sent
  /// `accept-encoding` or `if-none-match` without a proxy in between.
  List<String> get receivedHeaderNames =>
      _hits.isEmpty ? const <String>[] : _hits.last.headerNames;

  /// The `Cookie` header of the most recent request, or `null`.
  String? get lastCookieHeader => _hits.isEmpty ? null : _hits.last.cookieHeader;

  /// Bytes received by the most recent `POST /upload`.
  int get lastUploadBytes => _lastUploadBytes;

  /// Hex SHA-256 of the body received by the most recent `POST /upload`.
  String get lastUploadDigest => _lastUploadDigest;

  /// Whether the most recent `POST /upload` body ended before the client said
  /// it would.
  bool get lastUploadTruncated => _lastUploadTruncated;

  /// Length of the most recent message `/ws` received, in bytes.
  ///
  /// A WebSocket peer reassembles fragments before the application sees them,
  /// so this is the only place a test can prove that a client which framed a
  /// message in N pieces still delivered ONE message of the right size.
  int get lastWebSocketMessageBytes => _lastWebSocketMessageBytes;

  /// Hex SHA-256 of the most recent message `/ws` received.
  String get lastWebSocketMessageDigest => _lastWebSocketMessageDigest;

  /// Clears the request log and the upload bookkeeping.
  void resetCounters() {
    _hits.clear();
    _lastUploadBytes = 0;
    _lastUploadDigest = '';
    _lastUploadTruncated = false;
    _lastWebSocketMessageBytes = 0;
    _lastWebSocketMessageDigest = '';
  }

  /// Stops serving and closes every socket, including parked black-hole ones.
  Future<void> stop() async {
    for (final socket in _blackHoleSockets) {
      socket.destroy();
    }
    _blackHoleSockets.clear();
    await _blackHole.close();
    await _http.close(force: true);
  }

  void _serve() {
    final handler = const Pipeline()
        .addMiddleware(_recordMiddleware)
        .addHandler(_buildRouter().call);

    _http.listen((request) {
      // shelf goes through `dart:io`'s buffered sink, which coalesces small
      // writes. `/drip` exists to put one chunk on the wire at a time, so the
      // buffer has to go before shelf touches the response.
      request.response.bufferOutput = false;
      unawaited(
        shelf_io.handleRequest(request, handler, poweredByHeader: null),
      );
    });

    _blackHole.listen((socket) {
      // Hold the socket open and never write: that is the whole feature.
      _blackHoleSockets.add(socket);
    });
  }

  Handler _recordMiddleware(Handler inner) => (Request request) {
    _hits.add(
      ServerHit(
        method: request.method,
        path: request.requestedUri.path,
        headerNames: request.headers.keys
            .map((name) => name.toLowerCase())
            .toList(growable: false),
        cookieHeader: request.headers['cookie'],
      ),
    );
    return inner(request);
  };

  Router _buildRouter() {
    final router = Router();

    router.get('/echo', _echoDescription);
    for (final verb in const ['POST', 'PUT', 'PATCH', 'DELETE']) {
      router.add(verb, '/echo', _echoBody);
    }
    router.add('OPTIONS', '/echo', _echoDescription);
    router.add('TRACE', '/echo', _echoDescription);
    router.head('/echo', _echoDescription);

    router.get('/bytes/<length>', _bytes);
    router.get('/slow/<ms>', _slow);
    router.get('/drip/<count>/<delayMs>', _drip);
    router.get('/redirect/<hops>', _redirect);
    router.add('POST', '/redirect/<hops>', _redirect);
    router.all('/status/<code>', _status);
    router.get('/gzip', _gzip);
    router.get('/brotli', _brotli);
    router.get('/cache/<maxAge>', _cache);
    router.get('/setcookie', _setCookie);
    router.get('/readcookie', _readCookie);
    // Every body-carrying verb, not just POST: the matrix benchmark measures
    // PUT and PATCH against the same endpoint, and the handler only ever reads
    // the request body and hashes it.
    router.post('/upload', _upload);
    router.put('/upload', _upload);
    router.patch('/upload', _upload);

    // `/ws/close` is registered first: `Router` matches in registration order
    // and `/ws` would otherwise never see a more specific sibling.
    router.get('/ws/close', webSocketHandler(_wsClose));
    router.get('/ws', webSocketHandler(_wsEcho, protocols: const ['echo']));

    return router;
  }

  // ── Routes ─────────────────────────────────────────────────────────────────

  Response _echoDescription(Request request) => _json({
    'method': request.method,
    'path': request.requestedUri.path,
    'query': request.requestedUri.queryParametersAll,
    'headers': {
      for (final entry in request.headers.entries)
        entry.key.toLowerCase(): entry.value,
    },
  });

  Future<Response> _echoBody(Request request) async {
    final body = await _collect(request.read());
    return Response.ok(
      body,
      headers: {
        'content-type':
            request.headers['content-type'] ?? 'application/octet-stream',
        'content-length': '${body.length}',
        'x-echo-method': request.method,
      },
    );
  }

  Response _bytes(Request request, String length) {
    final total = int.tryParse(length);
    if (total == null || total < 0) return _badRequest('bad length');
    return Response.ok(
      deterministicByteStream(total),
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': '$total',
        'x-body-length': '$total',
      },
    );
  }

  Future<Response> _slow(Request request, String ms) async {
    final delay = int.tryParse(ms);
    if (delay == null || delay < 0) return _badRequest('bad delay');
    await Future<void>.delayed(Duration(milliseconds: delay));
    return _json({'delayedMs': delay});
  }

  Response _drip(Request request, String count, String delayMs) {
    final chunks = int.tryParse(count);
    final delay = int.tryParse(delayMs);
    final size =
        int.tryParse(request.url.queryParameters['size'] ?? '') ??
        defaultDripChunkBytes;
    if (chunks == null || delay == null || chunks < 0 || delay < 0 || size < 1) {
      return _badRequest('bad drip parameters');
    }

    // The delay sits *between* chunks, not before the first one. `dart:io`
    // writes response headers lazily on the first body byte, so delaying ahead
    // of chunk 0 would withhold the headers too — and a client could not then
    // tell an idle body apart from a slow response.
    Stream<List<int>> drip() async* {
      for (var i = 0; i < chunks; i++) {
        if (i > 0 && delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        final page = Uint8List(size);
        _fillPage(page, i, 0);
        yield page;
      }
    }

    // No content-length: the response goes out chunked, which is what makes the
    // client's credit loop observable.
    return Response.ok(
      drip(),
      headers: {
        'content-type': 'application/octet-stream',
        'x-drip-chunks': '$chunks',
        'x-drip-chunk-bytes': '$size',
      },
    );
  }

  Response _redirect(Request request, String hops) {
    final remaining = int.tryParse(hops);
    if (remaining == null || remaining < 0) return _badRequest('bad hop count');
    final location = remaining <= 1 ? '/echo' : '/redirect/${remaining - 1}';
    return Response.found(location, headers: {'x-hops-remaining': '$remaining'});
  }

  Response _status(Request request, String code) {
    final status = int.tryParse(code);
    if (status == null || status < 100 || status > 599) {
      return _badRequest('bad status code');
    }
    return Response(
      status,
      body: jsonEncode({'status': status}),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Response _gzip(Request request) {
    final encoded = gzip.encode(utf8.encode(compressiblePayload));
    return Response.ok(
      Uint8List.fromList(encoded),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'content-encoding': 'gzip',
        'content-length': '${encoded.length}',
      },
    );
  }

  Response _brotli(Request request) {
    final encoded = brotliStoredContainer(utf8.encode(compressiblePayload));
    return Response.ok(
      encoded,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'content-encoding': 'br',
        'content-length': '${encoded.length}',
      },
    );
  }

  Response _cache(Request request, String maxAge) {
    final seconds = int.tryParse(maxAge);
    if (seconds == null || seconds < 0) return _badRequest('bad max-age');
    final etag = '"cache-$seconds"';
    final cacheControl = seconds == 0
        ? 'no-cache, max-age=0'
        : 'max-age=$seconds';

    if (request.headers['if-none-match'] == etag) {
      return Response.notModified(
        headers: {'etag': etag, 'cache-control': cacheControl},
      );
    }

    _cacheSerial++;
    return Response.ok(
      jsonEncode({'maxAge': seconds, 'serial': _cacheSerial}),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': cacheControl,
        'etag': etag,
      },
    );
  }

  Response _setCookie(Request request) {
    final query = request.url.queryParameters;
    final name = query['name'] ?? 'sid';
    final value = query['value'] ?? 'local-session';
    final attributes = <String>['Path=/'];
    final maxAge = query['maxAge'];
    if (maxAge != null) attributes.add('Max-Age=$maxAge');
    return Response.ok(
      jsonEncode({'set': name}),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        // A multimap value: shelf writes one `Set-Cookie` line per entry, which
        // is the only correct framing for this header.
        'set-cookie': <String>[
          '$name=$value; ${attributes.join('; ')}',
          'flavour=vanilla; Path=/',
        ],
      },
    );
  }

  Response _readCookie(Request request) {
    final raw = request.headers['cookie'];
    final parsed = <String, String>{};
    if (raw != null) {
      for (final pair in raw.split(';')) {
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        parsed[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
      }
    }
    return _json({'cookie': raw, 'cookies': parsed});
  }

  Future<Response> _upload(Request request) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    var received = 0;
    var truncated = false;
    try {
      await for (final chunk in request.read()) {
        received += chunk.length;
        input.add(chunk);
      }
    } on Object {
      // A client that abandons a streamed body mid-flight lands here. Recording
      // it is what lets a test prove the request failed instead of quietly
      // uploading a short body.
      truncated = true;
    }
    input.close();

    _lastUploadBytes = received;
    _lastUploadDigest = sink.value;
    _lastUploadTruncated = truncated;

    final declared = int.tryParse(request.headers['content-length'] ?? '');
    if (truncated || (declared != null && declared != received)) {
      return Response(
        400,
        body: jsonEncode({
          'bytes': received,
          'declared': declared,
          'truncated': true,
        }),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }

    return _json({
      'bytes': received,
      'sha256': sink.value,
      'contentType': request.headers['content-type'],
    });
  }

  void _wsEcho(WebSocketChannel socket, String? protocol) {
    socket.stream.listen(
      (message) {
        // Recorded BEFORE the echo, and by the peer rather than the client:
        // fragments are reassembled below the application, so this is where a
        // test can prove a fragmented send arrived as one intact message.
        final bytes = message is String
            ? utf8.encode(message)
            : message as List<int>;
        _lastWebSocketMessageBytes = bytes.length;
        _lastWebSocketMessageDigest = sha256.convert(bytes).toString();
        if (socket.closeCode != null) return;
        socket.sink.add(message);
      },
      // A peer that vanishes mid-frame is normal here — several tests abort a
      // transfer on purpose — and must not become an unhandled error.
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  void _wsClose(WebSocketChannel socket, String? protocol) {
    // Close from the server side with an application code, so a client test can
    // assert the code and reason survive the handshake.
    unawaited(socket.sink.close(4001, 'server initiated close'));
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Response _json(Object? value) => Response.ok(
    jsonEncode(value),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Response _badRequest(String reason) => Response(
    400,
    body: jsonEncode({'error': reason}),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static Future<Uint8List> _collect(Stream<List<int>> source) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

/// Captures the hex digest produced by a chunked `sha256` conversion.
final class _DigestSink implements Sink<Digest> {
  String value = '';

  @override
  void add(Digest data) => value = data.toString();

  @override
  void close() {}
}
