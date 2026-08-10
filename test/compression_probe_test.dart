// Verifies the two halves of content compression against the real engine:
// what goes on the wire, and what comes back decoded.
//
// libcurl's `CURLOPT_ACCEPT_ENCODING` defaults to NULL, which means no
// `Accept-Encoding` header and no automatic decompression. This engine therefore
// sets it explicitly — and deliberately NOT to `""`, which would advertise
// whatever the locally linked libcurl happens to inflate and would abort the
// transfer on an unknown coding. See `ClientConfig::applyTo`.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

/// Captures the request head a client writes, by answering nothing.
Future<String> captureHead(Future<void> Function(String origin) send) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final bytes = <int>[];
  final firstRequest = Completer<void>();
  server.listen((socket) {
    socket.listen((chunk) {
      bytes.addAll(chunk);
      if (!firstRequest.isCompleted &&
          String.fromCharCodes(bytes).contains('\r\n\r\n')) {
        firstRequest.complete();
      }
    });
  });
  try {
    await send('http://127.0.0.1:${server.port}');
  } on Object {
    // A client that times out against a silent socket still wrote its head,
    // which is the only thing under test here.
  }
  if (!firstRequest.isCompleted) {
    await firstRequest.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
  }
  await server.close();
  return String.fromCharCodes(bytes).split('\r\n\r\n').first;
}

/// Mirrors `native_smoke_test.dart`: the probe needs a locally built engine,
/// and a checkout that has not run cmake (CI's unit-test job, a fresh clone)
/// must skip rather than fail.
String? _locateLibrary() {
  final override = Platform.environment['NITRO_HTTP_DYLIB'];
  if (override != null && File(override).existsSync()) return override;

  final names = <String>[
    if (Platform.isMacOS) 'libnitro_http.dylib',
    if (Platform.isLinux) 'libnitro_http.so',
    if (Platform.isWindows) 'nitro_http.dll',
  ];
  for (final root in <String>['build/lib', 'build/cpptest', 'build']) {
    for (final name in names) {
      final candidate = File('$root/$name');
      if (candidate.existsSync()) return candidate.absolute.path;
    }
  }
  return null;
}

void main() {
  final libraryPath = _locateLibrary();
  final skipReason = libraryPath == null
      ? 'native library not built — run: cmake -S src -B build/lib && '
            'cmake --build build/lib'
      : null;

  setUpAll(() {
    if (libraryPath == null) return;
    DynamicLibrary.open(libraryPath);
  });

  test('compression on advertises exactly what the engine can inflate', () async {
    final head = await captureHead((origin) async {
      final client = NitroHttpClient(settings: ClientSettings(baseUrl: origin));
      try {
        await client.get(
          '/x',
          options: const RequestOptions(timeout: Duration(seconds: 1)),
        );
      } finally {
        client.dispose();
      }
    });

    final line = head
        .split('\r\n')
        .firstWhere(
          (l) => l.toLowerCase().startsWith('accept-encoding:'),
          orElse: () => '',
        );
    expect(line, isNotEmpty, reason: 'no Accept-Encoding was sent at all:\n$head');
    // gzip and deflate come from zlib, which the engine always has. brotli and
    // zstd are advertised only when the linked build can actually inflate them —
    // advertising a coding we cannot decode would be the bug this guards.
    expect(line.toLowerCase(), contains('gzip'));
    expect(line.toLowerCase(), contains('deflate'));
    expect(
      line.toLowerCase().contains('br'),
      NitroHttp.supportsBrotli,
      reason: 'brotli must be advertised exactly when it can be inflated',
    );
    expect(
      line.toLowerCase().contains('zstd'),
      NitroHttp.supportsZstd,
      reason: 'zstd must be advertised exactly when it can be inflated',
    );
  }, skip: skipReason);

  test('compression off sends no Accept-Encoding at all', () async {
    final head = await captureHead((origin) async {
      final client = NitroHttpClient(
        settings: ClientSettings(baseUrl: origin, enableCompression: false),
      );
      try {
        await client.get(
          '/x',
          options: const RequestOptions(timeout: Duration(seconds: 1)),
        );
      } finally {
        client.dispose();
      }
    });

    expect(
      head.toLowerCase(),
      isNot(contains('accept-encoding')),
      reason: 'enableCompression: false must map to CURLOPT_ACCEPT_ENCODING '
          'NULL, which sends no header:\n$head',
    );
  }, skip: skipReason);

  test('a gzip body arrives decoded, and the header is not lying', () async {
    // A real server this time: the point is the response half.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final plain = 'nitro_http compression probe — the quick brown fox. ' * 20;
    server.listen((req) async {
      final gzipped = gzip.encode(utf8.encode(plain));
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'text/plain')
        ..headers.set('content-encoding', 'gzip')
        ..headers.contentLength = gzipped.length
        ..add(gzipped);
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    final client = NitroHttpClient(
      settings: ClientSettings(baseUrl: 'http://127.0.0.1:${server.port}'),
    );
    addTearDown(client.dispose);

    final res = await client.get('/gz');
    expect(res.statusCode, 200);
    expect(
      res.body,
      plain,
      reason: 'the engine must inflate gzip itself, because '
          'CURLOPT_HTTP_CONTENT_DECODING is deliberately off',
    );
    // The decoded body must not still claim to be encoded, or a caller that
    // trusts the header would try to inflate it twice.
    expect(res.headers['content-encoding'], isNull);
  }, skip: skipReason);
}
