import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('nitro_http_body'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  group('defaultContentType', () {
    test('text defaults to UTF-8 plain text and honours an override', () {
      expect(
        const HttpBody.text('hi').defaultContentType,
        'text/plain; charset=utf-8',
      );
      expect(
        const HttpBody.text('hi', contentType: 'text/csv').defaultContentType,
        'text/csv',
      );
    });

    test('json is always application/json', () {
      expect(
        const HttpBody.json(<String, int>{'a': 1}).defaultContentType,
        'application/json; charset=utf-8',
      );
    });

    test('bytes default to octet-stream and honour an override', () {
      expect(
        HttpBody.bytes(Uint8List(0)).defaultContentType,
        'application/octet-stream',
      );
      expect(
        HttpBody.bytes(Uint8List(0), contentType: 'image/png').defaultContentType,
        'image/png',
      );
    });

    test('form is url-encoded', () {
      expect(
        const HttpBody.form(<String, String>{}).defaultContentType,
        'application/x-www-form-urlencoded',
      );
    });

    test('multipart carries its own boundary', () {
      const body = HttpBody.multipart(
        <MultipartItem>[],
        boundary: 'fixedBoundary',
      );
      expect(
        body.defaultContentType,
        'multipart/form-data; boundary=fixedBoundary',
      );
    });

    test('stream and file report only what the caller supplied', () {
      expect(HttpBody.stream(const Stream<List<int>>.empty()).defaultContentType, isNull);
      expect(const HttpBody.file('/tmp/a.bin').defaultContentType, isNull);
      expect(
        const HttpBody.file('/tmp/a.bin', contentType: 'application/x-tar')
            .defaultContentType,
        'application/x-tar',
      );
    });

    test('a file body resolves its content type from the extension', () {
      expect(const HttpFileBody('/tmp/report.pdf').resolvedContentType, 'application/pdf');
      expect(
        const HttpFileBody('/tmp/report.pdf', contentType: 'text/plain')
            .resolvedContentType,
        'text/plain',
      );
    });
  });

  group('encodeFormFields', () {
    test('percent-encodes with space written as plus', () {
      expect(
        encodeFormFields(<String, String>{'q': 'a b&c=d', 'n': 'ü'}),
        'q=a+b%26c%3Dd&n=%C3%BC',
      );
    });

    test('encodes keys as well as values', () {
      expect(encodeFormFields(<String, String>{'a key': 'v'}), 'a+key=v');
    });

    test('an empty map encodes to an empty payload', () {
      expect(encodeFormFields(const <String, String>{}), '');
      expect(const HttpFormBody(<String, String>{'a': '1'}).encode(), 'a=1');
    });
  });

  group('multipart', () {
    test('generated boundaries are unique and header-safe', () {
      final boundaries = <String>{
        for (var i = 0; i < 64; i++) generateMultipartBoundary(),
      };

      expect(boundaries, hasLength(64));
      for (final b in boundaries) {
        expect(b, startsWith('nitroHttpBoundary'));
        expect(b, matches(RegExp(r'^[A-Za-z0-9]+$')));
      }
    });

    test('effectiveBoundary is stable per instance and differs per instance', () {
      // Built from a runtime list: two `const` bodies would be canonicalised
      // into one object and could not have distinct boundaries.
      List<MultipartItem> parts() =>
          <MultipartItem>[const MultipartItem.text('a', 'x')];
      final a = HttpMultipartBody(parts());
      final b = HttpMultipartBody(parts());

      expect(a.effectiveBoundary, a.effectiveBoundary);
      expect(a.effectiveBoundary, isNot(b.effectiveBoundary));
      expect(
        a.defaultContentType,
        'multipart/form-data; boundary=${a.effectiveBoundary}',
      );
      expect(
        const HttpMultipartBody(<MultipartItem>[], boundary: 'fixed')
            .effectiveBoundary,
        'fixed',
      );
    });

    test('a text part is framed exactly as RFC 7578 requires', () async {
      final bytes = await _collect(
        composeMultipart(
          const <MultipartItem>[MultipartItem.text('greeting', 'hello')],
          'B0UND',
        ),
      );

      expect(
        utf8.decode(bytes),
        '--B0UND\r\n'
        'Content-Disposition: form-data; name="greeting"\r\n'
        '\r\n'
        'hello\r\n'
        '--B0UND--\r\n',
      );
    });

    test('a bytes part with a filename gets an octet-stream content type', () async {
      final bytes = await _collect(
        composeMultipart(
          <MultipartItem>[
            MultipartItem.bytes(
              'blob',
              Uint8List.fromList(<int>[1, 2, 3]),
              filename: 'x.bin',
            ),
          ],
          'B',
        ),
      );

      expect(
        utf8.decode(bytes, allowMalformed: true),
        '--B\r\n'
        'Content-Disposition: form-data; name="blob"; filename="x.bin"\r\n'
        'Content-Type: application/octet-stream\r\n'
        '\r\n'
        '\u0001\u0002\u0003\r\n'
        '--B--\r\n',
      );
    });

    test('quotes are escaped and CR/LF are stripped from names and filenames', () async {
      // Only the first four yields are collected: the header block of the
      // second part is the last thing composed before it would open the file.
      final bytes = await _collect(
        composeMultipart(
          const <MultipartItem>[
            MultipartItem.text('na"me\r\ninjected', 'v'),
            MultipartItem.file(
              'f',
              '/nonexistent/ignored',
              filename: 'ev"il\r\nContent-Type: text/html',
              contentType: 'text/plain',
            ),
          ],
          'B',
        ).take(4),
      );

      expect(
        utf8.decode(bytes),
        '--B\r\n'
        r'Content-Disposition: form-data; name="na\"meinjected"'
        '\r\n'
        '\r\n'
        'v\r\n'
        '--B\r\n'
        r'Content-Disposition: form-data; name="f"; '
        r'filename="ev\"ilContent-Type: text/html"'
        '\r\n'
        'Content-Type: text/plain\r\n'
        '\r\n',
      );
    });

    test('a large file part streams in several chunks', () async {
      final file = File('${tempDir.path}/big.bin')
        ..writeAsBytesSync(Uint8List(300 * 1024));

      final sizes = <int>[];
      await for (final part in composeMultipart(
        <MultipartItem>[MultipartItem.file('f', file.path)],
        'B',
      )) {
        sizes.add(part.length);
      }

      final fileLength = file.lengthSync();
      final maxChunk = sizes.reduce((a, b) => a > b ? a : b);

      expect(sizes.length, greaterThan(3));
      expect(
        maxChunk,
        lessThan(fileLength),
        reason: 'the file must never be materialised as one buffer',
      );
      expect(sizes.reduce((a, b) => a + b), greaterThan(fileLength));
    });

    test('multipartContentLength equals the composed byte count', () async {
      final file = File('${tempDir.path}/note.txt')
        ..writeAsStringSync('some file contents');
      final parts = <MultipartItem>[
        const MultipartItem.text('a', 'first value'),
        MultipartItem.bytes('b', Uint8List.fromList(<int>[9, 8, 7])),
        MultipartItem.file('c', file.path, filename: 'note.txt'),
      ];

      final declared = await multipartContentLength(parts, 'BOUND');
      final composed = await _collect(composeMultipart(parts, 'BOUND'));

      expect(declared, composed.length);
    });

    test('multipartContentLength is null when a file part is missing', () async {
      expect(
        await multipartContentLength(
          <MultipartItem>[MultipartItem.file('c', '${tempDir.path}/absent')],
          'B',
        ),
        isNull,
      );
    });

    test('computeContentLength and compose agree on the instance boundary', () async {
      final body = HttpMultipartBody(<MultipartItem>[
        const MultipartItem.text('a', 'x'),
      ]);

      final composed = await _collect(body.compose());

      expect(await body.computeContentLength(), composed.length);
      expect(utf8.decode(composed), contains(body.effectiveBoundary));
    });

    test('a file part advertises the basename when no filename is given', () {
      expect(
        const MultipartFileItem('f', '/a/b/c/photo.png').effectiveFilename,
        'photo.png',
      );
      expect(
        const MultipartFileItem('f', r'C:\dir\photo.png').effectiveFilename,
        'photo.png',
      );
      expect(
        const MultipartFileItem('f', '/a/photo.png', filename: 'given.png')
            .effectiveFilename,
        'given.png',
      );
    });
  });

  group('guessContentTypeFromPath', () {
    test('recognises the common web and media types', () {
      expect(guessContentTypeFromPath('a/b/data.json'), 'application/json');
      expect(guessContentTypeFromPath('README.TXT'), 'text/plain; charset=utf-8');
      expect(guessContentTypeFromPath('page.HTM'), 'text/html; charset=utf-8');
      expect(guessContentTypeFromPath('photo.jpeg'), 'image/jpeg');
      expect(guessContentTypeFromPath(r'C:\assets\clip.mp4'), 'video/mp4');
      expect(guessContentTypeFromPath('module.wasm'), 'application/wasm');
    });

    test('misses yield null rather than a guess', () {
      expect(guessContentTypeFromPath('archive.tar.xyz'), isNull);
      expect(guessContentTypeFromPath('no_extension'), isNull);
      expect(guessContentTypeFromPath('trailing.'), isNull);
      expect(guessContentTypeFromPath('/a/.hidden'), isNull);
    });
  });
}
