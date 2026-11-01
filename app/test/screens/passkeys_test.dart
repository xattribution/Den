
import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/family/screens/family_screen.dart';
import 'package:den_app/features/family/state/passkeys.dart';
import 'package:den_app/features/onboarding/screens/passkey_offer_screen.dart';
import 'package:den_app/features/onboarding/screens/waiting_screen.dart';
import 'package:den_app/features/onboarding/screens/welcome_screen.dart';
import 'package:den_app/platform/sync/hub_client.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_app/platform/web/passkeys.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';
import 'web_onboarding_test.dart' show familyHub;

/// An iPhone's Home Screen app at the family's https address.
const _iPhone = WebAppInfo(
  ios: true,
  iosVersion: (major: 18, minor: 6),
  standalone: true,
  secure: true,
  worker: true,
  push: true,
  share: true,
  ready: true,
  mobile: true,
  passkeys: true,
);

/// Chrome on an Android phone.
const _android = WebAppInfo(secure: true, worker: true, push: true, share: true, ready: true, mobile: true, android: true, passkeys: true);

/// The same iPhone at a plain http address on the home network: no passkeys.
const _iPhoneHttp = WebAppInfo(ios: true, iosVersion: (major: 18, minor: 6), standalone: true, mobile: true);

const _tall = Size(390, 1500);

/// The browser's passkeys, answering [outcome] when a tap opens the sheet.
class _Browser extends PasskeyBrowser {
  _Browser({this.available = true, this.outcome});

  @override
  final bool available;

  @override
  String get host => 'den.example.com';

  @override
  WebAppInfo get info => _iPhone;

  PasskeyOutcome? outcome;
  final List<PasskeyKind> armed = [];
  final List<PasskeyKind> started = [];

  @override
  bool arm(PasskeyKind kind, Map<String, Object?> options) {
    armed.add(kind);
    return true;
  }

  @override
  Future<PasskeyOutcome> start(PasskeyKind kind) {
    started.add(kind);
    return Future.value(outcome ?? const PasskeyRefused('NotAllowedError'));
  }
}

/// The hub's side of a person's passkeys.
class _Source implements PasskeySource {
  _Source({List<PasskeySummary> mine = const [], this.existing = 0}) : _mine = [...mine];

  final List<PasskeySummary> _mine;
  final int existing;
  final List<Map<String, Object?>> registered = [];
  final List<String> removed = [];

  @override
  Future<PasskeyOptions> creationOptions() async => PasskeyOptions(
        options: const {
          'rp': {'id': 'den.example.com', 'name': 'Den'},
          'challenge': 'Y2hhbGxlbmdl',
        },
        expires: DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
        existing: existing,
      );

  @override
  Future<PasskeySummary> register(Map<String, Object?> credential) async {
    registered.add(credential);
    final made = PasskeySummary(id: 'K${registered.length}', madeOn: "Maya's iPhone", made: demoNow.millisecondsSinceEpoch);
    _mine.add(made);
    return made;
  }

  @override
  Future<List<PasskeySummary>> mine() async => [..._mine];

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    _mine.removeWhere((p) => p.id == id);
  }
}

/// Pairing that signs in with a passkey: as [ticket], or refused with [refusal].
class _Pairing extends FakePairing {
  _Pairing({this.refusal, super.recoveryKey, super.status}) : super(now: demoNow);

  final PairingException? refusal;
  final List<Map<String, Object?>> credentials = [];
  final List<String> names = [];
  int optionsAsked = 0;

  @override
  Future<Map<String, Object?>?> passkeySignInOptions() async {
    optionsAsked++;
    return const {'challenge': 'Y2hhbGxlbmdl', 'rpId': 'den.example.com', 'userVerification': 'required'};
  }

  @override
  Future<JoinTicket> signInWithPasskey(
    Map<String, Object?> credential, {
    required String Function(String name) deviceName,
    required DeviceKind kind,
  }) async {
    credentials.add(credential);
    names.add(deviceName('Alex'));
    if (refusal != null) throw refusal!;
    return const JoinTicket(familyId: 'FAMILY', familyName: 'The Carters', admitted: true, passkey: true);
  }
}

/// A hub from before passkeys.
class _OldHub extends _Pairing {
  @override
  Future<Map<String, Object?>?> passkeySignInOptions() async => null;
}

/// Maya's own iPhone, joined and let in by Alex's phone.
Future<AppState> _mayasPhone(WidgetTester tester) => real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      final maya = phone.members.firstWhere((m) => m.name == 'Maya').id;
      final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
      await d.requestJoin(
        familyId: phone.familyId!,
        founderPubkey: phone.founderPubkey!,
        deviceName: "Maya's iPhone",
        kind: DeviceKind.phone,
        memberId: maya,
      );
      await phone.ingest(d.changesSince(const {}));
      await phone.approveDevice(d.deviceId, member: maya, mode: DeviceMode.personal);
      await d.ingest(phone.changesSince(const {}));
      return AppState(d);
    });

/// The hub this test's devices keep their passkeys at.
void _hub(_Source source) {
  final reachable = PasskeyHub.reachable, made = PasskeyHub.source;
  PasskeyHub.reachable = (_) => true;
  PasskeyHub.source = (_) => source;
  addTearDown(() {
    PasskeyHub.reachable = reachable;
    PasskeyHub.source = made;
  });
}

void _browser(PasskeyBrowser browser) {
  final was = PasskeyBrowser.current;
  PasskeyBrowser.current = browser;
  addTearDown(() => PasskeyBrowser.current = was);
}

Future<GoRouter> _welcome(WidgetTester tester, AppState state, _Pairing pairing, _Browser browser, {WebAppInfo web = _iPhone}) async {
  final router = GoRouter(
    initialLocation: '/welcome',
    routes: [
      GoRoute(
        path: '/welcome',
        builder: (_, _) => Scaffold(
          body: SafeArea(child: WelcomeScreen(browser: true, hub: familyHub, web: web, passkeys: browser)),
        ),
        routes: [
          GoRoute(path: 'waiting', builder: (_, _) => const Scaffold(body: Text('Waiting'))),
          GoRoute(path: 'recover', builder: (_, _) => const Scaffold(body: Text('Recovery words'))),
        ],
      ),
    ],
  );
  await loadFonts();
  tester.view.physicalSize = phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    PairingScope(
      service: pairing,
      child: DenScope(
        state: state,
        child: MaterialApp.router(debugShowCheckedModeBanner: false, theme: denTheme(DenColors.day), routerConfig: router),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('Signing back in on the welcome screen', () {
    testWidgets('Sign in with Face ID is the one primary button, armed before the tap, which opens the sheet at once', (tester) async {
      final state = await empty(tester);
      final pairing = _Pairing();
      final browser = _Browser(outcome: const PasskeyAnswer({'id': 'K1'}));
      final router = await _welcome(tester, state, pairing, browser);
      await matchShot('web_welcome_passkey_phone');
      expect(find.text('Sign in with Face ID'), findsOneWidget);
      expect(find.text('Lost your phone? Use your recovery words'), findsOneWidget);
      expect(find.text('Join your family'), findsOneWidget, reason: 'invites stay the way in for someone new');
      expect(browser.armed, [PasskeyKind.get], reason: 'the challenge is in the page before the tap');

      await tester.tap(find.text('Sign in with Face ID'));
      // Straight from the tap, before anything is awaited: Safari opens the sheet only then.
      expect(browser.started, [PasskeyKind.get]);
      await tester.pumpAndSettle();
      expect(pairing.credentials, [
        {'id': 'K1'},
      ]);
      expect(pairing.names, ["Alex's new phone"], reason: '"new iPhone" in Safari on one');
      expect(Pairing.ticket?.passkey, isTrue);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/welcome/waiting');
    });

    testWidgets('a passkey that is nobody\'s here: ask for an invite', (tester) async {
      final state = await empty(tester);
      final pairing = _Pairing(
        refusal: const PairingException(
          "This passkey isn't for anyone in this family. Ask someone in your family for an invite.",
          reason: PairingException.notInFamily,
        ),
      );
      final browser = _Browser(outcome: const PasskeyAnswer({'id': 'K9'}));
      await _welcome(tester, state, pairing, browser);
      await tester.tap(find.text('Sign in with Face ID'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ask someone in your family for an invite'), findsOneWidget);
      expect(browser.armed, hasLength(2), reason: 'a new challenge for the next try');
      await matchShot('web_welcome_passkey_stranger_phone');
    });

    testWidgets('closing the sheet says nothing and gets ready again', (tester) async {
      final state = await empty(tester);
      final pairing = _Pairing();
      final browser = _Browser(outcome: const PasskeyRefused('NotAllowedError'));
      await _welcome(tester, state, pairing, browser);
      await tester.tap(find.text('Sign in with Face ID'));
      await tester.pumpAndSettle();
      expect(pairing.credentials, isEmpty);
      expect(find.textContaining('Try again'), findsNothing);
      expect(browser.armed, hasLength(2));
    });

    testWidgets('Android says fingerprint; plain http at home offers none and says nothing', (tester) async {
      final state = await empty(tester);
      await _welcome(tester, state, _Pairing(), _Browser(), web: _android);
      expect(find.text('Sign in with your fingerprint'), findsOneWidget);
      await matchShot('web_welcome_passkey_android_phone');

      final http = _Browser(available: false);
      await _welcome(tester, await empty(tester), _Pairing(), http, web: _iPhoneHttp);
      expect(find.textContaining('Sign in with'), findsNothing);
      expect(find.text('Lost your phone? Use your recovery words'), findsNothing);
      expect(find.textContaining('passkey'), findsNothing);
      expect(http.armed, isEmpty);
    });

    testWidgets('a hub that offers no passkeys (an older one) gets no button', (tester) async {
      await _welcome(tester, await empty(tester), _OldHub(), _Browser());
      expect(find.textContaining('Sign in with'), findsNothing);
      expect(find.text('Join your family'), findsOneWidget);
    });

    testWidgets('Lost your phone opens the recovery words', (tester) async {
      final router = await _welcome(tester, await empty(tester), _Pairing(), _Browser());
      await tester.tap(find.text('Lost your phone? Use your recovery words'));
      await tester.pumpAndSettle();
      expect(find.text('Recovery words'), findsOneWidget);
      expect(router.canPop(), isTrue, reason: 'pushed, so back returns to the welcome screen');
    });
  });

  group('Right after joining', () {
    testWidgets('a kid on their own iPhone: one tap makes the passkey; a parent lets them back in later', (tester) async {
      final state = await _mayasPhone(tester);
      final source = _Source();
      final browser = _Browser(outcome: const PasskeyAnswer({'id': 'K1'}));
      _hub(source);
      await pumpScreen(tester, PasskeyOfferScreen(source: source, browser: browser, web: _iPhone), state: state);
      await matchShot('onboarding_passkey_offer_phone');
      expect(findWords('Use Face ID to get back in'), findsOneWidget);
      expect(find.textContaining('a parent lets you back in with one tap'), findsOneWidget);
      expect(browser.armed, [PasskeyKind.create]);

      await tester.tap(find.text('Use Face ID'));
      expect(browser.started, [PasskeyKind.create], reason: 'straight from the tap');
      await tester.pumpAndSettle();
      expect(source.registered, hasLength(1));
      expect(findWords('Done. Face ID gets you back in.'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      await matchShot('onboarding_passkey_offer_done_phone');
    });

    testWidgets("a parent's passkey turns on the hub's help, so it lets them straight back in", (tester) async {
      final state = await demo(tester);
      final key = await real(tester, () async => (await RecoveryKey.generate()).publicKey);
      final source = _Source();
      final browser = _Browser(outcome: const PasskeyAnswer({'id': 'K1'}));
      _hub(source);
      await pumpScreen(
        tester,
        PasskeyOfferScreen(source: source, browser: browser, web: _iPhone),
        state: state,
        pairing: _Pairing(recoveryKey: key),
      );
      expect(find.textContaining('lets you straight back in'), findsOneWidget);
      expect(find.textContaining('everyone in the family can see'), findsOneWidget);
      await matchShot('onboarding_passkey_offer_parent_phone');
      expect(serverRecoveryKeyOf(state.den.family!), isNull);
      await tester.runAsync(() async {
        await tester.tap(find.text('Use Face ID'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      expect(source.registered, hasLength(1));
      expect(serverRecoveryKeyOf(state.den.family!), key);
    });

    testWidgets('someone who has one already, or a browser that can\'t, goes straight on', (tester) async {
      final state = await _mayasPhone(tester);
      final router = GoRouter(
        initialLocation: '/welcome/passkey',
        routes: [
          GoRoute(
            path: '/welcome/passkey',
            builder: (_, _) => Scaffold(body: PasskeyOfferScreen(source: _Source(existing: 1), browser: _Browser(), web: _iPhone)),
          ),
          GoRoute(path: '/today', builder: (_, _) => const Scaffold(body: Text('Today'))),
        ],
      );
      _hub(_Source());
      await loadFonts();
      await tester.pumpWidget(DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router)));
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('the waiting screen offers it once a parent lets this phone in, unless a passkey got it in', (tester) async {
      final state = await _mayasPhone(tester);
      _hub(_Source());
      _browser(_Browser());
      Future<String> after(JoinTicket ticket) async {
        final router = GoRouter(
          initialLocation: '/welcome/waiting',
          routes: [
            GoRoute(path: '/welcome/waiting', builder: (_, _) => Scaffold(body: WaitingScreen(ticket: ticket))),
            GoRoute(path: '/welcome/passkey', builder: (_, _) => const Scaffold(body: Text('Offer'))),
            GoRoute(path: '/today', builder: (_, _) => const Scaffold(body: Text('Today'))),
          ],
        );
        await tester.pumpWidget(
          PairingScope(
            service: _Pairing(status: const JoinStatus(JoinState.approved)),
            child: DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router)),
          ),
        );
        await tester.pumpAndSettle();
        return router.routerDelegate.currentConfiguration.uri.path;
      }

      expect(await after(const JoinTicket(familyId: 'F')), '/welcome/passkey');
      expect(await after(const JoinTicket(familyId: 'F', passkey: true)), '/today');
    });
  });

  group('On their own page', () {
    testWidgets("a kid sees Getting back in on their own page, and removes a passkey there", (tester) async {
      final state = await _mayasPhone(tester);
      final source = _Source(mine: [PasskeySummary(id: 'K1', madeOn: "Maya's iPhone", made: demoNow.millisecondsSinceEpoch)]);
      _hub(source);
      _browser(_Browser());
      await pumpScreen(tester, const FamilyScreen(), state: state, size: _tall, pushed: true);
      expect(find.text('Getting back in'), findsOneWidget);
      expect(find.text('Face ID is set up'), findsOneWidget);
      await matchShot('family_passkey_kid_phone');

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(source.removed, ['K1']);
      expect(find.text('Face ID is set up'), findsNothing);
      expect(find.text('Use Face ID'), findsOneWidget);
    });

    testWidgets("a parent's page: passkeys near the recovery words", (tester) async {
      final state = await demo(tester);
      _hub(_Source());
      _browser(_Browser());
      await pumpScreen(tester, const FamilyScreen(), state: state, size: phone, pushed: true);
      await tester.scrollUntilVisible(find.text('Recovery words'), 300, scrollable: find.byType(Scrollable).first);
      final passkeys = tester.getTopLeft(find.text('Getting back in')).dy;
      final words = tester.getTopLeft(find.text('Recovery words')).dy;
      expect(passkeys, lessThan(words));
      expect(find.textContaining('The hub checks it'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Getting back in'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await matchShot('family_passkey_parent_phone');
    });

    testWidgets('nobody else\'s page, and no browser that can\'t', (tester) async {
      final state = await demo(tester);
      _hub(_Source());
      _browser(_Browser(available: false));
      await pumpScreen(tester, const FamilyScreen(), state: state, size: const Size(390, 2400), pushed: true);
      expect(find.text('Getting back in'), findsNothing);
    });
  });

  group('The words', () {
    test('Face ID on an iPhone, a fingerprint or screen lock on Android, a passkey elsewhere', () {
      expect(PasskeyWords.of(_iPhone).signIn, 'Sign in with Face ID');
      expect(PasskeyWords.of(_iPhone).offer, 'Use Face ID to get back in');
      expect(PasskeyWords.of(_android).offer, 'Use your fingerprint or screen lock to get back in');
      expect(PasskeyWords.of(const WebAppInfo(ios: true, ipad: true)).make, 'Use Face ID or Touch ID');
      expect(PasskeyWords.of(const WebAppInfo(secure: true)).signIn, 'Sign in with a passkey');
    });

    test("the page's answers", () {
      expect(PasskeyOutcome.parse('{"credential":{"id":"K1"}}'), isA<PasskeyAnswer>());
      final cancelled = PasskeyOutcome.parse('{"error":"NotAllowedError"}') as PasskeyRefused;
      expect(cancelled.cancelled, isTrue);
      expect((PasskeyOutcome.parse('{"error":"InvalidStateError"}') as PasskeyRefused).alreadyHere, isTrue);
      expect((PasskeyOutcome.parse('nonsense') as PasskeyRefused).reason, 'failed');
    });

    test('a passkey summary from the hub', () {
      final p = PasskeySummary.fromJson({'id': 'K1', 'made_on': "Alex's iPhone", 'made_ms': 1, 'used_ms': 2})!;
      expect(p.madeOn, "Alex's iPhone");
      expect(PasskeySummary.fromJson({'made_on': 'x'}), isNull);
      expect(const HubException('x').code, isNull);
    });
  });
}
