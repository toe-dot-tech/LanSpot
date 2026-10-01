import 'package:flutter/material.dart';

import 'models.dart';

/// The app's small design system.
///
/// Everything visual is derived from a handful of tokens so the light and dark
/// builds stay in step, and so no widget has to invent its own colour. The rule
/// that keeps it looking like a considered product rather than a Material demo
/// is that depth comes from hairlines and spacing, never from shadows.
class Tokens {
  const Tokens({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.ink,
    required this.inkMuted,
    required this.hairline,
    required this.hairlineStrong,
    required this.accent,
    required this.onAccent,
    required this.accentWash,
    required this.starved,
    required this.onStarved,
    required this.starvedWash,
    required this.danger,
    required this.dangerWash,
  });

  final Brightness brightness;
  final Color canvas;
  final Color surface;
  final Color ink;
  final Color inkMuted;
  final Color hairline;
  final Color hairlineStrong;

  /// Vivid pop colour for the active, internet-sharing state.
  final Color accent;
  final Color onAccent;
  final Color accentWash;

  /// Deliberately a different hue from [accent] so "no internet" never reads as
  /// a slightly-off version of "normal" at a glance.
  final Color starved;
  final Color onStarved;
  final Color starvedWash;

  final Color danger;
  final Color dangerWash;

  bool get isDark => brightness == Brightness.dark;

  /// The colour that represents what the app is doing right now. Normal mode is
  /// teal, no-internet is amber, and an off hotspot drops back to plain ink so
  /// the screen goes quiet when nothing is happening.
  Color modeColor(HotspotMode mode, {required bool on}) {
    if (!on) return inkMuted;
    return mode == HotspotMode.noInternet ? starved : accent;
  }

  Color modeWash(HotspotMode mode, {required bool on}) {
    if (!on) return isDark ? const Color(0x14FFFFFF) : const Color(0x0F000000);
    return mode == HotspotMode.noInternet ? starvedWash : accentWash;
  }

  static const Tokens light = Tokens(
    brightness: Brightness.light,
    canvas: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF0E1116),
    inkMuted: Color(0xFF6B7280),
    hairline: Color(0xFFE4E7EC),
    hairlineStrong: Color(0xFFCED3DA),
    accent: Color(0xFF0A7C6B),
    onAccent: Color(0xFFFFFFFF),
    accentWash: Color(0xFFE6F4F1),
    starved: Color(0xFFB4530A),
    onStarved: Color(0xFFFFFFFF),
    starvedWash: Color(0xFFFDF0E3),
    danger: Color(0xFFB42318),
    dangerWash: Color(0xFFFDECEA),
  );

  static const Tokens dark = Tokens(
    brightness: Brightness.dark,
    canvas: Color(0xFF0B0D10),
    surface: Color(0xFF14171B),
    ink: Color(0xFFF2F4F7),
    inkMuted: Color(0xFF98A2B3),
    hairline: Color(0xFF23282F),
    hairlineStrong: Color(0xFF333A44),
    accent: Color(0xFF2FD4AE),
    onAccent: Color(0xFF06231E),
    accentWash: Color(0xFF0F2B27),
    starved: Color(0xFFFFB25C),
    onStarved: Color(0xFF2A1605),
    starvedWash: Color(0xFF2C1F10),
    danger: Color(0xFFFF8A80),
    dangerWash: Color(0xFF2C1614),
  );
}

/// Makes the tokens reachable from any widget without threading them by hand.
class TokensScope extends InheritedWidget {
  const TokensScope({super.key, required this.tokens, required super.child});

  final Tokens tokens;

  static Tokens of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TokensScope>();
    return scope?.tokens ?? Tokens.light;
  }

  @override
  bool updateShouldNotify(TokensScope oldWidget) => oldWidget.tokens != tokens;
}

/// Builds the Material theme that goes with a set of [Tokens].
ThemeData buildTheme(Tokens t) {
  final scheme = ColorScheme(
    brightness: t.brightness,
    primary: t.accent,
    onPrimary: t.onAccent,
    primaryContainer: t.accentWash,
    onPrimaryContainer: t.ink,
    secondary: t.starved,
    onSecondary: t.onStarved,
    secondaryContainer: t.starvedWash,
    onSecondaryContainer: t.ink,
    tertiary: t.starved,
    onTertiary: t.onStarved,
    error: t.danger,
    onError: t.isDark ? const Color(0xFF2A0A08) : Colors.white,
    errorContainer: t.dangerWash,
    onErrorContainer: t.danger,
    surface: t.surface,
    onSurface: t.ink,
    surfaceContainerLowest: t.canvas,
    surfaceContainerLow: t.surface,
    surfaceContainer: t.surface,
    surfaceContainerHigh: t.surface,
    surfaceContainerHighest: t.surface,
    onSurfaceVariant: t.inkMuted,
    outline: t.hairlineStrong,
    outlineVariant: t.hairline,
    shadow: Colors.black.withValues(alpha: t.isDark ? 0.5 : 0.08),
    scrim: Colors.black.withValues(alpha: 0.45),
    inverseSurface: t.isDark ? const Color(0xFFF2F4F7) : const Color(0xFF0E1116),
    onInverseSurface: t.isDark ? const Color(0xFF0E1116) : Colors.white,
    inversePrimary: t.isDark ? const Color(0xFF0A7C6B) : const Color(0xFF2FD4AE),
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.canvas,
    // Windows' own UI face. Falls back gracefully if it is ever missing.
    fontFamily: 'Segoe UI',
    fontFamilyFallback: const <String>['Segoe UI', 'Tahoma', 'sans-serif'],
    splashFactory: InkRipple.splashFactory,
  );

  return base.copyWith(
    // Flat by default. Depth in this app is expressed with hairline borders.
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: t.surface,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: t.hairline),
      ),
    ),
    dividerTheme: DividerThemeData(color: t.hairline, space: 1, thickness: 1),
    iconTheme: IconThemeData(color: t.inkMuted, size: 20),
    appBarTheme: AppBarTheme(
      backgroundColor: t.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: t.ink,
      titleTextStyle: TextStyle(
        color: t.ink,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: t.ink,
      displayColor: t.ink,
    ).copyWith(
          // Tighter, more deliberate type than the Material defaults.
          headlineMedium: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.8,
            color: t.ink,
            height: 1.1,
          ),
          titleMedium: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: t.ink,
          ),
          titleSmall: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            color: t.ink,
          ),
          bodyMedium: TextStyle(fontSize: 13.5, color: t.ink, height: 1.45),
          bodySmall: TextStyle(fontSize: 12.5, color: t.inkMuted, height: 1.4),
          labelLarge: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            color: t.ink,
          ),
          labelSmall: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: t.inkMuted,
          ),
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.isDark ? const Color(0xFF191D22) : const Color(0xFFFAFBFC),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      hintStyle: TextStyle(color: t.inkMuted, fontSize: 13.5),
      labelStyle: TextStyle(color: t.inkMuted, fontSize: 12.5),
      floatingLabelStyle: TextStyle(color: t.accent, fontSize: 12.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.accent, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.danger, width: 1.6),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? scheme.onPrimary : t.surface),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? t.accent : t.hairlineStrong),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? t.accent : t.hairlineStrong),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF2B3138) : const Color(0xFF1B2027),
        borderRadius: BorderRadius.circular(7),
      ),
      textStyle: const TextStyle(fontSize: 12, color: Colors.white),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: t.isDark ? const Color(0xFF222831) : const Color(0xFF1B2027),
      contentTextStyle: const TextStyle(fontSize: 13, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      insetPadding: const EdgeInsets.all(16),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.hairline),
      ),
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: t.ink,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(t.hairlineStrong),
      radius: const Radius.circular(99),
      thickness: const WidgetStatePropertyAll(6),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.ink,
        side: BorderSide(color: t.hairlineStrong),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.inkMuted,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: t.inkMuted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
  );
}
