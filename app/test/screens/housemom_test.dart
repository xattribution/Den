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
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The housemom pass (docs/design/HOUSEMOM_PASS.md): a busy parent's top jobs on an iPhone, tap
/// by tap, in the whole app at 390 by 844. Each test counts the taps of the shortest path, so a
/// change that adds one fails here.

/// The demo family on Alex's phone, with Grandma Rosa's iPad asking to join, after [setup].
Future<AppState> _family(WidgetTester tester, {bool deviceWaiting = false}) => real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      if (deviceWaiting) {
        final rosa = phone.members.firstWhere((m) => m.name == 'Grandma Rosa');
        final ipad = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
        await ipad.requestJoin(
          familyId: phone.familyId!,
          founderPubkey: phone.founderPubkey!,
          deviceName: "Rosa's iPad",
          kind: DeviceKind.tablet,
          memberId: rosa.id,
        );
        await phone.ingest(ipad.changesSince(phone.versionVector));
      }
      return AppState(phone);
    });

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

    testWidgets('add milk: 3 taps from anywhere, through Add', (tester) async {
      final state = await _family(tester);
      await _app(tester, state);
      final taps = _Taps(tester);
      await taps.on(find.byTooltip('Add'));
      await taps.on(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'milk');
      // Den reads the words once typing pauses.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await taps.on(find.text('Add to Groceries'));
      expect(state.den.lists.expand((l) => l.items).where((i) => i.text.toLowerCase() == 'milk' && !i.checked), hasLength(2),
          reason: 'the gallon already there, and this one');
      expect(taps.count, 3);
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

    testWidgets('Needs you, with a device asking to join, at night', (tester) async {
      final state = await _family(tester, deviceWaiting: true);
      await _app(tester, state, night: true);
      await matchShot('housemom/today_needs_device_phone_night');
    });
  });
}
