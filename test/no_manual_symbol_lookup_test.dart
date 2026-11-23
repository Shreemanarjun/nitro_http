// A symbol Dart finds by name must survive the strip an Xcode archive runs on
// the app binary. nitrogen marks the ones its bridge exports; a lookup written
// by hand carries no such mark and fails only in an archived build. Native
// functions are reached through the spec, lib/src/nitro_http.native.dart.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('hand-written Dart looks up no native symbol by name', () {
    final offenders = <String>[
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') &&
            !file.path.endsWith('.g.dart') &&
            !file.path.contains('/generated/') &&
            RegExp(r'\.lookup<|\.lookupFunction<').hasMatch(file.readAsStringSync()))
          file.path,
    ];
    expect(offenders, isEmpty);
  });
}
