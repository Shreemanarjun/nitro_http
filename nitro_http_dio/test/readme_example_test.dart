/// The `dio` snippet from the main package's README, compiled and run here
/// because this is the package that owns `useNitroHttp` and
/// `NitroHttpDioAdapter`. The adapter builds its owned client eagerly — which
/// would bind the native library — so the snippet runs under
/// [NitroHttpDioAdapter.clientFactoryForTesting], the same seam
/// `adapter_test.dart` uses.
library;

import 'package:dio/dio.dart';
import 'package:nitro_http/nitro_http.dart'
    show ClientSettings, NitroHttpClient;
import 'package:nitro_http_dio/nitro_http_dio.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  setUp(() {
    NitroHttpDioAdapter.clientFactoryForTesting = (forced) {
      final demux = FakeStreamDemux();
      return NitroHttpClient(
        settings: forced,
        executor: FakeRequestExecutor(demux),
        demux: demux,
      );
    };
  });

  tearDown(() => NitroHttpDioAdapter.clientFactoryForTesting = null);

  test('README dio snippet compiles and constructs', () {
    final dio = Dio()..useNitroHttp();
    expect(dio.httpClientAdapter, isA<NitroHttpDioAdapter>());

    // or, with settings or a shared client:
    final dio2 = Dio()
      ..httpClientAdapter = NitroHttpDioAdapter(
        settings: const ClientSettings(timeout: Duration(seconds: 30)),
      );
    expect(dio2.httpClientAdapter, isA<NitroHttpDioAdapter>());
  });
}
