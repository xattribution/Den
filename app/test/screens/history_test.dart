import 'package:den_app/app/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';

/// A few of this morning's changes: one soccer practice moved half an hour, the birthday party
/// moved an hour later to a new place, a ride taken, an event added.
Future<void> morningChanges(WidgetTester tester, AppState state) async {
  final den = state.den;
  final soccer = findEvent(state, 'Soccer');
  final party = findEvent(state, 'Sophie');
  final swim = findEvent(state, 'Swim');
  await write(tester, () async {
    await den.updateEvent(
      soccer.event.id,
      {'start': soccer.start + 30 * 60000, 'end': soccer.end + 30 * 60000},
      scope: EditScope.one,
      occurrence: soccer.seriesStart,
    );
    await den.updateEvent(party.event.id, {
      'start': party.start + 3600000,
      'end': party.end + 3600000,
      'location': 'Bounce Zone, Party Room B',
    });
    await den.claimRide(swim.event.id, occurrence: swim.seriesStart, leg: 'to', driver: den.actor!.id);
    await den.addEvent(
      title: 'Parent-teacher conference',
      start: party.start + 3 * 86400000 + 3 * 3600000,
      end: party.start + 3 * 86400000 + 3 * 3600000 + 30 * 60000,
      assignees: [den.members.firstWhere((m) => m.name == 'Maya').id],
    );
  });
}

void main() {
  group('History', () {
    testWidgets('phone, after this morning’s changes', (tester) async {
      final state = await demo(tester);
      await morningChanges(tester, state);
      await shootAt(tester, 'history_phone', state: state, location: '/history', size: tallPhone);
    });

    testWidgets('phone, night', (tester) async {
      final state = await demo(tester);
      await morningChanges(tester, state);
      await shootAt(tester, 'history_phone_night', state: state, location: '/history', night: true);
    });

    testWidgets('tablet', (tester) async {
      final state = await demo(tester);
      await morningChanges(tester, state);
      await shootAt(tester, 'history_tablet', state: state, location: '/history', size: tablet);
    });

    testWidgets('phone, just Leo', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'history_phone_leo',
        state: state,
        location: '/history',
        act: () => tester.tap(find.text('Leo')),
      );
    });

    testWidgets('phone, nothing matches', (tester) async {
      final state = await demo(tester);
      await shootAt(
        tester,
        'history_phone_no_match',
        state: state,
        location: '/history',
        act: () async {
          await tester.enterText(find.byType(TextField), 'trampoline');
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
    });
  });

  group('Search', () {
    testWidgets('phone', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'history_search_phone', state: state, location: '/search?q=so');
    });

    testWidgets('phone, night', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'history_search_phone_night', state: state, location: '/search?q=beach', night: true);
    });

    testWidgets('phone, nothing matches', (tester) async {
      final state = await demo(tester);
      await shootAt(tester, 'history_search_phone_empty', state: state, location: '/search?q=trampoline');
    });
  });
}
