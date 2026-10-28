import 'package:den_app/features/calendar/screens/agenda_view.dart';
import 'package:den_app/features/calendar/screens/day_view.dart';
import 'package:den_app/features/calendar/widgets/month_view.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';

void main() {
  final now = demoNow.millisecondsSinceEpoch;

  group('Month', () {
    testWidgets('phone', (tester) async {
      final state = await demo(tester);
      await shoot(tester, 'calendar_month_phone', MonthView(anchor: state.today), state: state);
    });

    testWidgets('phone, night', (tester) async {
      final state = await demo(tester);
      await shoot(tester, 'calendar_month_phone_night', MonthView(anchor: state.today), state: state, night: true);
    });

    testWidgets('tablet, in the calendar tab', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'calendar_month_tablet', state: state, location: '/calendar/month/${state.today}', size: tablet);
    });

    testWidgets('wall', (tester) async {
      final state = await demo(tester, wall: true);
      await shoot(tester, 'calendar_month_wall', MonthView(anchor: state.today), state: state, size: wall);
    });

    testWidgets('wall, night', (tester) async {
      final state = await demo(tester, wall: true);
      await shoot(tester, 'calendar_month_wall_night', MonthView(anchor: state.today), state: state, size: wall, night: true);
    });
  });

  group('Day', () {
    testWidgets('phone, today with the now line', (tester) async {
      final state = await demo(tester);
      await shoot(tester, 'calendar_day_phone', DayView(date: state.today, now: now), state: state);
    });

    testWidgets('phone, night', (tester) async {
      final state = await demo(tester);
      await shoot(tester, 'calendar_day_phone_night', DayView(date: state.today, now: now), state: state, night: true);
    });

    testWidgets('tablet, in the calendar tab', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'calendar_day_tablet', state: state, location: '/calendar/day/${state.today}', size: tablet);
    });

    testWidgets('phone, tomorrow', (tester) async {
      final state = await demo(tester);
      final tomorrow = state.formats.addDays(state.today, 1);
      await shoot(tester, 'calendar_day_phone_tomorrow', DayView(date: tomorrow, now: now), state: state);
    });

    testWidgets('phone, an empty day', (tester) async {
      final state = await demo(tester);
      const empty = '2025-02-11';
      await shoot(tester, 'calendar_day_phone_empty', DayView(date: empty, now: now), state: state);
    });
  });

  group('Agenda', () {
    testWidgets('phone', (tester) async {
      final state = await demo(tester);
      await shoot(tester, 'calendar_agenda_phone', AgendaView(start: state.today), state: state);
    });

    testWidgets('phone, night', (tester) async {
      final state = await demo(tester);
      await shoot(tester, 'calendar_agenda_phone_night', AgendaView(start: state.today), state: state, night: true);
    });

    testWidgets('tablet, in the calendar tab', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'calendar_agenda_tablet', state: state, location: '/calendar/agenda/${state.today}', size: tablet);
    });

    testWidgets('phone, nothing planned', (tester) async {
      final state = await demo(tester);
      const empty = '2025-02-11';
      await shoot(tester, 'calendar_agenda_phone_empty', AgendaView(start: empty), state: state);
    });
  });

  testWidgets('Month in the calendar tab on a phone', (tester) async {
    final state = await demo(tester);
    await shootAt(tester, 'calendar_month_phone_tab', state: state, location: '/calendar/month/${state.today}');
  });
}
