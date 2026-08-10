/// Application state, held in signals.
///
/// ## House rules for `signals_flutter` 7.1.0 in this app
///
/// Verified against the resolved package source, not from memory. Follow these
/// exactly — several of the v6 patterns still all over the internet are
/// deprecated in v7 and one of them does not exist at all.
///
/// 1. **One import.** `package:signals_flutter/signals_flutter.dart`. Never also
///    import `package:signals_core/...` in app code: the Flutter barrel
///    deliberately shadows `signal`, `computed`, `readonly` and `lazySignal`, so
///    importing both gives ambiguous-import errors.
/// 2. **Read with `SignalBuilder(builder: ...)`.** `builder` is a *required named*
///    parameter in 7.x; the v6 positional form does not compile. It rebuilds only
///    its own subtree, which is what keeps a twenty-field form from rebuilding
///    wholesale on every keystroke.
/// 3. **Do not use `Watch`, `WatchBuilder`, `SignalsMixin`, or
///    `signal.watch(context)`** — all four are deprecated in 7.0.0.
///    `signal.listen(context, cb)` does not exist at all. For side effects use
///    the `SignalEffect` widget or a bare `effect()`.
/// 4. **Options, not bare params.** `debugLabel:` and `autoDispose:` are
///    deprecated on every factory. Write
///    `signal(x, options: const SignalOptions(name: 'thing'))`.
/// 5. **Collections notify on in-place mutation, and only then.**
///    `listSignal`/`mapSignal` default to deep equality, so
///    `rows.value = [...rows.value]` does *not* notify. Use `.add`, `[i] =`,
///    `.removeAt`, or `set(v, force: true)`.
/// 6. **`autoDispose` defaults to false, so an undisposed signal leaks.** The
///    globals in this file are app-lifetime and intentionally never disposed.
///    Anything screen-scoped must be a field on a `State` and disposed in
///    `State.dispose()`, and an `effect()`'s returned cleanup must be stored and
///    called there too.
/// 7. **`batch()` around multi-field writes**, so one logical update produces one
///    rebuild instead of one per field. This matters most on the benchmark's
///    progress path, which writes several times a second.
/// 8. **`AsyncState<T>` is sealed** with three direct subtypes. Match `AsyncData`
///    and `AsyncError` *before* `AsyncLoading`: the refreshing/reloading variants
///    implement both, so a leading loading arm swallows states that still hold
///    data. This repo compiles an inexhaustive switch as an error, so all three
///    arms are mandatory.
library;

import 'package:signals_flutter/signals_flutter.dart';

import 'http_library.dart';
import 'request_spec.dart';
import 'sent_response.dart';

/// The demo server's origin, e.g. `http://127.0.0.1:53219`.
///
/// Empty until the server is up; every screen treats empty as "not ready".
final baseUrl = signal<String>(
  '',
  options: const SignalOptions(name: 'app.baseUrl'),
);

/// The library the request console currently sends through.
final selectedLibrary = signal<HttpLibrary>(
  HttpLibrary.nitroHttp,
  options: const SignalOptions(name: 'app.selectedLibrary'),
);

/// The most recent outcome shown in the console, or null before the first send.
final lastOutcome = signal<SendOutcome?>(
  null,
  options: const SignalOptions(name: 'console.lastOutcome'),
);

/// Whether a send is in flight, so the console can show a spinner and disable
/// Send without a second boolean to keep in sync.
final isSending = signal<bool>(
  false,
  options: const SignalOptions(name: 'console.isSending'),
);

/// Past outcomes, newest first. Capped so a long session cannot grow unbounded.
final history = listSignal<SendOutcome>(
  <SendOutcome>[],
  options: const ListSignalOptions(name: 'console.history'),
);

/// How many entries [history] keeps.
const int historyLimit = 50;

/// Records [outcome] as the current result and pushes it onto [history].
///
/// One `batch` so the console rebuilds once, not three times.
void recordOutcome(SendOutcome outcome) {
  batch(() {
    lastOutcome.value = outcome;
    // In-place mutation: a ListSignal notifies on `insert`, and would NOT notify
    // on `history.value = [...]` because its default equality is deep.
    history.insert(0, outcome);
    while (history.length > historyLimit) {
      history.removeLast();
    }
  });
}

/// The editable request, one signal per field.
///
/// Per-field signals rather than a single `signal<RequestSpec>` so that typing in
/// the URL bar rebuilds the URL bar and nothing else. [spec] recombines them for
/// the senders and the benchmark, and is lazy: it only recomputes when something
/// actually reads it.
final class RequestDraft {
  /// Creates a draft with sensible starting values for the demo server.
  RequestDraft() {
    spec = computed<RequestSpec>(
      () => RequestSpec(
        method: method.value,
        url: url.value,
        query: List<KeyValueRow>.unmodifiable(query),
        headers: List<KeyValueRow>.unmodifiable(headers),
        bodyKind: bodyKind.value,
        bodyText: bodyText.value,
        formFields: List<KeyValueRow>.unmodifiable(formFields),
        parts: List<MultipartPart>.unmodifiable(parts),
        filePath: filePath.value,
        generatedByteCount: generatedByteCount.value,
        contentTypeOverride: contentTypeOverride.value,
        responseMode: responseMode.value,
        followRedirects: followRedirects.value,
        maxRedirects: maxRedirects.value,
        connectTimeout: connectTimeout.value,
        totalTimeout: totalTimeout.value,
        sendCookies: sendCookies.value,
        acceptEncoding: acceptEncoding.value,
      ),
      options: const ComputedOptions(name: 'draft.spec'),
    );
  }

  /// The HTTP verb.
  final method = signal<String>(
    'GET',
    options: const SignalOptions(name: 'draft.method'),
  );

  /// The URL or path.
  ///
  /// `/echo` rather than something prettier because it is a route the demo server
  /// actually serves, and it echoes the method, path, query, headers and body back
  /// as JSON — so the very first send with no editing at all still demonstrates
  /// that every field reached the wire.
  final url = signal<String>(
    '/echo',
    options: const SignalOptions(name: 'draft.url'),
  );

  /// Query parameter rows.
  final query = listSignal<KeyValueRow>(
    <KeyValueRow>[],
    options: const ListSignalOptions(name: 'draft.query'),
  );

  /// Header rows.
  final headers = listSignal<KeyValueRow>(
    <KeyValueRow>[],
    options: const ListSignalOptions(name: 'draft.headers'),
  );

  /// What the body is made of.
  final bodyKind = signal<RequestBodyKind>(
    RequestBodyKind.none,
    options: const SignalOptions(name: 'draft.bodyKind'),
  );

  /// The raw text or JSON body.
  final bodyText = signal<String>(
    '',
    options: const SignalOptions(name: 'draft.bodyText'),
  );

  /// URL-encoded form rows.
  final formFields = listSignal<KeyValueRow>(
    <KeyValueRow>[],
    options: const ListSignalOptions(name: 'draft.formFields'),
  );

  /// Multipart parts.
  final parts = listSignal<MultipartPart>(
    <MultipartPart>[],
    options: const ListSignalOptions(name: 'draft.parts'),
  );

  /// The file to upload, for a file body.
  final filePath = signal<String?>(
    null,
    options: const SignalOptions(name: 'draft.filePath'),
  );

  /// How many bytes to synthesise for a generated body.
  final generatedByteCount = signal<int>(
    1024 * 1024,
    options: const SignalOptions(name: 'draft.generatedByteCount'),
  );

  /// An explicit content type, overriding the body kind's default.
  final contentTypeOverride = signal<String?>(
    null,
    options: const SignalOptions(name: 'draft.contentTypeOverride'),
  );

  /// Buffered or streamed response handling.
  final responseMode = signal<ResponseMode>(
    ResponseMode.buffered,
    options: const SignalOptions(name: 'draft.responseMode'),
  );

  /// Whether redirects are followed.
  final followRedirects = signal<bool>(
    true,
    options: const SignalOptions(name: 'draft.followRedirects'),
  );

  /// The redirect limit.
  final maxRedirects = signal<int>(
    5,
    options: const SignalOptions(name: 'draft.maxRedirects'),
  );

  /// Connect timeout, or null for the client default.
  final connectTimeout = signal<Duration?>(
    null,
    options: const SignalOptions(name: 'draft.connectTimeout'),
  );

  /// Whole-request timeout, or null for the client default.
  final totalTimeout = signal<Duration?>(
    null,
    options: const SignalOptions(name: 'draft.totalTimeout'),
  );

  /// Whether the cookie jar participates.
  final sendCookies = signal<bool>(
    true,
    options: const SignalOptions(name: 'draft.sendCookies'),
  );

  /// Whether compressed responses are requested and decoded.
  final acceptEncoding = signal<bool>(
    true,
    options: const SignalOptions(name: 'draft.acceptEncoding'),
  );

  /// The assembled request. Recomputed lazily from the fields above.
  late final ReadonlySignal<RequestSpec> spec;

  /// Replaces every field from [next], as one notification.
  void load(RequestSpec next) {
    batch(() {
      method.value = next.method;
      url.value = next.url;
      query
        ..clear()
        ..addAll(next.query);
      headers
        ..clear()
        ..addAll(next.headers);
      bodyKind.value = next.bodyKind;
      bodyText.value = next.bodyText;
      formFields
        ..clear()
        ..addAll(next.formFields);
      parts
        ..clear()
        ..addAll(next.parts);
      filePath.value = next.filePath;
      generatedByteCount.value = next.generatedByteCount;
      contentTypeOverride.value = next.contentTypeOverride;
      responseMode.value = next.responseMode;
      followRedirects.value = next.followRedirects;
      maxRedirects.value = next.maxRedirects;
      connectTimeout.value = next.connectTimeout;
      totalTimeout.value = next.totalTimeout;
      sendCookies.value = next.sendCookies;
      acceptEncoding.value = next.acceptEncoding;
    });
  }
}

/// The app-wide request draft, shared by the console and the benchmark so that
/// "benchmark the request I just sent" needs no copying.
final requestDraft = RequestDraft();
