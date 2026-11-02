import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/calendar/screens/calendar_screen.dart';
import 'package:den_app/features/calendar/widgets/date_strip.dart';
import 'package:den_app/features/settings/screens/appearance_screen.dart';
import 'package:den_app/features/settings/widgets/theme_choice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart' hide demo;
import 'family_fakes.dart';

/// The Soft theme where people see it (KIDS_MODE_AND_SOFT_THEME.md, phase 2): chosen in
/// Settings, Appearance with a live preview, and the calendar's chosen day in baby blue.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const tall = Size(390, 1800);

  group('Settings, Appearance', () {
    testWidgets('Soft is the fourth choice, one tap, kept on this device', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, const AppearanceScreen(), state: state, size: tall);
      expect(find.text('Soft'), findsOneWidget);
      expect(findWords('Baby blue and navy, light or dark as this device is'), findsOneWidget);
      await tester.tap(find.text('Soft'));
      await tester.pumpAndSettle();
      expect(state.theme, ThemeChoice.soft);
      expect((await SharedPreferences.getInstance()).getString('den.theme'), 'soft');
    });

    testWidgets('the preview follows the choice: Soft by day and at night, Day alone', (tester) async {
      final state = await demo(tester);
      state.theme = ThemeChoice.soft;
      await pumpScreen(tester, const AppearanceScreen(), state: state, size: tall);
      expect(find.text('By day'), findsOneWidget);
      expect(find.text('At night'), findsOneWidget);
      final soft = find.descendant(of: find.byType(ThemePreview), matching: find.text('29'));
      expect(soft, findsNWidgets(2));
      expect(tester.element(soft.first).colors.selection, DenColors.softDay.selection, reason: 'drawn by the real tokens');
      expect(tester.element(soft.last).colors.bg, DenColors.softNightGround);

      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();
      expect(find.text('By day'), findsNothing);
      expect(find.descendant(of: find.byType(ThemePreview), matching: find.text('29')), findsOneWidget);
    });

    testWidgets('the preview is a picture: the screen reader hears the rows, not it', (tester) async {
      final state = await demo(tester);
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, const AppearanceScreen(), state: state, size: tall);
      expect(find.bySemanticsLabel('Soft, Baby blue and navy, light or dark as this device is'), findsOneWidget);
      expect(find.bySemanticsLabel('Approve'), findsNothing);
      handle.dispose();
    });

    for (final (suffix, theme) in [('', DenColors.softDay), ('_night', DenColors.softNight)]) {
      testWidgets('phone, Soft$suffix', (tester) async {
        final state = await demo(tester);
        state.theme = ThemeChoice.soft;
        await shootWith(tester, 'settings_soft_phone$suffix', const AppearanceScreen(), state: state, size: tall, theme: theme, pushed: true);
      });
    }

    testWidgets('phone, Soft, 200 % text', (tester) async {
      final state = await demo(tester);
      state.theme = ThemeChoice.soft;
      withTextScale(tester, 2);
      await shootWith(tester, 'settings_soft_phone_text200', const AppearanceScreen(), state: state, size: const Size(390, 3600), theme: DenColors.softDay, pushed: true);
    });

    testWidgets('tablet, Soft', (tester) async {
      final state = await demo(tester);
      state.theme = ThemeChoice.soft;
      await shootWith(tester, 'settings_soft_tablet', const AppearanceScreen(), state: state, size: tablet, theme: DenColors.softDay, pushed: true);
    });
  });

  group('Calendar in Soft', () {
    for (final (suffix, theme) in [('', DenColors.softDay), ('_night', DenColors.softNight)]) {
      testWidgets('list, phone, Soft$suffix: the chosen day in baby blue', (tester) async {
        final state = await busyDemo(tester);
        await shootCalendar(tester, 'calendar_list_phone_soft$suffix', const CalendarScreen(), state: state, theme: theme);
      });

      testWidgets('month, phone, Soft$suffix', (tester) async {
        final state = await busyDemo(tester);
        await shootCalendar(tester, 'calendar_month_phone_soft$suffix', const CalendarScreen(view: CalendarView.month), state: state, theme: theme);
      });

      testWidgets('week, tablet, Soft$suffix, in the app', (tester) async {
        final state = await busyDemo(tester);
        await shootAt(tester, 'calendar_week_pad_soft$suffix', state: state, location: '/calendar', size: tablet, theme: theme);
      });
    }

    testWidgets('list, phone, Soft, 200 % text', (tester) async {
      final state = await busyDemo(tester);
      await shootCalendar(tester, 'calendar_list_phone_soft_text200', const CalendarScreen(), state: state, text: 2, size: tallPhone, theme: DenColors.softDay);
    });

    testWidgets("the chosen day is drawn in Soft's selection, with ink on it", (tester) async {
      final state = await busyDemo(tester);
      await pumpCalendar(tester, const CalendarScreen(), state: state, theme: DenColors.softDay);
      final day = '${state.formats.dateTime(state.today).day}';
      final number = find.descendant(of: find.byType(WeekStrip), matching: find.text(day)).first;
      expect((tester.widget<Text>(number).style?.color), DenColors.softDay.onSelection);
      final fills = tester
          .widgetList<DecoratedBox>(find.ancestor(of: number, matching: find.byType(DecoratedBox)))
          .map((b) => switch (b.decoration) {
                ShapeDecoration(:final color) => color,
                BoxDecoration(:final color) => color,
                _ => null,
              });
      expect(fills, contains(DenColors.softDay.selection));
    });

    testWidgets('in Day the chosen day stays ink, as before', (tester) async {
      final state = await busyDemo(tester);
      await pumpCalendar(tester, const CalendarScreen(), state: state);
      final day = '${state.formats.dateTime(state.today).day}';
      final number = find.descendant(of: find.byType(WeekStrip), matching: find.text(day)).first;
      expect((tester.widget<Text>(number).style?.color), DenColors.day.onPrimary);
    });
  });
}
