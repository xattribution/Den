import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../calendar/calendar.dart' show calendarDaysChoices, calendarLightChoices;

/// Settings, Appearance: how this device draws the calendar. "Calendar": matching the app, or
/// always light, so the calendar reads like paper even at night while the tab bar and the other
/// screens follow the app. "Show days as": the month's days with people's dots under them, or in
/// their colors (the calendar's view options say the same). Both are kept on this device.
class CalendarLookChoice extends StatelessWidget {
  const CalendarLookChoice({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {Changes.prefs});
    final c = context.colors;
    Widget label(String words) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Semantics(header: true, child: Text(words, style: context.text.meta(c.ink2))),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        label('Calendar'),
        const SizedBox(height: Sp.s),
        GroupCard(
          child: ChoiceRows<bool>(
            choices: calendarLightChoices,
            value: app.calendarLight,
            onChanged: (light) => app.calendarLight = light,
          ),
        ),
        const SizedBox(height: Sp.l),
        label('Show days as'),
        const SizedBox(height: Sp.s),
        GroupCard(
          child: ChoiceRows<CalendarDays>(
            choices: calendarDaysChoices,
            value: app.calendarDays,
            onChanged: (days) => app.calendarDays = days,
          ),
        ),
      ],
    );
  }
}
