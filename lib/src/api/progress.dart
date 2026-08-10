/// Transfer-progress reporting types.
library;

/// Reports transfer progress for a request or response body.
///
/// [transferred] is the number of bytes moved so far. [total] is the expected
/// total when it is known — it is `null` for chunked transfers and for
/// responses that arrive without a `Content-Length`.
///
/// Progress events are lossy by design: the engine coalesces them so a fast
/// transfer cannot flood the isolate. The terminal event, where `transferred`
/// equals `total`, is always delivered.
typedef ProgressCallback = void Function(int transferred, int? total);

/// An immutable snapshot of transfer progress.
///
/// Convenient when progress has to be pushed through a `ValueNotifier`, a
/// stream, or a state-management layer that wants a single value rather than
/// two loose arguments.
class ProgressSnapshot {
  /// Creates a snapshot of [transferred] bytes out of an optional [total].
  const ProgressSnapshot({required this.transferred, this.total});

  /// Bytes transferred so far.
  final int transferred;

  /// Expected total bytes, or `null` when the length is unknown.
  final int? total;

  /// Completion ratio in the range `0.0 .. 1.0`, or `null` when it cannot be
  /// computed.
  ///
  /// An unknown or non-positive [total] yields `null` rather than `0.0`, so a
  /// progress indicator can tell "indeterminate" apart from "not started".
  double? get fraction {
    final knownTotal = total;
    if (knownTotal == null || knownTotal <= 0) return null;
    return transferred / knownTotal;
  }

  /// Whether [total] is known and [transferred] has reached it.
  bool get isComplete {
    final knownTotal = total;
    return knownTotal != null && transferred >= knownTotal;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProgressSnapshot &&
          other.transferred == transferred &&
          other.total == total;

  @override
  int get hashCode => Object.hash(transferred, total);

  @override
  String toString() => 'ProgressSnapshot($transferred/${total ?? '?'})';
}
