import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds Material's theme from Den's tokens so platform widgets inherit the design system:
/// solid ink selected states, flush regions, radius on controls only, one overlay shadow.
ThemeData denTheme(DenColors c, {double typeScale = 1}) {
  final type = DenType(typeScale);
  final scheme = ColorScheme(
    brightness: c == DenColors.night ? Brightness.dark : Brightness.light,
    primary: c.ink,
    onPrimary: c.onInk,
    secondary: c.ink2,
    onSecondary: c.onInk,
    error: c.bad,
    onError: c.paper,
    surface: c.paper,
    onSurface: c.ink,
    surfaceContainerLowest: c.paper,
    surfaceContainerLow: c.paper,
    surfaceContainer: c.well,
    surfaceContainerHigh: c.well,
    surfaceContainerHighest: c.well,
    onSurfaceVariant: c.ink2,
    outline: c.rule,
    outlineVariant: c.rule,
    shadow: c.ink,
    inverseSurface: c.ink,
    onInverseSurface: c.onInk,
  );
  const controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.control)));
  final focusRing = BorderSide(color: c.ink, width: 2);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.paper,
    canvasColor: c.paper,
    fontFamily: DenType.family,
    extensions: [c, type],
    splashFactory: InkRipple.splashFactory,
    highlightColor: c.well,
    splashColor: c.rule,
    hoverColor: c.well,
    focusColor: c.well,
    dividerTheme: DividerThemeData(color: c.rule, thickness: 1, space: 1),
    textTheme: TextTheme(
      displaySmall: type.display(c.ink),
      headlineSmall: type.heading(c.ink),
      titleMedium: type.title(c.ink),
      bodyLarge: type.body(c.ink),
      bodyMedium: type.body(c.ink),
      bodySmall: type.meta(c.ink2),
      labelLarge: type.bodyStrong(c.ink),
      labelMedium: type.meta(c.ink2),
    ),
    iconTheme: IconThemeData(color: c.ink, size: 22),
    appBarTheme: AppBarTheme(
      backgroundColor: c.paper,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: type.heading(c.ink),
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.ink,
        foregroundColor: c.onInk,
        disabledBackgroundColor: c.well,
        disabledForegroundColor: c.ink3,
        minimumSize: const Size(64, Targets.adult),
        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
        shape: controlShape,
        textStyle: type.bodyStrong(c.onInk),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        side: BorderSide(color: c.rule),
        minimumSize: const Size(64, Targets.adult),
        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
        shape: controlShape,
        textStyle: type.bodyStrong(c.ink),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.ink,
        minimumSize: const Size(48, Targets.adult),
        padding: const EdgeInsets.symmetric(horizontal: Sp.m),
        shape: controlShape,
        textStyle: type.bodyStrong(c.ink),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.ink,
        minimumSize: const Size(Targets.adult, Targets.adult),
        shape: controlShape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.well,
      hintStyle: type.body(c.ink3),
      labelStyle: type.meta(c.ink2),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      contentPadding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.m),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.control)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.control)),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.control)),
        borderSide: focusRing,
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.control)),
        borderSide: BorderSide(color: c.bad, width: 2),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onInk : c.ink2),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.ink : c.well),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.ink : c.rule),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.ink : Colors.transparent),
      checkColor: WidgetStatePropertyAll(c.onInk),
      side: BorderSide(color: c.ink2, width: 1.5),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.paper,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.ink,
      indicatorShape: controlShape,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? type.meta(c.ink).copyWith(fontWeight: FontWeight.w700) : type.meta(c.ink2),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? c.onInk : c.ink2, size: 22),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.paper,
      indicatorColor: c.ink,
      indicatorShape: controlShape,
      selectedIconTheme: IconThemeData(color: c.onInk),
      unselectedIconTheme: IconThemeData(color: c.ink2),
      selectedLabelTextStyle: type.meta(c.ink).copyWith(fontWeight: FontWeight.w700),
      unselectedLabelTextStyle: type.meta(c.ink2),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.paper,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.paper,
      elevation: 8,
      shadowColor: c.ink.withValues(alpha: 0.18),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
      showDragHandle: true,
      dragHandleColor: c.rule,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.paper,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.control))),
      titleTextStyle: type.title(c.ink),
      contentTextStyle: type.body(c.ink),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: c.ink.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.control)),
        side: BorderSide(color: c.rule),
      ),
      textStyle: type.body(c.ink),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.ink,
      contentTextStyle: type.body(c.onInk),
      actionTextColor: c.onInk,
      behavior: SnackBarBehavior.floating,
      shape: controlShape,
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(Radii.control)),
      textStyle: type.meta(c.onInk),
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
