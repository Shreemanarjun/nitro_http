import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

/// Range requests are how a download or upload picks up where it left off, so
/// what matters is that the engine stays out of the way: the headers reach the
/// wire untouched, a 206 survives as a 206 rather than being normalised to 200,
/// and a partial body is delivered as-is instead of being stitched back into a
/// whole one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dylib = 'build/lib/libnitro_http.dylib';
  final available = File(dylib).existsSync();
  final skipReason = available ? null : 'build the engine first: tool/build-cpp.sh';

  late HttpServer server;
  late Uint8List payload;
  late String base;
  String receivedRange = '';
  String receivedContentRange = '';
  int receivedUploadBytes = 0;
  NitroHttpClient? client;

  setUpAll(() async {
    if (!available) return;
    DynamicLibrary.open(dylib);
    // A byte pattern rather than zeros, so a wrong offset shows up as a content
    // mismatch instead of matching by accident.
    payload = Uint8List.fromList(List.generate(10000, (i) => i % 251));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      if (request.uri.path == '/upload') {
        receivedContentRange = request.headers.value('content-range') ?? '';
        final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        receivedUploadBytes = body.length;
        // 308 with a Range header is the resumable-upload idiom: "I have this
        // much, continue from there."
        request.response
          ..statusCode = 308
          ..headers.set('Range', 'bytes=0-${body.length - 1}');
        await request.response.close();
        return;
      }
      final range = request.headers.value('range');
      receivedRange = range ?? '';
      request.response.headers.set('Accept-Ranges', 'bytes');
      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts[1].isEmpty ? payload.length - 1 : int.parse(parts[1]);
        request.response
          ..statusCode = 206
          ..headers.set('Content-Range', 'bytes $start-$end/${payload.length}')
          ..add(payload.sublist(start, end + 1));
      } else {
        request.response.add(payload);
      }
      await request.response.close();
    });
  });

  tearDown(() {
    client?.dispose();
    client = null;
  });

  tearDownAll(() async {
    if (available) await server.close(force: true);
  });

  group('resumable transfers', () {
    test('a buffered Range request returns exactly the requested tail', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(timeout: Duration(seconds: 20)),
      );
      final response = await client!.get(
        '$base/file',
        headers: HttpHeaders.fromMap({'Range': 'bytes=4000-'}),
      );

      // 206 is a success code, so it survives throwOnStatusCode (on by default).
      expect(response.statusCode, 206);
      expect(receivedRange, 'bytes=4000-');
      expect(response.headers['content-range'], 'bytes 4000-9999/10000');
      expect(response.bodyBytes, payload.sublist(4000));
    }, skip: skipReason);

    test('a streamed Range request delivers the slice unstitched', () async {
      // The realistic resume path for a large file: the caller appends to what
      // is already on disk rather than holding the whole body.
      client = NitroHttpClient(
        settings: const ClientSettings(timeout: Duration(seconds: 20)),
      );
      final response = await client!.requestStream(
        HttpMethod.get,
        '$base/file',
        headers: HttpHeaders.fromMap({'Range': 'bytes=9000-9099'}),
      );
      final received = <int>[];
      await for (final chunk in response.body) {
        received.addAll(chunk);
      }

      expect(response.statusCode, 206);
      expect(received, payload.sublist(9000, 9100));
    }, skip: skipReason);

    test('an upload can start at an offset with Content-Range', () async {
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          throwOnStatusCode: false,
        ),
      );
      final tail = payload.sublist(6000);
      final response = await client!.put(
        '$base/upload',
        body: HttpBody.bytes(tail),
        headers: HttpHeaders.fromMap({
          'Content-Range': 'bytes 6000-9999/10000',
        }),
      );

      expect(response.statusCode, 308);
      expect(receivedContentRange, 'bytes 6000-9999/10000');
      expect(receivedUploadBytes, tail.length);
    }, skip: skipReason);

    test('a streamed upload can resume from an offset', () async {
      // The case that matters for a big file: the source stream starts mid-file
      // and the engine must not rewind it or recompute the length.
      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          throwOnStatusCode: false,
        ),
      );
      final tail = payload.sublist(6000);
      final response = await client!.put(
        '$base/upload',
        body: HttpBody.stream(
          Stream.value(tail),
          contentLength: tail.length,
        ),
        headers: HttpHeaders.fromMap({
          'Content-Range': 'bytes 6000-9999/10000',
        }),
      );

      expect(response.statusCode, 308);
      expect(receivedUploadBytes, tail.length);
    }, skip: skipReason);

    test('the documented append-on-206 download resumes a partial file',
        () async {
      // The snippet in ADVANCED.md, run for real: a half-written file is
      // completed in place and must come out byte-identical to the whole one.
      final dir = await Directory.systemTemp.createTemp('nitro_resume');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/large.bin');
      await file.writeAsBytes(payload.sublist(0, 3500));

      client = NitroHttpClient(
        settings: const ClientSettings(
          timeout: Duration(seconds: 20),
          throwOnStatusCode: false,
        ),
      );
      final have = await file.length();
      final response = await client!.requestStream(
        HttpMethod.get,
        '$base/file',
        headers: HttpHeaders.fromMap({'Range': 'bytes=$have-'}),
      );

      if (response.statusCode == 206) {
        final sink = file.openWrite(mode: FileMode.append);
        await response.body.pipe(sink);
      } else {
        // A server may ignore Range; appending a full body to a partial file is
        // how a download ends up corrupt, so that case rewrites from scratch.
        await file.writeAsBytes(
          await response.body.expand((chunk) => chunk).toList(),
        );
      }

      expect(response.statusCode, 206);
      expect(await file.readAsBytes(), payload);
    }, skip: skipReason);

    test('Accept-Ranges reaches the caller, so resumability is detectable',
        () async {
      client = NitroHttpClient(
        settings: const ClientSettings(timeout: Duration(seconds: 20)),
      );
      final response = await client!.head('$base/file');
      expect(response.headers['accept-ranges'], 'bytes');
    }, skip: skipReason);
  });
}
