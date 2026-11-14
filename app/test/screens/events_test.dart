import 'package:den_app/features/calendar/screens/event_detail.dart';
import 'package:den_app/features/calendar/screens/event_editor.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_shots.dart';

/// An event, opened from the calendar: looked at, and changed in place. Drawn the way the
/// canvas's "An event, tap to change" board does, in light and dark, on a phone and an iPad, and
/// at 200 % text.
void main() {
  String detail(Occurrence occ) => '/event/${occ.event.id}?at=${occ.start}&from=calendar';
  Widget page(Occurrence occ, {DetailField? open}) =>
      EventDetailScreen(eventId: occ.event.id, at: occ.start, from: 'calendar', open: open);

  group('An event', () {
    testWidgets('phone: soccer, every Tuesday and Thursday, with rides', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'events_detail_phone', state: state, location: detail(findEvent(state, 'Soccer')));
    });

    testWidgets('phone, dark', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_detail_phone_dark',
        state: state,
        location: detail(findEvent(state, 'Soccer')),
        night: true,
      );
    });

    testWidgets('phone, 200 % text', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_detail_phone_text200',
        state: state,
        location: detail(findEvent(state, 'Soccer')),
        size: tallPhone,
        text: 2,
      );
    });

    testWidgets('phone: today, nobody driving yet', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'events_detail_phone_swim', state: state, location: detail(findEvent(state, 'Swim')));
    });

    testWidgets('phone: for everyone', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_detail_phone_everyone',
        state: state,
        location: detail(findEvent(state, 'Grandma')),
      );
    });

    testWidgets('phone: for everyone, dark', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_detail_phone_everyone_dark',
        state: state,
        location: detail(findEvent(state, 'Grandma')),
        night: true,
      );
    });

    testWidgets('iPad: a form sheet over the family week', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(
        tester,
        'events_detail_pad',
        state: state,
        base: '/calendar',
        location: detail(findEvent(state, 'Soccer')),
        size: pad,
      );
    });

    testWidgets('iPad, dark', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(
        tester,
        'events_detail_pad_dark',
        state: state,
        base: '/calendar',
        location: detail(findEvent(state, 'Dentist')),
        size: pad,
        night: true,
      );
    });

    testWidgets('phone: from another calendar, so changed there', (tester) async {
      final state = await demo(tester);
      final f = state.formats;
      await write(
        tester,
        () => state.den.addEvent(
          title: 'Field trip',
          start: f.startOf(state.today) + 9 * 3600000,
          end: f.startOf(state.today) + 14 * 3600000,
          assignees: [state.den.members.firstWhere((m) => m.name == 'Maya').id],
          location: 'Science Museum',
          source: const EventSource('ics', 'school', 'Oak Grove School'),
        ),
      );
      await shootAt(
        tester,
        'events_detail_phone_readonly',
        state: state,
        location: detail(findEvent(state, 'Field trip')),
      );
    });

    testWidgets('phone: an event that no longer exists', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'events_detail_phone_missing', state: state, location: '/event/GONE00000000000');
    });
  });

  group('Changing it in place', () {
    testWidgets('the title, as a field in the block', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(tester, 'events_edit_title_phone', page(soccer, open: DetailField.title), state: state);
    });

    testWidgets('the title, dark', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_edit_title_phone_dark',
        page(soccer, open: DetailField.title),
        state: state,
        night: true,
      );
    });

    testWidgets('when and how often', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_edit_when_phone',
        page(soccer),
        state: state,
        size: tallPhone,
        act: () => tester.tap(find.textContaining('Tuesday, 5:00')),
      );
    });

    testWidgets('when and how often, 200 % text', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_edit_when_phone_text200',
        page(soccer),
        state: state,
        size: const Size(390, 2600),
        text: 2,
        act: () => tester.tap(find.textContaining('Tuesday, 5:00')),
      );
    });

    testWidgets('a repeating event asks: just this one, or every one', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_edit_scope_phone',
        page(soccer, open: DetailField.title),
        state: state,
        size: tallPhone,
        act: () async {
          await tester.enterText(find.byType(TextField), 'Soccer practice (indoor)');
          await tester.tap(find.text('Done'));
        },
      );
      expect(find.textContaining('Change just this'), findsOneWidget);
    });

    testWidgets('more options', (tester) async {
      final state = await demo(tester);
      final party = findEvent(state, 'Sophie');
      await shootCalendar(
        tester,
        'events_more_options_phone',
        page(party, open: DetailField.more),
        state: state,
        size: tallPhone,
      );
    });

    testWidgets('who drives: a sheet of people', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_driver_sheet_phone',
        page(soccer),
        state: state,
        act: () => tester.tap(find.text('Priya').last),
      );
      expect(find.textContaining('driving Leo'), findsOneWidget);
    });

    testWidgets('who drives: a sheet of people, dark', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_driver_sheet_phone_dark',
        page(soccer),
        state: state,
        night: true,
        act: () => tester.tap(find.text('Priya').last),
      );
    });

    testWidgets('who drives, on iPad', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(
        tester,
        'events_driver_sheet_pad',
        state: state,
        base: '/calendar',
        location: detail(findEvent(state, 'Soccer')),
        size: pad,
        act: () => tester.tap(find.text('Priya').last),
      );
    });

    testWidgets('who drives, 200 % text', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_driver_sheet_phone_text200',
        page(soccer),
        state: state,
        text: 2,
        act: () async {
          await tester.ensureVisible(find.text('Priya').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Priya').last);
        },
      );
    });

    testWidgets('a change says what it did, with Undo in place', (tester) async {
      final state = await demo(tester);
      final swim = findEvent(state, 'Swim');
      await pumpCalendar(tester, page(swim), state: state);
      await tapAndWait(tester, find.text('I’ll drive'));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/events_undo_phone.png'));
    });

    testWidgets('a change that can’t be saved says why, where it was made, with the way out', (tester) async {
      final state = await failingDemo(tester);
      final party = findEvent(state, 'Sophie');
      await pumpCalendar(tester, page(party, open: DetailField.title), state: state);
      await tester.enterText(find.byType(TextField), 'Sophie’s party');
      await tapAndWait(tester, find.text('Done'));
      expect(find.text('Try again'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/events_error_phone.png'));
    });

    testWidgets('More: deleting a repeating event asks how far', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootCalendar(
        tester,
        'events_delete_phone',
        page(soccer),
        state: state,
        act: () => tester.tap(find.byTooltip('More')),
      );
    });
  });

  group('Adding an event', () {
    testWidgets('phone: from a tapped time', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_new_phone',
        state: state,
        base: '/calendar',
        location: '/event/new?date=${state.today}&time=15:30',
      );
    });

    testWidgets('phone, dark', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_new_phone_dark',
        state: state,
        base: '/calendar',
        location: '/event/new?date=${state.today}&time=15:30',
        night: true,
      );
    });

    testWidgets('phone, with more options', (tester) async {
      final state = await demo(tester);
      await shootCalendar(
        tester,
        'events_new_more_phone',
        EventEditorScreen(date: state.today, time: '15:30', moreOptions: true),
        state: state,
        size: tallPhone,
      );
    });

    testWidgets('phone, 200 % text', (tester) async {
      final state = await demo(tester);
      await shootCalendar(
        tester,
        'events_new_phone_text200',
        EventEditorScreen(date: state.today, time: '15:30'),
        state: state,
        size: const Size(390, 2400),
        text: 2,
      );
    });

    testWidgets('iPad: a form sheet', (tester) async {
      final state = await busyDemo(tester);
      await shootAt(
        tester,
        'events_new_pad',
        state: state,
        base: '/calendar',
        location: '/event/new?date=${state.today}&time=09:00',
        size: pad,
      );
    });

    testWidgets('phone: adding without a title says what to do', (tester) async {
      final state = await demo(tester);
      await shootCalendar(
        tester,
        'events_new_phone_errors',
        EventEditorScreen(date: state.today, time: '15:30'),
        state: state,
        act: () => tester.tap(find.text('Add event')),
      );
    });

    testWidgets('a time is picked from a list, and the end from times after it, with how long', (tester) async {
      final state = await demo(tester);
      await pumpAt(tester, state: state, location: '/event/new?date=${state.today}&time=15:30', base: '/calendar');
      final starts = find.bySemanticsLabel(RegExp(r'^Starts, 3:30'));
      expect(starts, findsOneWidget);
      await tester.tap(starts);
      await tester.pumpAndSettle();
      // Opened at the start it had, so 3:30 is on screen without scrolling.
      expect(find.textContaining('3:30'), findsWidgets);
      await tester.tap(find.textContaining('4:00').last);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Starts, 4:00')), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(RegExp(r'^Ends, ')));
      await tester.pumpAndSettle();
      expect(find.text('1 hr 30 min'), findsOneWidget);
      await tester.tap(find.text('1 hr 30 min'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Ends, 5:30')), findsOneWidget);
    });
  });
}
