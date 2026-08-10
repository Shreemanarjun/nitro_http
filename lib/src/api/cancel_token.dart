/// Cooperative request cancellation.
library;

import 'dart:async';
import 'dart:math' as math;

import 'exceptions.dart';

/// A one-shot cancellation signal shared by one or more requests.
///
/// A token can be handed to any number of requests; cancelling it aborts all
/// of them. Cancellation is cooperative and idempotent — the first [cancel]
/// wins, later ones are no-ops, and a request that has already completed is
/// unaffected.
class CancelToken {
  /// Distinguishes tokens minted by THIS isolate incarnation from any the
  /// native registry still holds from a previous one.
  ///
  /// The registry is process-global C++ state and outlives a hot restart, while
  /// these statics do not: with a plain counter the first token after a restart
  /// would reuse id 1, inherit whatever state id 1 was left in, and — if that
  /// token had been cancelled — every request bound to it would fail instantly
  /// with a cancellation the caller never asked for. Randomising the high bits
  /// per incarnation makes that collision impossible rather than merely
  /// unlikely, which matters because the symptom (requests cancel themselves
  /// after a hot restart) looks nothing like its cause.
  ///
  /// 30 bits of epoch in the high half, so a collision needs the same value
  /// twice out of ~1e9; 32 bits of counter in the low half, which is four
  /// billion tokens in one run. The product stays a positive 63-bit int.
  static final int _epoch = (math.Random().nextInt(0x3FFFFFFF) + 1) << 32;
  static int _counter = 0;

  /// Identifies this token to the engine.
  ///
  /// A request bound to it is refused before it opens a socket if the token is
  /// already cancelled, and cancelling reaches every bound transfer on every
  /// client in one call. Never `0` — that is the engine's "no token" sentinel.
  /// Internal: callers never need to see it.
  final int nativeId = _epoch | (++_counter);

  final Completer<void> _completer = Completer<void>();
  final List<void Function()> _listeners = [];
  bool _isCancelled = false;
  String? _reason;

  /// Whether [cancel] has been called.
  bool get isCancelled => _isCancelled;

  /// The reason passed to [cancel], or `null`.
  String? get reason => _reason;

  /// Completes when the token is cancelled.
  ///
  /// Never completes with an error, so it is safe to `await` or to race with
  /// `Future.any` without a `catchError`.
  Future<void> get whenCancelled => _completer.future;

  /// Cancels every request bound to this token.
  ///
  /// Calling this more than once has no further effect; the first [reason]
  /// is the one that is kept.
  void cancel([String? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;
    // Detach before notifying: a listener may cancel again or remove itself,
    // and neither may mutate the list being iterated.
    final pending = List<void Function()>.of(_listeners);
    _listeners.clear();
    if (!_completer.isCompleted) _completer.complete();
    for (final listener in pending) {
      _notify(listener);
    }
  }

  /// Registers [callback] to run when the token is cancelled.
  ///
  /// Runs exactly once. Registering on an already-cancelled token invokes
  /// [callback] immediately, so a request that starts after cancellation is
  /// still torn down instead of hanging.
  void addListener(void Function() callback) {
    if (_isCancelled) {
      _notify(callback);
      return;
    }
    _listeners.add(callback);
  }

  /// Unregisters a callback previously passed to [addListener].
  void removeListener(void Function() callback) {
    _listeners.remove(callback);
  }

  /// Throws [NitroHttpCancelException] when the token is already cancelled.
  void throwIfCancelled() {
    if (!_isCancelled) return;
    throw NitroHttpCancelException(reason: _reason);
  }

  /// A listener that throws must not abort the cancellation of the remaining
  /// requests, but the failure is real and belongs in the zone's error
  /// handler rather than swallowed.
  void _notify(void Function() listener) {
    try {
      listener();
    } catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }

  @override
  String toString() => _isCancelled
      ? 'CancelToken(cancelled${_reason == null ? '' : ': $_reason'})'
      : 'CancelToken(active)';
}
