import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/build_info.dart';
import 'package:den_app/app/den_app.dart' show buildRouter;
import 'package:den_app/app/screen_info.dart';
import 'package:den_app/design/layout.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/widgets.dart' show DenSidebar, DenTabBar;
import 'package:den_app/features/add/screens/add_sheet.dart' show AddSheet;
import 'package:den_app/features/advanced/screens/advanced_screen.dart';
import 'package:den_app/features/assistant/screens/ask_screen.dart';
import 'package:den_app/features/settings/screens/settings_screen.dart';
import 'package:den_app/platform/web/web_insets.dart';
import 'package:den_assistant/testing.dart';
import 'package:den_app/features/assistant/assistant.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'assistant_test.dart' show FakeLink, helperOnFor;
import 'chores_shots.dart';

/// Phones on their side, folding phones open and shut, tablets under a browser's bars and short
/// desktop windows: which layout each gets, that the sidebar never cuts anything off, and how
/// the app, its sheets and Ask look there (light and dark), with the safe areas each has.
///
/// Safe areas are top, right, bottom, left, as the page reports them: an iPhone on its side has
/// the notch or Dynamic Island at one end and gets the same inset at both, and the home
/// indicator at the bottom; Android's Chrome reports the status and gesture bars only in an
/// edge-to-edge Home Screen app.
const iphoneLandscape = Size(844, 390);
const iphoneLandscapeInsets = [0.0, 47.0, 21.0, 47.0];
const iphoneMaxLandscape = Size(932, 430);
const iphoneMaxLandscapeInsets = [0.0, 59.0, 21.0, 59.0];
const foldOpen = Size(820, 760);
const foldOpenPortrait = Size(760, 820);
const foldCover = Size(380, 800);
const foldCoverInsets = [24.0, 0.0, 24.0, 0.0];
const desktopShort = Size(1280, 560);

/// The whole app at [size] with the page's safe areas [insets], wrapped as the app's root wraps
/// it ([WebSafeArea], the screen info when [screenInfo]), at system text size [text].
Future<GoRouter> pumpWindow(
  WidgetTester tester,
  AppState state, {
  required Size size,
  List<double> insets = const [0, 0, 0, 0],
  bool night = false,
  double? text,
  bool screenInfo = false,
  Map<String, Object?>? Function()? page,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = buildRouter(state);
  await tester.pumpWidget(DenScope(
    state: state,
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: denTheme(night ? DenColors.night : DenColors.day),
      builder: (context, child) => systemText(
        tester,
        text,
        state: state,
        child: WebSafeArea(
          insets: insets,
          child: ScreenInfoOverlay(enabled: screenInfo, page: page, child: child!),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return router;
}

Future<void> shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));

/// The person at the foot of the sidebar.
Finder sidebarPerson(AppState state) =>
    find.descendant(of: find.byType(DenSidebar), matching: find.text(state.me!.name));

/// [finder]'s whole box lies on the screen of [size], inside the bottom safe area [bottom].
void expectOnScreen(WidgetTester tester, Finder finder, Size size, {double bottom = 0, String? reason}) {
  final box = tester.getRect(finder);
  expect(box.top, greaterThanOrEqualTo(0), reason: reason);
  expect(box.bottom, lessThanOrEqualTo(size.height - bottom + 0.5), reason: reason);
}

void main() {
  group('The window class', () {
    test('a phone gets the phone layout, on its side too', () {
      for (final size in [
        const Size(390, 844), iphoneLandscape, iphoneMaxLandscape, const Size(956, 440), const Size(667, 375), // iPhones
        foldCover, const Size(800, 380), // a Galaxy Z Fold shut, upright and on its side
        const Size(410, 760), const Size(820, 370), // the Fold open, split side by side and top and bottom
        const Size(1280, 450), // a desktop window shorter than a phone on its side
      ]) {
        expect(DenLayout.forWindow(size), DenWidth.compact, reason: '$size');
      }
    });

    test('a tablet-sized window gets the sidebar, however short its browser leaves it', () {
      for (final size in [foldOpen, foldOpenPortrait, const Size(820, 620), const Size(744, 1133), desktopShort]) {
        expect(DenLayout.forWindow(size).hasSidebar, isTrue, reason: '$size');
      }
      expect(DenLayout.forWindow(const Size(1194, 834)), DenWidth.wide);
    });
  });

  group('A phone on its side', () {
    for (final night in [false, true]) {
      testWidgets('iPhone 844 x 390${night ? ', night' : ''}: the tab bar between the safe areas', (tester) async {
        final state = await demo(tester);
        await pumpWindow(tester, state, size: iphoneLandscape, insets: iphoneLandscapeInsets, night: night);
        expect(find.byType(DenTabBar), findsOneWidget);
        expect(find.byType(DenSidebar), findsNothing);
        final tabs = tester.getRect(find.byType(DenTabBar));
        expect(tabs.bottom, iphoneLandscape.height);
        // The first and last tabs clear the notch's inset at both ends.
        expect(tester.getRect(find.text('Today').last).left, greaterThan(47));
        expect(tester.getRect(find.text('Lists').last).right, lessThan(iphoneLandscape.width - 47));
        await shot('window_iphone_landscape${night ? '_night' : ''}');
      });
    }

    for (final night in [false, true]) {
      testWidgets('iPhone 932 x 430 with the Dynamic Island${night ? ', night' : ''}: the phone layout', (tester) async {
        final state = await demo(tester);
        await pumpWindow(tester, state, size: iphoneMaxLandscape, insets: iphoneMaxLandscapeInsets, night: night);
        expect(find.byType(DenTabBar), findsOneWidget);
        expect(tester.getRect(find.text('Today').last).left, greaterThan(59));
        await shot('window_iphone_max_landscape${night ? '_night' : ''}');
      });
    }

    testWidgets('iPhone 932 x 430, night: Add\'s sheet from the bottom, between the safe areas', (tester) async {
      final state = await demo(tester);
      await pumpWindow(tester, state, size: iphoneMaxLandscape, insets: iphoneMaxLandscapeInsets, night: true);
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.byType(AddSheet));
      expect(sheet.width, lessThanOrEqualTo(DenLayout.readableWidth));
      expect(sheet.left, greaterThanOrEqualTo(59), reason: 'clear of the Dynamic Island');
      expect(sheet.bottom, lessThanOrEqualTo(iphoneMaxLandscape.height), reason: 'from the bottom edge');
      await shot('window_iphone_max_landscape_add_night');
    });

    testWidgets('iPhone 844 x 390: Ask is a sheet, not the side panel', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await demo(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(ScriptedChatModel(const []));
      addTearDown(() => Assistant.links = Assistant.hubLink);
      final router = await pumpWindow(tester, state, size: iphoneLandscape, insets: iphoneLandscapeInsets);
      router.push('/ask');
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.byType(AskScreen), findsOneWidget);
      final ask = tester.getRect(find.byType(AskScreen));
      expect(ask.bottom, greaterThan(iphoneLandscape.height - 60), reason: 'from the bottom, as on a phone');
      await shot('window_iphone_landscape_ask');
    });
  });

  group('A Galaxy Z Fold', () {
    for (final night in [false, true]) {
      testWidgets('shut, 380 x 800 in an edge-to-edge Home Screen app${night ? ', night' : ''}: the phone layout', (tester) async {
        final state = await demo(tester);
        await pumpWindow(tester, state, size: foldCover, insets: foldCoverInsets, night: night);
        expect(find.byType(DenTabBar), findsOneWidget);
        expect(tester.getRect(find.text('Today').last).bottom, lessThan(foldCover.height - 24));
        await shot('window_fold_cover${night ? '_night' : ''}');
      });
    }

    testWidgets('shut, on its side (800 x 380): the phone layout', (tester) async {
      final state = await demo(tester);
      await pumpWindow(tester, state, size: const Size(800, 380), insets: const [0, 24, 0, 0]);
      expect(find.byType(DenTabBar), findsOneWidget);
      expect(find.byType(DenSidebar), findsNothing);
    });

    for (final (name, size) in [('open', foldOpen), ('open_portrait', foldOpenPortrait)]) {
      for (final night in [false, true]) {
        testWidgets('$name, ${size.width.round()} x ${size.height.round()}${night ? ', night' : ''}: the sidebar, all of it in reach', (tester) async {
          final state = await demo(tester);
          await pumpWindow(tester, state, size: size, night: night);
          expect(find.byType(DenSidebar), findsOneWidget);
          expectOnScreen(tester, sidebarPerson(state), size, reason: 'the person at the foot of the sidebar');
          await shot('window_fold_$name${night ? '_night' : ''}');
        });
      }
    }

    testWidgets('open under Chrome\'s bars at 200 % text: the places scroll, the person stays', (tester) async {
      final state = await demo(tester);
      const size = Size(820, 600);
      await pumpWindow(tester, state, size: size, text: 2);
      expect(find.byType(DenSidebar), findsOneWidget);
      expectOnScreen(tester, sidebarPerson(state), size, reason: 'the person is never cut off');
      await shot('window_fold_open_short_200');
      // The last place is down the list, and a scroll brings it up.
      final places = find.descendant(of: find.byType(DenSidebar), matching: find.byType(Scrollable));
      final search = find.descendant(of: find.byType(DenSidebar), matching: find.text('Search'));
      await tester.scrollUntilVisible(search, 60, scrollable: places);
      expectOnScreen(tester, search, size);
      expectOnScreen(tester, sidebarPerson(state), size, reason: 'still there after the scroll');
      await tester.tap(sidebarPerson(state));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets, reason: 'the person opens their menu');
    });

    testWidgets('open: screen readers reach the sidebar, its places and the person', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await demo(tester);
      await pumpWindow(tester, state, size: foldOpen);
      for (final words in ['Today', 'Calendar', 'Search', state.me!.name]) {
        final node = tester.getSemantics(find.descendant(of: find.byType(DenSidebar), matching: find.text(words)));
        expect(node.label, contains(words), reason: '$words is its own node, not blocked by the page beside it');
        expect(node.rect.width, lessThan(DenLayout.sidebarWidth + 1));
      }
      semantics.dispose();
    });

    testWidgets('open: Ask is a centered sheet, under the panel\'s width', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await demo(tester);
      await helperOnFor(tester, state.den);
      Assistant.links = (_) => FakeLink(ScriptedChatModel(const []));
      addTearDown(() => Assistant.links = Assistant.hubLink);
      final router = await pumpWindow(tester, state, size: foldOpen, night: true);
      router.push('/ask');
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.byType(AskScreen), findsOneWidget);
      await shot('window_fold_open_ask_night');
    });
  });

  group('A short desktop window', () {
    for (final night in [false, true]) {
      testWidgets('1280 x 560${night ? ', night' : ''}: the sidebar with the person in reach', (tester) async {
        final state = await demo(tester);
        await pumpWindow(tester, state, size: desktopShort, night: night);
        expect(find.byType(DenSidebar), findsOneWidget);
        expectOnScreen(tester, sidebarPerson(state), desktopShort);
        await shot('window_desktop_short${night ? '_night' : ''}');
      });
    }

    testWidgets('1024 x 480 at 200 % text: everything in the sidebar reachable', (tester) async {
      final state = await demo(tester);
      const size = Size(1024, 480);
      await pumpWindow(tester, state, size: size, text: 2);
      expect(find.byType(DenSidebar), findsOneWidget);
      final places = find.descendant(of: find.byType(DenSidebar), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(sidebarPerson(state), 60, scrollable: places);
      expectOnScreen(tester, sidebarPerson(state), size, reason: 'the person, at the end of the scroll');
      await shot('window_desktop_tiny_200');
    });
  });

  group('Show screen info', () {
    testWidgets('Advanced turns it on and off; the panel shows over the app', (tester) async {
      final state = await demo(tester);
      await loadFonts();
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(DenScope(
        state: state,
        child: ListenableBuilder(
          listenable: state.device,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: denTheme(DenColors.day),
            builder: (context, child) => WebSafeArea(
              insets: const [24, 0, 0, 0],
              child: ScreenInfoOverlay(enabled: state.device.screenInfo, page: () => foldKeyboardPage, child: child!),
            ),
            home: const AdvancedScreen(web: true),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(state.device.screenInfo, isFalse, reason: 'off by default');
      expect(find.textContaining('Layout '), findsNothing);
      expect(findWords('Copy screen info'), findsNothing);
      await tester.scrollUntilVisible(findWords('Show screen info'), 100);
      await tester.tap(findWords('Show screen info'));
      await tester.pumpAndSettle();
      expect(state.device.screenInfo, isTrue);
      expect(findWords('Copy screen info'), findsOneWidget);
      final panel = find.textContaining('Layout compact for 412×915');
      expect(panel, findsOneWidget);
      expect(find.textContaining('let go: keyboard closed'), findsOneWidget, reason: 'the page\'s events');
      expect(find.textContaining('Visual 412×915 top 0'), findsOneWidget);
      await shot('screen_info_fold');
      // Touches go through it.
      expect(tester.getRect(panel).top, greaterThanOrEqualTo(24));
      await tester.tap(findWords('Show screen info'));
      await tester.pumpAndSettle();
      expect(state.device.screenInfo, isFalse);
      expect(find.textContaining('Layout '), findsNothing);
    });
  });

  group('The build', () {
    test('says its commit and when it was built', () {
      expect(DenBuild.describe('abc1234', '2026-10-29T17:10Z'), 'abc1234, built 2026-10-29 17:10 UTC');
      expect(DenBuild.describe('', '2026-10-29T17:10Z'), 'Built 2026-10-29 17:10 UTC');
      expect(DenBuild.describe('abc1234', ''), 'abc1234');
      expect(DenBuild.describe('', ''), 'Built on this computer');
      // A test run isn't given one.
      expect(DenBuild.label, 'Built on this computer');
    });

    test('reads what the hub serves', () {
      final hub = HubBuild.parse(build: '{"commit":"def5678","built":"2026-10-30T08:00Z"}', health: '{"ok":true,"version":"0.1.0"}')!;
      expect(hub.label, 'def5678, built 2026-10-30 08:00 UTC · hub 0.1.0');
      expect(hub.differsFrom('abc1234'), isTrue);
      expect(hub.differsFrom('def5678'), isFalse);
      expect(hub.differsFrom(''), isFalse, reason: 'a build without a commit can\'t tell');
      expect(HubBuild.parse(build: '<html>', health: null), isNull, reason: 'an older hub has no build.json');
      expect(HubBuild.parse(build: null, health: '{"ok":true}'), isNull);
      expect(HubBuild.parse(build: null, health: '{"version":"0.1.0"}')!.label, 'hub 0.1.0');
    });

    testWidgets('Settings, About shows it, and the hub\'s, and says when a newer one waits', (tester) async {
      final state = await demo(tester);
      await shoot(
        tester,
        'settings_about_build',
        SettingsScreen(
          version: '1.0.0',
          hub: () async => const HubBuild(commit: 'def5678', built: '2026-10-30T08:00Z', version: '0.1.0'),
        ),
        state: state,
        size: tall,
      );
      expect(find.text('Build'), findsOneWidget);
      expect(find.text(DenBuild.label), findsOneWidget);
      expect(find.text('On the hub'), findsOneWidget);
      expect(find.text('def5678, built 2026-10-30 08:00 UTC · hub 0.1.0'), findsOneWidget);
      // This test build has no commit, so it can't tell whether the hub's is newer.
      expect(find.textContaining('A newer Den is waiting'), findsNothing);
    });
  });
}

/// What den_web.js says on the Fold shut, just after the keyboard closed with its arrow.
const Map<String, Object?> foldKeyboardPage = {
  'ua': 'Mozilla/5.0 (Linux; Android 16; SM-F966U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
  'display': 'standalone',
  'dpr': 2.625,
  'screen': [412, 915],
  'orientation': 'portrait-primary',
  'inner': [412, 915],
  'client': [412, 915],
  'visual': {'width': 412, 'height': 915, 'offsetTop': 0, 'pageTop': 0, 'scale': 1},
  'scroll': {'window': 0, 'root': 0, 'body': 0},
  'view': [0, 0, 412, 915],
  'keyboard': 0,
  'full': 915,
  'virtualKeyboard': [0, 0, 0, 0],
  'focus': 'body',
  'safe': [24, 0, 0, 0],
  'events': [
    {'t': 12034, 'what': 'focus in', 'visual': 915, 'top': 0, 'inner': 915, 'drawn': 915, 'keyboard': 0, 'focus': 'input.flt-text-editing'},
    {'t': 12301, 'what': 'viewport resize', 'visual': 595, 'top': 0, 'inner': 915, 'drawn': 915, 'keyboard': 320, 'focus': 'input.flt-text-editing'},
    {'t': 15880, 'what': 'let go: keyboard closed', 'visual': 915, 'top': 0, 'inner': 915, 'drawn': 595, 'keyboard': 0, 'focus': 'input.flt-text-editing'},
    {'t': 15881, 'what': 'viewport resize', 'visual': 915, 'top': 0, 'inner': 915, 'drawn': 595, 'keyboard': 0, 'focus': 'body'},
    {'t': 15899, 'what': 'focus out', 'visual': 915, 'top': 0, 'inner': 915, 'drawn': 915, 'keyboard': 0, 'focus': 'body'},
  ],
};
