/// The `fetch`-backed [RequestExecutor], and the demux that feeds it.
///
/// A browser gives wasm no TCP or UDP socket, so the C++ engine cannot run here.
/// libcurl *can* be compiled to wasm — libcurl.js does it — but only by
/// tunnelling its sockets over a WebSocket to a relay the app operates, without
/// HTTP/3 and at the cost of a second TLS stack. `fetch` is the transport a page
/// actually has, so that is what this uses — through `package:http`'s
/// `BrowserClient`, which already handles the interop, redirects and streaming.
///
/// What that costs is honest and unavoidable: the settings that describe how the
/// engine talks to the network — TLS, proxies, DNS, HTTP version, the
/// connection pool, timings — have no browser equivalent. They throw
/// [NitroHttpConfigurationException] rather than being quietly ignored, because
/// a pinned certificate that silently stops being checked is worse than a build
/// that stops compiling.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api/exceptions.dart';
import '../nitro_http.native.dart';
import 'request_runner.dart';

/// Routes requests through an [http.Client] — `BrowserClient`, and so `fetch`,
/// in a real web build.
///
/// The client is injected rather than constructed here so this library imports
/// nothing browser-only and can therefore be tested on the VM against a fake.
/// `executor_web.dart` supplies the real one.
final class FetchRequestExecutor implements RequestExecutor {
  /// Creates an executor over [client].
  FetchRequestExecutor(http.Client client) : _client = client;

  final http.Client _client;
  final _aborts = <int, StreamSubscription<List<int>>>{};
  final _tokens = <int, Set<int>>{};
  var _disposed = false;

  @override
  void configureClient(RawClientConfig config) {
    // Only the settings a page can actually honour are accepted. The rest would
    // otherwise look configured and do nothing.
    _rejectUnsupported(config);
  }

  void _rejectUnsupported(RawClientConfig config) {
    final unsupported = <String>[
      if (config.proxy.mode != RawProxyMode.system) 'proxySettings',
      if (config.dns.dohUrl.isNotEmpty) 'dnsSettings.dohUrl',
      if (config.tls.pinnedSpkiSha256.isNotEmpty) 'tlsSettings.pinnedSpkiSha256',
      if (config.tls.clientCertPem.isNotEmpty) 'tlsSettings (mTLS)',
      if (config.tls.trustedRootsPem.isNotEmpty) 'tlsSettings.trustedRootsPem',
      if (!config.tls.verifyCertificates) 'tlsSettings.insecure()',
      if (config.enableCache) 'cacheSettings',
    ];
    if (unsupported.isEmpty) return;
    throw NitroHttpConfigurationException(
      engineMessage:
          'not available in the browser: ${unsupported.join(', ')}. The page '
          'has no control over TLS, proxying or DNS — the browser owns them.',
    );
  }

  @override
  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body) async {
    _checkAlive();
    final started = DateTime.now();
    try {
      final response = await _send(request, body);
      final bytes = await response.stream.toBytes();
      return _responseOf(request, response, bytes, started);
    } on http.ClientException catch (error) {
      return _errorResponse(request, error);
    }
  }

  @override
  Future<RawResponseHead> startStreamed(
    RawRequest request,
    Uint8List body,
  ) async {
    _checkAlive();
    final started = DateTime.now();
    final response = await _send(request, body);
    final demux = FetchStreamDemux.instance;

    // The body is pumped into the demux exactly as the native path posts chunks
    // onto the module-global stream, so the runner above is unchanged.
    _aborts[request.requestId] = response.stream.listen(
      (chunk) => demux.pushChunk(
        ChunkEvent(
          requestId: request.requestId,
          kind: 0,
          aux: 0,
          bytes: chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
        ),
      ),
      onError: (Object error) => demux.pushChunk(
        ChunkEvent(
          requestId: request.requestId,
          kind: 2,
          aux: RawErrorKind.io.index,
          bytes: Uint8List.fromList('$error'.codeUnits),
        ),
      ),
      onDone: () {
        demux.pushChunk(
          ChunkEvent(
            requestId: request.requestId,
            kind: 1,
            aux: 0,
            bytes: Uint8List(0),
          ),
        );
        _aborts.remove(request.requestId);
      },
      cancelOnError: true,
    );

    return _headOf(request, response, started);
  }

  Future<http.StreamedResponse> _send(RawRequest request, Uint8List body) {
    final out = http.Request(
      _methodOf(request),
      Uri.parse(request.url),
    );
    for (final header in request.headers) {
      out.headers[header.name] = header.value;
    }
    if (body.isNotEmpty) out.bodyBytes = body;
    // `-1` is the inherit sentinel; anything non-zero means follow.
    out.followRedirects = request.options.followRedirects != 0;
    if (request.options.maxRedirects > 0) {
      out.maxRedirects = request.options.maxRedirects;
    }
    return _client.send(out);
  }

  String _methodOf(RawRequest request) =>
      request.customMethod.isNotEmpty
      ? request.customMethod
      : request.method.name.toUpperCase();

  RawResponseHead _headOf(
    RawRequest request,
    http.StreamedResponse response,
    DateTime started,
  ) => RawResponseHead(
    requestId: request.requestId,
    errorKind: RawErrorKind.none,
    errorMessage: '',
    engineErrorCode: 0,
    statusCode: response.statusCode,
    reasonPhrase: response.reasonPhrase ?? '',
    version: RawHttpVersion.http11,
    finalUrl: response.request?.url.toString() ?? request.url,
    redirectCount: 0,
    headers: [
      for (final entry in response.headers.entries)
        RawHeader(name: entry.key, value: entry.value),
    ],
    fromCache: false,
    contentLength: response.contentLength ?? -1,
    primaryIp: '',
    primaryPort: 0,
    timings: _timingsSince(started),
  );

  RawResponse _responseOf(
    RawRequest request,
    http.StreamedResponse response,
    Uint8List body,
    DateTime started,
  ) {
    final head = _headOf(request, response, started);
    return RawResponse(
      requestId: head.requestId,
      errorKind: head.errorKind,
      errorMessage: head.errorMessage,
      engineErrorCode: head.engineErrorCode,
      statusCode: head.statusCode,
      reasonPhrase: head.reasonPhrase,
      version: head.version,
      finalUrl: head.finalUrl,
      redirectCount: head.redirectCount,
      headers: head.headers,
      body: body,
      fromCache: false,
      revalidated: false,
      primaryIp: head.primaryIp,
      primaryPort: head.primaryPort,
      timings: head.timings,
    );
  }

  RawResponse _errorResponse(RawRequest request, http.ClientException error) =>
      RawResponse(
        requestId: request.requestId,
        // `fetch` reports every network failure as one opaque TypeError, on
        // purpose: distinguishing DNS from refused from CORS would be a
        // cross-origin information leak. So this cannot be classified further.
        errorKind: RawErrorKind.io,
        errorMessage: error.message,
        engineErrorCode: 0,
        statusCode: 0,
        reasonPhrase: '',
        version: RawHttpVersion.http11,
        finalUrl: request.url,
        redirectCount: 0,
        headers: const [],
        body: Uint8List(0),
        fromCache: false,
        revalidated: false,
        primaryIp: '',
        primaryPort: 0,
        timings: _timingsSince(DateTime.now()),
      );

  RawTimings _timingsSince(DateTime started) {
    // A page cannot see DNS, connect or TLS separately; only the total is real,
    // and the rest stay zero rather than being invented.
    final total = DateTime.now().difference(started).inMicroseconds / 1000.0;
    return RawTimings(
      queueMs: 0,
      dnsMs: 0,
      connectMs: 0,
      tlsMs: 0,
      firstByteMs: 0,
      redirectMs: 0,
      totalMs: total,
    );
  }

  void _checkAlive() {
    if (_disposed) throw NitroHttpDisposedException();
  }

  @override
  void cancel(int requestId) {
    unawaited(_aborts.remove(requestId)?.cancel());
    FetchStreamDemux.instance.release(requestId);
  }

  @override
  void cancelAll() {
    for (final id in _aborts.keys.toList()) {
      cancel(id);
    }
  }

  @override
  void cancelToken(int tokenId, String reason) {
    for (final id in _tokens[tokenId]?.toList() ?? const <int>[]) {
      cancel(id);
    }
  }

  @override
  void releaseCancelToken(int tokenId) => _tokens.remove(tokenId);

  // `fetch` applies its own backpressure through the reader, so there is no
  // credit window to grant.
  @override
  void grantCredit(int requestId, int chunkCount, int ackedChunks) {}

  @override
  int feedUploadChunk(int requestId, Uint8List chunk) =>
      throw NitroHttpConfigurationException(
        engineMessage:
            'streamed uploads are not available in the browser: a request body '
            'must be complete before fetch is called. Send the body as bytes.',
      );

  @override
  void finishUpload(int requestId) {}

  @override
  void failUpload(int requestId, String message) {}

  @override
  List<RawCookie> getCookies(String url) => const [];

  @override
  void setCookie(RawCookie cookie) {}

  @override
  void clearCookies() {}

  @override
  void flushCookies() {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
    _client.close();
  }
}

/// The browser counterpart of the native demux.
///
/// The native one splits a single module-global stream by `requestId`; here each
/// response is already its own stream, so this only has to hand the runner the
/// per-request controller it expects.
final class FetchStreamDemux implements StreamDemux {
  FetchStreamDemux._();

  /// The process-wide instance, matching the native demux's shape.
  static final FetchStreamDemux instance = FetchStreamDemux._();

  final _chunks = <int, StreamController<ChunkEvent>>{};
  final _events = <int, StreamController<RawEvent>>{};

  StreamController<ChunkEvent> _chunkController(int requestId) =>
      _chunks.putIfAbsent(requestId, StreamController<ChunkEvent>.new);

  /// Pushes one body chunk to whoever is reading [ChunkEvent.requestId].
  void pushChunk(ChunkEvent event) {
    final controller = _chunkController(event.requestId);
    if (!controller.isClosed) controller.add(event);
  }

  @override
  Stream<ChunkEvent> chunks(int requestId) => _chunkController(requestId).stream;

  @override
  Stream<RawEvent> events(int requestId) => _events
      .putIfAbsent(requestId, StreamController<RawEvent>.new)
      .stream;

  @override
  void release(int requestId) {
    unawaited(_chunks.remove(requestId)?.close());
    unawaited(_events.remove(requestId)?.close());
  }
}
