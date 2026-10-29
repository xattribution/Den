import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/calendar/screens/calendar_screen.dart';
import 'package:den_app/features/calendar/screens/event_detail.dart';
import 'package:den_app/features/calendar/state/calendar_sources.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';

/// The demo family's busy October, with a day for four (Saturday the 24th: the first two colors
/// and "+2") and one for three (Wednesday the 21st), as a parent would see it in the month.
Future<AppState> colorfulDemo(WidgetTester tester, {CalendarDays days = CalendarDays.colors}) async {
  final state = await busyDemo(tester);
  await tester.runAsync(() async {
    final den = state.den;
    final f = state.formats;
    String id(String name) => den.members.firstWhere((m) => m.name == name).id;
    int at(String date, int hour) => f.startOf(date) + hour * 3600000;
    await den.addEvent(
      title: 'Pumpkin patch',
      start: at('2026-10-24', 10),
      end: at('2026-10-24', 12),
      assignees: [id('Alex'), id('Maya'), id('Leo'), id('Zoe')],
    );
    await den.addEvent(title: 'Book club', start: at('2026-10-21', 19), end: at('2026-10-21', 20), assignees: [id('Priya')]);
    await den.addEvent(title: 'Art class', start: at('2026-10-21', 16), end: at('2026-10-21', 17), assignees: [id('Zoe')]);
  });
  state.calendarDays = days;
  return state;
}

Future<void> _pack(WidgetTester tester, AppState state, ColorPack pack) =>
    write(tester, () => state.den.updateFamily({'colors': pack.name}));

/// Days in their people's colors, the calendar kept light in a dark app, and the family's color
/// packs, drawn on phone and iPad, by day and at night.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Days in their colors', () {
    testWidgets('phone', (tester) async {
      final state = await colorfulDemo(tester);
      await shootCalendar(tester, 'calendar_month_phone_colors', const CalendarScreen(view: CalendarView.month), state: state);
      expect(
        find.bySemanticsLabel(RegExp(r'^Saturday, October 24, Alex, Maya, Leo and Zoe$')),
        findsOneWidget,
        reason: 'a screen reader hears who, past the two colors drawn',
      );
      expect(find.text('+2'), findsNWidgets(3), reason: 'the 14th, the 21st and the 24th have four people or more');
    });

    testWidgets('phone, dark', (tester) async {
      final state = await colorfulDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_phone_colors_dark',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        night: true,
      );
    });

    testWidgets('phone, 200 % text', (tester) async {
      final state = await colorfulDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_phone_colors_text200',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        text: 2,
        size: tallPhone,
      );
    });

    testWidgets('phone, the Deep pack', (tester) async {
      final state = await colorfulDemo(tester);
      await _pack(tester, state, ColorPack.deep);
      await shootCalendar(tester, 'calendar_month_phone_colors_deep', const CalendarScreen(view: CalendarView.month), state: state);
    });

    testWidgets('iPad', (tester) async {
      final state = await colorfulDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_pad_colors',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        size: padContent,
      );
    });

    testWidgets('iPad, dark', (tester) async {
      final state = await colorfulDemo(tester);
      await shootCalendar(
        tester,
        'calendar_month_pad_colors_dark',
        const CalendarScreen(view: CalendarView.month),
        state: state,
        size: padContent,
        night: true,
      );
    });

    testWidgets('the view options turn colors on and off, and the day below stays', (tester) async {
      final state = await colorfulDemo(tester, days: CalendarDays.dots);
      await pumpCalendar(tester, const CalendarScreen(view: CalendarView.month), state: state);
      await tester.tap(find.bySemanticsLabel('View options'));
      await tester.pumpAndSettle();
      expect(findWords('Show days as'), findsOneWidget);
      await tester.tap(find.text('Colors'));
      await tester.pumpAndSettle();
      expect(state.calendarDays, CalendarDays.colors);
      expect(find.text('+2'), findsNWidgets(3), reason: 'the 14th, the 21st and the 24th have four people or more');
      expect(find.text('Today, Friday'), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString('den.calendarDays'), 'colors', reason: 'kept on this device');
    });

    testWidgets('only the month offers them', (tester) async {
      final state = await colorfulDemo(tester);
      await pumpCalendar(tester, const CalendarScreen(view: CalendarView.agenda), state: state);
      expect(find.bySemanticsLabel('View options'), findsNothing);
    });
  });

  testWidgets('a pack picked on another device recolors the calendar in place', (tester) async {
    final state = await colorfulDemo(tester);
    await pumpAt(tester, state: state, location: '/calendar?view=month');
    final before = tester.state(find.byType(CalendarScreen));
    await _pack(tester, state, ColorPack.soft);
    expect(Theme.of(tester.element(find.text('October'))).extension<DenColors>()!.pack, ColorPack.soft);
    expect(tester.state(find.byType(CalendarScreen)), same(before), reason: 'nothing starts over');
  });

  testWidgets('a calendar source is data of its own, colored apart from people', (tester) async {
    final state = await demo(tester);
    final sources = calendarSources(state);
    expect(sources.first.kind, CalendarSourceKind.family);
    expect(sources.first.label, state.den.family!.name);
    expect(sources.first.initial, state.den.family!.name.substring(0, 1).toUpperCase());
    expect(sources.first.color, isNull, reason: 'no source color until someone picks one');
    expect(sourceOf(state, findEvent(state, 'Soccer')), sources.first);
  });

  group('The calendar kept light in a dark app', () {
    Future<AppState> light(WidgetTester tester) async {
      final state = await colorfulDemo(tester, days: CalendarDays.dots);
      state.calendarLight = true;
      return state;
    }

    testWidgets('phone, the list', (tester) async {
      final state = await light(tester);
      await shootAt(tester, 'calendar_light_phone_app_dark', state: state, location: '/calendar', night: true);
      expect(Theme.of(tester.element(find.text('October'))).extension<DenColors>()!.isDark, isFalse);
      expect(Theme.of(tester.element(find.text('Calendar').last)).extension<DenColors>()!.isDark, isTrue, reason: 'the tab bar follows the app');
    });

    testWidgets('phone, the month in colors', (tester) async {
      final state = await light(tester);
      state.calendarDays = CalendarDays.colors;
      await shootAt(tester, 'calendar_light_month_phone_app_dark', state: state, location: '/calendar?view=month', night: true);
    });

    testWidgets('phone, an event opened from it', (tester) async {
      final state = await light(tester);
      final piano = findEvent(state, 'Piano');
      await shootAt(
        tester,
        'calendar_light_event_phone_dark',
        state: state,
        base: '/calendar',
        location: '/event/${piano.event.id}?at=${piano.start}&from=calendar',
        night: true,
        size: tallPhone,
      );
      expect(_pageColor(tester), DenColors.day.bg);
    });

    testWidgets('phone, a sheet opened from it', (tester) async {
      final state = await light(tester);
      await shootAt(
        tester,
        'calendar_light_sheet_phone_dark',
        state: state,
        location: '/calendar?view=month',
        night: true,
        act: () => tester.tap(find.bySemanticsLabel('View options')),
      );
    });

    testWidgets('iPad, the family week', (tester) async {
      final state = await light(tester);
      await shootAt(tester, 'calendar_light_pad_app_dark', state: state, location: '/calendar', size: pad, night: true);
    });

    testWidgets('the other tabs and an event opened elsewhere follow the app', (tester) async {
      final state = await light(tester);
      final piano = findEvent(state, 'Piano');
      await pumpAt(tester, state: state, location: '/event/${piano.event.id}?at=${piano.start}', base: '/today', night: true);
      expect(_pageColor(tester), DenColors.night.bg, reason: 'opened from Today, it follows the app');
    });
  });
}

/// The page color of the event page showing.
Color? _pageColor(WidgetTester tester) => tester
    .widget<Scaffold>(find.descendant(of: find.byType(EventDetailScreen), matching: find.byType(Scaffold)).first)
    .backgroundColor;
