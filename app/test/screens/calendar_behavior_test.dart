import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/calendar/screens/calendar_screen.dart';
import 'package:den_app/features/calendar/screens/event_detail.dart';
import 'package:den_app/features/calendar/state/day_groups.dart';
import 'package:den_app/features/calendar/words/block_words.dart';
import 'package:den_app/features/calendar/words/event_kinds.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';

/// What the calendar does, checked without screenshots.
void main() {
  String id(AppState state, String name) => state.den.members.firstWhere((m) => m.name == name).id;

  group('An event changed in place', () {
    testWidgets('who drives is two taps: the driver, then a person; for this day only, with Undo', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await pumpCalendar(
        tester,
        EventDetailScreen(eventId: soccer.event.id, at: soccer.start),
        state: state,
        size: tallPhone,
      );

      await tester.tap(find.text('Priya').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('driving Leo'), findsOneWidget);
      await tapAndWait(tester, find.text('Maya').last);

      Occurrence again() =>
          state.den.occurrences(soccer.start - 1, soccer.start + 1).firstWhere((o) => o.event.id == soccer.event.id);
      expect(again().rides.firstWhere((r) => r.leg == 'to').driver, id(state, 'Maya'));
      expect(
        state.den.event(soccer.event.id)!.rides.firstWhere((r) => r.leg == 'to').driver,
        id(state, 'Priya'),
        reason: 'one tap changes this day, not the series',
      );
      expect(find.textContaining('Maya is driving Leo'), findsOneWidget);

      await tapAndWait(tester, find.text('Undo'));
      expect(again().rides.firstWhere((r) => r.leg == 'to').driver, id(state, 'Priya'));
    });

    testWidgets('I’ll drive takes the leg nobody is driving in one tap', (tester) async {
      final state = await demo(tester);
      final swim = findEvent(state, 'Swim');
      await pumpCalendar(
        tester,
        EventDetailScreen(eventId: swim.event.id, at: swim.start),
        state: state,
        size: tallPhone,
      );
      await tapAndWait(tester, find.text('I’ll drive'));
      final now = state.den.occurrences(swim.start - 1, swim.start + 1).firstWhere((o) => o.event.id == swim.event.id);
      expect(now.rides.single.driver, state.me!.id);
      expect(find.textContaining('You’re driving Zoe'), findsOneWidget);
    });

    testWidgets('renaming an event that happens once goes through at once, with Undo', (tester) async {
      final state = await demo(tester);
      final party = findEvent(state, 'Sophie');
      await pumpCalendar(
        tester,
        EventDetailScreen(eventId: party.event.id, at: party.start),
        state: state,
        size: tallPhone,
      );
      await tester.tap(find.textContaining('birthday'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Sophie’s party');
      await tapAndWait(tester, find.text('Done'));
      expect(state.den.event(party.event.id)!.title, 'Sophie’s party');
      expect(find.textContaining('Renamed it'), findsOneWidget);
      await tapAndWait(tester, find.text('Undo'));
      expect(state.den.event(party.event.id)!.title, 'Sophie\'s birthday party');
    });

    testWidgets('renaming a repeating event asks in place, and "just this one" changes only it', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await pumpCalendar(
        tester,
        EventDetailScreen(eventId: soccer.event.id, at: soccer.start, open: DetailField.title),
        state: state,
        size: tallPhone,
      );
      await tester.enterText(find.byType(TextField), 'Soccer (indoor)');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Change just this Tuesday'), findsOneWidget);
      expect(state.den.event(soccer.event.id)!.title, 'Soccer practice', reason: 'nothing changes before the answer');

      await tapAndWait(tester, find.text('Just this one'));
      final day = state.den
          .occurrences(soccer.start - 1, soccer.start + 1)
          .firstWhere((o) => o.event.id == soccer.event.id);
      expect(day.title, 'Soccer (indoor)');
      expect(state.den.event(soccer.event.id)!.title, 'Soccer practice');
    });

    testWidgets('deleting says so in place, and Undo brings it back', (tester) async {
      final state = await demo(tester);
      final party = findEvent(state, 'Sophie');
      await pumpCalendar(
        tester,
        EventDetailScreen(eventId: party.event.id, at: party.start),
        state: state,
        size: tallPhone,
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.textContaining('Delete Sophie'));
      expect(state.den.event(party.event.id), isNull);
      expect(find.textContaining('Deleted Sophie'), findsOneWidget);
      await tapAndWait(tester, find.text('Undo'));
      expect(state.den.event(party.event.id), isNotNull);
    });

    testWidgets('someone without calendar access sees why, and nothing to press', (tester) async {
      final state = await demo(tester);
      final f = state.formats;
      await write(
        tester,
        () => state.den.addEvent(
          title: 'Field trip',
          start: f.startOf(state.today) + 9 * 3600000,
          end: f.startOf(state.today) + 14 * 3600000,
          source: const EventSource('ics', 'school', 'Oak Grove School'),
        ),
      );
      final trip = findEvent(state, 'Field trip');
      await pumpCalendar(
        tester,
        EventDetailScreen(eventId: trip.event.id, at: trip.start),
        state: state,
        size: tallPhone,
      );
      expect(find.textContaining('Change it'), findsOneWidget);
      expect(find.byTooltip('More'), findsNothing);
      expect(find.text('More options'), findsNothing);
    });
  });

  group('The calendar', () {
    testWidgets('a block opens its event, flying into the page, and back closes it', (tester) async {
      final state = await busyDemo(tester);
      await loadFonts();
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = buildRouter(state);
      await tester.pumpWidget(
        DenScope(
          state: state,
          child: MaterialApp.router(routerConfig: router, theme: denTheme(DenColors.day)),
        ),
      );
      router.go('/calendar');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dentist'));
      // Mid-flight: the block's color travels into the page.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.textContaining('Bright Smiles'), findsOneWidget);
      await tester.tap(find.text('Calendar').first);
      await tester.pumpAndSettle();
      expect(find.text('Today, Friday'), findsOneWidget);
    });

    testWidgets('a phone opens on the list; an iPad on the family week', (tester) async {
      final state = await demo(tester);
      await pumpCalendar(tester, const CalendarScreen(), state: state);
      expect(find.text('Today, Friday'), findsOneWidget);
      await pumpCalendar(tester, const CalendarScreen(), state: state, size: padContent);
      expect(find.text('Oct 11 to 17'), findsOneWidget);
    });

    testWidgets('events at the same time combine into one block and open again', (tester) async {
      final state = await busyDemo(tester);
      await pumpCalendar(tester, const CalendarScreen(), state: state, size: tallPhone);
      expect(find.text('Combine 2'), findsOneWidget);
      await tester.tap(find.text('Combine 2'));
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-flight it can be turned around, from where it is.
      await tester.tap(find.text('Show both'));
      await tester.pumpAndSettle();
      expect(find.text('Combine 2'), findsOneWidget);
      await tester.tap(find.text('Combine 2'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Piano lesson and Swim'), findsOneWidget);
      await tester.tap(find.textContaining('Piano lesson and Swim'));
      await tester.pumpAndSettle();
      expect(find.text('Combine 2'), findsOneWidget);
    });

    testWidgets('one person shows their events and everyone’s, in their color', (tester) async {
      final state = await busyDemo(tester);
      await pumpCalendar(tester, const CalendarScreen(), state: state, size: tallPhone);
      expect(find.text('Piano lesson'), findsOneWidget);
      await tester.drag(find.text('Priya'), const Offset(-320, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zoe'));
      await tester.pumpAndSettle();
      expect(find.text('Piano lesson'), findsNothing);
      expect(find.text('Swim lesson'), findsOneWidget);
      expect(find.text('Movie night'), findsOneWidget);
    });

    testWidgets('the week strip swipes to the next week and keeps the weekday', (tester) async {
      final state = await demo(tester);
      await pumpCalendar(tester, const CalendarScreen(), state: state, size: tallPhone);
      await tester.fling(find.text('16'), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('Friday, October 23'), findsOneWidget);
    });
  });

  group('Words', () {
    test('a kind from the title, the place, then the category', () {
      expect(eventKind('Soccer practice'), 'ball');
      expect(eventKind('Piano practice'), 'music');
      expect(eventKind('School drop-off'), 'car');
      expect(eventKind('Dentist'), 'tooth');
      expect(eventKind('Swim lesson'), 'swim');
      expect(eventKind('Beach trip'), 'beach');
      expect(eventKind('Business lunch'), 'food', reason: 'a bus only as a whole word');
      expect(eventKind('Checkup', location: 'Riverside Clinic'), 'doctor');
      expect(eventKind('Leo', category: 'sports'), 'ball');
      expect(eventKind('Something else'), 'calendar');
    });

    test('lines keep units together and never leave one long piece to split', () {
      expect(tidyLine('Anniversary dinner'), 'Anniversary dinner');
      expect(tidyLine('Dinner at Grandma’s'), 'Dinner at Grandma’s');
      expect(tidyLine('Leo, until 5:00 PM'), 'Leo, until 5:00 PM');
    });

    test('names and titles joined the way people say them', () {
      expect(joinNames(['Leo']), 'Leo');
      expect(joinNames(['Leo', 'Mia']), 'Leo and Mia');
      expect(joinNames(['Leo', 'Mia', 'Zoe']), 'Leo, Mia and Zoe');
      expect(combinedTitle(['Soccer, Field 4', 'Piano lesson']), 'Soccer and Piano lesson');
    });
  });

  testWidgets('events that overlap, directly or through a chain, are one group', (tester) async {
    final state = await demo(tester);
    final f = state.formats;
    final day = state.today;
    final start = f.startOf(day);
    Occurrence occ(String title, int from, int to) {
      final event = state.den.events.first;
      return Occurrence(
        event: event,
        start: start + from * 60000,
        end: start + to * 60000,
        title: title,
        location: '',
        notes: '',
        assignees: const [],
        allDay: false,
      );
    }

    final groups = groupDay(
      [occ('A', 900, 960), occ('B', 930, 990), occ('C', 980, 1000), occ('D', 1100, 1130)],
      f,
      day,
    );
    expect([for (final g in groups) g.items.map((o) => o.title).join()], ['ABC', 'D']);
    expect(groups.first.time, f.time(start + 900 * 60000));
  });
}
