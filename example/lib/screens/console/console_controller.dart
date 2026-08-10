/// Screen-scoped state for the request console, and the one place a send is
/// started from.
///
/// The draft itself lives in `core/app_state.dart` because the benchmark shares
/// it. What lives here is everything that is only true while the console is on
/// screen — which pane is showing, how wide the split is, whether a transfer is
/// in flight — so it can be created with the screen and disposed with it. Signals
/// default to `autoDispose: false`, so anything screen-scoped that is not
/// disposed is a leak; [ConsoleController.dispose] is the other half of that
/// contract.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../core/app_state.dart';
import '../../core/http_sender.dart';
import '../../core/request_spec.dart';
import '../../core/senders/sender_registry.dart';
import '../../core/sent_response.dart';

/// Which request editor is showing.
enum EditorTab {
  /// Query parameter rows.
  params('Params'),

  /// Request header rows.
  headers('Headers'),

  /// The request payload.
  body('Body'),

  /// Transport options.
  settings('Settings');

  const EditorTab(this.label);

  /// The tab title.
  final String label;
}

/// Which view of the response is showing.
enum ResponseView {
  /// Pretty-printed body.
  pretty('Pretty'),

  /// The body exactly as it arrived.
  raw('Raw'),

  /// Response headers.
  headers('Headers'),

  /// The phase breakdown.
  timings('Timings'),

  /// Library-specific detail.
  extras('Extras');

  const ResponseView(this.label);

  /// The tab title.
  final String label;
}

/// Which half of the console a narrow window is showing.
///
/// A phone cannot show the request and the response at once without making both
/// useless, so on narrow layouts they become destinations instead of columns.
enum NarrowPane {
  /// The request builder.
  request('Request', Icons.edit_note),

  /// The response inspector.
  response('Response', Icons.download_done),

  /// Past sends.
  history('History', Icons.history);

  const NarrowPane(this.label, this.icon);

  /// The destination title.
  final String label;

  /// The destination glyph.
  final IconData icon;
}

/// The verbs every client is expected to accept.
///
/// Used only to decide whether a typed verb counts as "custom" for a client that
/// says it cannot send those; the field itself never restricts what you can type.
const Set<String> standardMethods = <String>{
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'OPTIONS',
};

/// Why Send is disabled, or null when it is not.
///
/// Returned as prose rather than a bool because a disabled button with no
/// explanation is the single most common way a tool wastes someone's afternoon.
/// The checks run cheapest-first and stop at the first real problem, so the
/// message names the thing to fix next rather than everything wrong at once.
String? sendBlockedReason({
  required RequestSpec spec,
  required String baseUrl,
  required SenderCapabilities capabilities,
}) {
  if (baseUrl.isEmpty) {
    return 'The in-process demo server has not finished starting.';
  }
  if (spec.method.trim().isEmpty) return 'Enter an HTTP method.';
  if (spec.url.trim().isEmpty) {
    return 'Enter a URL, or a path such as /echo to use the demo server.';
  }
  if (spec.resolve(baseUrl: baseUrl) == null) {
    return 'That URL does not parse. Absolute URLs need a host; anything else '
        'is treated as a path on the demo server.';
  }
  final method = spec.method.trim().toUpperCase();
  if (!capabilities.customMethods && !standardMethods.contains(method)) {
    return capabilities.noteFor('customMethods') ??
        'This client only accepts the standard verbs, not $method.';
  }
  if (spec.bodyKind == RequestBodyKind.multipart && !capabilities.multipart) {
    return capabilities.noteFor('multipart') ??
        'This client cannot send multipart/form-data.';
  }
  if (spec.bodyKind == RequestBodyKind.file &&
      (spec.filePath == null || spec.filePath!.trim().isEmpty)) {
    return 'Pick a file for the body, or switch the body kind.';
  }
  if (spec.bodyKind == RequestBodyKind.multipart && spec.parts.isEmpty) {
    return 'A multipart body needs at least one part.';
  }
  return null;
}

/// Owns the console's transient state and its send loop.
final class ConsoleController {
  /// Creates a controller. One per mounted console.
  ConsoleController();

  /// Which request editor is open.
  final editorTab = signal<EditorTab>(
    EditorTab.params,
    options: const SignalOptions<EditorTab>(name: 'console.editorTab'),
  );

  /// Which response view is open.
  final responseView = signal<ResponseView>(
    ResponseView.pretty,
    options: const SignalOptions<ResponseView>(name: 'console.responseView'),
  );

  /// Which destination a narrow window is showing.
  final narrowPane = signal<NarrowPane>(
    NarrowPane.request,
    options: const SignalOptions<NarrowPane>(name: 'console.narrowPane'),
  );

  /// Whether the history rail is pinned open, or null to follow the window
  /// width.
  ///
  /// Tri-state on purpose: a plain bool seeded from the width would either fight
  /// the toggle on every resize or ignore the width entirely. Null means "you
  /// have not said", and the layout decides.
  final historyPinned = signal<bool?>(
    null,
    options: const SignalOptions<bool?>(name: 'console.historyPinned'),
  );

  /// The request pane's share of a wide layout, as a fraction of the width.
  final splitFraction = signal<double>(
    0.44,
    options: const SignalOptions<double>(name: 'console.splitFraction'),
  );

  /// The most recent transfer progress sample, or null when nothing is moving.
  final progress = signal<SendProgress?>(
    null,
    options: const SignalOptions<SendProgress?>(name: 'console.progress'),
  );

  Completer<void>? _cancel;
  final Stopwatch _sinceProgress = Stopwatch();

  /// Sends the current draft through the selected library.
  ///
  /// Every failure path ends in [recordOutcome], never in a thrown exception:
  /// `HttpSender.send` promises not to throw, but `senderFor` still has to build
  /// a client, and on a machine with no native engine that is exactly where an
  /// rhttp or nitro_http run dies. Turning that into a [FailedSend] keeps the
  /// console showing a result instead of a red screen.
  Future<void> send() async {
    if (isSending.value) return;
    final base = baseUrl.value;
    final spec = requestDraft.spec.value;
    final library = selectedLibrary.value;
    if (sendBlockedReason(
          spec: spec,
          baseUrl: base,
          capabilities: capabilitiesFor(library),
        ) !=
        null) {
      return;
    }

    final cancel = Completer<void>();
    _cancel = cancel;
    final watch = Stopwatch()..start();
    batch(() {
      isSending.value = true;
      progress.value = null;
    });
    try {
      final outcome = await senderFor(library).send(
        spec,
        baseUrl: base,
        onProgress: _reportProgress,
        cancel: cancel.future,
      );
      recordOutcome(outcome);
    } on Object catch (error) {
      recordOutcome(
        FailedSend(
          library: library,
          spec: spec,
          failure: SendFailure(
            kind: SendFailureKind.unknown,
            message: '$error',
            elapsed: watch.elapsed,
          ),
        ),
      );
    } finally {
      watch.stop();
      _sinceProgress.stop();
      _cancel = null;
      batch(() {
        isSending.value = false;
        progress.value = null;
      });
    }
  }

  /// Asks the in-flight send to stop.
  ///
  /// Cooperative: the completer is what the sender is watching, so a client that
  /// cannot abort mid-transfer will still run to completion. That is the client's
  /// limitation, and the button says so rather than pretending otherwise.
  void cancelSend() {
    final pending = _cancel;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// Coalesces progress samples to roughly twenty a second.
  ///
  /// A streamed megabyte can call back thousands of times; repainting a progress
  /// bar that often costs more than the transfer does.
  void _reportProgress(SendProgress sample) {
    if (_sinceProgress.isRunning && _sinceProgress.elapsedMilliseconds < 50) {
      return;
    }
    _sinceProgress
      ..reset()
      ..start();
    progress.value = sample;
  }

  /// Releases every screen-scoped signal.
  void dispose() {
    cancelSend();
    editorTab.dispose();
    responseView.dispose();
    narrowPane.dispose();
    historyPinned.dispose();
    splitFraction.dispose();
    progress.dispose();
  }
}

/// Hands the [ConsoleController] to the console's widgets.
///
/// An inherited widget rather than six constructor parameters threaded through
/// four levels: the controller is created once and never replaced, so nothing
/// below has to rebuild when it is read.
class ConsoleScope extends InheritedWidget {
  /// Provides [controller] to [child].
  const ConsoleScope({
    required this.controller,
    required super.child,
    super.key,
  });

  /// The console's state.
  final ConsoleController controller;

  /// The controller for the enclosing console.
  static ConsoleController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ConsoleScope>();
    assert(scope != null, 'ConsoleScope.of() used outside the request console');
    return scope!.controller;
  }

  @override
  bool updateShouldNotify(ConsoleScope oldWidget) =>
      controller != oldWidget.controller;
}
