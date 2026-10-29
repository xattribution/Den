import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/day_theme.dart';
import '../../../design/tokens.dart';

/// The calendar's content on the surface this device chose for it (Settings, Appearance,
/// "Calendar"). Matching the app, it's [child] as it is. Always light, it's [child] in the day
/// tokens ([DayTheme]) on a light panel with rounded corners, set into the app's own frame: the
/// tab bar, the sidebar, the status bar's strip and the safe areas keep the app's theme, so dark
/// chrome meets the light calendar at a deliberate edge, never at a seam. In a light app the
/// panel is the page's own color and nothing shows.
///
/// The panel doesn't depend on the app's brightness, so the calendar never flashes while the app
/// turns from day to night (Auto at sunset): only the frame around it changes. Turning the
/// setting on or off keeps the calendar where it was: the widgets around it stay the same kinds.
class CalendarSurface extends StatelessWidget {
  const CalendarSurface({super.key, required this.child, this.page = false});

  final Widget child;

  /// A page pushed over the whole app (an event on a phone): the panel starts under the status
  /// bar's strip, which keeps the app's color, and runs to the bottom edge.
  final bool page;

  /// The theme a sheet or page opened from the calendar takes: the day theme when this device
  /// keeps the calendar light, otherwise null (the app's).
  static ThemeData? sheetTheme(BuildContext context) =>
      DenScope.read(context).calendarLight ? DayTheme.around(context) : null;

  @override
  Widget build(BuildContext context) {
    final light = context.watch(const {Changes.prefs}).calendarLight;
    final frame = context.colors.bg;
    final theme = light ? DayTheme.around(context) : Theme.of(context);
    final day = theme.extension<DenColors>()!;
    final radius = !light
        ? BorderRadius.zero
        : page
            ? const BorderRadius.vertical(top: Radius.circular(Radii.section))
            : const BorderRadius.all(Radius.circular(Radii.section));
    final panel = Theme(
      data: theme,
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: light ? Clip.antiAlias : Clip.none,
        child: ColoredBox(
          color: light ? day.bg : const Color(0x00000000),
          child: DefaultTextStyle(
            style: light ? theme.textTheme.bodyMedium! : DefaultTextStyle.of(context).style,
            child: child,
          ),
        ),
      ),
    );
    if (!page) return panel;
    final top = light ? MediaQuery.paddingOf(context).top : 0.0;
    return ColoredBox(
      color: light ? frame : const Color(0x00000000),
      child: Padding(
        padding: EdgeInsets.only(top: top),
        child: MediaQuery.removePadding(context: context, removeTop: light, child: panel),
      ),
    );
  }
}
