/// Interceptors and the chain that executes them.
///
/// An interceptor observes and rewrites traffic on its way through the client.
/// The three hooks form a middleware stack: [Interceptor.beforeRequest] runs
/// outermost-first on the way in, and [Interceptor.afterResponse] /
/// [Interceptor.onError] run outermost-*last* on the way out, so an interceptor
/// registered first wraps every interceptor registered after it.
library;

import 'dart:async';

import 'exceptions.dart';
import 'request.dart';
import 'response.dart';

/// What an interceptor wants the chain to do next.
enum InterceptorDisposition {
  /// Continue to the following interceptor, optionally with a replaced value.
  next,

  /// Stop the chain here and use the value the interceptor supplied.
  stop,

  /// Abandon the chain and complete the call with a ready-made response.
  ///
  /// In [Interceptor.onError] this is how a failure becomes a success; in
  /// [Interceptor.beforeRequest] it short-circuits the network entirely.
  resolve,
}

/// The value an [Interceptor] hook returns.
///
/// Never constructed directly — use [Interceptor.next], [Interceptor.stop] or
/// [Interceptor.resolve].
final class InterceptorResult<T> {
  const InterceptorResult._(this.disposition, this.value, this.resolved);

  /// How the chain should proceed.
  final InterceptorDisposition disposition;

  /// Replacement for the value flowing through the chain.
  ///
  /// `null` means "leave the current value alone".
  final T? value;

  /// The response that ends the call, set only when [disposition] is
  /// [InterceptorDisposition.resolve].
  final HttpResponse? resolved;

  @override
  String toString() => 'InterceptorResult(${disposition.name})';
}

/// A hook into the request lifecycle.
///
/// All three methods default to [Interceptor.next], so a subclass overrides
/// only what it cares about:
///
/// ```dart
/// class AuthInterceptor extends Interceptor {
///   @override
///   Future<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) async {
///     request.headers.set('authorization', 'Bearer $token');
///     return Interceptor.next();
///   }
/// }
/// ```
///
/// A hook may throw. A [NitroHttpException] propagates unchanged; any other
/// object is wrapped in a [NitroHttpUnknownException] whose `engineMessage`
/// reads `interceptor threw: <error>` (see [InterceptorChain]).
abstract class Interceptor {
  /// Allows `const` subclasses.
  const Interceptor();

  /// Called before the request is handed to the engine, in registration order.
  ///
  /// Return [Interceptor.next] with a rewritten [HttpRequest] to modify the
  /// call, or [Interceptor.resolve] to answer it without touching the network.
  FutureOr<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) =>
      proceedRequest;

  /// Called after a successful transfer, in reverse registration order.
  ///
  /// "Successful" means the transport completed; a 500 arrives here, not in
  /// [onError], unless `throwOnStatusCode` is enabled.
  FutureOr<InterceptorResult<HttpResponse>> afterResponse(
    HttpResponse response,
  ) => proceedResponse;

  /// Called when the request failed, in reverse registration order.
  ///
  /// Return [Interceptor.resolve] to turn the failure into a response — the
  /// canonical use is refreshing a token after a 401 and replaying the call.
  FutureOr<InterceptorResult<HttpResponse>> onError(
    NitroHttpException exception,
  ) => proceedResponse;

  /// "Carry on unchanged" for a request hook — a shared constant.
  ///
  /// Returning this rather than `next()` costs no allocation, and returning it
  /// *as a value* rather than as a future costs no microtask either: the chain
  /// stays on its synchronous path for the whole request. Prefer it in any hook
  /// that has nothing to say.
  static const InterceptorResult<HttpRequest> proceedRequest =
      InterceptorResult<HttpRequest>._(InterceptorDisposition.next, null, null);

  /// "Carry on unchanged" for a response or error hook. See [proceedRequest].
  static const InterceptorResult<HttpResponse> proceedResponse =
      InterceptorResult<HttpResponse>._(InterceptorDisposition.next, null, null);

  /// Continues the chain, replacing the in-flight value when [value] is
  /// non-null.
  static InterceptorResult<T> next<T>([T? value]) =>
      InterceptorResult<T>._(InterceptorDisposition.next, value, null);

  /// Stops the chain, yielding [value] when non-null and the current in-flight
  /// value otherwise.
  static InterceptorResult<T> stop<T>([T? value]) =>
      InterceptorResult<T>._(InterceptorDisposition.stop, value, null);

  /// Abandons the chain and completes the call with [response].
  static InterceptorResult<T> resolve<T>(HttpResponse response) =>
      InterceptorResult<T>._(InterceptorDisposition.resolve, null, response);
}

/// An [Interceptor] assembled from closures, for one-off hooks and tests.
///
/// ```dart
/// final logger = DelegatingInterceptor(
///   onRequest: (r) async { print(r.url); return Interceptor.next(); },
/// );
/// ```
///
/// Omitted closures fall back to the pass-through defaults on [Interceptor].
class DelegatingInterceptor extends Interceptor {
  /// Creates an interceptor delegating to the supplied closures.
  const DelegatingInterceptor({this.onRequest, this.onResponse, this.onFailure});

  /// Delegate for [Interceptor.beforeRequest].
  final FutureOr<InterceptorResult<HttpRequest>> Function(HttpRequest request)?
  onRequest;

  /// Delegate for [Interceptor.afterResponse].
  final FutureOr<InterceptorResult<HttpResponse>> Function(
    HttpResponse response,
  )?
  onResponse;

  /// Delegate for [Interceptor.onError].
  final FutureOr<InterceptorResult<HttpResponse>> Function(
    NitroHttpException exception,
  )?
  onFailure;

  @override
  FutureOr<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) =>
      onRequest?.call(request) ?? super.beforeRequest(request);

  @override
  FutureOr<InterceptorResult<HttpResponse>> afterResponse(
    HttpResponse response,
  ) => onResponse?.call(response) ?? super.afterResponse(response);

  @override
  FutureOr<InterceptorResult<HttpResponse>> onError(
    NitroHttpException exception,
  ) => onFailure?.call(exception) ?? super.onError(exception);
}

/// Runs a group of observing interceptors concurrently instead of in turn.
///
/// The chain is sequential by design: each interceptor sees what the one before
/// it produced, which is what makes `auth → sign → retry` composable. That
/// ordering costs latency when the members are not actually cooperating —
/// several independent observers that each await I/O add up end to end.
///
/// ```dart
/// NitroHttpClient(
///   interceptors: [
///     AuthInterceptor(),                 // sequential: must run before signing
///     SigningInterceptor(),
///     ParallelInterceptors([             // concurrent: independent of each other
///       RemoteLogInterceptor(),
///       MetricsInterceptor(),
///     ]),
///   ],
/// );
/// ```
///
/// **Use this only for hooks that await something.** Running cheap synchronous
/// observers through [Future.wait] is slower than letting them run in turn, not
/// faster — a [LogInterceptor] writing to `print` belongs in the ordinary list.
///
/// Members must be observers: a member that returns a replacement value, stops
/// the chain or resolves it throws [StateError], because "first one wins" would
/// depend on completion order and so would silently differ run to run. Put an
/// interceptor that rewrites anything in the sequential list.
final class ParallelInterceptors extends Interceptor {
  /// Groups [members] to run concurrently within the enclosing chain.
  const ParallelInterceptors(this.members);

  /// The interceptors run concurrently. Each must be a pure observer.
  final List<Interceptor> members;

  @override
  FutureOr<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) {
    if (members.isEmpty) return Interceptor.proceedRequest;
    return _all(
      members.map((m) => m.beforeRequest(request)),
    ).then((_) => Interceptor.proceedRequest);
  }

  @override
  FutureOr<InterceptorResult<HttpResponse>> afterResponse(
    HttpResponse response,
  ) {
    if (members.isEmpty) return Interceptor.proceedResponse;
    return _all(
      members.map((m) => m.afterResponse(response)),
    ).then((_) => Interceptor.proceedResponse);
  }

  @override
  FutureOr<InterceptorResult<HttpResponse>> onError(
    NitroHttpException exception,
  ) {
    if (members.isEmpty) return Interceptor.proceedResponse;
    return _all(
      members.map((m) => m.onError(exception)),
    ).then((_) => Interceptor.proceedResponse);
  }

  /// Awaits every member and rejects any attempt to alter the chain.
  ///
  /// `Future.wait` with the default `eagerError: false` so one member throwing
  /// does not leave the others unawaited — an abandoned hook would go on writing
  /// after the call it belongs to had finished.
  Future<void> _all<T>(Iterable<FutureOr<InterceptorResult<T>>> hooks) async {
    final results = await Future.wait(
      hooks.map((h) => h is Future<InterceptorResult<T>> ? h : Future.value(h)),
    );
    for (final result in results) {
      if (result.disposition != InterceptorDisposition.next ||
          result.value != null) {
        throw StateError(
          'ParallelInterceptors members must observe, not modify: one returned '
          '${result.disposition.name}. Move it to the sequential list.',
        );
      }
    }
  }
}

/// The result of running one hook across every interceptor.
sealed class InterceptorOutcome<T> {
  /// Allows `const` subclasses.
  const InterceptorOutcome();
}

/// Every interceptor said [InterceptorDisposition.next]; carry on.
///
/// [value] is the input after all replacements were applied.
final class InterceptorProceed<T> extends InterceptorOutcome<T> {
  /// Wraps the fully-rewritten [value].
  const InterceptorProceed(this.value);

  /// The value to continue with.
  final T value;

  @override
  String toString() => 'InterceptorProceed($value)';
}

/// An interceptor said [InterceptorDisposition.stop].
///
/// The caller must not run the remaining stage — for `beforeRequest` that means
/// not issuing the request at all.
final class InterceptorShortCircuit<T> extends InterceptorOutcome<T> {
  /// Wraps the [value] the chain stopped on.
  const InterceptorShortCircuit(this.value);

  /// The value the interceptor stopped with.
  final T value;

  @override
  String toString() => 'InterceptorShortCircuit($value)';
}

/// An interceptor supplied a finished [HttpResponse].
///
/// From `beforeRequest` this is a cache/mock hit; from `onError` it is a
/// recovery and the original exception must be discarded.
final class InterceptorRecovered<T> extends InterceptorOutcome<T> {
  /// Wraps the [response] that completes the call.
  const InterceptorRecovered(this.response);

  /// The response that completes the call.
  final HttpResponse response;

  @override
  String toString() => 'InterceptorRecovered(${response.statusCode})';
}

/// Runs a list of [Interceptor]s with middleware-stack ordering.
///
/// [runBeforeRequest] walks the list forwards; [runAfterResponse] and
/// [runOnError] walk it backwards, so the first-registered interceptor is the
/// outermost layer and observes the response last.
///
/// Exceptions thrown by a hook are never swallowed: a [NitroHttpException]
/// propagates unchanged, and anything else is rethrown as a
/// [NitroHttpUnknownException] carrying the original in `engineMessage` and
/// preserving the original stack trace.
class InterceptorChain {
  /// Wraps [interceptors] in registration order.
  const InterceptorChain(this._interceptors);

  final List<Interceptor> _interceptors;

  /// The interceptors this chain runs, in registration order.
  List<Interceptor> get interceptors => List.unmodifiable(_interceptors);

  /// Whether the chain has no interceptors, in which case every `run*` method
  /// is a cheap pass-through.
  bool get isEmpty => _interceptors.isEmpty;

  /// Runs [Interceptor.beforeRequest] across the chain in registration order.
  ///
  /// Yields [InterceptorProceed] with the rewritten request,
  /// [InterceptorShortCircuit] if an interceptor stopped the chain, or
  /// [InterceptorRecovered] if one answered the call outright.
  ///
  /// Returns a value rather than a future when every hook answered
  /// synchronously, which is the common case — see [InterceptorChain].
  FutureOr<InterceptorOutcome<HttpRequest>> runBeforeRequest(
    HttpRequest request,
  ) {
    var current = request;
    for (var i = 0; i < _interceptors.length; i++) {
      final FutureOr<InterceptorResult<HttpRequest>> raw;
      try {
        raw = _interceptors[i].beforeRequest(current);
      } catch (error, stackTrace) {
        _rethrowNormalised(error, stackTrace, current);
      }
      if (raw is! InterceptorResult<HttpRequest>) {
        // First hook that actually suspends: the rest of the chain has to run
        // asynchronously, so hand over and pay the microtask once.
        return _resumeBeforeRequest(raw, i, current);
      }
      final (outcome, next) = _stepRequest(raw, current);
      if (outcome != null) return outcome;
      current = next;
    }
    return InterceptorProceed(current);
  }

  Future<InterceptorOutcome<HttpRequest>> _resumeBeforeRequest(
    Future<InterceptorResult<HttpRequest>> pending,
    int index,
    HttpRequest request,
  ) async {
    var current = request;
    var awaited = pending;
    for (var i = index; i < _interceptors.length; i++) {
      final result = await _guard(awaited, current);
      final (outcome, next) = _stepRequest(result, current);
      if (outcome != null) return outcome;
      current = next;
      if (i + 1 < _interceptors.length) {
        try {
          awaited = Future<InterceptorResult<HttpRequest>>.value(
            _interceptors[i + 1].beforeRequest(current),
          );
        } catch (error, stackTrace) {
          _rethrowNormalised(error, stackTrace, current);
        }
      }
    }
    return InterceptorProceed(current);
  }

  /// Applies one request result, returning the outcome that ends the chain or
  /// the value to continue with.
  (InterceptorOutcome<HttpRequest>?, HttpRequest) _stepRequest(
    InterceptorResult<HttpRequest> result,
    HttpRequest current,
  ) => switch (result.disposition) {
    InterceptorDisposition.next => (null, result.value ?? current),
    InterceptorDisposition.stop => (
      InterceptorShortCircuit(result.value ?? current),
      current,
    ),
    InterceptorDisposition.resolve => (
      InterceptorRecovered(result.resolved!),
      current,
    ),
  };

  /// Runs [Interceptor.afterResponse] across the chain in reverse order.
  ///
  /// [InterceptorDisposition.resolve] behaves like a stop that substitutes the
  /// supplied response wholesale.
  FutureOr<InterceptorOutcome<HttpResponse>> runAfterResponse(
    HttpResponse response,
  ) {
    var current = response;
    for (var i = _interceptors.length - 1; i >= 0; i--) {
      final FutureOr<InterceptorResult<HttpResponse>> raw;
      try {
        raw = _interceptors[i].afterResponse(current);
      } catch (error, stackTrace) {
        _rethrowNormalised(error, stackTrace, current.request);
      }
      if (raw is! InterceptorResult<HttpResponse>) {
        return _resumeAfterResponse(raw, i, current);
      }
      final (outcome, next) = _stepResponse(raw, current);
      if (outcome != null) return outcome;
      current = next;
    }
    return InterceptorProceed(current);
  }

  Future<InterceptorOutcome<HttpResponse>> _resumeAfterResponse(
    Future<InterceptorResult<HttpResponse>> pending,
    int index,
    HttpResponse response,
  ) async {
    var current = response;
    var awaited = pending;
    for (var i = index; i >= 0; i--) {
      final result = await _guard(awaited, current.request);
      final (outcome, next) = _stepResponse(result, current);
      if (outcome != null) return outcome;
      current = next;
      if (i - 1 >= 0) {
        try {
          awaited = Future<InterceptorResult<HttpResponse>>.value(
            _interceptors[i - 1].afterResponse(current),
          );
        } catch (error, stackTrace) {
          _rethrowNormalised(error, stackTrace, current.request);
        }
      }
    }
    return InterceptorProceed(current);
  }

  (InterceptorOutcome<HttpResponse>?, HttpResponse) _stepResponse(
    InterceptorResult<HttpResponse> result,
    HttpResponse current,
  ) => switch (result.disposition) {
    InterceptorDisposition.next => (null, result.value ?? current),
    InterceptorDisposition.stop => (
      InterceptorShortCircuit(result.value ?? current),
      current,
    ),
    InterceptorDisposition.resolve => (
      InterceptorRecovered(result.resolved!),
      current,
    ),
  };

  /// Runs [Interceptor.onError] across the chain in reverse order.
  ///
  /// There is no in-flight response during an error, so the chain accumulates a
  /// *candidate* recovery instead: [Interceptor.next] with a non-null response
  /// records the candidate and lets outer interceptors inspect or replace it,
  /// [Interceptor.stop] ends the chain immediately, and [Interceptor.resolve]
  /// short-circuits with a final response.
  ///
  /// If the chain finishes with no candidate the failure was not handled, and
  /// [exception] is rethrown — recovery is opt-in, silence is not success.
  FutureOr<InterceptorOutcome<HttpResponse>> runOnError(
    NitroHttpException exception,
  ) {
    HttpResponse? candidate;
    for (var i = _interceptors.length - 1; i >= 0; i--) {
      final FutureOr<InterceptorResult<HttpResponse>> raw;
      try {
        raw = _interceptors[i].onError(exception);
      } catch (error, stackTrace) {
        _rethrowNormalised(error, stackTrace, exception.request);
      }
      if (raw is! InterceptorResult<HttpResponse>) {
        return _resumeOnError(raw, i, exception, candidate);
      }
      final outcome = _stepError(raw, exception, candidate);
      if (outcome != null) return outcome;
      candidate = raw.value ?? candidate;
    }
    if (candidate == null) throw exception;
    return InterceptorRecovered(candidate);
  }

  Future<InterceptorOutcome<HttpResponse>> _resumeOnError(
    Future<InterceptorResult<HttpResponse>> pending,
    int index,
    NitroHttpException exception,
    HttpResponse? seen,
  ) async {
    var candidate = seen;
    var awaited = pending;
    for (var i = index; i >= 0; i--) {
      final result = await _guard(awaited, exception.request);
      final outcome = _stepError(result, exception, candidate);
      if (outcome != null) return outcome;
      candidate = result.value ?? candidate;
      if (i - 1 >= 0) {
        try {
          awaited = Future<InterceptorResult<HttpResponse>>.value(
            _interceptors[i - 1].onError(exception),
          );
        } catch (error, stackTrace) {
          _rethrowNormalised(error, stackTrace, exception.request);
        }
      }
    }
    if (candidate == null) throw exception;
    return InterceptorRecovered(candidate);
  }

  /// Applies one error result, returning the outcome that ends the chain or
  /// `null` to carry on with an updated candidate.
  InterceptorOutcome<HttpResponse>? _stepError(
    InterceptorResult<HttpResponse> result,
    NitroHttpException exception,
    HttpResponse? candidate,
  ) {
    switch (result.disposition) {
      case InterceptorDisposition.next:
        return null;
      case InterceptorDisposition.stop:
        final stopped = result.value ?? candidate;
        if (stopped == null) throw exception;
        return InterceptorShortCircuit(stopped);
      case InterceptorDisposition.resolve:
        return InterceptorRecovered(result.resolved!);
    }
  }

  /// Awaits a suspended hook, normalising whatever it throws.
  Future<InterceptorResult<T>> _guard<T>(
    Future<InterceptorResult<T>> pending,
    HttpRequest? request,
  ) async {
    try {
      return await pending;
    } catch (error, stackTrace) {
      _rethrowNormalised(error, stackTrace, request);
    }
  }

  /// Normalises anything a hook throws into the typed exception hierarchy.
  ///
  /// The original stack trace is both attached to the exception and used for
  /// the rethrow, so a bug inside an interceptor still points at the line that
  /// caused it rather than at this frame.
  Never _rethrowNormalised(
    Object error,
    StackTrace stackTrace,
    HttpRequest? request,
  ) {
    if (error is NitroHttpException) {
      error.stackTrace = stackTrace;
      Error.throwWithStackTrace(error, stackTrace);
    }
    final wrapped = NitroHttpUnknownException(
      request: request,
      engineMessage: 'interceptor threw: $error',
    )..stackTrace = stackTrace;
    Error.throwWithStackTrace(wrapped, stackTrace);
  }
}
