import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/widgets.dart';
import 'package:den_app/features/calendar/widgets/family_week.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart' show shootAt, tallPhone;

/// An iPad held upright: the sidebar and one column.
const Size portrait = Size(834, 1194);

/// The demo family at 6 PM, when Today looks ahead to tomorrow too.
Future<AppState> evening(WidgetTester tester) async =>
    (await tester.runAsync(() async => AppState(await createDemoFamily(now: DateTime.utc(2026, 10, 16, 23)))))!;

/// Taps on the real clock, so the engine can sign what the tap writes, then lets Today catch up.
Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

/// The row in Needs you that asks [title].
Finder needRow(String title) => find.ancestor(of: findWords(title), matching: find.byType(ActionRow));

void main() {
  group('Today', () {
    testWidgets('phone', (tester) async {
      final state = await demoIn(tester);
      await shootAt(tester, 'today_phone', state: state, location: '/today');
    });

    testWidgets('phone, night', (tester) async {
      final state = await demoIn(tester);
      await shootAt(tester, 'today_phone_night', state: state, location: '/today', night: true);
    });

    testWidgets('the whole page on a phone', (tester) async {
      final state = await demoIn(tester);
      await shootAt(tester, 'today_phone_full', state: state, location: '/today', size: tallPhone);
    });

    testWidgets('at 200 % text everything wraps and nothing is cut off', (tester) async {
      final state = await demoIn(tester);
      // shootAt sets the text size itself (its MediaQuery is over the system's).
      await shootAt(tester, 'today_phone_200', state: state, location: '/today', size: const Size(390, 2700), text: 2);
    });

    testWidgets('iPad, landscape: the sidebar and two columns', (tester) async {
      final state = await demoIn(tester);
      await shootAt(tester, 'today_tablet', state: state, location: '/today', size: tablet);
    });

    testWidgets('iPad, landscape, night', (tester) async {
      final state = await demoIn(tester);
      await shootAt(tester, 'today_tablet_night', state: state, location: '/today', size: tablet, night: true);
    });

    testWidgets('iPad, portrait: the sidebar and one column', (tester) async {
      final state = await demoIn(tester);
      await shootAt(tester, 'today_tablet_portrait', state: state, location: '/today', size: portrait);
    });

    testWidgets('from 5 PM it looks ahead to tomorrow', (tester) async {
      final state = await evening(tester);
      await shootAt(tester, 'today_evening_phone', state: state, location: '/today', size: tallPhone);
      expect(find.text('Good evening'), findsOneWidget);
      expect(find.text('Tomorrow'), findsOneWidget);
    });

    testWidgets('a new family: only the recovery words need anyone, and each empty part says how to start', (tester) async {
      final state = (await tester.runAsync(() async {
        final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
        await den.createFamily(
          familyName: 'The Testers',
          timezone: 'America/Chicago',
          yourName: 'Sam',
          deviceName: 'Sam\'s iPhone',
          deviceKind: DeviceKind.phone,
        );
        return AppState(den);
      }))!;
      await shootAt(tester, 'today_empty_phone', state: state, location: '/today');
      // Sam skipped the words, and has the family's only parent device.
      expect(find.text('Needs you'), findsOneWidget);
      expect(findWords('Save your recovery words'), findsOneWidget);
      expect(find.text('Add event'), findsOneWidget);
      expect(find.text('Add chore'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
    });

    testWidgets('a chore opens in place: its steps, Give to… for today, and Undo', (tester) async {
      final state = await demoIn(tester);
      await shootAt(
        tester,
        'today_chore_open_phone',
        state: state,
        location: '/today',
        size: tallPhone,
        act: () async {
          await tester.tap(find.text('Clean the kitchen'));
          await tester.pumpAndSettle();
          expect(find.text('Give to…'), findsOneWidget);
          expect(find.text('Details'), findsOneWidget);
        },
      );
      ChoreDay kitchen() => state.den.today().chores.firstWhere((d) => d.chore.title == 'Clean the kitchen');
      final owner = kitchen().owner;
      await tester.tap(find.text('Give to…'));
      await tester.pumpAndSettle();
      final zoe = state.den.members.firstWhere((m) => m.name == 'Zoe');
      await tapAndWait(tester, find.text('Zoe').last);
      expect(kitchen().owner, zoe.id);
      expect(findWords('Clean the kitchen is Zoe\'s today'), findsOneWidget);
      await tapAndWait(tester, find.text('Undo'));
      expect(kitchen().owner, owner);
    });

    testWidgets('I\'ll drive becomes what it did, in place, and Undo takes it back', (tester) async {
      final state = await demoIn(tester);
      await shootAt(
        tester,
        'today_needs_you_done_phone',
        state: state,
        location: '/today',
        size: tallPhone,
        act: () async {
          final row = needRow('Nobody is driving Zoe');
          expect(row, findsOneWidget);
          await tapAndWait(tester, find.descendant(of: row, matching: find.text('I\'ll drive')));
        },
      );
      final me = state.me!.id;
      Occurrence swim() => state.den.today().events.firstWhere((o) => o.title == 'Swim lesson');
      expect(swim().rides.first.driver, me);
      expect(find.textContaining('You\'re driving Zoe'), findsOneWidget);
      await tapAndWait(tester, find.text('Undo').first);
      expect(swim().rides.first.driver, isNull);
      expect(needRow('Nobody is driving Zoe'), findsOneWidget);
    });
  });

  testWidgets('Family week on the wall', (tester) async {
    final state = await demoIn(tester, wall: true);
    await shoot(
      tester,
      'family_week_wall',
      FamilyWeek(startDate: state.den.todayDate(), fillHeight: true),
      state: state,
      size: wall,
    );
  });
}
