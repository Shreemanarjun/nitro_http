/// Retry policy and the interceptor that carries it.
///
/// ## Why this is split in two
///
/// An interceptor cannot retry a request by itself: it has no reference to the
/// client, and giving it one would let a hook re-enter the very chain it is
/// currently suspended inside. That re-entrancy hazard is not theoretical — an
/// interceptor that both observes responses and re-issues requests will observe
/// its own retries, and any per-request state it keeps (an attempt counter, a
/// mutex, a token refresh future) is then mutated recursively.
///
/// So the decision and the action are separated:
///
/// * [RetryPolicy] is a pure value type. Given a response or an error and the
///   number of attempts already made, it answers *should we retry*, *how long
///   do we wait*, and *what request do we send next*. It touches nothing.
/// * [RetryInterceptor] carries a policy through the interceptor list. Its
///   hooks are pass-throughs; it exists so users configure retries the same way
///   they configure everything else.
///
/// The request runner looks for a [RetryInterceptor] in the chain, reads
/// [RetryInterceptor.policy], and drives the loop itself — it is the only party
/// that can legitimately re-issue a request. [RetryInterceptor.nextAttempt]
/// packages the whole decision so the runner stays a straight loop.
library;

import 'dart:async';
import 'dart:math';

import 'exceptions.dart';
import 'interceptor.dart';
import 'request.dart';
import 'response.dart';

/// Shared source of jitter for policies that were not given their own [Random].
final Random _sharedRandom = Random();

/// Decides whether, when and how a failed attempt is retried.
///
/// Every knob is a closure so callers can replace a rule without subclassing,
/// and so tests can pin behaviour exactly. `attempt` is always the number of
/// attempts *already completed*: the first response has `attempt == 0`.
class RetryPolicy {
  /// Creates a policy.
  ///
  /// [delay], [shouldRetry] and [beforeRetry] each replace the corresponding
  /// default entirely. [random] seeds the jitter of the default backoff and is
  /// injectable so tests get a deterministic sequence.
  const RetryPolicy({
    this.maxRetries = 3,
    this._delay,
    this._shouldRetry,
    this._beforeRetry,
    this._random,
    this.baseDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 30),
    this.respectRetryAfter = true,
    this.maxRetryAfter = const Duration(seconds: 60),
  });

  /// How many retries are allowed after the initial attempt.
  ///
  /// `maxRetries: 3` means at most four requests in total.
  final int maxRetries;

  /// First backoff step of the default schedule.
  final Duration baseDelay;

  /// Ceiling for the default exponential schedule, before jitter.
  final Duration maxDelay;

  /// Whether a `Retry-After` response header overrides the computed backoff.
  final bool respectRetryAfter;

  /// Ceiling applied to a `Retry-After` value.
  ///
  /// A server can ask for an hour; honouring that verbatim would silently hang
  /// the caller's future, so the wait is clamped.
  final Duration maxRetryAfter;

  /// Replaces the default backoff schedule; constructor parameter `delay`.
  final Duration Function(int attempt)? _delay;

  /// Replaces the default transient-failure rule; parameter `shouldRetry`.
  final bool Function(HttpResponse? response, NitroHttpException? error, int attempt)? _shouldRetry;

  /// Runs between attempts; constructor parameter `beforeRetry`.
  final FutureOr<HttpRequest?> Function(HttpRequest request, int attempt)? _beforeRetry;

  /// Jitter source; constructor parameter `random`.
  final Random? _random;

  /// Status codes the default rule treats as transient.
  ///
  /// 408 Request Timeout, 429 Too Many Requests, and the 5xx codes that mean
  /// "the upstream is momentarily unavailable". Notably absent: 501 and 505,
  /// which will fail identically forever.
  static const Set<int> retryableStatusCodes = {408, 429, 500, 502, 503, 504};

  /// Whether the attempt that produced [response] or [error] should be retried.
  ///
  /// [maxRetries] is a hard cap checked before any custom predicate runs, so a
  /// user rule can narrow the default behaviour but never exceed the budget.
  bool shouldRetry(HttpResponse? response, NitroHttpException? error, int attempt) {
    if (attempt >= maxRetries) return false;
    final custom = _shouldRetry;
    if (custom != null) return custom(response, error, attempt);
    return isRetryableByDefault(response, error);
  }

  /// The default transient-failure rule, exposed so custom predicates can
  /// delegate to it for the cases they do not care about.
  ///
  /// Retries connection failures (except an unsupported scheme, which is a
  /// permanent programming error), timeouts, and retryable status codes —
  /// whether the status arrived as a [HttpResponse] or, when the client is
  /// configured to throw on status codes, as a
  /// [NitroHttpStatusCodeException].
  ///
  /// Never retries a [NitroHttpCancelException]: a cancelled request stays
  /// cancelled, and resurrecting it would defeat the cancel token.
  static bool isRetryableByDefault(HttpResponse? response, NitroHttpException? error) {
    if (error != null) {
      return switch (error) {
        NitroHttpCancelException() => false,
        NitroHttpTimeoutException() => true,
        NitroHttpConnectionException(:final failure) =>
          failure != ConnectionFailure.unsupportedScheme,
        NitroHttpStatusCodeException(:final statusCode) =>
          retryableStatusCodes.contains(statusCode),
        // Everything below is a permanent failure of this request: a rejected
        // certificate, a redirect loop, a malformed reply, a body that would
        // not decode, an empty cache under `onlyIfCached`, a disposed client,
        // or a failure the engine could not classify. Replaying any of them
        // just spends the retry budget on the same outcome.
        NitroHttpCertificateException() ||
        NitroHttpRedirectException() ||
        NitroHttpProtocolException() ||
        NitroHttpDecodingException() ||
        NitroHttpCacheMissException() ||
        NitroHttpDisposedException() ||
        NitroHttpUnknownException() => false,
      };
    }
    if (response != null) return retryableStatusCodes.contains(response.statusCode);
    return false;
  }

  /// How long to wait before the retry that follows [attempt].
  ///
  /// A `Retry-After` header on [response] wins when [respectRetryAfter] is set
  /// — the server knows more about its own recovery than any client-side curve
  /// — clamped to [maxRetryAfter]. Otherwise the custom [delay] closure runs,
  /// and failing that the default schedule: `baseDelay * 2^attempt` capped at
  /// [maxDelay], then *full jitter* — a uniform draw from `[0, cap]`.
  ///
  /// Full jitter rather than the cap itself because a fleet of clients that
  /// backs off by the same amount retries in the same instant and re-creates
  /// the thundering herd it was backing off from.
  Duration delayFor(int attempt, {HttpResponse? response, NitroHttpException? error}) {
    if (respectRetryAfter) {
      final hinted = _retryAfterOf(response, error);
      if (hinted != null) {
        return hinted > maxRetryAfter ? maxRetryAfter : hinted;
      }
    }
    final custom = _delay;
    if (custom != null) return custom(attempt);
    return _exponentialWithJitter(attempt);
  }

  /// The request to send for retry [attempt], or `null` to give up.
  ///
  /// Runs the `beforeRetry` closure, which is the seam for refreshing a token
  /// or rewriting a URL between attempts. Returning `null` aborts the retry and
  /// surfaces the original failure.
  FutureOr<HttpRequest?> prepare(HttpRequest request, int attempt) {
    final hook = _beforeRetry;
    if (hook == null) return request;
    return hook(request, attempt);
  }

  Duration _exponentialWithJitter(int attempt) {
    final cap = _cappedBackoff(attempt);
    final random = _random ?? _sharedRandom;
    return Duration(microseconds: (cap.inMicroseconds * random.nextDouble()).round());
  }

  /// `baseDelay * 2^attempt`, saturating at [maxDelay].
  ///
  /// Computed in microseconds against the cap rather than by shifting, because
  /// a large [attempt] would overflow the shift long before the multiplication
  /// is meaningful.
  Duration _cappedBackoff(int attempt) {
    final capMicros = maxDelay.inMicroseconds;
    var micros = baseDelay.inMicroseconds;
    for (var i = 0; i < attempt; i++) {
      if (micros >= capMicros) return maxDelay;
      micros *= 2;
    }
    return micros >= capMicros ? maxDelay : Duration(microseconds: micros);
  }

  Duration? _retryAfterOf(HttpResponse? response, NitroHttpException? error) {
    final headers = response?.headers ??
        (error is NitroHttpStatusCodeException ? error.headers : null);
    final value = headers?['retry-after'];
    if (value == null) return null;
    return RetryInterceptor.parseRetryAfter(value);
  }
}

/// Carries a [RetryPolicy] through the interceptor list.
///
/// The hooks inherit [Interceptor]'s pass-through defaults on purpose: this
/// type never re-issues anything (see the library doc). The runner finds it in
/// the chain, reads [policy], and calls [nextAttempt] between attempts.
///
/// ```dart
/// final client = NitroHttpClient(
///   interceptors: [RetryInterceptor(maxRetries: 5)],
/// );
/// ```
class RetryInterceptor extends Interceptor {
  /// Creates a retry interceptor.
  ///
  /// [sleep] and [random] are injected rather than captured so tests can drive
  /// the backoff with a fake clock and a seeded generator, asserting the exact
  /// delay sequence without waiting for it.
  RetryInterceptor({
    int maxRetries = 3,
    Duration Function(int attempt)? delay,
    bool Function(HttpResponse? response, NitroHttpException? error, int attempt)? shouldRetry,
    FutureOr<HttpRequest?> Function(HttpRequest request, int attempt)? beforeRetry,
    Future<void> Function(Duration duration)? sleep,
    Random? random,
    Duration baseDelay = const Duration(milliseconds: 200),
    Duration maxDelay = const Duration(seconds: 30),
    bool respectRetryAfter = true,
  })  : policy = RetryPolicy(
          maxRetries: maxRetries,
          delay: delay,
          shouldRetry: shouldRetry,
          beforeRetry: beforeRetry,
          random: random,
          baseDelay: baseDelay,
          maxDelay: maxDelay,
          respectRetryAfter: respectRetryAfter,
        ),
        _sleep = sleep ?? _realSleep;

  /// Creates an interceptor around an already-built [policy].
  RetryInterceptor.withPolicy(
    this.policy, {
    Future<void> Function(Duration duration)? sleep,
  }) : _sleep = sleep ?? _realSleep;

  /// The decision logic the runner consults.
  final RetryPolicy policy;

  final Future<void> Function(Duration duration) _sleep;

  var _retriesPerformed = 0;

  /// How many retries this interceptor has waited out since construction.
  ///
  /// Purely observational — useful in tests and metrics.
  int get retriesPerformed => _retriesPerformed;

  /// Waits [duration] using the injected clock.
  Future<void> wait(Duration duration) => _sleep(duration);

  /// Decides the next attempt after [request] failed, waits out the backoff,
  /// and returns the request to send — or `null` when the runner should stop
  /// and surface [error] (or [response]) to the caller.
  ///
  /// Exactly one of [response] and [error] is expected; [attempt] is the number
  /// of attempts already completed.
  Future<HttpRequest?> nextAttempt(
    HttpRequest request, {
    required int attempt,
    HttpResponse? response,
    NitroHttpException? error,
  }) async {
    if (!policy.shouldRetry(response, error, attempt)) return null;
    final next = await policy.prepare(request, attempt);
    if (next == null) return null;
    await wait(policy.delayFor(attempt, response: response, error: error));
    _retriesPerformed++;
    return next;
  }

  /// Parses a `Retry-After` header value.
  ///
  /// Accepts both forms from RFC 9110 §10.2.3: delta-seconds (`120`) and an
  /// HTTP-date (`Wed, 21 Oct 2015 07:28:00 GMT`, plus the obsolete RFC 850 and
  /// asctime forms every HTTP parser must still accept). Returns `null` when
  /// the value is neither.
  ///
  /// A date already in the past yields [Duration.zero] rather than a negative
  /// duration, so callers can wait on the result unconditionally. [now] is
  /// injectable so date-form parsing is testable.
  static Duration? parseRetryAfter(String value, {DateTime? now}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    if (_deltaSeconds.hasMatch(trimmed)) {
      final seconds = int.tryParse(trimmed);
      return seconds == null ? null : Duration(seconds: seconds);
    }

    final date = _parseHttpDate(trimmed);
    if (date == null) return null;
    final reference = (now ?? DateTime.now()).toUtc();
    final delta = date.difference(reference);
    return delta.isNegative ? Duration.zero : delta;
  }

  static Future<void> _realSleep(Duration duration) => Future<void>.delayed(duration);

  static final RegExp _deltaSeconds = RegExp(r'^\d+$');

  static const Map<String, int> _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// Parses the three date formats RFC 9110 §5.6.7 requires a recipient to
  /// accept, returning UTC.
  ///
  /// Hand-rolled rather than borrowed from `dart:io` so this file stays free of
  /// platform imports and remains unit-testable without a Flutter binding.
  static DateTime? _parseHttpDate(String value) {
    final comma = value.indexOf(',');
    if (comma < 0) return _parseAsctime(value);
    final rest = value.substring(comma + 1).trim();
    return rest.contains('-') ? _parseRfc850(rest) : _parseRfc1123(rest);
  }

  /// `06 Nov 1994 08:49:37 GMT`
  static DateTime? _parseRfc1123(String rest) {
    final parts = _words(rest);
    if (parts.length < 4) return null;
    return _assemble(parts[0], parts[1], parts[2], parts[3]);
  }

  /// `06-Nov-94 08:49:37 GMT`
  static DateTime? _parseRfc850(String rest) {
    final parts = _words(rest);
    if (parts.length < 2) return null;
    final date = parts[0].split('-');
    if (date.length != 3) return null;
    final shortYear = int.tryParse(date[2]);
    if (shortYear == null) return null;
    // RFC 6265 §5.1.1's window: a two-digit year below 70 is 21st century.
    final year = date[2].length <= 2 ? (shortYear < 70 ? 2000 + shortYear : 1900 + shortYear) : shortYear;
    return _assemble(date[0], date[1], '$year', parts[1]);
  }

  /// `Sun Nov  6 08:49:37 1994`
  static DateTime? _parseAsctime(String value) {
    final parts = _words(value);
    if (parts.length < 5) return null;
    return _assemble(parts[2], parts[1], parts[4], parts[3]);
  }

  static List<String> _words(String value) =>
      value.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList(growable: false);

  static DateTime? _assemble(String day, String month, String year, String time) {
    final d = int.tryParse(day);
    final m = _months[month.toLowerCase()];
    final y = int.tryParse(year);
    final clock = time.split(':');
    if (d == null || m == null || y == null || clock.length != 3) return null;
    final hour = int.tryParse(clock[0]);
    final minute = int.tryParse(clock[1]);
    final second = int.tryParse(clock[2]);
    if (hour == null || minute == null || second == null) return null;
    if (d < 1 || d > 31 || hour > 23 || minute > 59 || second > 60) return null;
    // Second 60 is a leap second; clamp so DateTime does not roll the minute.
    return DateTime.utc(y, m, d, hour, minute, second == 60 ? 59 : second);
  }
}
