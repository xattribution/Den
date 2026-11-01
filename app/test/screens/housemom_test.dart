import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/router.dart';
import 'package:den_app/app/shell.dart' show PersonButton;
import 'package:den_app/design/motion.dart' show DenPressable;
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/widgets.dart';
import 'package:den_app/features/chores/widgets/chore_row.dart';
import 'package:den_app/features/family/family.dart' show InviteSheet;
import 'package:den_app/features/settings/screens/appearance_screen.dart';
import 'package:den_app/features/settings/screens/family_settings_screen.dart';
import 'package:den_app/features/settings/screens/settings_screen.dart';
import 'package:den_app/features/assistant/state/ask_access.dart' show askSetUpLineShows, askSetUpSeenKey, askSetUpWeeks;
import 'package:den_app/features/assistant/words/assistant_words.dart' show askSetUpLabel;
import 'package:den_app/features/today/state/needs_you.dart';
import 'package:den_app/features/today/widgets/needs_you_card.dart' show NeedsYouSection;
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_core/time.dart' show addDays;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The housemom pass (docs/design/HOUSEMOM_PASS.md): a busy parent's top jobs on an iPhone, tap
/// by tap, in the whole app at 390 by 844. Each test counts the taps of the shortest path, so a
/// change that adds one fails here.

/// The demo family on Alex's phone: with [deviceWaiting], Grandma Rosa's iPad asking to join
/// (and [moreDevices] more, each asking for nobody yet); with [alexLate], a chore of Alex's own
/// not done two days ago.
Future<AppState> _family(WidgetTester tester, {bool deviceWaiting = false, int moreDevices = 0, bool alexLate = false}) =>
    real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      Future<void> ask(String name, {String? member}) async {
        final device = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
        await device.requestJoin(
          familyId: phone.familyId!,
          founderPubkey: phone.founderPubkey!,
          deviceName: name,
          kind: DeviceKind.tablet,
          memberId: member,
        );
        await phone.ingest(device.changesSince(phone.versionVector));
      }

      if (deviceWaiting) await ask("Rosa's iPad", member: phone.members.firstWhere((m) => m.name == 'Grandma Rosa').id);
      for (var i = 0; i < moreDevices; i++) {
        await ask(['Hall tablet', 'Garage iPad', 'Den laptop'][i]);
      }
      if (alexLate) {
        final alex = phone.members.firstWhere((m) => m.name == 'Alex');
        await phone.addChore(
          title: 'Renew the car tags',
          owner: OwnerMember(alex.id),
          schedule: ChoreSchedule.once(addDays(phone.todayDate(), -2)),
        );
      }
      return AppState(phone);
    });

/// The row in Needs you that asks [title].
Finder _needRow(String title) => find.ancestor(of: findWords(title), matching: find.byType(ActionRow));

/// Swipes [finder] sideways by [dx] on the real clock, so the engine can sign what it writes.
Future<void> _swipe(WidgetTester tester, Finder finder, double dx) async {
  await tester.runAsync(() async {
    await tester.drag(finder, Offset(dx, 0));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

/// Lets Undo's few seconds pass ([NeedsYouSection.undoWindow], short in these tests) and
/// whatever waited on them be written.
Future<void> _undoPasses(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(NeedsYouSection.undoWindow + const Duration(milliseconds: 600)));
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

/// The whole app, Today first, at iPhone size.
Future<GoRouter> _app(WidgetTester tester, AppState state, {bool night = false, Size size = phone}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(state);
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: denTheme(night ? DenColors.night : DenColors.day),
        builder: (context, child) => TextSizeFromState(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// Counts each tap a path takes, on the real clock so the engine can sign what it writes.
class _Taps {
  _Taps(this.tester);
  final WidgetTester tester;
  int count = 0;

  Future<void> on(Finder finder) async {
    expect(finder, findsOneWidget, reason: 'tap ${count + 1}');
    count++;
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }
}

void main() {
  group('her shortest paths, from Today', () {
    testWidgets("I'll drive and Approve: one tap each, done in place with Undo", (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.text("I'll drive"));
      expect(find.textContaining("You're driving Zoe"), findsOneWidget);
      await taps.on(find.text('Approve'));
      expect(find.textContaining('approved'), findsOneWidget);
      expect(find.text('Undo'), findsNWidgets(2));
      expect(taps.count, 2);
    });

    testWidgets('a device asking to join comes right after the rides, before rewards and late chores', (tester) async {
      final state = await _family(tester, deviceWaiting: true);
      await _app(tester, state);
      final rows = tester.widgetList<ActionRow>(find.byType(ActionRow)).map((r) => r.title).toList();
      expect(rows.first, 'Nobody is driving Zoe');
      expect(rows[1], "Rosa's iPad wants to join as Grandma Rosa");
      expect(rows.indexOf('Maya wants \$5'), greaterThan(1));
    });

    testWidgets('invite her husband or grandma: 2 taps to the invite', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.byType(PersonButton));
      expect(find.text('Search'), findsNothing, reason: 'Search sits beside the face already');
      await taps.on(find.text('Invite someone'));
      expect(find.byType(InviteSheet), findsOneWidget);
      expect(taps.count, 2);
    });

    testWidgets('set up the kitchen screen: 3 taps to its invite, no Advanced', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.byType(PersonButton));
      await taps.on(find.text('Settings'));
      await taps.on(find.text('Kitchen screen'));
      expect(find.text('Invite a screen'), findsOneWidget);
      expect(taps.count, 3);
    });

    testWidgets('larger text: 4 taps, nothing to scroll past', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.byType(PersonButton));
      await taps.on(find.text('Settings'));
      expect(tester.getBottomLeft(find.text('Text size')).dy, lessThan(phone.height - 80), reason: 'on the first screen of Settings');
      await taps.on(find.text('Text size'));
      await taps.on(find.text('Larger'));
      expect(state.textSize, TextSize.larger);
      expect(taps.count, 4);
    });

    testWidgets('Night: 4 taps, with the preview where the choice is', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.byType(PersonButton));
      await taps.on(find.text('Settings'));
      await taps.on(find.text('Appearance'));
      await taps.on(find.text('Night'));
      expect(state.theme, ThemeChoice.night);
      expect(taps.count, 4);
    });

    testWidgets("Settings fits one iPhone screen: About's facts and the calendar's look are a tap away", (tester) async {
      final state = await _family(tester);
      final router = await _app(tester, state);
      router.push('/settings');
      await tester.pumpAndSettle();
      expect(find.text('Build'), findsNothing);
      expect(find.text('Show days as'), findsNothing);
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).last);
      expect(scroll.position.maxScrollExtent, lessThan(200), reason: 'at most a short nudge to the end');
    });

    testWidgets('check off a chore on the Chores tab: 2 taps, and the rows are only rings and names', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.descendant(of: find.byType(DenTabBar), matching: find.text('Chores')));
      expect(find.text('Give to…'), findsNothing);
      Finder row(String title) => find.byWidgetPredicate((w) => w is ChoreRow && w.day.chore.title == title && !w.day.done).first;
      final before = tester.widgetList<ChoreRow>(find.byType(ChoreRow)).where((r) => r.day.done).length;
      await taps.on(find.descendant(of: row('Make bed'), matching: find.byType(DenPressable)).first);
      expect(tester.widgetList<ChoreRow>(find.byType(ChoreRow)).where((r) => r.day.done).length, before + 1);
      expect(taps.count, 2);
      // Give to… is in the opened row, a tap on the words away.
      await tester.tap(find.descendant(of: row('Dishes'), matching: find.byType(DenPressable)).at(1));
      await tester.pumpAndSettle();
      expect(find.text('Give to…'), findsOneWidget);
    });

    testWidgets('add milk: 2 taps from anywhere, through Add, the keyboard already up', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.byTooltip('Add'));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue, reason: 'the field takes the focus as the sheet opens');
      expect(tester.testTextInput.isVisible, isTrue, reason: 'and the keyboard comes up with it');
      await tester.enterText(find.byType(TextField), 'milk');
      // Den reads the words once typing pauses.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await taps.on(find.text('Add to Groceries'));
      expect(state.den.lists.expand((l) => l.items).where((i) => i.text.toLowerCase() == 'milk' && !i.checked), hasLength(2),
          reason: 'the gallon already there, and this one');
      expect(taps.count, 2);
    });
  });

  group('round 2: Needs you', () {
    setUp(() => NeedsYouSection.undoWindow = const Duration(seconds: 2));
    tearDown(() => NeedsYouSection.undoWindow = const Duration(seconds: 5));

    testWidgets('shows three, then "2 more", which opens the rest in place, in the same order', (tester) async {
      final state = await _family(tester, deviceWaiting: true, moreDevices: 2);
      await _app(tester, state, size: const Size(390, 2400));
      expect(find.text('5 things'), findsOneWidget, reason: 'the count is of everything waiting');
      // What she can see and tap, top to bottom (a tall screen, so nothing is below the fold).
      List<String> shown() => [
            for (final e in find.byType(ActionRow).hitTestable().evaluate()) (e.widget as ActionRow).title,
          ];
      var rows = shown();
      expect(rows, hasLength(3));
      expect(rows.first, 'Nobody is driving Zoe');
      expect(rows.skip(1), everyElement(contains('wants to join')), reason: 'devices waiting come next');
      expect(rows, isNot(contains('Maya wants \$5')));
      final taps = _Taps(tester);
      await taps.on(find.text('2 more').hitTestable());
      expect(taps.count, 1);
      rows = shown();
      expect(rows, hasLength(5));
      expect(rows.first, 'Nobody is driving Zoe');
      expect(rows.last, 'Maya wants \$5', reason: 'the urgency order kept: rides, devices, then rewards');
      expect(find.text('2 more').hitTestable(), findsNothing);
    });

    testWidgets("a kid's late chore never shows in her Needs you; a grown-up's own still does", (tester) async {
      final state = await _family(tester, alexLate: true);
      await _app(tester, state, size: const Size(390, 2000));
      expect(state.den.lateChores(days: 1).map((d) => d.chore.title), contains('Return library books'), reason: "Leo's is late");
      expect(_needRow('Return library books'), findsNothing);
      expect(needsYou(state, now: state.den.now()).whereType<LateNeed>().map((n) => n.day.chore.title), ['Renew the car tags']);
      expect(_needRow('Renew the car tags'), findsOneWidget);
      // The Chores tab still shows Leo's late.
      await tester.tap(find.descendant(of: find.byType(DenTabBar), matching: find.text('Chores')));
      await tester.pumpAndSettle();
      expect(findWords('Return library books'), findsWidgets);
    });

    testWidgets('swipe right approves a reward, as the Approve button does, with Undo', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      expect(state.den.points().pending, hasLength(1));
      await _swipe(tester, findWords('Maya wants \$5'), 260);
      expect(state.den.points().pending, isEmpty);
      expect(findWords('\$5 approved for Maya'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Undo'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(state.den.points().pending, hasLength(1), reason: 'Undo takes the approval back');
    });

    testWidgets('swipe left declines a reward only once Undo has passed; Undo before that sends nothing', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final request = state.den.points().pending.single;
      final before = state.den.points().totals[request.member];
      await _swipe(tester, findWords('Maya wants \$5'), -260);
      expect(findWords('\$5 declined for Maya'), findsOneWidget);
      expect(state.den.points().pending, hasLength(1), reason: 'nothing sent while Undo shows');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(_needRow('Maya wants \$5'), findsOneWidget);
      await _undoPasses(tester);
      expect(state.den.points().pending, hasLength(1), reason: 'Undo meant no');

      // The × says the same, and once Undo has gone the no is sent and the row folds away.
      await _Taps(tester).on(find.descendant(of: _needRow('Maya wants \$5'), matching: find.bySemanticsLabel('Decline')));
      expect(state.den.points().pending, hasLength(1));
      await _undoPasses(tester);
      expect(state.den.points().pending, isEmpty);
      expect(state.den.points().totals[request.member], before, reason: 'declined, not spent');
      expect(findWords('Maya wants \$5').hitTestable(), findsNothing);
    });

    testWidgets("a device asking to join: swipe right lets it in from her own phone, swipe left turns it away after Undo", (tester) async {
      final state = await _family(tester, deviceWaiting: true, moreDevices: 1);
      await _app(tester, state);
      Device device(String name) => state.den.devices.firstWhere((d) => d.name == name);
      await _swipe(tester, findWords("Rosa's iPad wants to join as Grandma Rosa"), 260);
      expect(device("Rosa's iPad").approved, isTrue);
      expect(findWords("Rosa's iPad joined as Grandma Rosa"), findsOneWidget);

      await _swipe(tester, findWords('Hall tablet wants to join'), -260);
      expect(findWords('Hall tablet was turned away'), findsOneWidget);
      expect(device('Hall tablet').revoked, isFalse, reason: 'turning away waits out Undo');
      await _undoPasses(tester);
      expect(device('Hall tablet').revoked, isTrue);
    });

    testWidgets('a ride has no no: the × puts it off until an hour before it leaves, and Undo brings it back', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final ride = _needRow('Nobody is driving Zoe');
      final need = needsYou(state, now: state.den.now()).whereType<RideNeed>().single;
      final key = need.key;
      const hour = 3600000;
      expect(notNowUntil(state, need), need.leaves - hour, reason: 'never until tomorrow: a kid could be left without a ride');
      await _Taps(tester).on(find.descendant(of: ride, matching: find.bySemanticsLabel('Not now')));
      expect(findWords('Back at 3:30 PM if nobody is driving'), findsOneWidget, reason: 'the swim lesson leaves at 4:30 PM');
      expect(needsYou(state, now: state.den.now()).whereType<RideNeed>(), isEmpty);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(needsYou(state, now: state.den.now()).whereType<RideNeed>(), hasLength(1));
      expect(_needRow('Nobody is driving Zoe'), findsOneWidget);
      // Put off again, it stays away until an hour before the ride leaves, then comes back if
      // nobody has taken it.
      await _swipe(tester, findWords('Nobody is driving Zoe'), -260);
      await _undoPasses(tester);
      expect(findWords('Nobody is driving Zoe').hitTestable(), findsNothing);
      expect(state.snoozedUntil(key), need.leaves - hour);
      expect(putOff(state, need, now: need.leaves - hour - 1), isTrue);
      expect(needsYou(state, now: need.leaves - hour - 60000).whereType<RideNeed>(), isEmpty);
      expect(needsYou(state, now: need.leaves - hour).whereType<RideNeed>().map((n) => n.key), [key],
          reason: 'back an hour before it leaves');
      // Within the hour it can't be put off at all: it would be back at once.
      expect(canPutOff(state, need, now: need.leaves - hour + 60000), isFalse);
      expect(canPutOff(state, need, now: need.leaves - 2 * hour), isTrue);
    });

    testWidgets('a ride leaving within the hour has no × and no swipe', (tester) async {
      final state = await _family(tester);
      final need = needsYou(state, now: state.den.now()).whereType<RideNeed>().single;
      // Today at 4:00 PM, half an hour before the swim lesson.
      final soon = (await real(tester, () async => AppState(await createDemoFamily(now: DateTime.fromMillisecondsSinceEpoch(need.leaves - 1800000, isUtc: true)))));
      await _app(tester, soon);
      final ride = _needRow('Nobody is driving Zoe');
      expect(ride, findsOneWidget);
      expect(find.descendant(of: ride, matching: find.bySemanticsLabel('Not now')), findsNothing);
      expect(tester.widget<ActionRow>(ride).onDecline, isNull);
    });
  });

  group('round 2: the AI helper line', () {
    testWidgets('Not now puts it away for her on this phone', (tester) async {
      final state = await _family(tester);
      await _app(tester, state, size: const Size(390, 2000));
      expect(find.text(askSetUpLabel), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text(askSetUpLabel), findsNothing);
      expect(state.seen(askSetUpSeenKey(state.me!.id)), isTrue);
    });

    testWidgets("only in the family's first three weeks", (tester) async {
      final state = await _family(tester);
      final made = state.den.family!.rec.created.millis;
      const day = 86400000;
      expect(askSetUpLineShows(state, linked: false, now: made + day), isTrue);
      expect(askSetUpLineShows(state, linked: false, now: made + 20 * day), isTrue);
      expect(askSetUpLineShows(state, linked: false, now: made + askSetUpWeeks.inMilliseconds), isFalse);
      expect(askSetUpLineShows(state, linked: false, now: made + 30 * day), isFalse);
    });
  });

  group('shots', () {
    testWidgets("the person's menu", (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      await tester.tap(find.byType(PersonButton));
      await tester.pumpAndSettle();
      await matchShot('housemom/person_menu_phone');
    });

    for (final night in [false, true]) {
      final suffix = night ? '_night' : '';
      testWidgets('Settings, Appearance${night ? ', at night' : ''}', (tester) async {
        final state = await _family(tester);
        await shootWith(tester, 'housemom/settings_appearance_phone$suffix', const AppearanceScreen(),
            state: state, night: night, size: const Size(390, 1200), pushed: true);
      });

      testWidgets('Settings, Family colors${night ? ', at night' : ''}', (tester) async {
        final state = await _family(tester);
        await shootWith(tester, 'housemom/settings_family_colors_phone$suffix', const FamilyColorsScreen(),
            state: state, night: night, pushed: true);
      });

      testWidgets('Settings, at iPhone size${night ? ', at night' : ''}', (tester) async {
        final state = await _family(tester);
        await shootWith(tester, 'housemom/settings_phone$suffix', const SettingsScreen(version: '1.0.0'),
            state: state, night: night, pushed: true);
      });
    }

    testWidgets('Settings, Text size', (tester) async {
      final state = await _family(tester);
      await pumpScreen(tester, const SettingsScreen(version: '1.0.0'), state: state, pushed: true);
      await tester.tap(find.text('Text size'));
      await tester.pumpAndSettle();
      await matchShot('housemom/settings_text_size_sheet_phone');
    });

    testWidgets('Needs you, with a device asking to join', (tester) async {
      final state = await _family(tester, deviceWaiting: true);
      await _app(tester, state);
      await matchShot('housemom/today_needs_device_phone');
    });

    testWidgets('round 2: Needs you with five waiting, three and "2 more"', (tester) async {
      final state = await _family(tester, deviceWaiting: true, moreDevices: 2);
      await _app(tester, state);
      await matchShot('housemom/today_needs_more_phone');
    });

    testWidgets('round 2: a reward swiped halfway right, Approve behind it', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final gesture = await tester.startGesture(tester.getCenter(findWords('Maya wants \$5')));
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(130, 0));
      await tester.pump();
      await matchShot('housemom/today_needs_swiping_phone');
      await gesture.cancel();
      await tester.pumpAndSettle();
    });

    testWidgets('round 2: a reward declined, with Undo for a few seconds', (tester) async {
      NeedsYouSection.undoWindow = const Duration(minutes: 1);
      addTearDown(() => NeedsYouSection.undoWindow = const Duration(seconds: 5));
      final state = await _family(tester);
      await _app(tester, state);
      await tester.tap(find.descendant(of: _needRow('Maya wants \$5'), matching: find.bySemanticsLabel('Decline')));
      await tester.pumpAndSettle();
      await matchShot('housemom/today_needs_declined_phone');
      // Undo, so nothing waits to be sent when the test ends.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
    });

    testWidgets('round 2: Add opens with the keyboard up', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await matchShot('housemom/add_open_phone');
    });

    testWidgets('Needs you, with a device asking to join, at night', (tester) async {
      final state = await _family(tester, deviceWaiting: true);
      await _app(tester, state, night: true);
      await matchShot('housemom/today_needs_device_phone_night');
    });
  });
}
