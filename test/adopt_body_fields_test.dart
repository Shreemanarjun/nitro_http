// `_adoptBody` rebuilds a RawResponse with its body adopted. The record has no
// copyWith, so a field added to the spec and not to that rebuild would reset
// to its default, but only for bodies large enough to be adopted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('_adoptBody carries every RawResponse field', () {
    final spec = File('lib/src/nitro_http.native.dart').readAsStringSync();
    final record = RegExp(r'class RawResponse \{([\s\S]*?)\n\}').firstMatch(spec)![1]!;
    final fields = RegExp(r'^  final \S+ (\w+);', multiLine: true)
        .allMatches(record)
        .map((m) => m[1]!)
        .toSet()
      ..removeAll({'bodyAddress', 'bodyLength', 'bodyOwner'});
    expect(fields, contains('body'));

    final executor = File('lib/src/internal/executor_native.dart').readAsStringSync();
    final adopt = RegExp(r'RawResponse _adoptBody\([\s\S]*?\n  \}').firstMatch(executor)![0]!;
    for (final field in fields) {
      expect(adopt, contains('$field:'), reason: '$field is not carried over');
    }
  });
}
