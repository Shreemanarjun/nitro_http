import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

import 'support/fakes.dart';

/// An interceptor that appends `<name>.<hook>` to a shared log before
/// delegating, so a test can assert the exact traversal order.
final class _Recorder extends Interceptor {
  _Recorder(
    this.name,
    this.log, {
    this.onRequest,
    this.onResponse,
    this.onFailure,
  });

  final String name;
  final List<String> log;
  final Future<InterceptorResult<HttpRequest>> Function(HttpRequest)? onRequest;
  final Future<InterceptorResult<HttpResponse>> Function(HttpResponse)?
  onResponse;
  final Future<InterceptorResult<HttpResponse>> Function(NitroHttpException)?
  onFailure;

  @override
  Future<InterceptorResult<HttpRequest>> beforeRequest(HttpRequest request) {
    log.add('$name.beforeRequest');
    return onRequest?.call(request) ?? super.beforeRequest(request);
  }

  @override
  Future<InterceptorResult<HttpResponse>> afterResponse(HttpResponse response) {
    log.add('$name.afterResponse');
    return onResponse?.call(response) ?? super.afterResponse(response);
  }

  @override
  Future<InterceptorResult<HttpResponse>> onError(NitroHttpException e) {
    log.add('$name.onError');
    return onFailure?.call(e) ?? super.onError(e);
  }
}

void main() {
  test('an empty chain passes everything straight through', () async {
    const chain = InterceptorChain(<Interceptor>[]);
    final request = fakeRequest();
    final response = fakeTextResponse();

    expect(chain.isEmpty, isTrue);
    expect(chain.interceptors, isEmpty);
    expect(
      await chain.runBeforeRequest(request),
      isA<InterceptorProceed<HttpRequest>>().having(
        (o) => o.value,
        'value',
        same(request),
      ),
    );
    expect(
      await chain.runAfterResponse(response),
      isA<InterceptorProceed<HttpResponse>>().having(
        (o) => o.value,
        'value',
        same(response),
      ),
    );
  });

  test('the interceptor list is exposed unmodifiably', () {
    final chain = InterceptorChain(<Interceptor>[const DelegatingInterceptor()]);

    expect(chain.interceptors, hasLength(1));
    expect(chain.isEmpty, isFalse);
    expect(
      () => chain.interceptors.add(const DelegatingInterceptor()),
      throwsUnsupportedError,
    );
  });

  group('ordering', () {
    test('beforeRequest runs in registration order', () async {
      final log = <String>[];
      final chain = InterceptorChain(<Interceptor>[
        _Recorder('a', log),
        _Recorder('b', log),
        _Recorder('c', log),
      ]);

      await chain.runBeforeRequest(fakeRequest());

      expect(log, <String>[
        'a.beforeRequest',
        'b.beforeRequest',
        'c.beforeRequest',
      ]);
    });

    test('afterResponse runs in reverse registration order', () async {
      final log = <String>[];
      final chain = InterceptorChain(<Interceptor>[
        _Recorder('a', log),
        _Recorder('b', log),
        _Recorder('c', log),
      ]);

      await chain.runAfterResponse(fakeTextResponse());

      expect(log, <String>[
        'c.afterResponse',
        'b.afterResponse',
        'a.afterResponse',
      ]);
    });

    test('onError runs in reverse registration order', () async {
      final log = <String>[];
      final recovery = fakeTextResponse();
      final chain = InterceptorChain(<Interceptor>[
        _Recorder('a', log),
        _Recorder('b', log),
        _Recorder(
          'c',
          log,
          onFailure: (_) async => Interceptor.next(recovery),
        ),
      ]);

      await chain.runOnError(NitroHttpProtocolException());

      expect(log, <String>['c.onError', 'b.onError', 'a.onError']);
    });
  });

  group('dispositions', () {
    test('next(value) replaces the value flowing through the chain', () async {
      final seen = <Uri>[];
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(
          onRequest: (r) async {
            seen.add(r.url);
            return Interceptor.next(
              r.copyWith(url: Uri.parse('https://rewritten.test/')),
            );
          },
        ),
        DelegatingInterceptor(
          onRequest: (r) async {
            seen.add(r.url);
            return Interceptor.next();
          },
        ),
      ]);

      final outcome = await chain.runBeforeRequest(
        fakeRequest(url: 'https://original.test/'),
      );

      expect(seen.map((u) => u.toString()), <String>[
        'https://original.test/',
        'https://rewritten.test/',
      ]);
      expect(
        outcome,
        isA<InterceptorProceed<HttpRequest>>().having(
          (o) => o.value.url.toString(),
          'url',
          'https://rewritten.test/',
        ),
      );
    });

    test('next() with no value leaves the current value alone', () async {
      final response = fakeTextResponse(status: 204);
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(onResponse: (_) async => Interceptor.next()),
      ]);

      final outcome = await chain.runAfterResponse(response);

      expect(
        outcome,
        isA<InterceptorProceed<HttpResponse>>().having(
          (o) => o.value,
          'value',
          same(response),
        ),
      );
    });

    test('stop short-circuits and later interceptors never run', () async {
      final log = <String>[];
      final replacement = fakeRequest(url: 'https://stopped.test/');
      final chain = InterceptorChain(<Interceptor>[
        _Recorder(
          'a',
          log,
          onRequest: (_) async => Interceptor.stop(replacement),
        ),
        _Recorder('b', log),
      ]);

      final outcome = await chain.runBeforeRequest(fakeRequest());

      expect(log, <String>['a.beforeRequest']);
      expect(
        outcome,
        isA<InterceptorShortCircuit<HttpRequest>>().having(
          (o) => o.value,
          'value',
          same(replacement),
        ),
      );
    });

    test('stop in afterResponse skips the outer interceptors', () async {
      final log = <String>[];
      final chain = InterceptorChain(<Interceptor>[
        _Recorder('outer', log),
        _Recorder('inner', log, onResponse: (_) async => Interceptor.stop()),
      ]);

      final response = fakeTextResponse();
      final outcome = await chain.runAfterResponse(response);

      expect(log, <String>['inner.afterResponse']);
      expect(
        outcome,
        isA<InterceptorShortCircuit<HttpResponse>>().having(
          (o) => o.value,
          'value',
          same(response),
        ),
      );
    });

    test('resolve in beforeRequest answers without touching the network', () async {
      final canned = fakeTextResponse(status: 203);
      final log = <String>[];
      final chain = InterceptorChain(<Interceptor>[
        _Recorder('a', log, onRequest: (_) async => Interceptor.resolve(canned)),
        _Recorder('b', log),
      ]);

      final outcome = await chain.runBeforeRequest(fakeRequest());

      expect(log, <String>['a.beforeRequest']);
      expect(
        outcome,
        isA<InterceptorRecovered<HttpRequest>>().having(
          (o) => o.response,
          'response',
          same(canned),
        ),
      );
    });

    test('resolve in onError turns the failure into a response', () async {
      final canned = fakeTextResponse(status: 200);
      final log = <String>[];
      final chain = InterceptorChain(<Interceptor>[
        _Recorder('a', log),
        _Recorder('b', log, onFailure: (_) async => Interceptor.resolve(canned)),
      ]);

      final outcome = await chain.runOnError(NitroHttpProtocolException());

      expect(log, <String>['b.onError']);
      expect(
        outcome,
        isA<InterceptorRecovered<HttpResponse>>().having(
          (o) => o.response,
          'response',
          same(canned),
        ),
      );
    });

    test('a next() candidate in onError recovers once the chain finishes', () async {
      final candidate = fakeTextResponse(status: 200);
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(
          onFailure: (_) async => Interceptor.next(candidate),
        ),
      ]);

      final outcome = await chain.runOnError(NitroHttpProtocolException());

      expect(
        outcome,
        isA<InterceptorRecovered<HttpResponse>>().having(
          (o) => o.response,
          'response',
          same(candidate),
        ),
      );
    });

    test('an outer interceptor may replace an inner candidate', () async {
      final inner = fakeTextResponse(status: 500);
      final outer = fakeTextResponse(status: 200);
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(onFailure: (_) async => Interceptor.stop(outer)),
        DelegatingInterceptor(onFailure: (_) async => Interceptor.next(inner)),
      ]);

      final outcome = await chain.runOnError(NitroHttpProtocolException());

      expect(
        outcome,
        isA<InterceptorShortCircuit<HttpResponse>>().having(
          (o) => o.value,
          'value',
          same(outer),
        ),
      );
    });

    test('stop with a candidate already recorded uses that candidate', () async {
      final candidate = fakeTextResponse(status: 200);
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(onFailure: (_) async => Interceptor.stop()),
        DelegatingInterceptor(
          onFailure: (_) async => Interceptor.next(candidate),
        ),
      ]);

      final outcome = await chain.runOnError(NitroHttpProtocolException());

      expect(
        outcome,
        isA<InterceptorShortCircuit<HttpResponse>>().having(
          (o) => o.value,
          'value',
          same(candidate),
        ),
      );
    });
  });

  group('unhandled failures', () {
    test('an unhandled onError rethrows the original exception', () async {
      final failure = NitroHttpProtocolException(engineMessage: 'bad framing');
      final chain = InterceptorChain(<Interceptor>[
        const DelegatingInterceptor(),
        const DelegatingInterceptor(),
      ]);

      await expectLater(
        chain.runOnError(failure),
        throwsA(same(failure)),
      );
    });

    test('stop with no candidate is still unhandled', () async {
      final failure = NitroHttpProtocolException();
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(onFailure: (_) async => Interceptor.stop()),
      ]);

      await expectLater(chain.runOnError(failure), throwsA(same(failure)));
    });
  });

  group('hooks that throw', () {
    test('a NitroHttpException passes through unchanged', () async {
      final thrown = NitroHttpCacheMissException(engineMessage: 'cold');
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(onRequest: (_) async => throw thrown),
      ]);

      await expectLater(
        chain.runBeforeRequest(fakeRequest()),
        throwsA(same(thrown)),
      );
      expect(thrown.stackTrace, isNotNull);
    });

    test('a foreign object is wrapped, carrying the request and the original text', () async {
      final request = fakeRequest(url: 'https://wrapped.test/');
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(
          onRequest: (_) async => throw const FormatException('nope'),
        ),
      ]);

      await expectLater(
        chain.runBeforeRequest(request),
        throwsA(
          isA<NitroHttpUnknownException>()
              .having((e) => e.request, 'request', same(request))
              .having(
                (e) => e.engineMessage,
                'engineMessage',
                contains('interceptor threw: FormatException: nope'),
              )
              .having((e) => e.stackTrace, 'stackTrace', isNotNull),
        ),
      );
    });

    test('a foreign object thrown from afterResponse is wrapped too', () async {
      final response = fakeTextResponse();
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(onResponse: (_) async => throw StateError('x')),
      ]);

      await expectLater(
        chain.runAfterResponse(response),
        throwsA(
          isA<NitroHttpUnknownException>().having(
            (e) => e.request,
            'request',
            same(response.request),
          ),
        ),
      );
    });

    test('a foreign object thrown from onError is wrapped, not swallowed', () async {
      final chain = InterceptorChain(<Interceptor>[
        DelegatingInterceptor(onFailure: (_) async => throw StateError('x')),
      ]);

      await expectLater(
        chain.runOnError(NitroHttpProtocolException()),
        throwsA(isA<NitroHttpUnknownException>()),
      );
    });
  });

  test('DelegatingInterceptor falls back to the pass-through defaults', () async {
    const interceptor = DelegatingInterceptor();
    final request = fakeRequest();

    expect(
      (await interceptor.beforeRequest(request)).disposition,
      InterceptorDisposition.next,
    );
    expect(
      (await interceptor.afterResponse(fakeTextResponse())).disposition,
      InterceptorDisposition.next,
    );
    expect(
      (await interceptor.onError(NitroHttpProtocolException())).disposition,
      InterceptorDisposition.next,
    );
    expect(
      Interceptor.next<int>(1).toString(),
      'InterceptorResult(next)',
    );
  });
}
