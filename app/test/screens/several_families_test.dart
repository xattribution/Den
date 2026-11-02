// A device in several families (FAMILY-LINKS-PLAN §4.1, §4.2): the switcher on Today and in the
// iPad sidebar, switching, pages of another family under /l/<family>, "All my families" (Today,
// Calendar, Lists), and leaving one family from its Settings. Each screen is also a screenshot,
// in light and dark, on phone and iPad.
import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/household.dart';
import 'package:den_app/app/log_scope.dart';
import 'package:den_app/app/router.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/family/family.dart' show FamiliesSheet, FamilySwitch, MembershipActions;
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/households.dart';
import '../helpers/shots.dart';

/// The Smiths, beside the demo family: Dana, Ruby and Alex (whose phone this is), with a pottery
/// class and dinner today and their groceries, on the demo family's clock.
Future<Den> smithFamily() async {
  final now = demoNow.millisecondsSinceEpoch;
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => now);
  await den.createFamily(
    familyName: 'Smith family',
    timezone: 'America/Chicago',
    yourName: 'Alex',
    marker: Marker.tangerine,
    animal: Animal.bird,
    deviceName: "Alex's phone",
    deviceKind: DeviceKind.phone,
  );
  final ruby = await den.addMember(name: 'Ruby', role: Role.kid, tier: Tier.big, marker: Marker.aqua, picture: 'fox');
  await den.addMember(name: 'Dana', role: Role.parent, marker: Marker.coral, picture: 'owl');
  const hour = 3600000;
  // 8 AM in Chicago is 13:00 UTC on the demo's Friday.
  await den.addEvent(title: 'Pottery class', start: now + 2 * hour, end: now + 3 * hour, assignees: [ruby], location: 'Clay studio');
  await den.addEvent(title: "Dinner at Grandma's", start: now + 10 * hour + hour ~/ 2, end: now + 12 * hour);
  await den.addEvent(title: 'Lake day', start: now + 26 * hour, end: now + 32 * hour);
  final groceries = await den.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
  for (final item in ['Peaches', 'Oat milk', 'Sunscreen']) {
    await den.addItem(groceries, text: item);
  }
  return den;
}

/// The demo family (first, as this device's first family) and the Smiths, sharing this device's
/// settings.
Future<Household> twoFamilies(WidgetTester tester, {bool all = false}) async {
  final (carter, smith) = (await tester.runAsync(() async => (await createDemoFamily(now: demoNow), await smithFamily())))!;
  final device = DevicePrefs();
  final home = Household([
    FamilyLog(membership: Membership(id: carter.familyId!, primary: true, color: Marker.sky.name), state: AppState(carter, device: device)),
    FamilyLog(membership: Membership(id: smith.familyId!, color: Marker.grass.name), state: AppState(smith, device: device)),
  ], active: all ? Memberships.all : null);
  return home;
}

/// The app as DenApp builds it for [home], at [location].
Future<GoRouter> pumpHome(WidgetTester tester, Household home, {Size size = phone, bool night = false, String location = '/today'}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(home.active.state, household: home);
  await tester.pumpWidget(
    HouseholdScope(
      household: home,
      child: ListenableBuilder(
        listenable: home,
        builder: (context, child) => DenScope(state: home.active.state, child: child!),
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: denTheme(night ? DenColors.night : DenColors.day),
          builder: (context, child) => TextSizeFromState(child: child!),
        ),
      ),
    ),
  );
  if (location != '/today') router.go(location);
  await tester.pumpAndSettle();
  return router;
}

/// The page's own scrolling, not a row of chips.
Finder vertical() => find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

Future<void> shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the switcher', () {
    testWidgets('one family: no switcher anywhere, as always', (tester) async {
      final state = await demoIn(tester);
      final home = Household.single(state);
      await pumpHome(tester, home);
      expect(find.byType(FamilySwitch), findsNothing);
      expect(find.text('Carter family'), findsNothing);
      await pumpHome(tester, home, size: tablet);
      expect(find.byType(FamilySwitch), findsNothing);
      expect(find.text('Carter family'), findsOneWidget, reason: "the sidebar's title, as always");
    });

    for (final night in [false, true]) {
      final dark = night ? '_dark' : '';
      testWidgets('on a phone: the family at the top of Today, and the sheet${night ? ', dark' : ''}', (tester) async {
        final home = await twoFamilies(tester);
        await pumpHome(tester, home, night: night);
        expect(find.byType(FamilySwitch), findsOneWidget);
        expect(find.text('Carter family'), findsOneWidget);
        await shot(tester, 'families_today_phone$dark');

        await tester.tap(find.byType(FamilySwitch));
        await tester.pumpAndSettle();
        expect(find.byType(FamiliesSheet), findsOneWidget);
        expect(find.text('Your families'), findsOneWidget);
        expect(find.text('Smith family'), findsOneWidget);
        expect(find.text('All my families'), findsOneWidget);
        expect(find.text('Paste an invite'), findsOneWidget);
        await shot(tester, 'families_sheet_phone$dark');
      });

      testWidgets('on iPad: the sidebar title is the switcher${night ? ', dark' : ''}', (tester) async {
        final home = await twoFamilies(tester);
        await pumpHome(tester, home, size: tablet, night: night);
        expect(find.byType(FamilySwitch), findsOneWidget);
        await shot(tester, 'families_sidebar_pad$dark');
        await tester.tap(find.byType(FamilySwitch));
        await tester.pumpAndSettle();
        await shot(tester, 'families_sheet_pad$dark');
      });
    }

    testWidgets('at 200 % text the switch and the sheet wrap rather than cut off', (tester) async {
      withTextScale(tester, 2);
      final home = await twoFamilies(tester);
      await pumpHome(tester, home);
      await shot(tester, 'families_today_phone_text200');
      await tester.tap(find.byType(FamilySwitch));
      await tester.pumpAndSettle();
      await shot(tester, 'families_sheet_phone_text200');
    });

    testWidgets("an invite's link on a device in a family opens joining another family", (tester) async {
      final home = await twoFamilies(tester);
      final router = await pumpHome(tester, home);
      router.go('/join/maple-river-canoe-tiger');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/families/join');
      expect(router.state.uri.queryParameters['code'], 'maple-river-canoe-tiger');
      expect(findWords('Join another family'), findsOneWidget);
      expect(find.text('I lost my phone'), findsNothing);
    });

    testWidgets('choosing a family shows it at once, everywhere, and the device remembers', (tester) async {
      final home = await twoFamilies(tester);
      final smith = home.logs[1];
      await pumpHome(tester, home);
      expect(find.text('Pottery class'), findsNothing);
      await tester.tap(find.byType(FamilySwitch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smith family'));
      await tester.pumpAndSettle();
      expect(identical(home.active, smith), isTrue);
      expect(find.descendant(of: find.byType(FamilySwitch), matching: find.text('Smith family')), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Pottery class'), 200, scrollable: vertical());
      expect(find.text('Pottery class'), findsOneWidget, reason: "Today is the Smiths' now");
      await tester.tap(find.text('Lists'));
      await tester.pumpAndSettle();
      expect(find.text('Peaches'), findsOneWidget);
    });

    testWidgets("a page of the family not showing opens in that family's scope, and what it opens stays there", (tester) async {
      final home = await twoFamilies(tester);
      final smith = home.logs[1];
      final pottery = smith.den.events.firstWhere((e) => e.title == 'Pottery class');
      final router = await pumpHome(tester, home);
      router.push('/l/${smith.id}/event/${pottery.id}');
      await tester.pumpAndSettle();
      expect(find.text('Pottery class'), findsWidgets);
      expect(identical(home.active, home.logs.first), isTrue, reason: 'the Carters still show behind it');
      // From inside, a page it opens is the Smiths' too.
      final inner = GoRouter.of(tester.element(find.text('Pottery class').first));
      expect(inner, isA<ScopedRouter>());
      expect(inLog(smith.id, '/lists/L1'), '/l/${smith.id}/lists/L1');
      expect(inLog(smith.id, '/today'), '/today', reason: "the app's places stay the app's");
      // A family this device doesn't hold: a page that says so, never another family's page.
      router.go('/l/nobody/settings');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/families/missing');
      // `/l/<family>/today` shows that family.
      router.go('/l/${smith.id}/today');
      await tester.pumpAndSettle();
      expect(identical(home.active, smith), isTrue);
    });
  });

  group('All my families', () {
    for (final night in [false, true]) {
      final dark = night ? '_dark' : '';
      testWidgets('Today, Calendar and Lists together, each thing tagged with its family${night ? ', dark' : ''}', (tester) async {
        final home = await twoFamilies(tester, all: true);
        final router = await pumpHome(tester, home, night: night);
        expect(home.showingAll, isTrue);
        expect(find.text('All my families'), findsOneWidget);
        expect(find.text('Carter family needs you'), findsWidgets);
        await shot(tester, 'all_today_phone$dark');
        await tester.scrollUntilVisible(find.text('Pottery class'), 300, scrollable: vertical());
        expect(find.text('Pottery class'), findsOneWidget);
        await shot(tester, 'all_today_phone_events$dark');
        router.go('/calendar');
        await tester.pumpAndSettle();
        await shot(tester, 'all_calendar_phone$dark');
        router.go('/lists');
        await tester.pumpAndSettle();
        await shot(tester, 'all_lists_phone$dark');
      });

      testWidgets('on iPad${night ? ', dark' : ''}', (tester) async {
        final home = await twoFamilies(tester, all: true);
        final router = await pumpHome(tester, home, size: tablet, night: night);
        await shot(tester, 'all_today_pad$dark');
        router.go('/calendar');
        await tester.pumpAndSettle();
        await shot(tester, 'all_calendar_pad$dark');
        router.go('/lists');
        await tester.pumpAndSettle();
        await shot(tester, 'all_lists_pad$dark');
      });
    }

    testWidgets("an event opens in its own family; a family's chip takes it off the calendar", (tester) async {
      final home = await twoFamilies(tester, all: true);
      final smith = home.logs[1];
      final router = await pumpHome(tester, home);
      await tester.scrollUntilVisible(find.text('Pottery class'), 300, scrollable: vertical());
      await tester.ensureVisible(find.text('Pottery class'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pottery class'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, startsWith('/l/${smith.id}/event/'));
      router.go('/calendar');
      await tester.pumpAndSettle();
      expect(find.text('Pottery class'), findsOneWidget);
      await tester.tap(find.widgetWithText(Semantics, 'Smith family').first);
      await tester.pumpAndSettle();
      expect(find.text('Pottery class'), findsNothing);
    });

    testWidgets('checking off a Smith item writes to the Smiths, with Undo there', (tester) async {
      final home = await twoFamilies(tester, all: true);
      final smith = home.logs[1];
      final router = await pumpHome(tester, home);
      final list = smith.den.lists.firstWhere((l) => l.list.title == 'Groceries');
      router.go('/lists?log=${smith.id}&list=${list.list.id}');
      await tester.pumpAndSettle();
      expect(find.text('Peaches'), findsOneWidget);
      final before = smith.den.lists.firstWhere((l) => l.list.id == list.list.id).items.where((i) => i.checked).length;
      await tester.tap(find.text('Peaches'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      final after = smith.den.lists.firstWhere((l) => l.list.id == list.list.id).items.where((i) => i.checked).length;
      expect(after, before + 1, reason: "the Smiths' engine took the change");
      expect(home.logs.first.den.lists.any((l) => l.list.id == list.list.id), isFalse);
    });
  });

  group('leaving a family', () {
    testWidgets("Settings offers it only while another family stays", (tester) async {
      final store = MemoryHouseholdStore(networks: false);
      final (home, smithId) = (await tester.runAsync(() async {
        final home = await Household.boot(store);
        await found(home.active.den, 'Kotvas', you: 'Grandma');
        final dana = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
        await found(dana, 'Smith family', you: 'Dana');
        final smith = await home.prepare(dana.familyId!);
        final member = await dana.addMember(name: 'Grandma', role: Role.adult);
        await smith.den.requestJoin(familyId: dana.familyId!, founderPubkey: dana.founderPubkey!, deviceName: "Grandma's phone", kind: DeviceKind.phone);
        await dana.ingest(smith.den.changesSince(const {}));
        await dana.approveDevice(smith.den.deviceId, member: member);
        await smith.den.ingest(dana.changesSince(const {}));
        await home.adopt(smith);
        return (home, dana.familyId!);
      }))!;
      await pumpHome(tester, home, location: '/settings');
      expect(find.text('Leave Smith family on this device'), findsOneWidget);
      expect(find.text('Join another family'), findsOneWidget);
      await tester.ensureVisible(find.text('Leave Smith family on this device'));
      await tester.pumpAndSettle();
      await shot(tester, 'families_settings_phone');
      await tester.tap(find.text('Leave Smith family on this device'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Leave Smith family'));
      await tester.pumpAndSettle();
      await shot(tester, 'families_leave_phone');
      await tester.tap(find.text('Leave Smith family'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      await tester.pumpAndSettle();
      expect(home.logs, hasLength(1));
      expect(home.active.den.family?.name, 'Kotvas');
      expect(store.forgotten.map((m) => m.id), [smithId]);
      expect(MembershipActions.canLeave(home, home.active), isFalse);
      // Back in one family: Settings has no Leave.
      await pumpHome(tester, home, location: '/settings');
      expect(find.textContaining('Leave '), findsNothing);
    });
  });
}
