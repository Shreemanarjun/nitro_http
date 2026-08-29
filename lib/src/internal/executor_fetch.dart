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
import '../api/settings.dart';
import '../nitro_http.native.dart';
import 'request_runner.dart';

/// The fetch cache mode chosen for a request, keyed by the request itself.
///
/// `package:http` gives a request no room for transport options. Carrying the
/// mode as a header would work, but the client would then have to strip a
/// header out of the caller's own map — and would silently eat it if a caller
/// ever set that name themselves. An [Expando] keeps it off the request
/// entirely: nothing to strip, nothing to collide with, and it disappears with
/// the request it belongs to.
final Expando<String> fetchCacheMode = Expando<String>('fetchCacheMode');

/// Maps a [RawCacheMode] onto the `fetch` cache mode that means the same thing.
///
/// The two vocabularies line up almost exactly, which is why the disk-cache
/// settings can be refused on web while the per-request mode still works: the
/// browser runs the cache, and this says how to use it.
String fetchCacheModeOf(RawCacheMode mode) => switch (mode) {
  RawCacheMode.normal => 'default',
  RawCacheMode.noStore => 'no-store',
  // "Ignore what is stored and go to the network", which is `reload` — not
  // `no-cache`, which would still revalidate against the entry.
  RawCacheMode.bypass => 'reload',
  RawCacheMode.onlyIfCached => 'only-if-cached',
  RawCacheMode.refresh => 'no-cache',
};

/// Per-phase timings a page can see, or null when the browser has none.
typedef TimingsLookup = RawTimings? Function(String url);

/// Turns Resource Timing milestones into the timings the engine reports.
///
/// Every figure is milliseconds **from the start of the request**, not the
/// length of that phase, because that is what `CURLINFO_*_TIME_T` means on the
/// native side and `HttpTimings` has to mean one thing everywhere.
///
/// A reused connection legitimately reports zero for DNS and connect: the
/// browser records those milestones as equal to the start. Cross-origin entries
/// are zeroed altogether unless the server sends `Timing-Allow-Origin`, which
/// leaves only the total real — the same shape the wall-clock fallback has.
RawTimings timingsFromMilestones({
  required double start,
  required double domainLookupEnd,
  required double connectEnd,
  required double secureConnectionStart,
  required double responseStart,
  required double redirectEnd,
  required double duration,
}) {
  double since(double milestone) {
    final value = milestone - start;
    return value > 0 ? value : 0;
  }

  return RawTimings(
    // A page has no queue: `fetch` starts when it is called.
    queueMs: 0,
    dnsMs: since(domainLookupEnd),
    connectMs: since(connectEnd),
    // TLS finishes when the connection does; zero when the scheme is plain.
    tlsMs: secureConnectionStart > 0 ? since(connectEnd) : 0,
    firstByteMs: since(responseStart),
    redirectMs: since(redirectEnd),
    totalMs: duration,
  );
}

/// Routes requests through an [http.Client] — `BrowserClient`, and so `fetch`,
/// in a real web build.
///
/// The client is injected rather than constructed here so this library imports
/// nothing browser-only and can therefore be tested on the VM against a fake.
/// `executor_web.dart` supplies the real one.
/// Whether a request body goes up as a `ReadableStream` rather than buffered.
///
/// Lives here rather than beside the `fetch` call because it is a decision, and
/// the interop file cannot be tested off web. Two things veto streaming: a
/// browser that cannot do it at all, and `keepalive`, which the Fetch
/// specification forbids from carrying a stream body — a keepalive request has
/// to be buffered, which its 64 KiB budget makes reasonable anyway.
bool streamsUploadBody({
  required bool isStreamed,
  required bool keepAlive,
  required bool browserSupportsStreaming,
}) => isStreamed && !keepAlive && browserSupportsStreaming;

/// Internal signal that the ceiling was passed mid-body. Never escapes this
/// file — `sendBuffered` turns it into a `responseTooLarge` response.
final class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}

final class FetchRequestExecutor implements RequestExecutor {
  /// Creates an executor over [client].
  ///
  /// [setCredentials] is how the browser-only wiring exposes
  /// `BrowserClient.withCredentials` without this library importing it — that
  /// import is what would make the file uncompilable, and untestable, off web.
  FetchRequestExecutor(
    http.Client client, {
    void Function(bool)? setCredentials,
    TimingsLookup? timings,
    this.unsupported = UnsupportedSettingPolicy.reject,
  }) : _client = client,
       // ignore: prefer_initializing_formals
       _setCredentials = setCredentials,
       // ignore: prefer_initializing_formals
       _timings = timings;

  final http.Client _client;
  final void Function(bool)? _setCredentials;
  final TimingsLookup? _timings;
  /// What to do with a setting a browser cannot honour.
  final UnsupportedSettingPolicy unsupported;
  final _aborts = <int, StreamSubscription<List<int>>>{};
  final _tokens = <int, Set<int>>{};
  /// In-flight requests that can still be given up on, by request id.
  final _pending = <int, Completer<RawResponse>>{};
  /// The request behind each in-flight id, so a cancellation can name it.
  final _cancelledRequests = <int, RawRequest>{};
  /// Sinks for streamed request bodies, by request id. A streamed upload is
  /// fed chunk by chunk by the runner long after `send` was called, so the body
  /// has to be a stream the client pulls from rather than bytes.
  final _uploads = <int, StreamController<List<int>>>{};

  /// Tokens cancelled already. A caller can cancel before the request is even
  /// registered — the engine handles that by refusing the token in `startTask`
  /// before opening a socket, and this is the same refusal.
  final _cancelledTokens = <int>{};
  RawClientConfig? _config;
  var _disposed = false;

  @override
  void configureClient(RawClientConfig config) {
    // Only the settings a page can actually honour are accepted. The rest would
    // otherwise look configured and do nothing.
    _rejectUnsupported(config);
    _config = config;
    // The browser owns the jar, but it will only attach it cross-origin when
    // credentials are requested. `cookies.enabled` is the closest thing the
    // caller already says, so honour it rather than inventing a web-only knob.
    _setCredentials?.call(config.cookies.enabled);
  }

  /// The response ceiling in bytes, or 0 when there is none.
  ///
  /// The native engine enforces this with `CURLOPT_MAXFILESIZE_LARGE` plus a
  /// running count; here both halves are done by hand, which is the same
  /// guarantee: a declared `Content-Length` over the limit fails before the body
  /// is read, and a body that grows past it fails partway.
  int get _maxResponseBytes => _config?.maxResponseBytes ?? 0;

  String _tooLargeMessage(int limit) =>
      'response body exceeds the configured limit of $limit bytes';

  /// The deadline for [request], or null when neither it nor the client set one.
  ///
  /// `fetch` cannot separate connecting from transferring, so `connectTimeout`
  /// and `timeout` both bound the whole call and the shorter one wins. That is
  /// stricter than the engine, never looser, so a request that would have timed
  /// out natively still does.
  Duration? _deadlineFor(RawRequest request) {
    final candidates = <int>[
      request.options.requestTimeoutMs,
      request.options.connectTimeoutMs,
      _config?.requestTimeoutMs ?? -1,
      _config?.connectTimeoutMs ?? -1,
    ].where((ms) => ms > 0);
    if (candidates.isEmpty) return null;
    return Duration(milliseconds: candidates.reduce((a, b) => a < b ? a : b));
  }

  /// Registers [requestId] so `cancel` and `cancelToken` can reach it.
  void _track(RawRequest request, Completer<RawResponse> pending) {
    _pending[request.requestId] = pending;
    _cancelledRequests[request.requestId] = request;
    final tokenId = request.options.cancelTokenId;
    if (tokenId > 0) {
      (_tokens[tokenId] ??= <int>{}).add(request.requestId);
    }
  }

  void _untrack(int requestId) {
    _pending.remove(requestId);
    _cancelledRequests.remove(requestId);
    for (final ids in _tokens.values) {
      ids.remove(requestId);
    }
  }

  /// A page has no filesystem to write to, so `saveToPath` cannot be honoured.
  ///
  /// Refused whatever [unsupported] says, unlike a transport setting: ignoring a
  /// destination would hand the caller a successful response and no file, and
  /// there would be nothing to tell them the download went nowhere.
  void _rejectFileDestination(RawRequest request) {
    if (request.responseFilePath.isEmpty) return;
    throw NitroHttpConfigurationException(
      engineMessage:
          'downloadToFile is not available in the browser: a page cannot write '
          'to a path. Read the body and hand it to the download the user asked '
          'for instead.',
    );
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
      if (config.hstsCachePath.isNotEmpty) 'hstsCachePath',
      if (config.unixSocketPath.isNotEmpty) 'unixSocketPath',
      if (config.networkInterface.isNotEmpty) 'networkInterface',
    ];
    if (unsupported.isEmpty) return;
    // The caller has said they know these do nothing here — usually so one
    // `ClientSettings` can serve native and web without a `kIsWeb` branch at
    // every call site.
    if (this.unsupported == UnsupportedSettingPolicy.ignore) return;
    throw NitroHttpConfigurationException(
      engineMessage:
          'not available in the browser: ${unsupported.join(', ')}. The page '
          'has no control over TLS, proxying, DNS or its own sockets — the '
          'browser owns them.',
    );
  }

  @override
  Future<RawResponse> sendBuffered(RawRequest request, Uint8List body) async {
    _checkAlive();
    _rejectFileDestination(request);
    final started = DateTime.now();
    if (_isAlreadyCancelled(request)) {
      return _failed(
        request,
        RawErrorKind.cancelled,
        'the request was cancelled',
        started,
      );
    }
    // Given up on either by `cancel` or by the deadline below. `fetch` itself
    // keeps running — `package:http` exposes no per-request abort — so this
    // stops the caller waiting rather than stopping the bytes. Documented on
    // `cancel`, because the difference is observable as traffic.
    final pending = Completer<RawResponse>();
    _track(request, pending);

    final limit = _maxResponseBytes;

    Future<RawResponse> transfer() async {
      final response = await _send(request, body);
      if (limit > 0 &&
          (response.contentLength ?? -1) > limit) {
        // Nothing has been read yet, so this is the cheap refusal — the same one
        // `CURLOPT_MAXFILESIZE_LARGE` makes natively.
        return _failed(
          request,
          RawErrorKind.responseTooLarge,
          _tooLargeMessage(limit),
          started,
        );
      }
      // Read through a subscription rather than `toBytes()`: BrowserClient
      // wires an AbortController to this stream, so cancelling the subscription
      // aborts the fetch itself instead of merely abandoning the future.
      final collected = BytesBuilder(copy: false);
      final finished = Completer<void>();
      final total = response.contentLength ?? -1;
      late final StreamSubscription<List<int>> sub;
      sub = response.stream.listen(
        (chunk) {
          collected.add(chunk);
          if (limit > 0 && collected.length > limit) {
            // Cancelling the subscription aborts the fetch, so an oversized
            // body stops arriving rather than being read and thrown away.
            unawaited(sub.cancel());
            _aborts.remove(request.requestId);
            if (!finished.isCompleted) {
              finished.completeError(const _ResponseTooLarge());
            }
            return;
          }
          _reportProgress(request.requestId, collected.length, total);
        },
        onError: finished.completeError,
        onDone: finished.complete,
        cancelOnError: true,
      );
      _aborts[request.requestId] = sub;
      try {
        await finished.future;
      } finally {
        _aborts.remove(request.requestId);
      }
      return _responseOf(request, response, collected.takeBytes(), started);
    }

    try {
      var race = Future.any<RawResponse>([transfer(), pending.future]);
      final deadline = _deadlineFor(request);
      if (deadline != null) {
        race = race.timeout(deadline);
      }
      return await race;
    } on TimeoutException {
      return _failed(
        request,
        RawErrorKind.timeoutRequest,
        'the request exceeded its deadline',
        started,
      );
    } on _ResponseTooLarge {
      return _failed(
        request,
        RawErrorKind.responseTooLarge,
        _tooLargeMessage(limit),
        started,
      );
    } on http.ClientException catch (error) {
      return _errorResponse(request, error);
    } finally {
      _untrack(request.requestId);
    }
  }

  @override
  Future<RawResponseHead> startStreamed(
    RawRequest request,
    Uint8List body,
  ) async {
    _checkAlive();
    _rejectFileDestination(request);
    final started = DateTime.now();
    if (_isAlreadyCancelled(request)) {
      final demux = FetchStreamDemux.instance;
      scheduleMicrotask(
        () => demux.pushChunk(
          ChunkEvent(
            requestId: request.requestId,
            kind: 2,
            aux: RawErrorKind.cancelled.index,
            bytes: Uint8List.fromList('the request was cancelled'.codeUnits),
          ),
        ),
      );
      return _headOfCancelled(request);
    }
    final response = await _send(request, body);
    final demux = FetchStreamDemux.instance;
    final total = response.contentLength ?? -1;
    final limit = _maxResponseBytes;
    var received = 0;

    if (limit > 0 && total > limit) {
      scheduleMicrotask(
        () => demux.pushChunk(
          ChunkEvent(
            requestId: request.requestId,
            kind: 2,
            aux: RawErrorKind.responseTooLarge.index,
            bytes: Uint8List.fromList(_tooLargeMessage(limit).codeUnits),
          ),
        ),
      );
      return _headOf(request, response, started);
    }

    // The body is pumped into the demux exactly as the native path posts chunks
    // onto the module-global stream, so the runner above is unchanged.
    _aborts[request.requestId] = response.stream.listen(
      (chunk) {
        received += chunk.length;
        if (limit > 0 && received > limit) {
          unawaited(_aborts.remove(request.requestId)?.cancel());
          demux.pushChunk(
            ChunkEvent(
              requestId: request.requestId,
              kind: 2,
              aux: RawErrorKind.responseTooLarge.index,
              bytes: Uint8List.fromList(_tooLargeMessage(limit).codeUnits),
            ),
          );
          return;
        }
        demux.pushChunk(
          ChunkEvent(
            requestId: request.requestId,
            kind: 0,
            aux: 0,
            bytes: chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          ),
        );
        _reportProgress(request.requestId, received, total);
      },
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
    if (request.bodyKind == RawBodyKind.streamed) {
      return _sendStreamed(request);
    }
    final out = http.Request(
      _methodOf(request),
      Uri.parse(request.url),
    );
    for (final header in request.headers) {
      out.headers[header.name] = header.value;
    }
    if (body.isNotEmpty) out.bodyBytes = body;
    fetchCacheMode[out] = fetchCacheModeOf(request.options.cacheMode);
    // `-1` is the inherit sentinel; anything non-zero means follow.
    out.followRedirects = request.options.followRedirects != 0;
    if (request.options.maxRedirects > 0) {
      out.maxRedirects = request.options.maxRedirects;
    }
    return _client.send(out);
  }

  /// Sends a request whose body arrives after the call, via [feedUploadChunk].
  ///
  /// Whether this reaches the network as a real streamed upload depends on the
  /// browser: only some can put a `ReadableStream` in a request body. The rest
  /// buffer it in the client, which costs memory but sends the same bytes —
  /// better than refusing an upload outright, which is what this used to do.
  Future<http.StreamedResponse> _sendStreamed(RawRequest request) {
    final controller = StreamController<List<int>>();
    _uploads[request.requestId] = controller;

    final out = http.StreamedRequest(
      _methodOf(request),
      Uri.parse(request.url),
    );
    for (final header in request.headers) {
      out.headers[header.name] = header.value;
    }
    if (request.options.uploadContentLength >= 0) {
      out.contentLength = request.options.uploadContentLength;
    }
    fetchCacheMode[out] = fetchCacheModeOf(request.options.cacheMode);
    out.followRedirects = request.options.followRedirects != 0;

    controller.stream.listen(
      out.sink.add,
      onError: out.sink.addError,
      onDone: out.sink.close,
      cancelOnError: true,
    );
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
    timings: _timingsFor(
      response.request?.url.toString() ?? request.url,
      started,
    ),
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
      _failed(
        request,
        // `fetch` reports every network failure as one opaque TypeError, on
        // purpose: distinguishing DNS from refused from CORS would be a
        // cross-origin information leak. So this cannot be classified further.
        RawErrorKind.io,
        error.message,
        DateTime.now(),
      );

  RawResponse _failed(
    RawRequest request,
    RawErrorKind kind,
    String message,
    DateTime started,
  ) =>
      RawResponse(
        requestId: request.requestId,
        errorKind: kind,
        errorMessage: message,
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
        timings: _timingsSince(started),
      );

  /// Publishes a download-progress event, the same shape the engine posts.
  ///
  /// Upload progress has no counterpart: `fetch` takes the whole body at once
  /// and reports nothing about sending it, so `onSendProgress` stays silent on
  /// web rather than being faked from the byte count.
  void _reportProgress(int requestId, int received, int total) {
    FetchStreamDemux.instance.pushEvent(
      RawEvent(
        requestId: requestId,
        kind: RawEventKind.downloadProgress,
        a: received,
        b: total,
        message: '',
      ),
    );
  }

  /// True when the request's token was cancelled before it could be sent.
  bool _isAlreadyCancelled(RawRequest request) {
    final tokenId = request.options.cancelTokenId;
    return tokenId > 0 && _cancelledTokens.contains(tokenId);
  }

  RawResponseHead _headOfCancelled(RawRequest request) => RawResponseHead(
    requestId: request.requestId,
    errorKind: RawErrorKind.cancelled,
    errorMessage: 'the request was cancelled',
    engineErrorCode: 0,
    statusCode: 0,
    reasonPhrase: '',
    version: RawHttpVersion.http11,
    finalUrl: request.url,
    redirectCount: 0,
    headers: const [],
    fromCache: false,
    contentLength: -1,
    primaryIp: '',
    primaryPort: 0,
    timings: _timingsSince(DateTime.now()),
  );

  /// A stand-in for a request that has already been forgotten.
  RawRequest _placeholder(int requestId) => RawRequest(
    requestId: requestId,
    method: RawMethod.get,
    customMethod: '',
    url: '',
    headers: const [],
    bodyKind: RawBodyKind.none,
    bodyFilePath: '',
    options: const RawRequestOptions(
      connectTimeoutMs: -1,
      requestTimeoutMs: -1,
      followRedirects: 1,
      maxRedirects: -1,
      cacheMode: RawCacheMode.normal,
      reportProgress: false,
      wantTimings: false,
      uploadContentLength: -1,
      pinnedSpkiOverride: '',
      cancelTokenId: 0,
    ),
  );

  /// Real per-phase timings when the browser has them, else the wall clock.
  RawTimings _timingsFor(String url, DateTime started) =>
      _timings?.call(url) ?? _timingsSince(started);

  RawTimings _timingsSince(DateTime started) {
    // Only the total is real. A page can read per-phase figures from the
    // Resource Timing API in principle, but nothing here has been shown to do
    // it reliably, so the phases stay zero rather than being invented.
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
    // Cancelling the subscription aborts the fetch itself, because the client
    // ties an AbortController to the response stream.
    unawaited(_aborts.remove(requestId)?.cancel());
    // A buffered request is also waiting on this, and without it the caller
    // would sit there until the transfer finished on its own.
    final pending = _pending.remove(requestId);
    if (pending != null && !pending.isCompleted) {
      pending.complete(
        _failed(
          _cancelledRequests[requestId] ?? _placeholder(requestId),
          RawErrorKind.cancelled,
          'the request was cancelled',
          DateTime.now(),
        ),
      );
    }
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
    // Remembered as well as applied: a caller can cancel before the request is
    // registered, and the next send on this token must then refuse rather than
    // go out on the wire.
    _cancelledTokens.add(tokenId);
    for (final id in _tokens[tokenId]?.toList() ?? const <int>[]) {
      cancel(id);
    }
  }

  @override
  void releaseCancelToken(int tokenId) {
    _tokens.remove(tokenId);
    _cancelledTokens.remove(tokenId);
  }

  // `fetch` applies its own backpressure through the reader, so there is no
  // credit window to grant.
  @override
  void grantCredit(int requestId, int chunkCount, int ackedChunks) {}

  @override
  int feedUploadChunk(int requestId, Uint8List chunk) {
    final controller = _uploads[requestId];
    if (controller == null || controller.isClosed) return 0;
    controller.add(chunk);
    // The runner pauses its source on this figure. A browser gives no view of
    // what has actually left the machine, so report what is waiting to be read.
    return controller.hasListener ? chunk.length : 0;
  }

  @override
  void finishUpload(int requestId) {
    unawaited(_uploads.remove(requestId)?.close());
  }

  @override
  void failUpload(int requestId, String message) {
    final controller = _uploads.remove(requestId);
    if (controller == null) return;
    // An errored sink aborts the request rather than sending a short body.
    controller.addError(NitroHttpConfigurationException(engineMessage: message));
    unawaited(controller.close());
  }

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
    for (final controller in _uploads.values.toList()) {
      unawaited(controller.close());
    }
    _uploads.clear();
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

  /// Hands one progress event to whoever is reading [RawEvent.requestId].
  void pushEvent(RawEvent event) {
    final controller = _events.putIfAbsent(
      event.requestId,
      StreamController<RawEvent>.new,
    );
    if (!controller.isClosed) controller.add(event);
  }

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
