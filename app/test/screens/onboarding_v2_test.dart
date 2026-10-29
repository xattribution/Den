import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/advanced/screens/computer_link_screen.dart';
import 'package:den_app/features/advanced/words/history_words.dart';
import 'package:den_app/features/family/screens/family_screen.dart';
import 'package:den_app/features/family/widgets/invite_sheet.dart';
import 'package:den_app/features/onboarding/screens/join_screen.dart';
import 'package:den_app/features/onboarding/screens/start_family_screen.dart';
import 'package:den_app/features/onboarding/screens/waiting_screen.dart';
import 'package:den_app/features/onboarding/screens/welcome_screen.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';
import 'web_onboarding_test.dart' show familyHub, freshHub, iPhoneHomeScreen, iPhoneSafari;

/// Onboarding v2 (docs/design/onboarding.md): a link that lets someone in with one tap, the
/// setup link with nothing to type, Copy invite and Paste an invite for a link that can't reach
/// the Home Screen app, and the parents told whenever an invite let someone in.
const _iPadHomeScreen = WebAppInfo(ios: true, ipad: true, iosVersion: (major: 26, minor: 1), standalone: true, secure: true, worker: true);
const _iPadSafari = WebAppInfo(ios: true, ipad: true, iosVersion: (major: 26, minor: 1), secure: true, worker: true);
const Size _tall = Size(390, 1600);

/// What an invite for Grandma Rosa opens: her face, and in at once.
const _rosa = InvitePeek(familyName: 'Carter family', memberName: 'Grandma Rosa', marker: Marker.lavender, picture: 'teacup', letsIn: true);

/// The message an invite that lets someone in at once sends, good until tomorrow at 9:00 AM.
final _message = InviteMessage(
  words: const ['maple', 'river', 'canoe', 'tiger'],
  link: Uri.parse('https://den.example.com/#/join/maple-river-canoe-tiger'),
  expires: DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
  familyName: 'Carter family',
  forName: 'Grandma Rosa',
  letsIn: true,
);

String _id(AppState state, String name) => state.den.members.firstWhere((m) => m.name == name).id;

/// The demo family on Alex's phone after Grandma Rosa's new iPhone let itself in with the invite
/// Alex sent: what every parent's own device holds once it synced.
Future<AppState> _rosaJoined(WidgetTester tester) => real(tester, () async {
      final state = await demoState();
      final den = state.den;
      final rosa = _id(state, 'Grandma Rosa');
      final key = await InviteKey.generate();
      final now = demoNow.millisecondsSinceEpoch;
      await den.createInviteKey(member: rosa, publicKey: key.publicKey, expires: now + 24 * 3600000);
      final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => now + 5 * 60000);
      final proof = await key.prove(family: den.familyId!, member: rosa, devicePubkey: phone.keys.pubkey, expires: now + 20 * 60000);
      await phone.requestInviteJoin(
        familyId: den.familyId!,
        founderPubkey: den.founderPubkey!,
        deviceName: "Grandma Rosa's iPhone",
        kind: DeviceKind.phone,
        proof: proof,
      );
      final result = await den.ingest(phone.changesSince(const {}));
      expect(result.invalid, isEmpty);
      return state;
    });

Future<void> _tapAndWait(WidgetTester tester, Finder finder, {int ms = 400}) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(Duration(milliseconds: ms));
  });
  await tester.pumpAndSettle();
}

void main() {
  group('An invite opened in Safari', () {
    testWidgets('keeps the invite for the Home Screen app, with Copy invite above the steps', (tester) async {
      final state = await empty(tester);
      await shootWith(
        tester,
        'onboarding_v2_safari_invite_phone',
        const JoinScreen(browser: true, code: 'maple river canoe tiger', web: iPhoneSafari),
        state: state,
        size: _tall,
      );
      expect(find.text('Copy invite'), findsOneWidget);
      expect(findWords('Add Den to your Home Screen'), findsOneWidget);
      expect(find.text('More'), findsOneWidget, reason: "an iPhone's compact bar keeps Share behind the three dots");
      expect(findWords('Den picks up this invite there by itself.'), findsOneWidget);
      expect(find.text('maple river canoe tiger'), findsOneWidget, reason: 'the words, if Den asks');
      expect(find.text('Join the family'), findsNothing);
    });

    testWidgets('night', (tester) async {
      final state = await empty(tester);
      await shootWith(
        tester,
        'onboarding_v2_safari_invite_phone_night',
        const JoinScreen(browser: true, code: 'maple river canoe tiger', web: iPhoneSafari),
        state: state,
        size: _tall,
        night: true,
      );
    });

    testWidgets('on an iPad, Share is at the top', (tester) async {
      final state = await empty(tester);
      await shootWith(
        tester,
        'onboarding_v2_safari_invite_tablet',
        const JoinScreen(browser: true, code: 'maple river canoe tiger', web: _iPadSafari),
        state: state,
        size: tablet,
      );
      expect(find.text('More'), findsNothing);
      expect(find.text('Share'), findsOneWidget);
    });
  });

  group('The invite in the Home Screen app', () {
    testWidgets('says whose device this becomes, and joins with one tap, let in at once', (tester) async {
      final state = await empty(tester);
      final pairing = FakePairing(now: demoNow, peek: _rosa, admits: true);
      final router = GoRouter(
        initialLocation: '/join',
        routes: [
          GoRoute(
            path: '/join',
            builder: (_, _) => const Scaffold(body: SafeArea(child: JoinScreen(browser: true, code: 'maple river canoe tiger', web: iPhoneHomeScreen))),
          ),
          GoRoute(path: '/welcome/waiting', builder: (_, _) => const Scaffold(body: WaitingScreen())),
        ],
      );
      await loadFonts();
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        PairingScope(
          service: pairing,
          child: DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router, debugShowCheckedModeBanner: false)),
        ),
      );
      await tester.pumpAndSettle();
      expect(findWords('Join your family'), findsOneWidget);
      expect(find.text('Carter family'), findsOneWidget);
      expect(findWords("This iPhone becomes Grandma Rosa's, as soon as you tap Join."), findsOneWidget);
      await matchShot('onboarding_v2_join_confirm_phone');
      await tester.tap(find.text('Join as Grandma Rosa'));
      await tester.pumpAndSettle();
      expect(pairing.invitesUsed.single.$1, 'maple river canoe tiger');
      expect(findWords('Joining your family'), findsOneWidget, reason: 'nobody to wait for: it is let in at once');
      expect(find.text('Start over with a new invite'), findsOneWidget);
    });

    testWidgets('night, and on an iPad', (tester) async {
      final state = await empty(tester);
      // An invite with "Let them in right away" off.
      final pairing = FakePairing(
        now: demoNow,
        peek: const InvitePeek(familyName: 'Carter family', memberName: 'Grandma Rosa', marker: Marker.lavender, picture: 'teacup'),
      );
      await shootWith(
        tester,
        'onboarding_v2_join_confirm_phone_night',
        const JoinScreen(browser: true, code: 'maple river canoe tiger', web: iPhoneHomeScreen),
        state: state,
        night: true,
        pairing: pairing,
      );
      expect(findWords("This iPhone becomes Grandma Rosa's once a parent lets it in."), findsOneWidget,
          reason: 'an invite without a key: a parent still approves');
      await shootWith(
        tester,
        'onboarding_v2_join_confirm_tablet',
        const JoinScreen(browser: true, code: 'maple river canoe tiger', web: _iPadHomeScreen),
        state: state,
        size: tablet,
        pairing: FakePairing(now: demoNow, peek: _rosa),
      );
    });

    testWidgets('at 200% text', (tester) async {
      withTextScale(tester, 2);
      final state = await empty(tester);
      await shootWith(
        tester,
        'onboarding_v2_join_confirm_phone_200',
        const JoinScreen(browser: true, code: 'maple river canoe tiger', web: iPhoneHomeScreen),
        state: state,
        pairing: FakePairing(now: demoNow, peek: _rosa),
      );
      expect(find.text('Join as Grandma Rosa'), findsOneWidget);
    });

    testWidgets("words that open nothing go back to typing, with why", (tester) async {
      final state = await empty(tester);
      await pumpScreen(
        tester,
        const JoinScreen(browser: true, code: 'maple river canoe tiger', web: iPhoneHomeScreen),
        state: state,
        pairing: FakePairing(now: demoNow),
      );
      expect(findWords("That code isn't right, or the invite has expired. Ask for a new invite."), findsOneWidget);
      expect(find.text('Paste the invite'), findsOneWidget);
    });

    testWidgets('Joining, let in at once', (tester) async {
      final state = await empty(tester);
      await shootWith(
        tester,
        'onboarding_v2_joining_phone',
        const WaitingScreen(ticket: JoinTicket(familyId: 'F', familyName: 'Carter family', admitted: true)),
        state: state,
      );
      expect(findWords('Letting this device in'), findsOneWidget);
    });
  });

  group('Paste an invite', () {
    String? clipboard;
    setUp(() => clipboard = null);

    Future<GoRouter> pumpWelcome(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final state = await empty(tester);
      final router = GoRouter(
        initialLocation: '/welcome',
        routes: [
          GoRoute(path: '/welcome', builder: (_, _) => Scaffold(body: WelcomeScreen(browser: true, hub: familyHub, web: iPhoneHomeScreen))),
          GoRoute(path: '/welcome/join', builder: (_, s) => Scaffold(body: Text('join ${s.uri.queryParameters['code']}'))),
          GoRoute(
            path: '/welcome/start',
            builder: (_, s) => Scaffold(body: Text('start ${s.uri.queryParameters['setup']} ${s.uri.queryParameters['hub']}')),
          ),
        ],
      );
      await loadFonts();
      await tester.pumpWidget(
        PairingScope(
          service: FakePairing(now: demoNow),
          child: DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router)),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('a link copied in Safari opens the step it is for', (tester) async {
      clipboard = 'https://den.example.com/#/join/maple-river-canoe-tiger';
      await pumpWelcome(tester);
      await tester.tap(find.text('Paste an invite'));
      await tester.pumpAndSettle();
      expect(find.text('join maple river canoe tiger'), findsOneWidget);
    });

    testWidgets('a setup link starts the family with that hub', (tester) async {
      clipboard = 'https://den.example.com/#/setup/ABCD-EFGH/h7q2kx4m9pa3tbv6';
      await pumpWelcome(tester);
      await tester.tap(find.text('Paste an invite'));
      await tester.pumpAndSettle();
      expect(find.text('start ABCD-EFGH h7q2kx4m9pa3tbv6'), findsOneWidget);
    });

    testWidgets("says so when there's nothing to paste", (tester) async {
      clipboard = 'Pick up milk on the way home';
      await pumpWelcome(tester);
      await tester.tap(find.text('Paste an invite'));
      await tester.pumpAndSettle();
      expect(find.textContaining("There's no invite on the clipboard"), findsOneWidget);
    });
  });

  group('The setup link', () {
    testWidgets('starts the family with nothing to type: the hub it names joins on its own', (tester) async {
      final state = await empty(tester);
      final setup = FakeHubSetup(HubSetupStage.sending);
      final pairing = FakePairing(now: demoNow, setup: setup);
      await pumpScreen(
        tester,
        StartFamilyScreen(
          initialTimeZone: 'America/Chicago',
          hub: freshHub,
          setupCode: 'ABCD-EFGH',
          hubDevice: freshHub.device,
          web: iPhoneHomeScreen,
        ),
        state: state,
        pairing: pairing,
      );
      expect(find.text('ABCD-EFGH'), findsNothing, reason: 'no setup code to type');
      expect(findWords("Den hub joins as the family's hub"), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'The Riveras'), 'The Riveras');
      await tester.enterText(find.widgetWithText(TextField, 'Sam'), 'Sam');
      await tester.pumpAndSettle();
      await matchShot('onboarding_v2_start_from_link_phone');
      await _tapAndWait(tester, find.text('Create family'));
      expect(state.den.family?.name, 'The Riveras');
      expect(pairing.hubsSetUp.single, ('ABCD-EFGH', freshHub.device), reason: 'only the hub the link names');
    });

    testWidgets("a page from another hub than the link's says so, and offers the code instead", (tester) async {
      final state = await empty(tester);
      await pumpScreen(
        tester,
        StartFamilyScreen(initialTimeZone: 'America/Chicago', hub: freshHub, setupCode: 'ABCD-EFGH', hubDevice: 'someotherhub0000', web: iPhoneHomeScreen),
        state: state,
        pairing: FakePairing(now: demoNow),
      );
      expect(find.textContaining('another hub than the one that printed the link'), findsOneWidget);
      await tester.tap(find.text('Type the setup code instead'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'ABCD-EFGH'), findsOneWidget, reason: 'the hint in the code field');
    });

    testWidgets('opened in Safari: the Home Screen first, with the link kept', (tester) async {
      final state = await empty(tester);
      await shootWith(
        tester,
        'onboarding_v2_safari_setup_phone',
        StartFamilyScreen(
          initialTimeZone: 'America/Chicago',
          hub: freshHub,
          setupCode: 'ABCD-EFGH',
          hubDevice: freshHub.device,
          web: iPhoneSafari,
          browser: true,
        ),
        state: state,
        size: _tall,
      );
      expect(find.text('Copy link'), findsOneWidget);
      expect(findWords('Den picks up this link there by itself, and starts your family.'), findsOneWidget);
      expect(find.text('ABCD-EFGH'), findsOneWidget, reason: 'the code, if Den asks');
    });
  });

  group('Inviting', () {
    testWidgets('lets them in right away by default; off, a parent approves', (tester) async {
      final state = await demo(tester);
      final pairing = FakePairing(now: demoNow, invite: _message);
      await pumpScreen(
        tester,
        InviteSheet(memberId: _id(state, 'Grandma Rosa'), now: () => demoNow),
        state: state,
        pairing: pairing,
        size: _tall,
      );
      expect(findWords('Let them in right away'), findsOneWidget);
      expect(pairing.invitesLetIn, [true]);
      await matchShot('onboarding_v2_invite_sheet_phone');
      await tester.tap(findWords('Let them in right away'));
      await tester.pumpAndSettle();
      expect(pairing.invitesLetIn, [true, false]);
    });

    testWidgets('Open Den on your computer: your own link, nothing to scan or approve', (tester) async {
      final state = await demo(tester);
      final pairing = FakePairing(now: demoNow, invite: _message);
      await shootWith(
        tester,
        'onboarding_v2_computer_link_phone',
        ComputerLinkScreen(now: () => demoNow),
        state: state,
        pairing: pairing,
        size: _tall,
        pushed: true,
      );
      expect(find.text('den.example.com/#/join/maple-river-canoe-tiger'), findsOneWidget);
      expect(pairing.invitesLetIn, [true]);
      expect(find.text('Show a code on the computer instead'), findsOneWidget);
    });
  });

  group('The parents hear of it', () {
    testWidgets("Needs you: Grandma Rosa joined; Got it, or That wasn't Grandma Rosa", (tester) async {
      final state = await _rosaJoined(tester);
      await shootWith(
        tester,
        'onboarding_v2_needs_invited_phone',
        FamilyScreen(selected: _id(state, 'Maya')),
        state: state,
        pairing: FakePairing(now: demoNow),
        pushed: true,
      );
      expect(findWords('Grandma Rosa joined on an iPhone'), findsOneWidget);
      expect(findWords('With your invite, today'), findsOneWidget);
      await _tapAndWait(tester, find.text("That wasn't Grandma Rosa"));
      final device = state.den.devices.firstWhere((d) => d.name == "Grandma Rosa's iPhone");
      expect(device.revoked, isTrue);
      expect(state.den.inviteKey(inviteOf(device)!.invite)!.key, isNull, reason: 'the key that let it in is taken away');
      expect(findWords("We removed Grandma Rosa's iPhone. Grandma Rosa needs a new invite."), findsOneWidget);
    });

    testWidgets('night', (tester) async {
      final state = await _rosaJoined(tester);
      await shootWith(
        tester,
        'onboarding_v2_needs_invited_phone_night',
        FamilyScreen(selected: _id(state, 'Maya')),
        state: state,
        pairing: FakePairing(now: demoNow),
        pushed: true,
        night: true,
      );
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(findWords("Grandma Rosa's iPhone stays in the family"), findsOneWidget);
      expect(state.seen('invited:${state.den.devices.firstWhere((d) => d.name == "Grandma Rosa's iPhone").id}'), isTrue);
    });

    testWidgets('History says how it got in', (tester) async {
      final state = await _rosaJoined(tester);
      final join = state.den.history().firstWhere((h) => h.type == RecordType.device && h.actorName == "Grandma Rosa's iPhone");
      final line = historyLine(state, join);
      expect('${join.actorName} ${line.verb} ${line.title}', "Grandma Rosa's iPhone joined with Alex's invite");
      final made = state.den.history().firstWhere((h) => h.type == RecordType.inviteKey);
      final invited = historyLine(state, made);
      expect('${made.actorName} ${invited.verb} ${invited.title}', 'Alex invited Grandma Rosa');
    });
  });

  testWidgets('The setup link, followed with no family, lands on Start with its code and hub', (tester) async {
    final state = await empty(tester);
    final router = buildRouter(state);
    await loadFonts();
    await tester.pumpWidget(DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router)));
    await tester.pumpAndSettle();
    router.go('/setup/ABCD-EFGH/h7q2kx4m9pa3tbv6');
    await tester.pumpAndSettle();
    final at = router.routerDelegate.currentConfiguration.uri;
    expect(at.path, '/welcome/start');
    expect(at.queryParameters, {'setup': 'ABCD-EFGH', 'hub': 'h7q2kx4m9pa3tbv6'});
  });
}
