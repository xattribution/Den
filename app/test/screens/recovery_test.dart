import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/features/advanced/words/history_words.dart';
import 'package:den_app/features/family/family.dart';
import 'package:den_app/features/family/screens/family_screen.dart';
import 'package:den_app/features/onboarding/screens/recover_screen.dart';
import 'package:den_app/features/onboarding/screens/recovery_words_screen.dart';
import 'package:den_app/features/settings/screens/family_settings_screen.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_app/platform/web/web_app.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show RecoveryWords;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// BIP-39's test phrase for 9e885d952ad362caeb4efe34a8e91bd2: real words with a right checksum,
/// so screenshots stay the same.
const _words = ['scheme', 'spot', 'photo', 'card', 'baby', 'mountain', 'device', 'kick', 'cradle', 'pact', 'join', 'borrow'];

const Size _tall = Size(390, 2000);

String _id(AppState state, String name) => state.den.members.firstWhere((m) => m.name == name).id;

/// A device clock a minute after the demo family's, as a phone's would read.
int _later() => demoNow.millisecondsSinceEpoch + 60000;

/// The new phone's clock, later still: it comes after everything the family wrote.
int _newer() => demoNow.millisecondsSinceEpoch + 5 * 60000;

/// Whose words Den found, answering at once.
class FakeRecoverySession extends RecoverySession {
  FakeRecoverySession({this.byHub = false});

  @override
  final bool byHub;
  bool confirmed = false;
  bool cancelled = false;

  @override
  String get memberName => 'Alex';

  @override
  Marker? get marker => Marker.sky;

  @override
  String? get picture => 'dog';

  @override
  String? get familyName => 'Carter family';

  @override
  Future<JoinTicket> confirm() async {
    confirmed = true;
    return const JoinTicket(familyId: 'FAMILY', familyName: 'Carter family');
  }

  @override
  Future<void> cancel() async => cancelled = true;
}

/// A new phone let in as [member] with [key], its recovery change ingested by [into] as every
/// device of the family receives it.
Future<Den> _recover(Den into, String member, RecoveryKey key, {String name = "Priya's new iPhone"}) async {
  final phone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: _newer);
  final proof = await key.prove(
    family: into.familyId!,
    kind: RecoveryKind.words,
    member: member,
    devicePubkey: phone.keys.pubkey,
    expires: _newer() + 15 * 60000,
  );
  await phone.requestRecovery(
    familyId: into.familyId!,
    founderPubkey: into.founderPubkey!,
    deviceName: name,
    kind: DeviceKind.phone,
    proof: proof,
  );
  await into.ingest(phone.changesSince(const {}));
  return phone;
}

/// The demo family on Alex's phone, after Priya lost hers and let a new one in with her words;
/// that phone then let in devices named [letIn] as Priya's, each through the one before.
Future<AppState> _priyaRecovered(WidgetTester tester, {List<String> letIn = const []}) => real(tester, () async {
      final state = await demoState();
      final den = state.den;
      final priya = _id(state, 'Priya');
      // Priya set up her words on her own phone, which she then lost.
      final old = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: _later);
      await old.requestJoin(
        familyId: den.familyId!,
        founderPubkey: den.founderPubkey!,
        deviceName: "Priya's iPhone",
        kind: DeviceKind.phone,
        memberId: priya,
      );
      await den.ingest(old.changesSince(const {}));
      await den.approveDevice(old.deviceId, member: priya, mode: DeviceMode.personal);
      await old.ingest(den.changesSince(const {}, spaces: den.spacesForDevice(old.deviceId)));
      final key = await RecoveryWords.key(_words);
      await old.setRecoveryKey(priya, key.publicKey);
      await den.ingest(old.changesSince(den.versionVector));
      var approver = await _recover(den, priya, key);
      for (final name in letIn) {
        await approver.ingest(den.changesSince(const {}, spaces: den.spacesForDevice(approver.deviceId)));
        final next = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: _newer);
        await next.requestJoin(
          familyId: den.familyId!,
          founderPubkey: den.founderPubkey!,
          deviceName: name,
          kind: DeviceKind.tablet,
          memberId: priya,
        );
        await approver.ingest(next.changesSince(const {}));
        await approver.approveDevice(next.deviceId, member: priya, mode: DeviceMode.personal);
        await den.ingest(approver.changesSince(const {}));
        approver = next;
      }
      return state;
    });

/// Alex's new phone, let in with Alex's words after the old one was lost: the family as it
/// sees it once it synced.
Future<AppState> _alexRecovered(WidgetTester tester) => real(tester, () async {
      final old = (await demoState()).den;
      final alex = old.actor!.id;
      final key = await RecoveryWords.key(_words);
      await old.setRecoveryKey(alex, key.publicKey);
      final phone = await _recover(old, alex, key, name: "Alex's new iPhone");
      await phone.ingest(old.changesSince(const {}, spaces: old.spacesForDevice(phone.deviceId)));
      return AppState(phone);
    });

/// The demo family on Alex's phone before Alex saved recovery words.
Future<AppState> _noWords(WidgetTester tester) => real(tester, () async {
      final state = await demoState();
      await state.den.setRecoveryKey(state.den.actor!.id, null);
      return state;
    });

/// The demo family with a hub in the closet, approved by Alex's phone.
Future<AppState> _withHub(WidgetTester tester) => real(tester, () async {
      final state = await demoState();
      final den = state.den;
      final hub = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: _later);
      await hub.requestJoin(
        familyId: den.familyId!,
        founderPubkey: den.founderPubkey!,
        deviceName: 'Closet hub',
        kind: DeviceKind.hub,
        mode: DeviceMode.hub,
      );
      await den.ingest(hub.changesSince(const {}));
      await den.approveDevice(hub.deviceId, mode: DeviceMode.hub);
      return state;
    });

Future<void> _tapAndWait(WidgetTester tester, Finder finder, {int ms = 400}) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(Duration(milliseconds: ms));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

Future<GoRouter> _routed(WidgetTester tester, AppState state, String location, {PairingService? pairing}) async {
  final router = buildRouter(state);
  await loadFonts();
  tester.view.physicalSize = _tall;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp.router(
        theme: denTheme(DenColors.day),
        routerConfig: router,
        builder: pairing == null ? null : (context, child) => PairingScope(service: pairing, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  router.go(location);
  await tester.pumpAndSettle();
  return router;
}

void main() {
  test('the screenshots\' words are a real phrase', () => expect(RecoveryWords.valid(_words), isTrue));

  group('Setting up the words', () {
    testWidgets('right after starting a family, phone', (tester) async {
      final state = await demo(tester);
      await shootWith(tester, 'recovery_words_setup_phone', const RecoveryWordsScreen(words: _words), state: state);
      expect(find.text('Save to Passwords'), findsOneWidget);
      expect(find.text('I wrote them down'), findsOneWidget);
      expect(find.text('mountain'), findsOneWidget);
    });

    testWidgets('night', (tester) async {
      final state = await demo(tester);
      await shootWith(tester, 'recovery_words_setup_phone_night', const RecoveryWordsScreen(words: _words), state: state, night: true);
    });

    testWidgets('at 200 % text the words go one to a line', (tester) async {
      final state = await demo(tester);
      withTextScale(tester, 2);
      await shootWith(tester, 'recovery_words_setup_phone_200', const RecoveryWordsScreen(words: _words), state: state, size: const Size(390, 2400));
    });

    testWidgets('I wrote them down saves the key their words stretch to, then Add people', (tester) async {
      final state = await _noWords(tester);
      final router = await _routed(tester, state, '/welcome/words');
      expect(findWords('Save these 12 words'), findsOneWidget);
      await _tapAndWait(tester, find.text('I wrote them down'), ms: 3000);
      final me = state.den.member(state.me!.id)!;
      expect(recoveryKeyOf(me), isNotNull);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/welcome/people');
      expect(findWords('Add people'), findsOneWidget);
    });

    testWidgets('a new family goes from Create family to the words, and Not now moves on', (tester) async {
      final state = await empty(tester);
      final router = await _routed(tester, state, '/welcome/start');
      await tester.enterText(find.widgetWithText(TextField, 'The Riveras'), 'The Riveras');
      await tester.enterText(find.widgetWithText(TextField, 'Sam'), 'Sam');
      await tester.tap(find.text('Create family'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(findWords('Save these 12 words'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/welcome/people');
    });
  });

  group('A parent\'s own page', () {
    testWidgets('Recovery words, not set up yet', (tester) async {
      final state = await _noWords(tester);
      await shootWith(tester, 'recovery_section_phone', FamilyScreen(selected: _id(state, 'Alex')), state: state, size: _tall, pushed: true);
      expect(findWords('Recovery words'), findsOneWidget);
      expect(find.text('Make my words'), findsOneWidget);
    });

    testWidgets('not on someone else\'s page', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, FamilyScreen(selected: _id(state, 'Priya')), state: state, size: _tall, pushed: true);
      expect(findWords('Recovery words'), findsNothing);
    });

    testWidgets('Make my words shows twelve, and saving them sets the key', (tester) async {
      final state = await _noWords(tester);
      await pumpScreen(tester, FamilyScreen(selected: _id(state, 'Alex')), state: state, size: _tall, pushed: true);
      await tester.tap(find.text('Make my words'));
      await tester.pumpAndSettle();
      expect(findWords('Save these 12 words'), findsOneWidget);
      await _tapAndWait(tester, find.text('I wrote them down'), ms: 3000);
      expect(recoveryKeyOf(state.den.member(_id(state, 'Alex'))!), isNotNull);
      expect(findWords('Your words are set up'), findsOneWidget);
      // Make new words asks first: the old ones stop working.
      await tester.tap(find.text('Make new words'));
      await tester.pumpAndSettle();
      expect(findWords('Your old words stop working once you save the new ones.'), findsOneWidget);
    });

    testWidgets('after getting back in: Remove your old phone', (tester) async {
      final state = await _alexRecovered(tester);
      await shootWith(tester, 'recovery_section_recovered_phone', FamilyScreen(selected: _id(state, 'Alex')), state: state, size: _tall, pushed: true);
      expect(findWords('Remove your old phone'), findsOneWidget);
      expect(find.text("Alex's phone"), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'Remove').last);
      await tester.pumpAndSettle();
      await _tapAndWait(tester, find.text("Remove Alex's phone"));
      final old = state.den.devices.firstWhere((d) => d.name == "Alex's phone");
      expect(old.revoked, isTrue);
    });
  });

  group('I lost my phone', () {
    testWidgets('the words, phone', (tester) async {
      final state = await empty(tester);
      await pumpScreen(tester, const RecoverScreen(browser: true, web: WebAppInfo(ios: true, standalone: true)), state: state, pushed: true);
      await tester.enterText(find.byType(TextField), _words.take(7).join(' '));
      await tester.pumpAndSettle();
      expect(findWords('7 of 12 words'), findsOneWidget);
      await matchShot('recovery_recover_phone');
    });

    testWidgets('a wrong word, or too few, says so before asking anyone', (tester) async {
      final state = await empty(tester);
      final pairing = FakePairing(now: demoNow, recovery: FakeRecoverySession());
      await pumpScreen(tester, const RecoverScreen(browser: true, web: WebAppInfo(ios: true, standalone: true)), state: state, pairing: pairing);
      await tester.enterText(find.byType(TextField), [..._words.take(11), 'zoo'].join(' '));
      await tester.tap(find.text('Find me'));
      await tester.pumpAndSettle();
      expect(findWords("One of the words isn't right. Check them against where you saved them."), findsOneWidget);
      await tester.enterText(find.byType(TextField), _words.take(5).join(' '));
      await tester.tap(find.text('Find me'));
      await tester.pumpAndSettle();
      expect(findWords("That's 5 of 12 words. Type all of them, in order."), findsOneWidget);
      expect(pairing.recoveriesStarted, isEmpty);
    });

    testWidgets('pasted with numbers and new lines, Den asks whose they are: is this you?', (tester) async {
      final state = await empty(tester);
      final pairing = FakePairing(now: demoNow, recovery: FakeRecoverySession());
      await pumpScreen(tester, const RecoverScreen(browser: true, web: WebAppInfo(ios: true, standalone: true)), state: state, pairing: pairing);
      await tester.enterText(find.byType(TextField), [for (final (i, w) in _words.indexed) '${i + 1}. $w'].join('\n'));
      await tester.tap(find.text('Find me'));
      await tester.pumpAndSettle();
      expect(pairing.recoveriesStarted.single.$2, "Alex's new phone");
      expect(findWords('Is this you?'), findsOneWidget);
      expect(find.text('Yes, let this phone in'), findsOneWidget);
      await matchShot('recovery_recover_who_phone');
      await tester.tap(find.text("That's not me"));
      await tester.pumpAndSettle();
      expect(findWords('Get back in'), findsOneWidget);
    });

    testWidgets('is this you, by the hub, night', (tester) async {
      final state = await empty(tester);
      final pairing = FakePairing(now: demoNow, recovery: FakeRecoverySession(byHub: true));
      await pumpScreen(tester, const RecoverScreen(browser: true, web: WebAppInfo(ios: true, standalone: true), code: 'maple river canoe tiger'), state: state, pairing: pairing, night: true);
      await tester.tap(find.text('Find me'));
      await tester.pumpAndSettle();
      expect(findWords("This phone becomes Alex's. Everyone in the family will see it was let in by the hub's recovery."), findsOneWidget);
      await matchShot('recovery_recover_who_phone_night');
    });

    testWidgets('from the join screen, and from the hub\'s link; yes lets the phone in', (tester) async {
      final state = await empty(tester);
      final session = FakeRecoverySession(byHub: true);
      final pairing = FakePairing(now: demoNow, recovery: session);
      final router = await _routed(tester, state, '/welcome/join', pairing: pairing);
      expect(findWords('I lost my phone'), findsOneWidget);
      router.go('/recover/maple-river-canoe-tiger');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/welcome/recover');
      expect(find.text('maple river canoe tiger'), findsOneWidget);
      await tester.tap(find.text('Find me'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes, let this phone in'));
      await tester.pumpAndSettle();
      expect(session.confirmed, isTrue);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/welcome/waiting');
    });
  });

  group('Let the hub help us get back in', () {
    testWidgets('off, asks what it means, then on', (tester) async {
      final state = await _withHub(tester);
      const key = 'c2VydmVyLXJlY292ZXJ5LWtleS0xMjM0NTY3ODkwYWI';
      final pairing = FakePairing(now: demoNow, recoveryKey: key);
      await pumpScreen(tester, const FamilySettingsScreen(), state: state, size: _tall, pairing: pairing, pushed: true);
      expect(findWords('Let the hub help us get back in'), findsOneWidget);
      await tester.tap(findWords('Let the hub help us get back in'));
      await tester.pumpAndSettle();
      expect(findWords('Turn it on'), findsOneWidget);
      await matchShot('recovery_hub_help_phone');
      await _tapAndWait(tester, find.text('Turn it on'));
      expect(serverRecoveryKeyOf(state.den.family!), key);
      await _tapAndWait(tester, findWords('Let the hub help us get back in'));
      expect(serverRecoveryKeyOf(state.den.family!), isNull, reason: 'off needs no asking: it only takes help away');
    });

    testWidgets('a family without a hub isn\'t offered it', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, const FamilySettingsScreen(), state: state, size: _tall, pushed: true);
      expect(findWords('Let the hub help us get back in'), findsNothing);
    });
  });

  group('Everyone else sees it', () {
    testWidgets('Needs you on another parent\'s phone: OK, or That wasn\'t us', (tester) async {
      final state = await _priyaRecovered(tester);
      await shootWith(tester, 'recovery_needs_family_phone', FamilyScreen(selected: _id(state, 'Maya')), state: state, pairing: FakePairing(now: demoNow), pushed: true);
      expect(findWords("Priya's new iPhone was let in with Priya's recovery words"), findsOneWidget);
      expect(find.text("That wasn't us"), findsOneWidget);
      await _tapAndWait(tester, find.text("That wasn't us"));
      expect(state.den.devices.firstWhere((d) => d.name == "Priya's new iPhone").revoked, isTrue);
      expect(
        findWords("We removed Priya's new iPhone and turned off the words it used. Priya needs new recovery words."),
        findsOneWidget,
      );
      // The words that let it in let nobody in now.
      expect(recoveryKeyOf(state.den.member(_id(state, 'Priya'))!), isNull);
      expect(find.text('Remove them too'), findsNothing);
    });

    testWidgets('That wasn\'t us names the devices the phone let in, and removes them too', (tester) async {
      final state = await _priyaRecovered(tester, letIn: const ["Priya's iPad", "Priya's laptop"]);
      await pumpScreen(tester, FamilyScreen(selected: _id(state, 'Maya')), state: state, size: _tall, pairing: FakePairing(now: demoNow), pushed: true);
      await _tapAndWait(tester, find.text("That wasn't us"));
      expect(findWords("It also let in Priya's iPad and Priya's laptop"), findsOneWidget);
      await _tapAndWait(tester, find.text('Remove them too'));
      for (final name in ["Priya's new iPhone", "Priya's iPad", "Priya's laptop"]) {
        expect(state.den.devices.firstWhere((d) => d.name == name).revoked, isTrue, reason: name);
      }
      expect(
        findWords("We removed Priya's new iPhone and turned off the words it used. Priya needs new recovery words. "
            "Priya's iPad and Priya's laptop were removed too"),
        findsOneWidget,
      );
    });

    testWidgets('History says how it got in', (tester) async {
      final state = await _priyaRecovered(tester);
      final entry = state.den.history().firstWhere((h) => h.type == RecordType.device && h.actorName == "Priya's new iPhone");
      final line = historyLine(state, entry);
      expect('${entry.actorName} ${line.verb} ${line.title}', "Priya's new iPhone was let in with Priya's recovery words");
      final words = state.den.history().firstWhere((h) => h.type == RecordType.member && h.actorName == 'Priya');
      final set = historyLine(state, words);
      expect('${words.actorName} ${set.verb} ${set.title}', 'Priya set up new recovery words');
      expect(RecoveryLines.when(state, state.den.devices.firstWhere((d) => d.name == "Priya's new iPhone")), 'Oct 16');
    });
  });
}
