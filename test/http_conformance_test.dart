// `package:http_client_conformance_tests` against `NitroHttpCompatClient`.
//
// This is the strongest available signal that the adapter is a genuine
// `package:http` drop-in: it is the same suite `cronet_http` and
// `cupertino_http` are validated with, it spins up its own servers in-process,
// and it covers the header, redirect, streaming, compression and multipart edge
// cases nobody writes by hand.
//
// Requires the native library, so it skips itself when that has not been built:
//
//   cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release
//   cmake --build build/lib -j8
//
// `NITRO_HTTP_DYLIB` overrides the path.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_client_conformance_tests/http_client_conformance_tests.dart';
import 'package:nitro_http/nitro_http.dart';

String? _locateLibrary() {
  final override = Platform.environment['NITRO_HTTP_DYLIB'];
  if (override != null && File(override).existsSync()) return override;
  for (final name in <String>[
    if (Platform.isMacOS) 'libnitro_http.dylib',
    if (Platform.isLinux) 'libnitro_http.so',
    if (Platform.isWindows) 'nitro_http.dll',
  ]) {
    for (final root in <String>['build/lib', 'build']) {
      final candidate = File('$root/$name');
      if (candidate.existsSync()) return candidate.absolute.path;
    }
  }
  return null;
}

void main() {
  final libraryPath = _locateLibrary();
  if (libraryPath == null) {
    test('http client conformance', () {}, skip: 'native library not built');
    return;
  }
  // Apple resolves through `DynamicLibrary.process()`, so the plugin must
  // already be in this process.
  DynamicLibrary.open(libraryPath);

  group('NitroHttpCompatClient', () {
    testAll(
      NitroHttpCompatClient.new,
      // The engine follows redirects itself, and `package:http` per-request
      // `followRedirects`/`maxRedirects` are mapped through, so the suite's
      // redirect-control expectations apply as written.
      redirectAlwaysAllowed: false,
      // curl uppercases well-known methods and passes an unknown token through
      // verbatim via CURLOPT_CUSTOMREQUEST.
      preservesMethodCase: true,
      // The cookie jar lives in the engine, so `Cookie`/`Set-Cookie` cross the
      // boundary like any other header.
      canSendCookieHeaders: true,
      canReceiveSetCookieHeaders: true,
      // Verified, not assumed: with this flipped on, the isolate test fails
      // with a cancelled request. Each client owns an OS thread and a
      // curl_multi, and `Dart_PostCObject_DL` ports are isolate-scoped.
      canWorkInIsolates: false,
      // Verified, not assumed: with this flipped on, curl reports `BAR` for
      // `foo: BAR\r\n BAZ\r\n`. It drops the continuation line rather than
      // folding it, and nothing downstream can put it back.
      supportsFoldedHeaders: false,
      // `http.Abortable`'s `abortTrigger` is wired to a `CancelToken`, which is
      // the same one-shot signal under another name, and the engine already
      // tears a transfer down mid-body on it. All nine abort cases pass.
      supportsAbort: true,
    );
  });
}
