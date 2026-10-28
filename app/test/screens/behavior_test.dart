import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/widgets.dart';
import 'package:den_app/features/chores/screens/chores_board.dart';
import 'package:den_app/features/calendar/screens/event_detail.dart';
import 'package:den_app/features/family/screens/device_screen.dart';
import 'package:den_app/features/family/screens/family_screen.dart';
import 'package:den_app/features/family/screens/member_editor.dart';
import 'package:den_app/features/lists/screens/list_detail.dart';
import 'package:den_app/features/lists/words/list_words.dart';
import 'package:den_app/features/rewards/screens/points_screen.dart';
import 'package:den_app/features/today/screens/today_screen.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// What the screens do, checked without screenshots: each test here failed before the fix it
/// names.

const Size _tall = Size(390, 2400);
const int _hour = 3600000;

/// The demo family on Alex's phone, after [setup] runs on the real clock.
Future<AppState> _family(WidgetTester tester, [Future<void> Function(Den den)? setup]) => real(tester, () async {
      final state = await demoState();
      await setup?.call(state.den);
      return state;
    });

/// The demo family on a kid's own phone: [setup] runs on Alex's phone first (to change the kid's
/// permissions, say), then the phone joins as [name] and takes what it may hold.
Future<AppState> _kidPhone(WidgetTester tester, String name, [Future<void> Function(Den parent, String kid)? setup]) =>
    real(tester, () async {
      final parent = await createDemoFamily(now: demoNow);
      final kid = parent.members.firstWhere((m) => m.name == name).id;
      await setup?.call(parent, kid);
      final phone = await Den.open(
        storage: MemoryStorage(),
        keys: await DeviceKeys.generate(),
        now: () => demoNow.millisecondsSinceEpoch,
      );
      await phone.requestJoin(
        familyId: parent.familyId!,
        founderPubkey: parent.founderPubkey!,
        deviceName: '$name\'s phone',
        kind: DeviceKind.phone,
        memberId: kid,
      );
      await parent.ingest(phone.changesSince(parent.versionVector));
      await parent.approveDevice(phone.deviceId, member: kid);
      await phone.ingest(
        parent.changesSince(phone.versionVector, spaces: parent.spacesForDevice(phone.deviceId)),
        through: parent.completeVector,
      );
      return AppState(phone);
    });

/// The whole app at [location].
Future<GoRouter> _app(WidgetTester tester, AppState state, String location) async {
  tester.view.physicalSize = _tall;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(state);
  await tester.pumpWidget(
    DenScope(state: state, child: MaterialApp.router(routerConfig: router, theme: denTheme(DenColors.day))),
  );
  await tester.pumpAndSettle();
  router.go(location);
  await tester.pumpAndSettle();
  return router;
}

/// Taps on the real clock, so the engine can sign what the tap writes, then lets the screen catch
/// up, and gives anything that continues after it (a sheet or dialog closing first) time too.
Future<void> _tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
  await _settle(tester);
}

/// Lets engine work started on the test's clock finish on the real one, then the screen catch up.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
  await tester.pumpAndSettle();
}

String _id(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;

void main() {
  group('Today', () {
    testWidgets('Take it takes the leg nobody is driving, for that day (B2)', (tester) async {
      late int start;
      final state = await _family(tester, (den) async {
        start = den.dayStart(den.todayDate()) + 18 * _hour;
        final piano = await den.addEvent(
          title: 'Piano',
          start: start,
          end: start + _hour,
          rrule: 'FREQ=WEEKLY',
          assignees: [_id(den, 'Leo')],
          rides: const [Ride('to', null), Ride('from', null)],
        );
        await den.claimRide(piano, occurrence: start, leg: 'to', driver: _id(den, 'Priya'));
      });
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall);
      final line = find.widgetWithText(AttentionLine, 'Nobody is picking up Leo from Piano');
      expect(line, findsOneWidget);
      await _tapAndWait(tester, find.descendant(of: line, matching: find.text('Take it')));
      final rides = state.den.occurrences(start, start + _hour).firstWhere((o) => o.title == 'Piano').rides;
      expect({for (final r in rides) r.leg: r.driver}, {'to': _id(state.den, 'Priya'), 'from': _id(state.den, 'Alex')});
      expect(state.den.events.firstWhere((e) => e.title == 'Piano').rides.every((r) => r.driver == null), isTrue,
          reason: 'only this day changes');
    });

    testWidgets('ride actions show only to people the engine lets set a driver (B3)', (tester) async {
      final noGrant = await _kidPhone(tester, 'Maya', (parent, maya) => parent.updateMember(maya, {
            'grants': [Grant.lists],
          }));
      await pumpScreen(tester, const TodayScreen(), state: noGrant, size: _tall);
      expect(find.text('Nobody is driving Zoe to Swim lesson'), findsOneWidget);
      expect(find.text('Take it'), findsNothing);
      final swim = noGrant.den.today().events.firstWhere((o) => o.title == 'Swim lesson');
      await pumpScreen(tester, EventDetailScreen(eventId: swim.event.id, at: swim.start), state: noGrant, size: _tall);
      expect(find.text('Nobody is driving'), findsOneWidget);
      expect(find.text('Take it'), findsNothing);

      final withGrant = await _kidPhone(tester, 'Maya');
      await pumpScreen(tester, const TodayScreen(), state: withGrant, size: _tall);
      expect(find.text('Take it'), findsOneWidget, reason: 'a teen with the events grant may drive');
    });

    testWidgets('two of one person\'s events at once warn once; an event for everyone doesn\'t (B13)', (tester) async {
      final state = await _family(tester, (den) async {
        final six = den.dayStart(den.todayDate()) + 18 * _hour;
        final leo = _id(den, 'Leo');
        await den.addEvent(title: 'Piano', start: six, end: six + _hour, assignees: [leo]);
        await den.addEvent(title: 'Art', start: six + _hour ~/ 2, end: six + 3 * _hour ~/ 2, assignees: [leo]);
        await den.addEvent(title: 'Family dinner', start: six, end: six + _hour);
      });
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall);
      expect(find.textContaining('at the same time'), findsOneWidget);
      expect(find.text('Leo has Piano and Art at the same time'), findsOneWidget);
    });

    testWidgets('with points off, chores show no stars and Add offers no Points (B12)', (tester) async {
      final state = await _family(tester, (den) => den.updateFamily({'pointsEnabled': false}));
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall);
      expect(find.text('Make bed'), findsWidgets);
      expect(find.byType(StarCount), findsNothing);
      await _app(tester, state, '/today');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Event'), findsOneWidget);
      expect(find.text('Points'), findsNothing);
    });
  });

  group('Lists', () {
    testWidgets('a kid without the lists grant is offered no way to add or change items (B4)', (tester) async {
      final state = await _kidPhone(tester, 'Maya', (parent, maya) => parent.updateMember(maya, {
            'grants': [Grant.events],
          }));
      await pumpScreen(tester, ListDetailScreen(id: groceriesList(state.den)!.list.id), state: state, size: _tall);
      expect(find.text('Toothpaste'), findsOneWidget);
      expect(find.byType(AddItemRow), findsNothing);
      expect(find.byType(Dismissible), findsNothing);
      await _app(tester, state, '/today');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Event'), findsOneWidget);
      expect(find.text('Grocery item'), findsNothing);
    });

    testWidgets('Undo after clearing done items brings the same items back, in place, at once (B5)', (tester) async {
      final state = await _family(tester);
      final list = groceriesList(state.den)!.list.id;
      final before = state.den.list(list)!.items;
      final done = [for (final i in before) if (i.checked) i.id];
      expect(done, isNotEmpty);
      await pumpScreen(tester, ListDetailScreen(id: list), state: state, size: _tall);
      await _tapAndWait(tester, find.textContaining('done item'));
      expect(state.den.list(list)!.items.where((i) => i.checked), isEmpty);
      final changes = state.den.history(limit: 1 << 20).length;
      await _tapAndWait(tester, find.text('Undo'));
      final after = state.den.list(list)!.items;
      expect(after.map((i) => i.id), before.map((i) => i.id));
      expect([for (final i in after) if (i.checked) i.id], done);
      expect(state.den.history(limit: 1 << 20).length - changes, done.length, reason: 'one change each');
      for (final text in [for (final i in before) if (i.checked) i.text]) {
        expect(find.textContaining(text), findsOneWidget, reason: '$text shows again');
      }
    });
  });

  group('Chores', () {
    testWidgets('Undo after deleting a chore brings back the same chore, its done days and stars (B5)', (tester) async {
      final state = await _family(tester);
      final den = state.den;
      final cat = den.chores.firstWhere((c) => c.title == 'Feed the cat').id;
      final leo = _id(den, 'Leo');
      final stars = den.points().totals[leo];
      final doneDays = den.completionsFor(cat).where((c) => c.done).map((c) => c.date).toList();
      expect(doneDays, isNotEmpty);
      await _app(tester, state, '/chore/$cat?date=${state.today}');
      await _tapAndWait(tester, find.text('Delete chore'));
      expect(den.chore(cat), isNull);
      await _tapAndWait(tester, find.text('Undo'));
      expect(den.chore(cat), isNotNull, reason: 'the same chore, not a copy');
      expect(den.chores.where((c) => c.title == 'Feed the cat'), hasLength(1));
      expect(den.completionsFor(cat).where((c) => c.done).map((c) => c.date), doneDays);
      expect(den.points().totals[leo], stars);
    });

    testWidgets('the screen reader\'s swap action names the day it swaps (B14)', (tester) async {
      final state = await _family(tester);
      final tomorrow = state.formats.addDays(state.today, 1);
      await pumpScreen(tester, ChoresBoard(date: tomorrow), state: state, size: _tall);
      final labels = [
        for (final w in tester.widgetList<Semantics>(
          find.byWidgetPredicate((w) => w is Semantics && w.properties.customSemanticsActions != null),
        ))
          ...w.properties.customSemanticsActions!.keys.map((a) => a.label),
      ];
      expect(labels, contains('Swap for ${state.formats.short(tomorrow)}'));
      expect(labels, isNot(contains('Swap for today')));
    });
  });

  group('Points', () {
    testWidgets('a request waiting for a parent counts against what a kid can still spend (B6)', (tester) async {
      final state = await _kidPhone(tester, 'Maya', (parent, maya) async {
        for (final r in parent.points().pending.where((r) => r.member == maya)) {
          await parent.decideRedemption(r.id, approve: false);
        }
        final balance = parent.points().totals[maya] ?? 0;
        if (balance != 45) await parent.adjustPoints(maya, 45 - balance, 'Getting ready');
        final five = parent.points().rewards.firstWhere((r) => r.title == '\$5');
        await parent.requestReward(five.id, member: maya);
      });
      expect(state.den.points().totals[_id(state.den, 'Maya')], 45);
      await pumpScreen(tester, const PointsScreen(), state: state, size: _tall);
      expect(find.text('Asked'), findsOneWidget);
      expect(find.text('15 more to go'), findsOneWidget, reason: 'Pick dinner costs 30, and 30 of 45 are asked for');
      expect(find.text('5 more to go'), findsOneWidget, reason: 'Later bedtime costs 20');
    });

    testWidgets('a parent turns points off and on in the family settings', (tester) async {
      final state = await _family(tester);
      await pumpScreen(tester, const FamilyScreen(), state: state, size: const Size(390, 3200));
      final toggle = find.widgetWithText(SwitchListTile, 'Points and rewards');
      expect(toggle, findsOneWidget);
      await _tapAndWait(tester, toggle);
      expect(state.den.family!.pointsEnabled, isFalse);
      await _tapAndWait(tester, toggle);
      expect(state.den.family!.pointsEnabled, isTrue);
    });
  });

  group('Family', () {
    testWidgets('a kid\'s permissions don\'t offer "Manage points"', (tester) async {
      final state = await _family(tester);
      await pumpScreen(tester, MemberEditor(memberId: _id(state.den, 'Maya')), state: state, size: _tall);
      expect(find.text('Add lists'), findsOneWidget);
      expect(find.text('Manage points'), findsNothing);
    });

    testWidgets('a role change says what it does and waits for a yes', (tester) async {
      final state = await _family(tester);
      final maya = _id(state.den, 'Maya');
      await pumpScreen(tester, MemberEditor(memberId: maya), state: state, size: _tall);
      await tester.tap(find.text('Parent'));
      await tester.pumpAndSettle();
      expect(find.text('Make Maya a parent?'), findsOneWidget);
      expect(find.textContaining('Maya will manage the family'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.den.member(maya)!.role, Role.kid);
      await tester.tap(find.text('Parent'));
      await tester.pumpAndSettle();
      await _tapAndWait(tester, find.text('Make Maya a parent'));
      expect(state.den.member(maya)!.role, Role.parent);
    });

    testWidgets('the privacy switch changes just that person\'s entry (B8)', (tester) async {
      final state = await _family(tester);
      final maya = _id(state.den, 'Maya');
      await pumpScreen(tester, MemberEditor(memberId: maya), state: state, size: const Size(390, 3200));
      await _tapAndWait(
        tester,
        find.ancestor(of: find.textContaining('private items'), matching: find.byType(SwitchListTile)),
      );
      expect(state.den.family!.parentsSeePrivate(maya), isFalse);
      expect(state.den.history().first.diffs.map((d) => d.field), ['oversight.$maya']);
    });

    testWidgets('a device\'s owner can\'t be changed, and Photos isn\'t a layout (B9)', (tester) async {
      final state = await _family(tester);
      final display = state.den.devices.firstWhere((d) => d.mode == DeviceMode.shared);
      await pumpScreen(tester, DeviceScreen(deviceId: display.id), state: state, size: _tall);
      expect(find.text('Change'), findsNothing);
      expect(find.text('Week'), findsOneWidget);
      expect(find.text('Photos'), findsNothing);
    });

    testWidgets('making a shared display asks a parent with no PIN to set one (B10)', (tester) async {
      final state = await _family(tester, (den) async {
        await den.setSignIn(den.actor!.id, kind: 'none');
        final tablet = await Den.open(
          storage: MemoryStorage(),
          keys: await DeviceKeys.generate(),
          now: () => demoNow.millisecondsSinceEpoch,
        );
        await tablet.requestJoin(
          familyId: den.familyId!,
          founderPubkey: den.founderPubkey!,
          deviceName: 'Hall tablet',
          kind: DeviceKind.tablet,
          mode: DeviceMode.shared,
        );
        await den.ingest(tablet.changesSince(den.versionVector));
      });
      await pumpScreen(tester, const FamilyScreen(), state: state, size: _tall, pairing: FakePairing(now: demoNow));
      await tester.tap(find.text('Approve Hall tablet'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Shared display')));
      await tester.pumpAndSettle();
      await _settle(tester);
      await _settle(tester);
      expect(state.den.devices.firstWhere((d) => d.name == 'Hall tablet').approved, isTrue);
      expect(find.text('Set your PIN for shared screens'), findsOneWidget);
    });

    testWidgets('leaving a page right after typing a name saves it and throws nothing (B16)', (tester) async {
      final state = await _family(tester);
      final maya = _id(state.den, 'Maya');
      final router = await _app(tester, state, '/family');
      router.push('/family/member/$maya');
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Maya Rose');
      router.pop();
      await tester.pumpAndSettle();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(state.den.member(maya)!.name, 'Maya Rose');
    });
  });

  testWidgets('month view steps by calendar month (B7)', (tester) async {
    final state = await _family(tester);
    final router = await _app(tester, state, '/calendar/month/2026-10-31');
    // The month's arrows are the iPad's; a phone swipes the month instead.
    tester.view.physicalSize = const Size(1180, 820);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Last month'));
    await tester.pumpAndSettle();
    expect(find.text('September'), findsWidgets);
    router.go('/calendar/month/2027-01-31');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(find.text('February 2027'), findsWidgets);
    expect(state.formats.addMonths('2028-03-31', -1), '2028-02-29');
    expect(state.formats.addMonths('2026-12-15', 1), '2027-01-15');
  });

  testWidgets('a write that fails for any other reason says so instead of throwing (B17)', (tester) async {
    final state = await _family(tester);
    bool? saved;
    await pumpScreen(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () async => saved = await attempt(context, () async => throw StateError('The disk is full')),
            child: const Text('Save'),
          ),
        ),
      ),
      state: state,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, isFalse);
    expect(find.text(writeFailedMessage), findsOneWidget);
    expect(await tryWrite(() async => throw StateError('The disk is full')), writeFailedMessage);
  });
}
