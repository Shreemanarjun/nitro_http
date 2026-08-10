/// The app's visual language.
///
/// Centralised for a practical reason rather than a stylistic one: three screens
/// are built independently against plain Material 3 widgets, and a theme is the
/// only place that can restyle all of them at once without touching a single call
/// site. Anything here that a screen has to opt into by name has failed at that
/// job, so this file sets component themes rather than exporting helper widgets.
library;

import 'package:flutter/material.dart';

/// Semantic colours for HTTP concepts, resolved against the active scheme.
///
/// A status code, a verb and a latency all want colour, and none of them map onto
/// Material's primary/secondary/tertiary roles. Deriving them here keeps a single
/// definition of "what 4xx looks like" instead of one per widget.
@immutable
final class HttpPalette extends ThemeExtension<HttpPalette> {
  /// Creates a palette.
  const HttpPalette({
    required this.success,
    required this.onSuccess,
    required this.redirect,
    required this.onRedirect,
    required this.clientError,
    required this.onClientError,
    required this.serverError,
    required this.onServerError,
    required this.info,
    required this.onInfo,
    required this.neutral,
    required this.onNeutral,
  });

  /// Derives a palette from [scheme], keeping contrast on both brightnesses.
  factory HttpPalette.of(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    // Hand-picked rather than generated: the point of these is instant
    // recognition, so 2xx must read green and 5xx red regardless of the seed
    // colour, which a scheme-derived tone would not guarantee.
    Color pair(Color light, Color night) => dark ? night : light;
    return HttpPalette(
      success: pair(const Color(0xFF1B5E20), const Color(0xFF7BD88F)),
      onSuccess: pair(Colors.white, const Color(0xFF06210C)),
      redirect: pair(const Color(0xFF01579B), const Color(0xFF7FC8F8)),
      onRedirect: pair(Colors.white, const Color(0xFF04202E)),
      clientError: pair(const Color(0xFFB26500), const Color(0xFFFFB870)),
      onClientError: pair(Colors.white, const Color(0xFF2B1600)),
      serverError: pair(const Color(0xFFB3261E), const Color(0xFFFFB4AB)),
      onServerError: pair(Colors.white, const Color(0xFF3B0906)),
      info: pair(const Color(0xFF4A148C), const Color(0xFFD0BCFF)),
      onInfo: pair(Colors.white, const Color(0xFF21005D)),
      neutral: scheme.surfaceContainerHighest,
      onNeutral: scheme.onSurfaceVariant,
    );
  }

  /// 2xx.
  final Color success;

  /// Foreground on [success].
  final Color onSuccess;

  /// 3xx.
  final Color redirect;

  /// Foreground on [redirect].
  final Color onRedirect;

  /// 4xx.
  final Color clientError;

  /// Foreground on [clientError].
  final Color onClientError;

  /// 5xx.
  final Color serverError;

  /// Foreground on [serverError].
  final Color onServerError;

  /// 1xx and informational chrome.
  final Color info;

  /// Foreground on [info].
  final Color onInfo;

  /// Anything without a status.
  final Color neutral;

  /// Foreground on [neutral].
  final Color onNeutral;

  /// The background/foreground pair for an HTTP [statusCode].
  (Color, Color) forStatus(int statusCode) => switch (statusCode) {
    >= 200 && < 300 => (success, onSuccess),
    >= 300 && < 400 => (redirect, onRedirect),
    >= 400 && < 500 => (clientError, onClientError),
    >= 500 => (serverError, onServerError),
    _ => (info, onInfo),
  };

  /// The background/foreground pair for an HTTP method.
  ///
  /// Colouring by side effect rather than by name: reads are calm, writes are
  /// warm, deletes are alarming. A reader scanning a history list should be able
  /// to spot a DELETE without reading the word.
  (Color, Color) forMethod(String method) => switch (method.toUpperCase()) {
    'GET' || 'HEAD' || 'OPTIONS' || 'TRACE' => (redirect, onRedirect),
    'POST' || 'PUT' || 'PATCH' => (success, onSuccess),
    'DELETE' => (serverError, onServerError),
    _ => (info, onInfo),
  };

  @override
  HttpPalette copyWith({
    Color? success,
    Color? onSuccess,
    Color? redirect,
    Color? onRedirect,
    Color? clientError,
    Color? onClientError,
    Color? serverError,
    Color? onServerError,
    Color? info,
    Color? onInfo,
    Color? neutral,
    Color? onNeutral,
  }) => HttpPalette(
    success: success ?? this.success,
    onSuccess: onSuccess ?? this.onSuccess,
    redirect: redirect ?? this.redirect,
    onRedirect: onRedirect ?? this.onRedirect,
    clientError: clientError ?? this.clientError,
    onClientError: onClientError ?? this.onClientError,
    serverError: serverError ?? this.serverError,
    onServerError: onServerError ?? this.onServerError,
    info: info ?? this.info,
    onInfo: onInfo ?? this.onInfo,
    neutral: neutral ?? this.neutral,
    onNeutral: onNeutral ?? this.onNeutral,
  );

  @override
  HttpPalette lerp(covariant HttpPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return HttpPalette(
      success: mix(success, other.success),
      onSuccess: mix(onSuccess, other.onSuccess),
      redirect: mix(redirect, other.redirect),
      onRedirect: mix(onRedirect, other.onRedirect),
      clientError: mix(clientError, other.clientError),
      onClientError: mix(onClientError, other.onClientError),
      serverError: mix(serverError, other.serverError),
      onServerError: mix(onServerError, other.onServerError),
      info: mix(info, other.info),
      onInfo: mix(onInfo, other.onInfo),
      neutral: mix(neutral, other.neutral),
      onNeutral: mix(onNeutral, other.onNeutral),
    );
  }
}

/// Builds the app theme for [brightness].
///
/// Two deliberate departures from the Material defaults, both for a tool rather
/// than a consumer app:
///
/// * **Density is tighter.** A request console is a dense, data-heavy surface and
///   the default 48 px touch rhythm wastes a third of a laptop screen. It is
///   tightened, not collapsed — taps stay above the 44 px accessibility floor on
///   the controls that matter.
/// * **Monospace is a first-class text style.** Headers, payloads and timings are
///   all tabular data, so `bodyMedium` keeps the reading font while a dedicated
///   style carries code, and both come from the theme so a screen never hardcodes
///   `fontFamily: 'monospace'`.
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B5BD6),
    brightness: brightness,
  );
  final palette = HttpPalette.of(scheme);
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.compact,
  );

  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[palette],
    scaffoldBackgroundColor: scheme.surface,
    // Surfaces do the layering, not shadows: a tool with many panels reads better
    // as flat tinted regions than as a stack of floating cards.
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      margin: EdgeInsets.zero,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // 44 is the accessibility floor for a primary action; compact density
        // must not eat the one button every flow goes through.
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: scheme.outlineVariant,
      indicatorSize: TabBarIndicatorSize.tab,
      labelStyle: base.textTheme.labelLarge,
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: base.textTheme.labelSmall,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
    listTileTheme: const ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
    ),
    textTheme: base.textTheme.copyWith(
      // One tabular style, themed once. `fontFeatures` matters more than the
      // family: without tabular figures a column of latencies jitters as digits
      // change width, which makes a results table hard to scan.
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      labelSmall: base.textTheme.labelSmall?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        letterSpacing: 0.2,
      ),
    ),
  );
}

/// The monospace style for payloads, headers and numbers.
///
/// A function on `BuildContext` rather than a `TextStyle` constant so it inherits
/// the themed colour and scales with the platform text size.
TextStyle codeStyle(BuildContext context, {double size = 12}) {
  final scheme = Theme.of(context).colorScheme;
  return TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['Menlo', 'Consolas', 'DejaVu Sans Mono'],
    fontSize: size,
    height: 1.45,
    color: scheme.onSurface,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// The palette for the current theme.
HttpPalette paletteOf(BuildContext context) =>
    Theme.of(context).extension<HttpPalette>() ??
    HttpPalette.of(Theme.of(context).colorScheme);
