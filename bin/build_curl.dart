// One-command vendored-libcurl build, runnable from any app that depends on
// this package — no repo clone required:
//
//   dart run nitro_http:build_curl            # everything buildable here
//   dart run nitro_http:build_curl apple      # 5 slices + NitroCurl.xcframework
//   dart run nitro_http:build_curl android    # arm64-v8a, armeabi-v7a, x86_64
//   dart run nitro_http:build_curl linux      # host architecture
//   dart run nitro_http:build_curl --list     # print the plan, build nothing
//
// POSIX targets delegate to tool/build-curl.sh (which orchestrates the
// tool/deps superbuild); Windows delegates to tool/deps/build.ps1. Output
// lands in <package>/tool/deps/out/stage — the layout NITRO_HTTP_DEPS_DIR
// consumes — and the script prints the export line when it finishes.
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  final marker = await Isolate.resolvePackageUri(
    Uri.parse('package:nitro_http/nitro_http.dart'),
  );
  if (marker == null) {
    stderr.writeln(
      'nitro_http: package not resolvable — run this from an app that '
      'depends on nitro_http.',
    );
    exitCode = 1;
    return;
  }
  final packageRoot = File.fromUri(marker).parent.parent.path; // lib/ -> root

  if (Platform.isWindows) {
    final script = '$packageRoot\\tool\\deps\\build.ps1';
    if (!File(script).existsSync()) {
      stderr.writeln('nitro_http: $script not found.');
      exitCode = 1;
      return;
    }
    // Windows builds exactly one thing: its own x64 slice. The POSIX target
    // words must not reach PowerShell — `build.ps1`'s first positional
    // parameter is `-Out`, so a stray `android` would silently become the
    // output directory. Flags (`-NoHttp3`, `-Clean`, ...) pass through.
    const posixTargets = {'apple', 'android', 'linux', 'all'};
    final rejected = args.where(
      (a) => posixTargets.contains(a.toLowerCase()),
    );
    if (rejected.isNotEmpty) {
      stderr.writeln(
        'nitro_http: ${rejected.join(', ')} cannot be built from Windows — '
        'this host builds only the windows-x64 slice. Run the same command '
        'on macOS (apple) or any OS with an Android NDK (android).',
      );
      exitCode = 2;
      return;
    }
    if (args.contains('--list')) {
      stdout.writeln(r'  tool\deps\build.ps1   # windows-x64 slice');
      return;
    }
    final process = await Process.start(
      'pwsh',
      <String>['-File', script, ...args],
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
    return;
  }

  final script = '$packageRoot/tool/build-curl.sh';
  if (!File(script).existsSync()) {
    stderr.writeln('nitro_http: $script not found.');
    exitCode = 1;
    return;
  }
  final process = await Process.start(
    'bash',
    <String>[script, ...args],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
