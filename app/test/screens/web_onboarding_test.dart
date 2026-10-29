import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_app/features/onboarding/screens/join_screen.dart';
import 'package:den_app/features/onboarding/screens/start_family_screen.dart';
import 'package:den_app/features/onboarding/screens/waiting_screen.dart';
import 'package:den_app/features/onboarding/screens/welcome_screen.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// A fresh hub that served the page, waiting for its setup code.
final HubInfo freshHub = HubInfo(
  base: Uri.parse('https://den.example.com'),
  paired: false,
  device: 'H7Q2KX4M9PA3TBV6',
  name: 'Den hub',
  stage: 'waiting_for_code',
);

/// The same hub once it's in a family.
final HubInfo familyHub = HubInfo(
  base: Uri.parse('https://den.example.com'),
  paired: true,
  device: 'H7Q2KX4M9PA3TBV6',
  name: 'Den hub',
  stage: 'ready',
);

const iPhoneSafari = WebAppInfo(ios: true, iosVersion: (major: 18, minor: 6), secure: true, worker: true, share: true);
const iPhoneHomeScreen = WebAppInfo(
  ios: true,
  iosVersion: (major: 18, minor: 6),
  standalone: true,
  secure: true,
  worker: true,
  push: true,
  permission: 'default',
  share: true,
  ready: true,
);

void main() {
  testWidgets('A fresh hub: the browser starts the family, since there is none to join yet', (tester) async {
    final state = await empty(tester);
    await shootWith(
      tester,
      'web_welcome_fresh_hub_phone',
      WelcomeScreen(browser: true, hub: freshHub, web: iPhoneHomeScreen),
      state: state,
    );
    expect(find.text('Start a family'), findsOneWidget);
    expect(find.text('Join your family'), findsNothing, reason: 'a hub waiting for its setup code holds no family');
    expect(find.text("Link with a parent's phone"), findsNothing);
  });

  testWidgets('A hub already in a family: the browser joins it', (tester) async {
    final state = await empty(tester);
    await pumpScreen(tester, WelcomeScreen(browser: true, hub: familyHub, web: iPhoneHomeScreen), state: state);
    expect(find.text('Start a family'), findsNothing);
    expect(find.text('Join your family'), findsOneWidget);
    expect(find.text("Link with a parent's phone"), findsNothing, reason: 'no camera to scan with in this family');
  });

  testWidgets('Safari on an iPhone shows how to add Den to the Home Screen first', (tester) async {
    final state = await empty(tester);
    await shootWith(
      tester,
      'web_welcome_add_to_home_screen_phone',
      WelcomeScreen(browser: true, hub: freshHub, web: iPhoneSafari),
      state: state,
    );
    expect(find.text('Add Den to your Home Screen'), findsOneWidget);
    expect(find.text('Start a family'), findsNothing, reason: "a family started in Safari wouldn't be on the Home Screen");
    await tester.tap(find.text('Use Den in Safari instead'));
    await tester.pumpAndSettle();
    expect(find.text('Start a family'), findsOneWidget);
  });

  testWidgets('Starting the family in a browser asks for the hub setup code', (tester) async {
    final state = await empty(tester);
    await pumpScreen(tester, StartFamilyScreen(initialTimeZone: 'America/Chicago', hub: freshHub), state: state);
    await tester.enterText(find.widgetWithText(TextField, 'The Riveras'), 'The Riveras');
    await tester.enterText(find.widgetWithText(TextField, 'Sam'), 'Sam');
    await tester.tap(find.text('Create family'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(findWords("Add the hub's setup code."), 200, scrollable: find.byType(Scrollable).first);
    expect(findWords("Add the hub's setup code."), findsOneWidget);
    expect(state.den.hasFamily, isFalse, reason: 'nothing is created without the code');
    await matchShot('web_start_family_setup_code_phone');
  });

  testWidgets('An invite link opens Join with its words, and joining takes one tap', (tester) async {
    final state = await empty(tester);
    final pairing = FakePairing(now: demoNow);
    final router = GoRouter(
      initialLocation: '/join',
      routes: [
        GoRoute(
          path: '/join',
          builder: (_, _) => const Scaffold(body: JoinScreen(browser: true, code: 'maple river candle tiger', web: iPhoneHomeScreen)),
        ),
        GoRoute(path: '/welcome/waiting', builder: (_, _) => const Scaffold(body: Text('Waiting'))),
      ],
    );
    await loadFonts();
    await tester.pumpWidget(
      PairingScope(
        service: pairing,
        child: DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'maple river candle tiger'), findsOneWidget);
    expect(find.text('Hub address (optional)'), findsNothing, reason: 'a browser joins the hub that served it');
    await tester.tap(find.text('Join the family'));
    await tester.pumpAndSettle();
    expect(pairing.invitesUsed.single.$1, 'maple river candle tiger');
    expect(pairing.invitesUsed.single.$2, "Zoe's phone", reason: 'named for whom the invite is, when nobody typed a name');
    expect(find.text('Waiting'), findsOneWidget);
  });

  testWidgets("An invite's link, followed in a device with no family, lands on Join with the words", (tester) async {
    final state = await empty(tester);
    final router = buildRouter(state);
    await loadFonts();
    await tester.pumpWidget(DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router)));
    await tester.pumpAndSettle();
    router.go('/join/maple-river-candle-tiger');
    await tester.pumpAndSettle();
    expect(findWords('Join your family'), findsWidgets);
    expect(find.widgetWithText(TextField, 'maple river candle tiger'), findsOneWidget);
  });

  testWidgets('Safari on an iPhone keeps the invite words at hand while Den goes on the Home Screen', (tester) async {
    final state = await empty(tester);
    await pumpScreen(tester, const JoinScreen(browser: true, code: 'maple river candle tiger', web: iPhoneSafari), state: state);
    expect(find.text('Add Den to your Home Screen'), findsOneWidget);
    expect(find.text('maple river candle tiger'), findsOneWidget);
    expect(find.text('Join the family'), findsNothing);
  });

  testWidgets('Waiting for approval can start over', (tester) async {
    final state = await empty(tester);
    await pumpScreen(tester, const WaitingScreen(ticket: JoinTicket(familyId: 'F')), state: state);
    expect(find.text('Start over with a new invite'), findsOneWidget);
  });

  /// What a parent's invite message says (InviteMessage.text), with real invite words.
  const message = 'Zoe, join The Carters on Den: https://den.example.com/#/join/maple-river-canoe-tiger\n\n'
      'On an iPhone or iPad, open the link in Safari, add Den to your Home Screen, then open Den from there. '
      'If it asks for a code, type: maple river canoe tiger\n\nThis invite works until Monday, October 19.';

  test('The whole invite message gives its words and the hub', () {
    final whole = inviteFrom(message);
    expect(whole.words, ['maple', 'river', 'canoe', 'tiger']);
    expect(whole.hub, 'https://den.example.com');
    // A messaging app that dropped the link still leaves the words to type.
    final noLink = inviteFrom(message.replaceFirst('https://den.example.com/#/join/maple-river-canoe-tiger', 'the link'));
    expect(noLink.words, ['maple', 'river', 'canoe', 'tiger']);
    expect(noLink.hub, isNull);
    expect(inviteFrom('maple-river-canoe-tiger').words, ['maple', 'river', 'canoe', 'tiger']);
  });

  group('Paste on Join', () {
    String? clipboard;
    setUp(() => clipboard = null);
    String fieldText(WidgetTester tester, int index) =>
        tester.widget<TextField>(find.byType(TextField).at(index)).controller!.text;

    Future<void> pumpJoin(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final state = await empty(tester);
      await pumpScreen(tester, const JoinScreen(scan: false), state: state, pushed: true);
    }

    testWidgets('fills the four words from the whole invite message, and the hub', (tester) async {
      clipboard = message;
      await pumpJoin(tester);
      await tester.tap(find.text('Paste the invite'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 0), 'maple river canoe tiger');
      expect(fieldText(tester, 1), 'https://den.example.com');
      await matchShot('onboarding_join_pasted_phone');
    });

    testWidgets('takes the words with spaces or dashes', (tester) async {
      clipboard = ' Maple-River-Canoe-Tiger ';
      await pumpJoin(tester);
      await tester.tap(find.text('Paste the invite'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 0), 'maple river canoe tiger');
    });

    testWidgets("says so when there's no invite on the clipboard", (tester) async {
      clipboard = 'Pick up milk on the way home';
      await pumpJoin(tester);
      await tester.tap(find.text('Paste the invite'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no invite on the clipboard'), findsOneWidget);
    });
  });

  test('An invite pasted whole gives its words and the hub', () {
    final pasted = inviteFrom('https://den.example.com/#/join/maple-river-candle-tiger');
    expect(pasted.words, ['maple', 'river', 'candle', 'tiger']);
    expect(pasted.hub, 'https://den.example.com');
    final typed = inviteFrom(' Maple, river  candle-tiger ');
    expect(typed.words, ['maple', 'river', 'candle', 'tiger']);
    expect(typed.hub, isNull);
  });

  test('The invite message says what to do, in plain words', () {
    final message = InviteMessage(
      words: const ['maple', 'river', 'candle', 'tiger'],
      link: Uri.parse('https://den.example.com/#/join/maple-river-candle-tiger'),
      expires: DateTime(2026, 10, 30, 18).millisecondsSinceEpoch,
      familyName: 'The Riveras',
      forName: 'Grandma',
    );
    expect(message.text, startsWith('Grandma, join The Riveras on Den: https://den.example.com/#/join/maple-river-candle-tiger'));
    expect(message.text, contains('add Den to your Home Screen'));
    expect(message.text, contains('type: maple river candle tiger'));
    expect(message.text, endsWith('This invite works until Friday, October 30.'));
    expect(message.text, isNot(contains('!')));
  });
}
