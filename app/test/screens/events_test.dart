import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';

void main() {
  String detail(Occurrence occ) => '/event/${occ.event.id}?at=${occ.start}';
  String edit(Occurrence occ) => '/event/${occ.event.id}/edit?at=${occ.start}';

  group('Event detail', () {
    testWidgets('phone: a repeating event with rides', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootAt(tester, 'events_detail_phone', state: state, location: detail(soccer));
    });

    testWidgets('phone, night', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootAt(tester, 'events_detail_phone_night', state: state, location: detail(soccer), night: true);
    });

    testWidgets('phone: today, nobody driving', (tester) async {
      final state = await demo(tester);
      final swim = findEvent(state, 'Swim');
      await shootAt(tester, 'events_detail_phone_swim', state: state, location: detail(swim));
    });

    testWidgets('phone: a multi-day trip with a countdown', (tester) async {
      final state = await demo(tester);
      final beach = findEvent(state, 'Beach');
      await shootAt(tester, 'events_detail_phone_beach', state: state, location: detail(beach));
    });

    testWidgets('tablet: a side panel over the month', (tester) async {
      final state = await demo(tester);
      final party = findEvent(state, 'Sophie');
      await shootAt(
        tester,
        'events_detail_tablet_panel',
        state: state,
        base: '/calendar/month/${state.today}',
        location: detail(party),
        size: tablet,
      );
    });

    testWidgets('phone: deleting a repeating event asks how far', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootAt(
        tester,
        'events_detail_phone_delete_scope',
        state: state,
        location: detail(soccer),
        act: () async {
          await tester.scrollUntilVisible(find.text('Delete event'), 200);
          await tester.tap(find.text('Delete event'));
        },
      );
    });

    testWidgets('phone: an event that no longer exists', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'events_detail_phone_missing', state: state, location: '/event/GONE00000000000');
    });
  });

  group('Event editor', () {
    testWidgets('phone: new, from a tapped slot', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_editor_phone_new',
        state: state,
        location: '/event/new?date=${state.today}&time=15:30',
        size: tallPhone,
      );
    });

    testWidgets('phone: editing a repeating event', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootAt(tester, 'events_editor_phone_edit', state: state, location: edit(soccer), size: tallPhone);
    });

    testWidgets('phone: editing a repeating event, night', (tester) async {
      final state = await demo(tester);
      final soccer = findEvent(state, 'Soccer');
      await shootAt(tester, 'events_editor_phone_edit_night', state: state, location: edit(soccer), size: tallPhone, night: true);
    });

    testWidgets('phone: monthly on the third Friday', (tester) async {
      final state = await demo(tester);
      final f = state.formats;
      await write(
        tester,
        () => state.den.addEvent(
          title: 'Book club',
          start: f.startOf(state.today) + 19 * 3600000,
          end: f.startOf(state.today) + 21 * 3600000,
          rrule: 'FREQ=MONTHLY;BYDAY=3FR;COUNT=6',
          assignees: [state.den.members.firstWhere((m) => m.name == 'Priya').id],
        ),
      );
      final club = findEvent(state, 'Book club');
      await shootAt(tester, 'events_editor_phone_monthly', state: state, location: edit(club), size: tallPhone);
    });

    testWidgets('phone: a repeat rule from another app stays as it is', (tester) async {
      final state = await demo(tester);
      final f = state.formats;
      await write(
        tester,
        () => state.den.addEvent(
          title: 'Piano lesson',
          start: f.startOf(state.today) + 16 * 3600000,
          end: f.startOf(state.today) + 17 * 3600000,
          rrule: 'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
        ),
      );
      final piano = findEvent(state, 'Piano');
      await shootAt(tester, 'events_editor_phone_custom', state: state, location: edit(piano), size: tallPhone);
    });

    testWidgets('phone: saving without a title', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_editor_phone_errors',
        state: state,
        location: '/event/new?date=${state.today}&time=15:30',
        act: () => tester.tap(find.text('Add event')),
      );
    });

    testWidgets('tablet: a side panel over the day', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'events_editor_tablet_panel',
        state: state,
        base: '/calendar/day/${state.today}',
        location: '/event/new?date=${state.today}&time=09:00',
        size: tablet,
      );
    });
  });

  testWidgets('Repeating changes ask how far they reach', (tester) async {
    final state = await demo(tester);
    final soccer = findEvent(state, 'Soccer');
    await shootAt(
      tester,
      'events_editor_phone_scope',
      state: state,
      location: edit(soccer),
      act: () async {
        await tester.enterText(find.byType(TextField).first, 'Soccer practice (indoor)');
        await tester.pump();
        await tester.tap(find.text('Save changes'));
      },
    );
  });
}
