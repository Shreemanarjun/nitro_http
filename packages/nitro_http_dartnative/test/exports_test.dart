import 'package:nitro_http/dio.dart' as upstream_dio;
import 'package:nitro_http/nitro_http.dart' as upstream;
import 'package:nitro_http_dartnative/dio.dart';
import 'package:nitro_http_dartnative/nitro_http_dartnative.dart';
import 'package:test/test.dart';

void main() {
  test('re-exports nitro_http types unchanged', () {
    expect(NitroHttpClient, same(upstream.NitroHttpClient));
    expect(ClientSettings, same(upstream.ClientSettings));
    expect(HttpTextResponse, same(upstream.HttpTextResponse));
    expect(NitroWebSocket, same(upstream.NitroWebSocket));
    expect(NitroHttpCompatClient, same(upstream.NitroHttpCompatClient));
    expect(NitroHttpDioAdapter, same(upstream_dio.NitroHttpDioAdapter));
  });
}
