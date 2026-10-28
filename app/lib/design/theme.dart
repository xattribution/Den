import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds Material's theme from Den's tokens so platform widgets inherit the design system:
/// ink pills for actions, inputs on the card color with 14 corners, no ripples (press feedback
/// is a fill, see DenPressable), shadows only on true overlays, and the iOS page transition with
/// its edge-swipe back on every platform.
ThemeData denTheme(DenColors c, {double typeScale = 1}) {
  final type = DenType(typeScale);
  final text = DenText(typeScale);
  final scheme = ColorScheme(
    brightness: c.brightness,
    primary: c.primary,
    onPrimary: c.onPrimary,
    secondary: c.ink2,
    onSecondary: c.onPrimary,
    tertiary: c.ink2,
    onTertiary: c.onPrimary,
    error: c.destructive,
    onError: c.onPrimary,
    surface: c.bg,
    onSurface: c.ink,
    surfaceContainerLowest: c.card,
    surfaceContainerLow: c.card,
    surfaceContainer: c.card,
    surfaceContainerHigh: c.raised,
    surfaceContainerHighest: c.raised,
    onSurfaceVariant: c.ink2,
    outline: c.line,
    outlineVariant: c.line,
    shadow: const Color(0xFF000000),
    scrim: c.scrim,
    surfaceTint: Colors.transparent,
    inverseSurface: c.ink,
    onInverseSurface: c.onPrimary,
    inversePrimary: c.onPrimary,
  );
  const pill = StadiumBorder();
  const inputRadius = BorderRadius.all(Radius.circular(Radii.input));
  final focusRing = BorderSide(color: c.ink, width: 2);

  // Pressing shades the fill (6 %), hovering a little less; nothing ripples or flashes.
  WidgetStateProperty<Color?> overlay(Color on) => WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.pressed)) return on.withValues(alpha: 0.08);
        if (s.contains(WidgetState.focused)) return on.withValues(alpha: 0.08);
        if (s.contains(WidgetState.hovered)) return on.withValues(alpha: 0.04);
        return null;
      });

  // Overlays (menus) get a shadow by day; at night a shadow can't show on black, so they get
  // a line edge instead. Never both.
  final overlayShape = RoundedRectangleBorder(
    borderRadius: inputRadius,
    side: c.isDark ? BorderSide(color: c.line) : BorderSide.none,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: c.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    fontFamily: DenType.family,
    extensions: [c, type, text],
    splashFactory: NoSplash.splashFactory,
    highlightColor: c.ink.withValues(alpha: 0.06),
    splashColor: Colors.transparent,
    hoverColor: c.ink.withValues(alpha: 0.04),
    focusColor: c.ink.withValues(alpha: 0.08),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
      },
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    // Material roles keep the sizes the current screens were laid out for, except fields, which
    // are 17 (iOS zooms into anything under 16) like Den's body text.
    textTheme: TextTheme(
      displaySmall: type.display(c.ink),
      headlineSmall: type.heading(c.ink),
      titleMedium: type.title(c.ink),
      bodyLarge: text.body(c.ink),
      bodyMedium: type.body(c.ink),
      bodySmall: type.meta(c.ink2),
      labelLarge: type.bodyStrong(c.ink),
      labelMedium: type.meta(c.ink2),
    ),
    iconTheme: IconThemeData(color: c.ink, size: 22),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: type.heading(c.ink),
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        disabledBackgroundColor: c.line,
        disabledForegroundColor: c.ink2,
        minimumSize: const Size(Targets.adult, Targets.adult),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: pill,
        elevation: 0,
        textStyle: text.label(c.onPrimary),
      ).copyWith(overlayColor: overlay(c.onPrimary)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: c.card,
        foregroundColor: c.ink,
        disabledForegroundColor: c.ink2,
        side: BorderSide(color: c.line, width: 1.5),
        minimumSize: const Size(Targets.adult, Targets.adult),
        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
        shape: pill,
        textStyle: text.label(c.ink),
      ).copyWith(overlayColor: overlay(c.ink)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.ink,
        disabledForegroundColor: c.ink2,
        minimumSize: const Size(Targets.adult, Targets.adult),
        padding: const EdgeInsets.symmetric(horizontal: Sp.m),
        shape: pill,
        textStyle: text.label(c.ink),
      ).copyWith(overlayColor: overlay(c.ink)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.ink,
        minimumSize: const Size(Targets.adult, Targets.adult),
        shape: const CircleBorder(),
      ).copyWith(overlayColor: overlay(c.ink)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.card,
      hintStyle: text.body(c.ink2),
      labelStyle: text.meta(c.ink2),
      floatingLabelStyle: text.meta(c.ink2),
      errorStyle: text.meta(c.destructive),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      contentPadding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: 14),
      border: const OutlineInputBorder(borderRadius: inputRadius, borderSide: BorderSide.none),
      enabledBorder: const OutlineInputBorder(borderRadius: inputRadius, borderSide: BorderSide.none),
      disabledBorder: const OutlineInputBorder(borderRadius: inputRadius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: inputRadius, borderSide: focusRing),
      errorBorder: OutlineInputBorder(borderRadius: inputRadius, borderSide: BorderSide(color: c.destructive, width: 2)),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: inputRadius,
        borderSide: BorderSide(color: c.destructive, width: 2),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.ink,
      selectionColor: c.ink.withValues(alpha: 0.2),
      selectionHandleColor: c.ink,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onPrimary : c.knob),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.primary : c.switchOff),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.primary : Colors.transparent),
      checkColor: WidgetStatePropertyAll(c.onPrimary),
      side: BorderSide(color: c.ink2, width: 1.5),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6))),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.ink : c.ink2),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.ink, linearTrackColor: c.track, circularTrackColor: c.track),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.bar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? text.tab(c.ink, selected: true) : text.tab(c.ink3),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? c.ink : c.ink3, size: 26),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.bar,
      indicatorColor: c.fill,
      indicatorShape: pill,
      selectedIconTheme: IconThemeData(color: c.ink),
      unselectedIconTheme: IconThemeData(color: c.ink3),
      selectedLabelTextStyle: text.caption(c.ink).bold,
      unselectedLabelTextStyle: text.caption(c.ink3),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.bg,
      modalBarrierColor: c.scrim,
      elevation: 0,
      modalElevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet))),
      showDragHandle: true,
      dragHandleColor: c.handle,
      dragHandleSize: const Size(40, 5),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.raised,
      surfaceTintColor: Colors.transparent,
      barrierColor: c.scrim,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.section)),
        side: c.isDark ? BorderSide(color: c.line) : BorderSide.none,
      ),
      titleTextStyle: text.section(c.ink),
      contentTextStyle: text.body(c.ink),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: c.isDark ? 0 : 8,
      shadowColor: const Color(0x29000000),
      shape: overlayShape,
      textStyle: text.body(c.ink),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(c.isDark ? 0 : 8),
        shadowColor: const WidgetStatePropertyAll(Color(0x29000000)),
        shape: WidgetStatePropertyAll(overlayShape),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.ink,
      contentTextStyle: text.body(c.onPrimary),
      actionTextColor: c.onPrimary,
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: inputRadius),
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(8)),
      textStyle: text.meta(c.onPrimary),
      waitDuration: const Duration(milliseconds: 400),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: Sp.l),
      minVerticalPadding: Sp.m,
      titleTextStyle: type.body(c.ink),
      subtitleTextStyle: type.meta(c.ink2),
      iconColor: c.ink2,
    ),
  );
}
