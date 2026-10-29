import '../../app/app_state.dart';
import '../../design/widgets.dart';

/// How the month shows who has something on a day, as the calendar's view options and Settings,
/// Appearance offer it.
const List<Choice<CalendarDays>> calendarDaysChoices = [
  Choice(CalendarDays.dots, 'Dots', detail: 'A dot under the day for each person'),
  Choice(CalendarDays.colors, 'Colors', detail: 'Each day in its people’s colors'),
];

/// Whether the calendar matches the app or stays light (Settings, Appearance).
const List<Choice<bool>> calendarLightChoices = [
  Choice(false, 'Match the app'),
  Choice(true, 'Always light', detail: 'Light even when the app is dark'),
];
