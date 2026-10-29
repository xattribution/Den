// What another family's page opens acts in that family (review of FAMILY-LINKS-PLAN phase 2):
// a sheet, a dialog or a picker is a route of its own over the app, above the page that opened
// it, so it carries the page's family ([SheetScope], LogScope) instead of reading the family the
// device shows. Each test opens something from a page of the Smiths while the Carters show, and
// checks what it wrote, and where.
import 'dart:async';
import 'dart:io';

import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/family_label.dart';
import 'package:den_app/app/household.dart';
import 'package:den_app/app/log_scope.dart';
import 'package:den_app/app/redirect.dart' show mergedFamilies, showsTabs;
import 'package:den_app/design/sheet.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/widgets.dart' show DenTabBar, PersonPill;
import 'package:den_app/features/add/add.dart' show Capture, CaptureScope, CaptureService, CaptureSettings, MemoryCaptureSecrets, showAddSheet;
import 'package:den_app/features/add/screens/capture_screen.dart' show CaptureRoute;
import 'package:den_capture/den_capture.dart' show CaptureInput, HubCaptureClient;
import 'package:den_app/features/add/screens/add_sheet.dart' show AddSheet;
import 'package:den_app/features/family/family.dart' show FamilySwitch, MissingFamilyScreen, askParentForSignIn, showInviteSheet;
import 'package:den_app/features/onboarding/screens/join_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart' show TextSizeFromState, demoNow, findWords, loadFonts, phone, tablet;
import 'family_fakes.dart' show FakePairing;
import 'several_families_test.dart' show twoFamilies, pumpHome, shot, vertical;

/// A pairing that only notes who asked it for an invite.
class _NotingPairing extends LocalOnlyPairing {
  _NotingPairing(this.name);
  final String name;
  final List<String?> invites = [];

  @override
  Future<InviteMessage> createInvite({String? memberId, bool letIn = true}) async {
    invites.add(memberId);
    throw PairingException('No hub for $name in this test.');
  }
}

/// The Carters' scope at the app's root (what the device shows), and a page in the Smiths' scope
/// below it, as `/l/<smiths>/...` builds one. Returns the page's context and the root's.
Future<(BuildContext page, BuildContext root)> _scoped(
  WidgetTester tester,
  Household home, {
  PairingService? carters,
  CaptureService? capture,
}) async {
  late BuildContext page;
  late BuildContext root;
  final carter = home.logs[0];
  final smith = home.logs[1];
  await tester.pumpWidget(
    HouseholdScope(
      household: home,
      child: CaptureScope(
        service: capture ?? Capture.service,
        child: DenScope(
        state: carter.state,
        child: PairingScope(
          service: carters ?? _NotingPairing('the Carters'),
          child: MaterialApp(
            theme: denTheme(DenColors.day),
            home: Builder(builder: (context) {
              root = context;
              return LogScope(
                log: smith,
                child: Builder(builder: (context) {
                  page = context;
                  return const Scaffold(body: SizedBox.expand());
                }),
              );
            }),
          ),
        ),
      ),
      ),
    ),
  );
  return (page, root);
}

Den _denOf(WidgetTester tester, Finder finder) => DenScope.read(tester.element(finder)).den;

/// Text containing [words], spaces kept together or not.
Finder _containing(String words) => find.byWidgetPredicate(
      (w) => w is Text && ((w.data ?? w.textSpan?.toPlainText()) ?? '').replaceAll(RegExp('[\u00a0\u202f]'), ' ').contains(words),
      description: 'text containing "$words"',
    );

/// Joining another family on [home]'s device with [pairing], as `/families/join` shows it.
Future<GoRouter> _pumpJoin(WidgetTester tester, Household home, PairingService pairing, {bool night = false}) async {
  await loadFonts();
  tester.view.physicalSize = phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => HouseholdScope(
        household: home,
        child: PairingScope(
          service: pairing,
          child: const Scaffold(body: SafeArea(child: JoinScreen(another: true, browser: false, scan: false))),
        ),
      ),
    ),
    GoRoute(path: '/welcome/waiting', builder: (_, _) => const Scaffold(body: Text('Waiting'))),
  ]);
  await tester.pumpWidget(
    DenScope(
      state: home.active.state,
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group("a sheet opened on another family's page is that family's", () {
    testWidgets('Den sheets, bottom sheets and pickers all carry the page’s family', (tester) async {
      final home = await twoFamilies(tester);
      final smith = home.logs[1];
      final (page, root) = await _scoped(tester, home);
      expect(SheetScope.of(root), isNull, reason: "the root is the family the device shows: nothing to carry");

      showDenSheet<void>(page, builder: (_) => const Text('den sheet'));
      await tester.pumpAndSettle();
      expect(identical(_denOf(tester, find.text('den sheet')), smith.den), isTrue);
      Navigator.of(tester.element(find.text('den sheet'))).pop();
      await tester.pumpAndSettle();

      showModalBottomSheet<void>(context: page, builder: carryScope(page, (_) => const Text('bottom sheet')));
      await tester.pumpAndSettle();
      expect(identical(_denOf(tester, find.text('bottom sheet')), smith.den), isTrue);
      Navigator.of(tester.element(find.text('bottom sheet'))).pop();
      await tester.pumpAndSettle();

      showDatePicker(
        context: page,
        builder: carryTransition(page),
        initialDate: DateTime(2026, 10, 30),
        firstDate: DateTime(2026),
        lastDate: DateTime(2027),
      );
      await tester.pumpAndSettle();
      expect(identical(_denOf(tester, find.byType(DatePickerDialog)), smith.den), isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Opened from the root, a sheet is the family the device shows, as always.
      showDenSheet<void>(root, builder: (_) => const Text('root sheet'));
      await tester.pumpAndSettle();
      expect(identical(_denOf(tester, find.text('root sheet')), home.logs[0].den), isTrue);
    });

    testWidgets("the invite sheet asks that family's pairing, never the one the device shows", (tester) async {
      final base = await twoFamilies(tester);
      final carters = _NotingPairing('the Carters');
      final smiths = _NotingPairing('the Smiths');
      final home = Household([
        FamilyLog(membership: base.logs[0].membership, state: base.logs[0].state, pairing: carters),
        FamilyLog(membership: base.logs[1].membership, state: base.logs[1].state, pairing: smiths),
      ]);
      final smith = home.logs[1];
      final (page, _) = await _scoped(tester, home, carters: carters);
      final ruby = smith.den.members.firstWhere((m) => m.name == 'Ruby');
      showInviteSheet(page, memberId: ruby.id);
      await tester.pumpAndSettle();
      expect(smiths.invites, [ruby.id]);
      expect(carters.invites, isEmpty);
    });

    testWidgets("a PIN asked for after approving a display is that family's parent's", (tester) async {
      final home = await twoFamilies(tester);
      final smith = home.logs[1];
      final (page, root) = await _scoped(tester, home);
      // As approveDevice does: what it needs is taken on the page, the sheet asked from the root
      // (the request's row is gone by then).
      final me = DenScope.read(page).me;
      expect(me?.name, 'Alex');
      unawaited(askParentForSignIn(root, 'Kitchen iPad', me: me, scope: SheetScope.of(page)));
      await tester.pumpAndSettle();
      expect(identical(_denOf(tester, find.text('Set a PIN')), smith.den), isTrue);
      await tester.tap(find.text('Set a PIN'));
      await tester.pumpAndSettle();
      final signIn = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SignInSheet');
      expect(signIn, findsOneWidget);
      expect(identical(_denOf(tester, signIn), smith.den), isTrue, reason: "the Smiths' PIN, set in the Smiths' family");
    });
  });

  group("what reaches a hub from another family's page is that family's", () {
    testWidgets("Add's reader: the page's family's hub, never the hub of the family shown", (tester) async {
      final home = await twoFamilies(tester);
      final smith = home.logs[1];
      // The family shown has a hub reader; the Smiths, on this device without a connection, none.
      final shown = CaptureService(
        settings: CaptureSettings(secrets: MemoryCaptureSecrets()),
        hubClient: HubCaptureClient(bases: () => [Uri.parse('https://den.carter.example')], sign: (_, _, _) async => const {}),
      );
      final (page, root) = await _scoped(tester, home, capture: shown);
      expect(Capture.of(root).hub, isNotNull);
      final theirs = Capture.of(page);
      expect(identical(theirs, shown), isFalse);
      expect(theirs.hub, isNull, reason: "the Smiths' page never reads through the Carters' hub");
      expect(identical(theirs.settings, shown.settings), isTrue, reason: "the device's own reader settings, the same");
      expect(identical(Capture.forFamily(shown, den: smith.den, network: smith.network), theirs), isTrue, reason: 'kept per family');
    });

    testWidgets('Add\'s review page under /l/<smiths>/capture reads in the Smiths\' scope', (tester) async {
      final home = await twoFamilies(tester);
      final smith = home.logs[1];
      final router = await pumpHome(tester, home);
      router.push('/l/${smith.id}/capture', extra: CaptureInput.typed('Swim Saturday at 9'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      final page = tester.element(find.byType(CaptureRoute));
      expect(identical(DenScope.read(page).den, smith.den), isTrue);
      expect(identical(Capture.of(page), Capture.forFamily(Capture.service, den: smith.den, network: smith.network)), isTrue);
      expect(identical(Capture.of(page), Capture.service), isFalse);
    });

    testWidgets("something shared while All my families shows asks which family first, and reads nothing before", (tester) async {
      final home = await twoFamilies(tester, all: true);
      final smith = home.logs[1];
      final router = await pumpHome(tester, home);
      router.push('/capture', extra: CaptureInput.typed('Swim Saturday at 9'));
      await tester.pumpAndSettle();
      expect(findWords('Which family is this for?'), findsOneWidget);
      expect(find.text('Add to Carter family'), findsOneWidget);
      await shot(tester, 'all_share_phone');
      await tester.tap(find.text('Add to Smith family'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(router.state.uri.path, '/l/${smith.id}/capture');
      final page = tester.element(find.byType(CaptureRoute).last);
      expect(identical(DenScope.read(page).den, smith.den), isTrue);
      expect(find.descendant(of: find.byType(FamilyLabel), matching: find.textContaining('Smith family')), findsOneWidget);
    });
  });

  group("the app's own pages, opened from a page of the Smiths", () {
    testWidgets('every page opens: the family pages under /l/, Ask, the kids\' app and the wall once the Smiths show', (tester) async {
      final home = await twoFamilies(tester);
      final carter = home.logs[0], smith = home.logs[1];
      final ruby = smith.den.members.firstWhere((m) => m.name == 'Ruby');
      final router = await pumpHome(tester, home, size: tablet);
      final paths = <String>{};
      void collect(RouteBase r, String parent) {
        if (r is GoRoute) {
          final full = r.path.startsWith('/') ? r.path : (parent.endsWith('/') ? '$parent${r.path}' : '$parent/${r.path}');
          if (full.startsWith('/l/')) return;
          paths.add(full);
          for (final c in r.routes) {
            collect(c, full);
          }
        } else if (r is ShellRouteBase) {
          for (final c in r.routes) {
            collect(c, parent);
          }
        }
      }
      for (final r in router.configuration.routes) {
        collect(r, '');
      }
      expect(paths, containsAll(['/ask', '/kid', '/kid/:member', '/wall', '/capture', '/today', '/family']));
      String concrete(String path) => path
          .replaceAll(':member', ruby.id)
          .replaceAll(':code', 'maple-river-canoe-tiger')
          .replaceAll(':view', 'week')
          .replaceAll(':date', '2026-10-16')
          .replaceAll(RegExp(r':\w+'), 'X1');
      final places = <String, String>{};
      for (final path in paths.where((p) => p != '/')) {
        await home.choose(carter);
        router.go('/l/${smith.id}/family');
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        final page = find.descendant(
          of: find.byWidgetPredicate((w) => w is LogScope && identical(w.log, smith)),
          matching: find.byType(Text),
        );
        final scoped = GoRouter.of(tester.element(page.first));
        expect(scoped, isA<ScopedRouter>());
        scoped.go(concrete(path));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(router.routerDelegate.currentConfiguration.isError, isFalse, reason: '$path from the Smiths opened nothing');
        places[path] = '${router.state.uri.path} ${identical(home.active, smith) ? 'smith' : 'carter'}';
      }
      expect(places['/family'], '/l/${smith.id}/family carter', reason: 'a family page, in the family');
      expect(places['/kid/:member'], '/kid/${ruby.id} smith', reason: "Ruby's screen, with the Smiths shown first");
      expect(places['/ask']!.endsWith('smith'), isTrue, reason: 'Ask, with the Smiths shown first');
      expect(places['/today'], '/today carter', reason: "the app's places stay the app's");
      // Leave things settled for the test's end.
      router.go('/today');
      await tester.pump(const Duration(milliseconds: 400));
    });

    test("a family link that doesn't decode names no family", () {
      expect(splitLog('/l/%C3%28/event/E1'), (log: '%C3%28', rest: '/event/E1'));
      // What a tapped reminder or push opens is checked first: the router can't match a path
      // whose escapes don't decode, so such a link opens "That family isn't on this device".
      expect(openable('/l/%C3%28/event/E1'), '/families/missing');
      expect(openable('/event/%C3%28'), '/today');
      expect(openable('/l/abcdefghijklmnop/event/E1?at=9'), '/l/abcdefghijklmnop/event/E1?at=9');
      expect(openable('/l/Smith%20family/today'), '/l/Smith%20family/today');
    });
  });

  group('the whole app, from a page of the Smiths', () {
    testWidgets('Add someone on /l/<smiths>/family adds them to the Smiths', (tester) async {
      final home = await twoFamilies(tester);
      final carter = home.logs[0], smith = home.logs[1];
      final router = await pumpHome(tester, home);
      router.push('/l/${smith.id}/family');
      await tester.pumpAndSettle();
      expect(find.text('Ruby'), findsWidgets, reason: "the Smiths' people");
      final add = find.text('Add someone');
      await tester.ensureVisible(add.first);
      await tester.pumpAndSettle();
      await tester.tap(add.first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Mallory');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Parent').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Parent').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add Mallory'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Mallory'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pumpAndSettle();
      expect(smith.den.members.any((m) => m.name == 'Mallory'), isTrue, reason: 'added to the Smiths');
      expect(carter.den.members.any((m) => m.name == 'Mallory'), isFalse, reason: 'never to the family the device shows');
    });

    testWidgets("editing a Smith item in All my families edits the Smiths' item", (tester) async {
      final home = await twoFamilies(tester, all: true);
      final carter = home.logs[0], smith = home.logs[1];
      final router = await pumpHome(tester, home);
      final list = smith.den.lists.firstWhere((l) => l.list.title == 'Groceries');
      router.go('/lists?log=${smith.id}&list=${list.list.id}');
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Peaches'));
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'Peaches');
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Peaches, ripe');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pumpAndSettle();
      final items = smith.den.lists.firstWhere((l) => l.list.id == list.list.id).items.map((i) => i.text);
      expect(items, contains('Peaches, ripe'));
      expect([for (final l in carter.den.lists) for (final i in l.items) i.text], isNot(contains('Peaches, ripe')));
    });

    testWidgets("Settings under /l/<smiths>/settings leaves the Smiths, and says whose settings they are", (tester) async {
      final home = await twoFamilies(tester);
      final smith = home.logs[1];
      final router = await pumpHome(tester, home);
      router.push('/l/${smith.id}/settings');
      await tester.pumpAndSettle();
      final label = find.byType(FamilyLabel);
      expect(find.descendant(of: label, matching: find.textContaining('Smith family')), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('Leave Smith family'), 300, scrollable: vertical());
      expect(find.textContaining('Leave Smith family'), findsOneWidget);
      expect(find.textContaining('Leave Carter family'), findsNothing);
    });

    testWidgets("a link to a family this device doesn't hold says so", (tester) async {
      final home = await twoFamilies(tester);
      final router = await pumpHome(tester, home);
      router.go('/l/abcdefghijklmnop/event/E1');
      await tester.pumpAndSettle();
      expect(router.state.uri.toString(), '/families/missing');
      expect(find.byType(MissingFamilyScreen), findsOneWidget);
      expect(findWords("That family isn't on this device"), findsOneWidget);
      await shot(tester, 'families_missing_phone');
    });
  });

  group('All my families says which family the rest is', () {
    testWidgets('Add says where it adds, and adds there', (tester) async {
      final home = await twoFamilies(tester, all: true);
      final carter = home.logs[0], smith = home.logs[1];
      final router = await pumpHome(tester, home);
      // The tab bar's Add, from the app's own places.
      unawaited(showAddSheet(tester.element(find.byType(DenTabBar))));
      await tester.pumpAndSettle();
      expect(find.text('Adding to Carter family'), findsOneWidget);
      expect(identical(_denOf(tester, find.byType(AddSheet)), carter.den), isTrue);
      await shot(tester, 'all_add_phone');
      await tester.tap(find.descendant(of: find.byType(PersonPill), matching: find.text('Smith family')));
      await tester.pumpAndSettle();
      expect(find.text('Adding to Smith family'), findsOneWidget);
      expect(identical(_denOf(tester, find.byType(AddSheet)), smith.den), isTrue);
      await tester.ensureVisible(find.text('Chore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chore'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/l/${smith.id}/chore/new', reason: "the Smiths' new chore");
      expect(home.showingAll, isTrue);
    });

    testWidgets('Chores, which stay with each family, names the family', (tester) async {
      final home = await twoFamilies(tester, all: true);
      final router = await pumpHome(tester, home);
      router.go('/chores');
      await tester.pumpAndSettle();
      expect(find.textContaining('Chores and stars stay with each family'), findsOneWidget);
      expect(find.descendant(of: find.byType(FamilyLabel), matching: find.textContaining('Carter family')), findsOneWidget);
      await shot(tester, 'all_chores_phone');
      // Family and Settings say so too.
      router.go('/family');
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(FamilyLabel), matching: find.textContaining('Carter family')), findsOneWidget);
      router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(FamilyLabel), matching: find.textContaining('Carter family')), findsOneWidget);
    });

    testWidgets('without All my families, the family the switcher shows needs no label', (tester) async {
      final home = await twoFamilies(tester);
      final router = await pumpHome(tester, home);
      router.go('/chores');
      await tester.pumpAndSettle();
      expect(find.textContaining('Chores and stars stay with each family'), findsNothing);
    });

    testWidgets("a family this device is a wall display in isn't merged, and its Today is the wall", (tester) async {
      final home = await twoFamilies(tester, all: true);
      final smith = home.logs[1];
      await tester.runAsync(() => smith.den.setThisDeviceMode(DeviceMode.shared));
      expect(smith.den.thisDevice!.isShared, isTrue);
      expect(showsTabs(smith.state), isFalse);
      expect(mergedFamilies(home), [home.logs[0]]);
      final router = await pumpHome(tester, home, size: tablet);
      expect(find.text('Pottery class'), findsNothing, reason: "the Smiths' Today isn't in All my families");
      router.go('/l/${smith.id}/today');
      await tester.pumpAndSettle();
      expect(identical(home.active, smith), isTrue);
      expect(router.state.uri.path, '/wall');
    });
  });

  testWidgets('two families of one name: the switcher says which server each is on', (tester) async {
    final base = await twoFamilies(tester);
    final carter = base.logs[0], smith = base.logs[1];
    await tester.runAsync(() => smith.den.updateFamily({'name': 'Carter family'}));
    final home = Household([
      FamilyLog(membership: carter.membership.copyWith(hub: 'https://den.carter.example'), state: carter.state),
      FamilyLog(membership: smith.membership.copyWith(hub: 'https://den.other.example'), state: smith.state),
    ]);
    await pumpHome(tester, home);
    await tester.tap(find.byType(FamilySwitch));
    await tester.pumpAndSettle();
    expect(_containing('on den.carter.example'), findsOneWidget);
    expect(_containing('on den.other.example'), findsOneWidget);
  });

  group('joining another family', () {
    for (final night in [false, true]) {
      testWidgets('typed words: whose invite it is, on which server, before anything starts${night ? ', dark' : ''}', (tester) async {
        final home = await twoFamilies(tester);
        final pairing = FakePairing(
          now: demoNow,
          peek: const InvitePeek(
            familyName: 'Carter family',
            memberName: 'Grandma Rosa',
            marker: Marker.lavender,
            picture: 'teacup',
            letsIn: true,
            server: 'den.example.com',
          ),
        );
        final router = await _pumpJoin(tester, home, pairing, night: night);
        await tester.enterText(find.byType(TextField).first, 'maple river canoe tiger');
        await tester.enterText(find.byType(TextField).last, 'https://den.example.com');
        await tester.tap(find.text('Join'));
        await tester.pumpAndSettle();
        expect(pairing.invitesUsed, isEmpty, reason: 'nothing starts before the person saw it');
        expect(_containing('on den.example.com'), findsWidgets);
        expect(_containing('in a family called Carter family already'), findsOneWidget,
            reason: 'a family of the same name is on this device: check who sent it');
        await shot(tester, 'families_join_confirm_phone${night ? '_dark' : ''}');
        await tester.tap(find.text('Join as Grandma Rosa'));
        await tester.pumpAndSettle();
        expect(pairing.invitesUsed.single.$1, 'maple river canoe tiger');
        expect(router.state.uri.path, '/welcome/waiting');
      });
    }

    testWidgets('other words after the confirmation are confirmed again', (tester) async {
      final home = await twoFamilies(tester);
      final pairing = FakePairing(now: demoNow, peek: const InvitePeek(familyName: 'Lee family', server: 'den.lee.example'));
      await _pumpJoin(tester, home, pairing);
      await tester.enterText(find.byType(TextField).first, 'maple river canoe tiger');
      await tester.enterText(find.byType(TextField).last, 'https://den.lee.example');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(_containing('in a family called'), findsNothing, reason: 'no family of that name here');
      await tester.tap(find.text('Use other words'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'lemon river canoe tiger');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(pairing.invitesUsed, isEmpty, reason: 'new words: shown again first');
      expect(_containing('on den.lee.example'), findsWidgets);
    });
  });

  test('nothing in the app shows a route over it without carrying the scope it opened from', () {
    // Every sheet, dialog and picker goes through showDenSheet (which carries it) or passes
    // carryScope / carryTransition; nothing else pushes a route; and a context that outlives its
    // page (the root navigator's) is kept only for notes, or with the family passed along.
    const shows = ['showModalBottomSheet', 'showDialog', 'showGeneralDialog', 'showCupertinoModalPopup', 'showDatePicker',
      'showTimePicker', 'showDateRangePicker', 'showMenu', 'showSearch', 'showAdaptiveDialog'];
    const pushes = ['Navigator.push(', 'Navigator.of(context).push', '.push(MaterialPageRoute', 'PageRouteBuilder(', 'DialogRoute(',
      'ModalBottomSheetRoute(', 'OverlayEntry('];
    const rootContexts = {
      // Undo and notes only, with the page's actions taken first.
      'lib/features/chores/screens/chore_detail.dart',
      'lib/features/rewards/screens/reward_editor.dart',
      'lib/features/rewards/screens/goal_editor.dart',
      'lib/features/lists/state/list_actions.dart',
      'lib/features/lists/screens/list_detail.dart',
      // The PIN sheet after approving a display: passes the family's parent and scope.
      'lib/features/family/widgets/person_sheets.dart',
    };
    final problems = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll(r'\', '/');
      if (path.endsWith('lib/design/sheet.dart') || path.endsWith('lib/design/sheet_page.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('//')) continue;
        for (final show in shows) {
          if (!line.contains('$show(') && !line.contains('$show<')) continue;
          final around = lines.sublist(i, (i + 8).clamp(0, lines.length)).join('\n');
          if (!around.contains('carryScope(') && !around.contains('carryTransition(')) problems.add('$path:${i + 1}: $show without carryScope/carryTransition');
        }
        for (final push in pushes) {
          if (line.contains(push)) problems.add('$path:${i + 1}: pushes a route of its own ($push); use showDenSheet');
        }
        if (line.contains('rootNavigator: true') && !rootContexts.contains(path.substring(path.indexOf('lib/')))) {
          problems.add("$path:${i + 1}: the root navigator's context acts for the family the device shows");
        }
      }
    }
    final pin = File('lib/features/family/widgets/person_sheets.dart').readAsStringSync();
    if (!pin.contains('askParentForSignIn(keep, name, me: me, scope: scope)')) problems.add('approveDevice: the PIN sheet lost its family');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
