/// Host-VM proof that the app degrades gracefully with no native engine.
///
/// The prebuilt engine binaries are not published yet, so a build without them
/// is the common case for a reader cloning this repo. Every tab must then render
/// a readable explanation instead of a red screen — a requirement no integration
/// test can check, because those need the engine to exist.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http_example/main.dart';

void main() {
  testWidgets('every tab renders without the native engine', (tester) async {
    // Wide enough that the scrollable TabBar puts all six tabs on screen, so
    // each tap really lands and each tab really builds.
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const NitroHttpDemoApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.textContaining('Could not reach the native engine'),
      findsOne,
      reason: 'the shell must say why nothing works',
    );

    for (final label in const [
      'Streaming',
      'WebSocket',
      'Cache',
      'Cookies',
      'Benchmark',
      'Console',
    ]) {
      await tester.tap(find.widgetWithText(Tab, label));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull, reason: 'tab $label threw');
      expect(
        find.byType(Card),
        findsWidgets,
        reason: 'tab $label rendered nothing',
      );
    }

    // Disposing the tree stops the LocalServer; its idle timer would otherwise
    // trip flutter_test's pending-timer invariant.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  });
}
