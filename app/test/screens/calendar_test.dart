import 'package:den_app/features/calendar/screens/calendar_screen.dart';
import 'package:den_app/features/calendar/screens/day_view.dart';
import 'package:den_app/features/calendar/widgets/family_week.dart';
import 'package:den_app/features/calendar/widgets/month_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';

/// The calendar, drawn the way the canvas's Calendar and iPad family week boards do: in light
/// and dark, on a phone and an iPad, and at 200 % text.
void main() {
  final now = demoNow.millisecondsSinceEpoch;

  group('List (the phone calendar)', () {
    testWidgets('phone', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(tester, 'calendar_list_phone', const CalendarScreen(), state: state);
    });

    testWidgets('phone, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(tester, 'calendar_list_phone_dark', const CalendarScreen(), state: state, night: true);
    });

    testWidgets('phone, in the app', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(tester, 'calendar_list_phone_app', state: state, location: '/calendar');
    });

    testWidgets('phone, in the app, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(tester, 'calendar_list_phone_app_dark', state: state, location: '/calendar', night: true);
    });

    testWidgets('phone, 200 % text', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_list_phone_text200',
        const CalendarScreen(),
        state: state,
        text: 2,
        size: tallPhone,
      );
    });

    testWidgets('phone, events at the same time combined into one', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_list_phone_combined',
        const CalendarScreen(),
        state: state,
        act: () => tester.tap(find.text('Combine 2')),
      );
      expect(find.textContaining('Piano lesson and Swim'), findsOneWidget);
      expect(find.text('Show both'), findsOneWidget);
    });

    testWidgets('phone, combined, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_list_phone_combined_dark',
        const CalendarScreen(),
        state: state,
        night: true,
        act: () => tester.tap(find.text('Combine 2')),
      );
    });

    testWidgets('phone, one person', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_list_phone_leo',
        const CalendarScreen(),
        state: state,
        act: () async {
          // Slide the people across to Leo, as a finger would.
          await tester.drag(find.text('Priya'), const Offset(-200, 0));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Leo'));
        },
      );
    });

    testWidgets('phone, a day with nothing on it, and offline', (tester) async {
      final state = await demo(tester);
      await shootCalendar(
        tester,
        'calendar_list_phone_empty_offline',
        const CalendarScreen(date: '2025-02-11', offline: true),
        state: state,
      );
    });
  });

  group('Day', () {
    testWidgets('phone, today with the now line', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(tester, 'calendar_day_phone', const CalendarScreen(view: CalendarView.day), state: state);
    });

    testWidgets('phone, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_day_phone_dark',
        const CalendarScreen(view: CalendarView.day),
        state: state,
        night: true,
      );
    });

    testWidgets('phone, 200 % text', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_day_phone_text200',
        DayView(date: state.today, now: now),
        state: state,
        text: 2,
      );
    });

    testWidgets('iPad, a column per person', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_day_pad',
        const CalendarScreen(view: CalendarView.day),
        state: state,
        size: padContent,
      );
    });
  });

  group('Week (the iPad family week)', () {
    testWidgets('iPad', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(tester, 'calendar_week_pad', const CalendarScreen(), state: state, size: padContent);
    });

    testWidgets('iPad, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_week_pad_dark',
        const CalendarScreen(),
        state: state,
        size: padContent,
        night: true,
      );
    });

    testWidgets('iPad, 200 % text', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_week_pad_text200',
        const CalendarScreen(),
        state: state,
        size: padContent,
        text: 2,
      );
    });

    testWidgets('iPad, in the app', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(tester, 'calendar_week_pad_app', state: state, location: '/calendar', size: pad);
    });

    testWidgets('iPad, in the app, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(tester, 'calendar_week_pad_app_dark', state: state, location: '/calendar', size: pad, night: true);
    });

    testWidgets('iPad 1024 wide, six people, in the app', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(tester, 'calendar_week_pad_1024', state: state, location: '/calendar', size: const Size(1024, 1366));
    });

    testWidgets('iPad, in the app, 200 % text', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(tester, 'calendar_week_pad_app_text200', state: state, location: '/calendar', size: pad, text: 2);
    });

    testWidgets('on the wall', (tester) async {
      final state = await demo(tester, wall: true);
      await shootCalendar(
        tester,
        'calendar_week_wall',
        FamilyWeek(startDate: state.today, showChores: false, fillHeight: true),
        state: state,
        size: wall,
      );
    });
  });

  group('Month', () {
    testWidgets('phone', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(tester, 'calendar_month_phone', const CalendarScreen(view: CalendarView.month), state: state);
    });

    testWidgets('phone, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_phone_dark',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        night: true,
      );
    });

    testWidgets('phone, 200 % text', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_phone_text200',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        text: 2,
        size: tallPhone,
      );
    });

    testWidgets('iPad', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_pad',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        size: padContent,
      );
    });

    testWidgets('iPad, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_pad_dark',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        size: padContent,
        night: true,
      );
    });

    testWidgets('on the wall', (tester) async {
      final state = await demo(tester, wall: true);
      await shootCalendar(
        tester,
        'calendar_month_wall',
        MonthView(anchor: state.today),
        state: state,
        size: wall,
      );
    });
  });
}
