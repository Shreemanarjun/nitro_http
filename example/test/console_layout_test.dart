/// Layout contract for the request console.
///
/// The console is the screen the app is judged on, and it has to hold together
/// from a 380 px phone to a 1600 px desktop window, at the text size the reader
/// chose rather than the one we assumed. Both of those break silently: an
/// overflow is a debug-only stripe, and a clipped helper line looks like a
/// design choice. This suite pumps the real screen at real sizes and fails on
/// the exception Flutter raises when a box does not fit.
///
/// It is deliberately not a golden test. Goldens would pin the pixels and turn
/// every intentional restyle into a fixture update; what needs defending here is
/// that nothing overflows and that the first-second state explains itself.
library;


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http_example/core/app_state.dart';
import 'package:nitro_http_example/core/http_library.dart';
import 'package:nitro_http_example/core/request_spec.dart';
import 'package:nitro_http_example/core/sent_response.dart';
import 'package:nitro_http_example/screens/console/console_bits.dart';
import 'package:nitro_http_example/screens/console/console_controller.dart';
import 'package:nitro_http_example/screens/console/history_pane.dart';
import 'package:nitro_http_example/screens/console/request_console_screen.dart';
import 'package:nitro_http_example/theme/app_theme.dart';

/// The window sizes the console claims to work at.
const Size phone = Size(380, 800);
const Size tablet = Size(800, 1200);
const Size desktop = Size(1600, 1000);

/// A request that exercises every editor: rows on two tabs, a JSON body, and
/// non-default transport settings so the Settings tab renders its badge.
const RequestSpec _busyRequest = RequestSpec(
  method: 'POST',
  url: '/echo',
  query: <KeyValueRow>[
    KeyValueRow(name: 'q', value: 'a rather long query value to crowd the row'),
    KeyValueRow(name: 'page', value: '2', enabled: false),
  ],
  headers: <KeyValueRow>[
    KeyValueRow(name: 'Content-Type', value: 'application/json'),
    KeyValueRow(name: 'Authorization', value: 'Bearer sk-not-a-real-token'),
  ],
  bodyKind: RequestBodyKind.json,
  bodyText: '{"name":"nitro_http","native":true}',
  responseMode: ResponseMode.streamed,
  connectTimeout: Duration(milliseconds: 750),
  totalTimeout: Duration(seconds: 5),
  sendCookies: false,
);

SentResponse _response() => SentResponse(
  library: HttpLibrary.nitroHttp,
  spec: _busyRequest,
  statusCode: 200,
  reasonPhrase: 'OK',
  headers: const <KeyValueRow>[
    KeyValueRow(name: 'content-type', value: 'application/json'),
    KeyValueRow(
      name: 'x-long-header-name-for-layout',
      value: 'a value long enough to need the column to give way',
    ),
  ],
  bodyBytes: Uint8List.fromList('{"hello":"world","count":3}'.codeUnits),
  timings: const ResponseTimings(
    total: Duration(milliseconds: 12, microseconds: 340),
    dns: Duration(microseconds: 210),
    connect: Duration(microseconds: 940),
    tls: Duration(milliseconds: 4),
    firstByte: Duration(milliseconds: 9),
  ),
  httpVersion: 'HTTP/1.1',
  finalUrl: 'http://127.0.0.1:53219/echo?q=a%20rather%20long%20query%20value',
  redirectCount: 2,
  extras: const <String, String>{
    'curl_effective_method': 'POST',
    'connection_reused': 'false',
  },
);

FailedSend _failure() => const FailedSend(
  library: HttpLibrary.rhttp,
  spec: _busyRequest,
  failure: SendFailure(
    kind: SendFailureKind.connection,
    message:
        'ClientException: Connection refused (os error 61), '
        'uri=http://127.0.0.1:53219/echo',
    elapsed: Duration(milliseconds: 3, microseconds: 120),
  ),
);

/// Pumps the console at [size], honouring [textScaler].
///
/// The view is sized rather than the widget wrapped in a `SizedBox`: a console
/// that only behaves inside a box of the right shape is not a responsive
/// console, and `MediaQuery` size is what its `LayoutBuilder`s ultimately read.
Future<void> _pumpConsole(
  WidgetTester tester, {
  required Size size,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: const Scaffold(body: RequestConsoleScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Fails with the offending render exception, naming an overflow as one.
///
/// `takeException` alone would pass a test whose widget tree threw for some
/// unrelated reason and then say nothing useful; this reports what broke.
void expectNoLayoutFailure(WidgetTester tester, String where) {
  final failure = tester.takeException();
  if (failure == null) return;
  final text = failure.toString();
  final overflowed = text.contains('overflowed');
  fail(
    '$where: ${overflowed ? 'a box overflowed' : 'render failure'}\n$text',
  );
}

/// A string that only appears while the given editor tab is showing.
///
/// `EditorHeading` upper-cases its text, so these match what is painted rather
/// than what the source says.
const Map<EditorTab, String> _editorMarker = <EditorTab, String>{
  EditorTab.params: 'QUERY PARAMETERS',
  EditorTab.headers: 'REQUEST HEADERS',
  EditorTab.body: 'BODY KIND',
  EditorTab.settings: 'Response mode',
};

/// A string that only appears while the given response view is showing.
const Map<ResponseView, String> _responseMarker = <ResponseView, String>{
  ResponseView.pretty: '"hello": "world"',
  ResponseView.raw: '{"hello":"world","count":3}',
  ResponseView.headers: 'Copy all',
  ResponseView.timings: 'PHASES',
  ResponseView.extras: 'final url',
};

/// Taps [label] inside the strip of type [S] and waits for the switch.
///
/// The strips scroll sideways once the labels stop fitting, which they do on a
/// phone at a large text scale. `ensureVisible` gets the segment into the
/// viewport, but a segment wider than what is left of the viewport can still
/// have its centre outside the clip — and a tap there lands on whatever is
/// beside the strip. Clamping the tap into the viewport is what makes this
/// reliable at 2x rather than accidentally opening the Examples menu.
Future<void> _tapSegment<S>(WidgetTester tester, String label) async {
  final target = find.descendant(
    of: find.byType(SegmentBar<S>),
    matching: find.text(label),
  );
  expect(target, findsOneWidget, reason: 'segment "$label" should exist');
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();

  final viewport = tester.getRect(
    find
        .descendant(
          of: find.byType(SegmentBar<S>),
          matching: find.byType(SingleChildScrollView),
        )
        .first,
  );
  final segment = tester.getRect(target);
  await tester.tapAt(
    Offset(
      segment.center.dx.clamp(viewport.left + 4, viewport.right - 4),
      segment.center.dy,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // The console reads app-global signals, so each test starts from a known
    // one rather than inheriting whatever the previous test left behind.
    baseUrl.value = 'http://127.0.0.1:53219';
    selectedLibrary.value = HttpLibrary.nitroHttp;
    isSending.value = false;
    lastOutcome.value = null;
    history.clear();
    requestDraft.load(_busyRequest);
  });

  group('no overflow', () {
    for (final (String name, Size size, TextScaler scale) in <
      (String, Size, TextScaler)
    >[
      ('phone', phone, TextScaler.noScaling),
      ('tablet', tablet, TextScaler.noScaling),
      ('desktop', desktop, TextScaler.noScaling),
      ('phone at 2x text', phone, TextScaler.linear(2)),
    ]) {
      testWidgets('$name lays out every editor tab', (WidgetTester tester) async {
        lastOutcome.value = _response();
        history.add(_response());
        await _pumpConsole(tester, size: size, textScaler: scale);
        expectNoLayoutFailure(tester, '$name: first frame');

        for (final tab in EditorTab.values) {
          await _tapSegment<EditorTab>(tester, tab.label);
          expectNoLayoutFailure(tester, '$name: ${tab.label} tab');
          // Proves the tap landed: without this the suite would still pass if
          // every tap missed and the pane never changed.
          expect(
            find.text(_editorMarker[tab]!),
            findsWidgets,
            reason: '${tab.label} tab should be showing after the tap',
          );
        }
      });

      testWidgets('$name lays out every response view', (
        WidgetTester tester,
      ) async {
        lastOutcome.value = _response();
        await _pumpConsole(tester, size: size, textScaler: scale);
        if (size.width < 900) {
          await _tapSegment<NarrowPane>(tester, NarrowPane.response.label);
        }
        expectNoLayoutFailure(tester, '$name: response pane');

        for (final view in ResponseView.values) {
          await _tapSegment<ResponseView>(tester, view.label);
          expectNoLayoutFailure(tester, '$name: ${view.label} view');
          expect(
            find.textContaining(_responseMarker[view]!),
            findsWidgets,
            reason: '${view.label} view should be showing after the tap',
          );
        }
      });
    }

    testWidgets('every body kind lays out on a phone', (
      WidgetTester tester,
    ) async {
      await _pumpConsole(tester, size: phone);
      await _tapSegment<EditorTab>(tester, EditorTab.body.label);
      for (final kind in RequestBodyKind.values) {
        final chip = find.widgetWithText(ChoiceChip, kind.label);
        await tester.ensureVisible(chip.first);
        await tester.pumpAndSettle();
        await tester.tap(chip.first);
        await tester.pumpAndSettle();
        expectNoLayoutFailure(tester, 'phone: ${kind.label} body');
      }
    });

    testWidgets('a failed send lays out as a result', (
      WidgetTester tester,
    ) async {
      lastOutcome.value = _failure();
      history.add(_failure());
      await _pumpConsole(tester, size: desktop);
      expectNoLayoutFailure(tester, 'desktop: failed send');
      expect(find.text('Connection'), findsWidgets);
      expect(find.textContaining('Connection refused'), findsOneWidget);
    });
  });

  group('startup state', () {
    testWidgets('Send is disabled and says why while the server is starting', (
      WidgetTester tester,
    ) async {
      baseUrl.value = '';
      await _pumpConsole(tester, size: desktop);
      expectNoLayoutFailure(tester, 'desktop: empty base url');

      final send = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Send'),
      );
      expect(
        send.onPressed,
        isNull,
        reason: 'Send must be dead until the demo server reports a base URL',
      );

      // The reason has to reach the user two ways: on hover, and in the field
      // that is actually blocking. A disabled button with no explanation is the
      // failure this asserts against.
      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.widgetWithText(FilledButton, 'Send'),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      expect(tooltip.message, contains('demo server'));
      expect(
        find.text('Waiting for the demo server to start…'),
        findsOneWidget,
      );
    });

    testWidgets('an unparseable URL blocks Send with a visible error', (
      WidgetTester tester,
    ) async {
      requestDraft.url.value = 'http://';
      await _pumpConsole(tester, size: desktop);
      expectNoLayoutFailure(tester, 'desktop: bad url');

      final send = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Send'),
      );
      expect(send.onPressed, isNull);
      expect(find.textContaining('Absolute URLs need a host'), findsOneWidget);
    });
  });

  group('history', () {
    testWidgets('tapping an entry loads it back into the draft', (
      WidgetTester tester,
    ) async {
      requestDraft.load(const RequestSpec());
      history.add(_response());
      await _pumpConsole(tester, size: desktop);
      expectNoLayoutFailure(tester, 'desktop: history rail');

      expect(requestDraft.method.value, 'GET');
      // Scoped to the rail: the URL field's hint is also "/echo", and tapping
      // that would prove nothing.
      await tester.tap(
        find.descendant(
          of: find.byType(HistoryPane),
          matching: find.text('/echo'),
        ),
      );
      await tester.pumpAndSettle();

      expect(requestDraft.method.value, 'POST');
      expect(requestDraft.bodyKind.value, RequestBodyKind.json);
      expect(requestDraft.headers.value.length, 2);
      expect(selectedLibrary.value, HttpLibrary.nitroHttp);
    });
  });

  group('sending', () {
    testWidgets('pressing Send always ends in a rendered result', (
      WidgetTester tester,
    ) async {
      // A real send through the real registry: `senderFor`, the outcome, and
      // `recordOutcome`, all the way to something painted. What comes back is
      // deliberately not asserted, because `TestWidgetsFlutterBinding` swaps in
      // an `HttpClient` that answers 400 without touching the network — so the
      // environment decides between a response and a failure, and the contract
      // under test is that *either* is rendered as a result and neither escapes
      // as an exception.
      baseUrl.value = 'http://127.0.0.1:1';
      selectedLibrary.value = HttpLibrary.dartIo;
      requestDraft.load(const RequestSpec(url: '/echo'));
      await _pumpConsole(tester, size: desktop);

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pump();

      // Widget tests run in fake async, so a socket only makes progress inside
      // `runAsync`. Bounded, so a hung send fails the test instead of hanging
      // the suite.
      await tester.runAsync(() async {
        for (var tick = 0; tick < 200 && isSending.value; tick++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pumpAndSettle();

      expect(isSending.value, isFalse, reason: 'the send should have settled');
      expect(history.value, hasLength(1));
      expectNoLayoutFailure(tester, 'desktop: after a send');

      switch (lastOutcome.value) {
        case null:
          fail('the console recorded no outcome at all');
        case SentResponse(:final statusCode):
          expect(find.textContaining('$statusCode'), findsWidgets);
        case FailedSend():
          expect(find.text('No response arrived'), findsOneWidget);
      }
    });

    testWidgets('Ctrl+Enter sends without touching the button', (
      WidgetTester tester,
    ) async {
      baseUrl.value = 'http://127.0.0.1:1';
      selectedLibrary.value = HttpLibrary.dartIo;
      requestDraft.load(const RequestSpec(url: '/echo'));
      await _pumpConsole(tester, size: desktop);
      expect(history.value, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(
        isSending.value,
        isTrue,
        reason: 'the shortcut should start a send on its own',
      );
      // Drain it, so the test does not end with a socket in flight.
      await tester.runAsync(() async {
        for (var tick = 0; tick < 200 && isSending.value; tick++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pumpAndSettle();
      expect(history.value, hasLength(1));
    });
  });
}
