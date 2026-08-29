/// A `fetch` client that exposes the options `package:http` does not.
///
/// `BrowserClient` covers the common case but hides `RequestInit.cache`, and a
/// page's cache mode is the one piece of the disk-cache API a browser *can*
/// honour — it runs the cache itself. This subclasses [http.BaseClient] so the
/// executor keeps its `http.Client` seam and every VM test still applies; only
/// the interop lives here, where it cannot be tested off web.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../api/settings.dart' show ReferrerPolicy;
import '../nitro_http.native.dart';
import 'executor_fetch.dart'
    show fetchCacheMode, streamsUploadBody, timingsFromMilestones;

/// Sends requests with `fetch`, honouring the cache mode the executor sets.
class NitroFetchClient extends http.BaseClient {
  /// Starts collecting Resource Timing immediately.
  ///
  /// Not left to the first lookup: `PerformanceObserver` delivers even its
  /// buffered entries asynchronously, so an observer created while the first
  /// response is being read has nothing in it yet and that request alone falls
  /// back to the wall clock.
  NitroFetchClient({this.keepAlive = false, this.referrerPolicy}) {
    _ensureObserving();
  }

  /// Whether requests may outlive the page. See `ClientSettings.keepAlive`.
  final bool keepAlive;

  /// How much of the referring URL to disclose, or null for the browser's
  /// default.
  final ReferrerPolicy? referrerPolicy;

  /// Whether cookies ride along on cross-origin requests.
  bool withCredentials = false;

  final _aborters = <web.AbortController>{};
  var _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('Client is closed', request.url);
    }

    final headers = <String, String>{...request.headers};
    // A transport option, not a header: the executor attaches it to the request
    // object, so the caller's own headers are passed through untouched.
    final cache = fetchCacheMode[request] ?? 'default';

    final controller = web.AbortController();
    _aborters.add(controller);

    final init = web.RequestInit(
      method: request.method,
      headers: headers.jsify()! as web.HeadersInit,
      credentials: withCredentials ? 'include' : 'same-origin',
      redirect: request.followRedirects ? 'follow' : 'error',
      signal: controller.signal,
      cache: cache,
    );

    final referrer = referrerPolicy;
    if (referrer != null) init.referrerPolicy = referrer.wireName;

    if (keepAlive) init.keepalive = true;

    if (streamsUploadBody(
      isStreamed: request is http.StreamedRequest,
      keepAlive: keepAlive,
      browserSupportsStreaming: supportsStreamingUpload(),
    )) {
      // The body goes up as it arrives. `duplex: 'half'` is mandatory for a
      // stream body and means "finish sending before reading the response",
      // which is the only mode any browser implements.
      init.body = _readableStreamOf(request.finalize());
      init.duplex = 'half';
    } else {
      // Either a plain body, or a streamed one on a browser that cannot send a
      // stream — buffer it and send the same bytes.
      final body = await request.finalize().toBytes();
      if (body.isNotEmpty) init.body = body.toJS;
    }

    final web.Response response;
    try {
      response = await web.window
          .fetch(request.url.toString().toJS, init)
          .toDart;
    } catch (error) {
      _aborters.remove(controller);
      // `fetch` rejects with one opaque TypeError whatever went wrong, on
      // purpose — telling DNS from refused from CORS would leak cross-origin
      // information. Nothing more specific can honestly be reported.
      throw http.ClientException('$error', request.url);
    }

    final responseHeaders = <String, String>{};
    (response.headers as _IterableHeaders).forEach(
      (String value, String key, [JSAny? _]) {
        responseHeaders[key.toLowerCase()] = value;
      }.toJS,
    );

    final length = response.headers.get('content-length');
    return http.StreamedResponse(
      _read(response, controller),
      response.status,
      contentLength: length == null ? null : int.tryParse(length),
      request: request,
      headers: responseHeaders,
      reasonPhrase: response.statusText,
    );
  }

  /// Pumps the response body, aborting the fetch if the consumer stops reading.
  Stream<List<int>> _read(
    web.Response response,
    web.AbortController controller,
  ) async* {
    final body = response.body;
    if (body == null) {
      _aborters.remove(controller);
      return;
    }
    final reader = body.getReader() as web.ReadableStreamDefaultReader;
    try {
      while (true) {
        final chunk = await reader.read().toDart;
        if (chunk.done) return;
        final value = chunk.value;
        if (value == null) continue;
        yield (value as JSUint8Array).toDart;
      }
    } finally {
      _aborters.remove(controller);
      // Reaching here without `done` means the consumer walked away — cancel
      // the token so the browser stops downloading rather than finishing into
      // nothing.
      controller.abort();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final controller in _aborters.toList()) {
      controller.abort();
    }
    _aborters.clear();
  }
}

/// The newest Resource Timing entry seen for each URL.
///
/// Collected by an observer rather than read on demand: the entry is recorded
/// when the browser finishes the resource, which is *after* the fetch promise
/// resolves, so a lookup at response time loses the race.
final _timings = <String, web.PerformanceResourceTiming>{};
web.PerformanceObserver? _observer;

void _ensureObserving() {
  if (_observer != null) return;
  final observer = web.PerformanceObserver(
    (web.PerformanceObserverEntryList list, web.PerformanceObserver _) {
      for (final entry in list.getEntries().toDart) {
        if (entry.entryType == 'resource') {
          _timings[entry.name] = entry as web.PerformanceResourceTiming;
        }
      }
    }.toJS,
  );
  // `buffered` replays entries recorded before this ran, so the first request
  // of a session is not the one that misses out.
  observer.observe(
    web.PerformanceObserverInit(type: 'resource', buffered: true),
  );
  _observer = observer;
}

/// Reads the browser's own timing for [url], or null when it has none.
///
/// Reported the way the engine reports it: each figure is milliseconds **from
/// the start of the request**, not the duration of that phase, because that is
/// what `CURLINFO_*_TIME_T` means natively and `HttpTimings` has to mean the
/// same thing on every platform.
///
/// Cross-origin entries are zeroed unless the server sends
/// `Timing-Allow-Origin`; the phases then collapse to zero and only the total
/// is real, which is what the wall-clock fallback already reports.
RawTimings? resourceTimingFor(String url) {
  _ensureObserving();
  final absolute = Uri.base.resolve(url).toString();
  // The observer is the reliable path, but its callback is asynchronous, so on
  // a fast connection the very first request can finish before delivery. The
  // buffer itself is already populated by then, so read it directly first.
  final entry =
      _newestEntry(absolute) ?? _timings[absolute] ?? _timings[url];

  if (entry == null) return null;

  return timingsFromMilestones(
    start: entry.startTime,
    domainLookupEnd: entry.domainLookupEnd,
    connectEnd: entry.connectEnd,
    secureConnectionStart: entry.secureConnectionStart,
    responseStart: entry.responseStart,
    redirectEnd: entry.redirectEnd,
    duration: entry.duration,
  );
}

/// Whether this browser can put a `ReadableStream` in a request body.
///
/// Probed by construction rather than by user agent: building a `Request` with
/// a stream body throws where it is unsupported, and that throw *is* the
/// answer. Chrome supports it; Firefox and Safari do not, and buffer instead.
bool supportsStreamingUpload() {
  final cached = _supportsStreamingUpload;
  if (cached != null) return cached;
  var supported = false;
  try {
    web.Request(
      'data:,'.toJS,
      web.RequestInit(
        method: 'POST',
        body: web.ReadableStream(),
        // Mandatory for a stream body, and the reason the construction throws
        // where streaming uploads are not implemented.
        duplex: 'half',
      ),
    );
    supported = true;
  } catch (_) {
    supported = false;
  }
  return _supportsStreamingUpload = supported;
}

bool? _supportsStreamingUpload;

/// Wraps a Dart byte stream as the `ReadableStream` `fetch` wants.
web.ReadableStream _readableStreamOf(Stream<List<int>> source) {
  StreamSubscription<List<int>>? sub;
  final underlying = JSObject();

  underlying.setProperty(
    'start'.toJS,
    ((web.ReadableStreamDefaultController controller) {
      sub = source.listen(
        (chunk) => controller.enqueue(
          (chunk is Uint8List ? chunk : Uint8List.fromList(chunk)).toJS,
        ),
        onError: (Object error) => controller.error('$error'.toJS),
        onDone: () => controller.close(),
      );
    }).toJS,
  );
  // The consumer walked away — stop pulling from the source rather than reading
  // a body nobody is going to send.
  underlying.setProperty(
    'cancel'.toJS,
    ((JSAny? reason) => unawaited(sub?.cancel() ?? Future<void>.value())).toJS,
  );

  return web.ReadableStream(underlying);
}

/// The most recent Resource Timing entry recorded for [url], read straight from
/// the performance buffer rather than waiting for the observer.
web.PerformanceResourceTiming? _newestEntry(String url) {
  final entries = web.window.performance.getEntriesByName(url, 'resource').toDart;
  if (entries.isEmpty) return null;
  return entries.last as web.PerformanceResourceTiming;
}

/// `Headers` offers no Dart-visible way to iterate, so this reaches the JS
/// `forEach` directly. `package:http` carries the same workaround privately.
@JS()
extension type _IterableHeaders._(JSObject _) implements JSObject {
  external void forEach(JSFunction fn);
}
