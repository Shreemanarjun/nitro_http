// Every Dart snippet in the README is type-checked against the real API.
//
// Documentation drifts silently: an API gets renamed, everything still compiles
// because no code references the README, and the first person to find out is a
// reader who copies a snippet that does not work. That happened while this
// README was being written — it confidently used `res.json`, `MultipartText`,
// `RequestOptions(cancelToken:)` and `client.prefetch()`, none of which exist.
//
// So the snippets are extracted, wrapped in a preamble supplying the variables
// the surrounding prose establishes, and handed to `dart analyze`. Anything that
// does not compile fails this test with the analyzer's own message.
//
// Deliberately an analyze and not an execution: the snippets talk to real hosts
// and read real files, so running them would be a network test. Compiling them
// is what catches the failure mode that actually happens.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The imports every wrapped snippet gets.
const String _preambleImports = '''
// ignore_for_file: unused_local_variable, unused_element, unused_import
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:nitro_http/nitro_http.dart';
''';

/// Stand-ins for the names the README's prose introduces.
///
/// A snippet is an excerpt, not a program: it says `client.get(...)` because the
/// paragraph above it created `client`. Declaring those here is what lets the
/// snippets stay readable instead of repeating six lines of setup every time.
const String _preambleDecls = '''
late NitroHttpClient client;
late String token;
late Uint8List bytes;
late String cacheDir;
late String appSupportDir;

class TokenStore {
  Future<String> access() async => '';
}

late TokenStore tokens;

void setState(void Function() fn) {}
double? _progress;
void showRetry(String message) {}
void showOffline() {}
void showNotFound() {}
void handleText(String text) {}
void handleBinary(Object data) {}
void handleClose(int? code, String? reason) {}
''';

/// Snippets checked in another package rather than skipped.
///
/// Exactly one case: the dio adapter lives in `nitro_http_dio`, which the example
/// app does not depend on, so `nitro_http_dio/test/readme_snippet_test.dart`
/// covers that snippet from a package that can see it.
bool _checkedElsewhere(String snippet) =>
    snippet.contains('Dio()') || snippet.contains('useNitroHttp');

List<String> _dartSnippets(String markdown) => RegExp(
  r'```dart\n(.*?)```',
  dotAll: true,
).allMatches(markdown).map((RegExpMatch m) => m.group(1)!).toList();

/// Wraps a snippet into a compilable library.
///
/// A snippet's own imports have to join the preamble's imports, because Dart
/// requires every directive before every declaration. Snippets that declare a
/// class are spliced in at top level; the rest are statements and go inside an
/// async function, which is also what makes their bare `await`s legal.
String _wrap(String snippet, int index) {
  final lines = snippet.trimRight().split('\n');
  final imports = lines.where((String l) => l.startsWith('import ')).join('\n');
  final rest = lines.where((String l) => !l.startsWith('import ')).toList();
  final declaresTopLevel = rest.any(
    (String l) =>
        l.startsWith('class ') ||
        l.startsWith('final class ') ||
        l.startsWith('@'),
  );
  final body = declaresTopLevel
      ? rest.join('\n')
      : 'Future<void> _snippet$index() async {\n'
            '${rest.map((String l) => '  $l').join('\n')}\n'
            '}';
  return '$_preambleImports$imports\n$_preambleDecls\n$body\n';
}

void main() {
  test('every README Dart snippet compiles against the real API', () async {
    final readme = File('../README.md');
    expect(readme.existsSync(), isTrue, reason: 'README.md moved');

    final snippets = _dartSnippets(readme.readAsStringSync());
    expect(
      snippets.length,
      greaterThan(10),
      reason: 'the extractor found almost nothing, so it is more likely broken '
          'than the README being empty',
    );

    // Inside lib/ so package resolution works; removed however the test ends.
    final dir = Directory('lib/readme_snippets_check');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    var checked = 0;
    for (var i = 0; i < snippets.length; i++) {
      if (_checkedElsewhere(snippets[i])) continue;
      File(
        '${dir.path}/snippet_$i.dart',
      ).writeAsStringSync(_wrap(snippets[i], i));
      checked++;
    }
    expect(checked, greaterThan(10), reason: 'almost everything was skipped');

    final result = await Process.run('dart', <String>[
      'analyze',
      '--no-fatal-warnings',
      dir.path,
    ], workingDirectory: Directory.current.path);

    final errors = const LineSplitter()
        .convert('${result.stdout}${result.stderr}')
        .where((String l) => l.contains(' error '))
        .toList();

    expect(
      errors,
      isEmpty,
      reason:
          'A README snippet does not compile against the current API. Either the '
          'README is wrong, or an API changed and the README was not updated.\n'
          '${errors.join('\n')}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
