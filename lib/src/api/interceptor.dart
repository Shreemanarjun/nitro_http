/// Interceptors and the chain that executes them.
///
/// An interceptor observes and rewrites traffic on its way through the client.
/// The three hooks form a middleware stack: [Interceptor.beforeRequest] runs
/// outermost-first on the way in, and [Interceptor.afterResponse] /
/// [Interceptor.onError] run outermost-*last* on the way out, so an interceptor
/// registered first wraps every interceptor registered after it.
library;

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
  Future<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) =>
      _proceedRequest;

  /// Called after a successful transfer, in reverse registration order.
  ///
  /// "Successful" means the transport completed; a 500 arrives here, not in
  /// [onError], unless `throwOnStatusCode` is enabled.
  Future<InterceptorResult<HttpResponse>> afterResponse(HttpResponse response) =>
      _proceedResponse;

  /// Called when the request failed, in reverse registration order.
  ///
  /// Return [Interceptor.resolve] to turn the failure into a response — the
  /// canonical use is refreshing a token after a 401 and replaying the call.
  Future<InterceptorResult<HttpResponse>> onError(NitroHttpException exception) =>
      _proceedResponse;

  /// "Carry on unchanged", shared rather than rebuilt per call.
  ///
  /// [InterceptorResult] is immutable and a completed [Future] can be awaited
  /// any number of times, so the pass-through answer is the same object every
  /// time. That matters because these defaults run on every hook a subclass did
  /// not override: a two-interceptor client used to allocate six results and six
  /// futures per request just to say nothing.
  static final Future<InterceptorResult<HttpRequest>> _proceedRequest =
      Future<InterceptorResult<HttpRequest>>.value(next<HttpRequest>());

  static final Future<InterceptorResult<HttpResponse>> _proceedResponse =
      Future<InterceptorResult<HttpResponse>>.value(next<HttpResponse>());

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
  final Future<InterceptorResult<HttpRequest>> Function(HttpRequest request)? onRequest;

  /// Delegate for [Interceptor.afterResponse].
  final Future<InterceptorResult<HttpResponse>> Function(HttpResponse response)? onResponse;

  /// Delegate for [Interceptor.onError].
  final Future<InterceptorResult<HttpResponse>> Function(NitroHttpException exception)? onFailure;

  @override
  Future<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) =>
      onRequest?.call(request) ?? super.beforeRequest(request);

  @override
  Future<InterceptorResult<HttpResponse>> afterResponse(HttpResponse response) =>
      onResponse?.call(response) ?? super.afterResponse(response);

  @override
  Future<InterceptorResult<HttpResponse>> onError(NitroHttpException exception) =>
      onFailure?.call(exception) ?? super.onError(exception);
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
  Future<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) async {
    if (members.isEmpty) return Interceptor.next();
    await _all(members.map((m) => m.beforeRequest(request)));
    return Interceptor.next();
  }

  @override
  Future<InterceptorResult<HttpResponse>> afterResponse(HttpResponse response) async {
    if (members.isEmpty) return Interceptor.next();
    await _all(members.map((m) => m.afterResponse(response)));
    return Interceptor.next();
  }

  @override
  Future<InterceptorResult<HttpResponse>> onError(NitroHttpException exception) async {
    if (members.isEmpty) return Interceptor.next();
    await _all(members.map((m) => m.onError(exception)));
    return Interceptor.next();
  }

  /// Awaits every member and rejects any attempt to alter the chain.
  ///
  /// `Future.wait` with the default `eagerError: false` so one member throwing
  /// does not leave the others unawaited — an abandoned hook would go on writing
  /// after the call it belongs to had finished.
  Future<void> _all<T>(Iterable<Future<InterceptorResult<T>>> hooks) async {
    final results = await Future.wait(hooks);
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
  Future<InterceptorOutcome<HttpRequest>> runBeforeRequest(HttpRequest request) async {
    var current = request;
    for (var i = 0; i < _interceptors.length; i++) {
      final result = await _invoke(
        () => _interceptors[i].beforeRequest(current),
        current,
      );
      switch (result.disposition) {
        case InterceptorDisposition.next:
          current = result.value ?? current;
        case InterceptorDisposition.stop:
          return InterceptorShortCircuit(result.value ?? current);
        case InterceptorDisposition.resolve:
          return InterceptorRecovered(result.resolved!);
      }
    }
    return InterceptorProceed(current);
  }

  /// Runs [Interceptor.afterResponse] across the chain in reverse order.
  ///
  /// [InterceptorDisposition.resolve] behaves like a stop that substitutes the
  /// supplied response wholesale.
  Future<InterceptorOutcome<HttpResponse>> runAfterResponse(HttpResponse response) async {
    var current = response;
    for (var i = _interceptors.length - 1; i >= 0; i--) {
      final result = await _invoke(
        () => _interceptors[i].afterResponse(current),
        current.request,
      );
      switch (result.disposition) {
        case InterceptorDisposition.next:
          current = result.value ?? current;
        case InterceptorDisposition.stop:
          return InterceptorShortCircuit(result.value ?? current);
        case InterceptorDisposition.resolve:
          return InterceptorRecovered(result.resolved!);
      }
    }
    return InterceptorProceed(current);
  }

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
  Future<InterceptorOutcome<HttpResponse>> runOnError(NitroHttpException exception) async {
    HttpResponse? candidate;
    for (var i = _interceptors.length - 1; i >= 0; i--) {
      final result = await _invoke(
        () => _interceptors[i].onError(exception),
        exception.request,
      );
      switch (result.disposition) {
        case InterceptorDisposition.next:
          candidate = result.value ?? candidate;
        case InterceptorDisposition.stop:
          final stopped = result.value ?? candidate;
          if (stopped == null) throw exception;
          return InterceptorShortCircuit(stopped);
        case InterceptorDisposition.resolve:
          return InterceptorRecovered(result.resolved!);
      }
    }
    if (candidate == null) throw exception;
    return InterceptorRecovered(candidate);
  }

  /// Normalises anything a hook throws into the typed exception hierarchy.
  ///
  /// The original stack trace is both attached to the exception and used for
  /// the rethrow, so a bug inside an interceptor still points at the line that
  /// caused it rather than at this frame.
  Future<InterceptorResult<T>> _invoke<T>(
    Future<InterceptorResult<T>> Function() hook,
    HttpRequest? request,
  ) async {
    try {
      return await hook();
    } on NitroHttpException catch (typed, stackTrace) {
      typed.stackTrace = stackTrace;
      rethrow;
    } catch (error, stackTrace) {
      final wrapped = NitroHttpUnknownException(
        request: request,
        engineMessage: 'interceptor threw: $error',
      )..stackTrace = stackTrace;
      Error.throwWithStackTrace(wrapped, stackTrace);
    }
  }
}
