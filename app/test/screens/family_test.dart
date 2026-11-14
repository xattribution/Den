import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/pickers/pattern_pad.dart';
import 'package:den_app/design/pickers/pin_pad.dart';
import 'package:den_app/design/widgets.dart';
import 'package:den_app/features/family/screens/family_screen.dart';
import 'package:den_app/features/family/state/trust_actions.dart';
import 'package:den_app/features/family/widgets/invite_sheet.dart';
import 'package:den_app/features/family/widgets/quick_add_sheet.dart';
import 'package:den_app/features/family/words/oversight.dart';
import 'package:den_app/features/family/words/who.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

String _id(AppState state, String name) => state.den.members.firstWhere((m) => m.name == name).id;

/// A phone asking to join as [name], with the invite a parent sent them.
Future<void> _asking(WidgetTester tester, AppState state, String name, {String? device}) => real(tester, () async {
      final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
      await d.requestJoin(
        familyId: state.den.familyId!,
        founderPubkey: state.den.founderPubkey!,
        deviceName: device ?? "$name's iPhone",
        kind: DeviceKind.phone,
        memberId: _id(state, name),
      );
      await state.den.ingest(d.changesSince(const {}));
    });

/// Taps on the real clock, so the engine can sign what the tap writes, then lets the screen
/// catch up.
Future<void> _tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

final InviteMessage _invite = InviteMessage(
  words: const ['maple', 'river', 'candle', 'tiger'],
  link: Uri.parse('https://den.example.com/#/join/maple-river-candle-tiger'),
  expires: demoNow.add(const Duration(days: 3)).millisecondsSinceEpoch,
  familyName: 'The Carters',
  forName: 'Rosa',
);

const Size _tall = Size(390, 2000);

void main() {
  group('Family, the board', () {
    testWidgets('phone: Needs you, the faces, Maya chosen, and what a teen may do', (tester) async {
      final state = await demo(tester);
      await _asking(tester, state, 'Grandma Rosa');
      await shootWith(tester, 'family_phone', FamilyScreen(selected: _id(state, 'Maya')), state: state, pairing: FakePairing(now: demoNow), pushed: true);
      expect(find.text('Needs you'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(findWords('Can keep things private from parents'), findsOneWidget);
      expect(find.text('Manage points'), findsNothing);
    });

    testWidgets('phone, night', (tester) async {
      final state = await demo(tester);
      await _asking(tester, state, 'Grandma Rosa');
      await shootWith(
        tester,
        'family_phone_night',
        FamilyScreen(selected: _id(state, 'Maya')),
        state: state,
        night: true,
        pairing: FakePairing(now: demoNow), pushed: true);
    });

    testWidgets('a little kid, the whole page', (tester) async {
      final state = await demo(tester);
      await shootWith(tester, 'family_kid_little_phone', FamilyScreen(selected: _id(state, 'Leo')), state: state, size: _tall, pushed: true);
      expect(findWords('Can keep things private from parents'), findsNothing, reason: 'teens only');
      expect(findWords('Can use the AI helper'), findsNothing, reason: 'never a little kid');
      expect(find.text("Leo's devices"), findsOneWidget);
    });

    testWidgets('a grown-up says what they do, in a sentence', (tester) async {
      final state = await demo(tester);
      await shootWith(tester, 'family_grown_up_phone', FamilyScreen(selected: _id(state, 'Grandma Rosa')), state: state, size: _tall, pushed: true);
      expect(findWords("Grandma Rosa adds and changes plans, chores and lists, but doesn't manage people, devices or stars."), findsOneWidget);
    });

    testWidgets('at 200 % text everything wraps', (tester) async {
      final state = await demo(tester);
      withTextScale(tester, 2);
      await shootWith(tester, 'family_phone_200', FamilyScreen(selected: _id(state, 'Maya')), state: state, size: const Size(390, 2600), pushed: true);
    });

    testWidgets('iPad, landscape: the family on the left, the person on the right', (tester) async {
      final state = await demo(tester);
      await _asking(tester, state, 'Grandma Rosa');
      await shootWith(tester, 'family_tablet', FamilyScreen(selected: _id(state, 'Maya')), state: state, size: tablet, pairing: FakePairing(now: demoNow), pushed: true);
    });

    testWidgets('iPad, portrait, night', (tester) async {
      final state = await demo(tester);
      await shootWith(
        tester,
        'family_tablet_portrait_night',
        FamilyScreen(selected: _id(state, 'Leo')),
        state: state,
        size: const Size(834, 1194),
        night: true, pushed: true);
    });

    testWidgets('a kid sees who is in the family, and nothing to change', (tester) async {
      final state = await littleKidTablet(tester);
      await pumpScreen(tester, const FamilyScreen(), state: state, pushed: true);
      expect(find.byType(SwitchLine), findsNothing);
      expect(find.text('Invite someone'), findsNothing);
      expect(find.text('Needs you'), findsNothing);
    });
  });

  group('Family, doing things', () {
    testWidgets('a device asking for someone is let in with one tap, and Undo is right there', (tester) async {
      final state = await demo(tester);
      await _asking(tester, state, 'Grandma Rosa');
      await pumpScreen(tester, const FamilyScreen(), state: state, pairing: FakePairing(now: demoNow), pushed: true);
      await _tapAndWait(tester, find.text('Approve'));
      final device = state.den.devices.firstWhere((d) => d.name == "Grandma Rosa's iPhone");
      expect(device.approved, isTrue);
      expect(device.member, _id(state, 'Grandma Rosa'));
      expect(findWords("Grandma Rosa's iPhone is in the family"), findsOneWidget);
      await matchShot('family_let_in_done_phone');
    });

    testWidgets("That's not her turns the device away", (tester) async {
      final state = await demo(tester);
      await _asking(tester, state, 'Grandma Rosa');
      await pumpScreen(tester, const FamilyScreen(), state: state, pairing: FakePairing(now: demoNow), pushed: true);
      await _tapAndWait(tester, find.text("That's not Grandma Rosa"));
      expect(state.den.devices.firstWhere((d) => d.name == "Grandma Rosa's iPhone").revoked, isTrue);
      expect(find.textContaining('was turned away'), findsOneWidget);
    });

    testWidgets('a switch says what it will do, and saves only on Turn on (B8: just that person)', (tester) async {
      final state = await demo(tester);
      final maya = _id(state, 'Maya');
      await pumpScreen(tester, FamilyScreen(selected: maya), state: state, size: _tall, pushed: true);
      await tester.tap(findWords('Can keep things private from parents'));
      await tester.pumpAndSettle();
      expect(find.textContaining("can't be unseen"), findsOneWidget);
      expect(state.den.family!.parentsSeePrivate(maya), isTrue, reason: 'nothing saves before the yes');
      await matchShot('family_switch_confirm_phone');
      await _tapAndWait(tester, find.text('Turn on'));
      expect(state.den.family!.parentsSeePrivate(maya), isFalse);
      expect(state.den.history().first.diffs.map((d) => d.field), ['oversight.$maya']);
    });

    testWidgets('Can add to lists turns on just that grant', (tester) async {
      final state = await demo(tester);
      final leo = _id(state, 'Leo');
      final before = state.den.member(leo)!.grants;
      await pumpScreen(tester, FamilyScreen(selected: leo), state: state, size: _tall, pushed: true);
      final on = before.contains(Grant.lists);
      await tester.tap(findWords('Can add to lists'));
      await tester.pumpAndSettle();
      await _tapAndWait(tester, find.text(on ? 'Turn off' : 'Turn on'));
      expect(state.den.member(leo)!.grants.contains(Grant.lists), !on);
      expect(state.den.member(leo)!.grants.difference({Grant.lists}), before.difference({Grant.lists}));
    });

    testWidgets('a role change says what it does and waits for a yes', (tester) async {
      final state = await demo(tester);
      final maya = _id(state, 'Maya');
      await pumpScreen(tester, FamilyScreen(selected: maya), state: state, size: _tall, pushed: true);
      await tester.tap(find.text('Who Maya is'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Parent'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Maya will run the family'), findsOneWidget);
      expect(state.den.member(maya)!.role, Role.kid);
      await matchShot('family_role_sheet_phone');
      await _tapAndWait(tester, find.text('Make Maya a parent'));
      expect(state.den.member(maya)!.role, Role.parent);
    });

    testWidgets('removing a device says so in place first', (tester) async {
      final state = await demo(tester);
      final alex = _id(state, 'Alex');
      await _asking(tester, state, 'Alex', device: "Alex's iPad");
      await real(tester, () async {
        final ipad = state.den.devices.firstWhere((d) => d.name == "Alex's iPad");
        await state.den.approveDevice(ipad.id, member: alex);
      });
      await pumpScreen(tester, FamilyScreen(selected: alex), state: state, size: _tall, pushed: true);
      await tester.tap(find.text('Remove').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('stops syncing right away'), findsOneWidget);
      await _tapAndWait(tester, find.text("Remove Alex's iPad"));
      expect(state.den.devices.firstWhere((d) => d.name == "Alex's iPad").revoked, isTrue);
    });

    testWidgets('picture and color', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, FamilyScreen(selected: _id(state, 'Maya')), state: state, pushed: true);
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();
      expect(findWords("Maya's picture"), findsOneWidget);
      await matchShot('family_picture_sheet_phone');
    });
  });

  group('Adding someone', () {
    testWidgets('a name and who they are, then Add: two taps', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, const FamilyScreen(), state: state, pushed: true);
      // Below the parent's own page, which ends with their recovery words.
      await tester.ensureVisible(find.text('Add someone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add someone'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Ava');
      await tester.tap(find.text('9 to 12'));
      await tester.pumpAndSettle();
      await matchShot('family_quick_add_phone');
      await _tapAndWait(tester, find.text('Add Ava'));
      final ava = state.den.members.firstWhere((m) => m.name == 'Ava');
      expect(ava.role, Role.kid);
      expect(ava.tier, Tier.big);
      expect(ava.grants, {Grant.lists}, reason: 'a 9 to 12 starts able to add to lists');
      expect(find.text('Ava'), findsWidgets, reason: 'her page shows next');
    });

    testWidgets('night', (tester) async {
      final state = await demo(tester);
      await shootWith(tester, 'family_quick_add_phone_night', const QuickAddSheet(initialName: 'Priya', initialWho: Who.parent), state: state, night: true);
    });
  });

  group('Inviting', () {
    testWidgets("from a person: their message, the four words, Send and Copy", (tester) async {
      final state = await demo(tester);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpScreen(
        tester,
        SingleChildScrollView(child: InviteSheet(memberId: _id(state, 'Grandma Rosa'), now: () => demoNow)),
        state: state,
        pairing: FakePairing(now: demoNow, invite: _invite),
      );
      expect(find.text('maple river candle tiger'), findsOneWidget);
      expect(find.text('Send invite'), findsOneWidget);
      await matchShot('family_invite_phone');
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied.single, _invite.text);
      expect(findWords('Copied. Paste it into a message to Grandma Rosa.'), findsOneWidget);
      await matchShot('family_invite_copied_phone');
    });

    testWidgets('who is it for, night', (tester) async {
      final state = await demo(tester);
      await shootWith(
        tester,
        'family_invite_choose_phone_night',
        SingleChildScrollView(child: InviteSheet(now: () => demoNow)),
        state: state,
        night: true,
        pairing: FakePairing(now: demoNow, invite: _invite),
      );
    });

    testWidgets('without a hub it says why, and the way out', (tester) async {
      final state = await demo(tester);
      await pumpScreen(
        tester,
        SingleChildScrollView(child: InviteSheet(memberId: _id(state, 'Grandma Rosa'))),
        state: state,
        pairing: FakePairing(now: demoNow),
      );
      expect(find.text(LocalOnlyPairing.message), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('Oversight words', () {
    test('a teen starts able to add lists, events and chores; a nine-year-old lists; younger, nothing', () {
      expect(defaultGrants(Tier.teen), {Grant.lists, Grant.events, Grant.chores});
      expect(defaultGrants(Tier.big), {Grant.lists});
      expect(defaultGrants(Tier.little), isEmpty);
      expect(defaultGrants(Tier.preReader), isEmpty);
    });

    test('switches map onto grants, and Rewards need my OK only ever takes the points grant away', () {
      expect(grantsWith(KidSwitch.plans, true, {Grant.lists}), {Grant.lists, Grant.events, Grant.chores});
      expect(grantsWith(KidSwitch.plans, false, {Grant.lists, Grant.events, Grant.chores}), {Grant.lists});
      expect(grantsWith(KidSwitch.rewardsOk, true, {Grant.points, Grant.lists}), {Grant.lists});
      expect(grantsWith(KidSwitch.rewardsOk, false, {Grant.lists}), {Grant.lists}, reason: 'Manage points is never given');
    });

    testWidgets("a parent turns a kid's reminders off, and gets them instead", (tester) async {
      final state = await demo(tester);
      final kid = state.den.members.firstWhere((m) => m.isKid);
      bool on(KidSwitch s) => kidSwitches(state.den.member(kid.id)!, state.den.family).firstWhere((v) => v.which == s).on;
      expect(on(KidSwitch.reminders), isTrue);
      expect(on(KidSwitch.parentsReminded), isFalse);
      await tester.runAsync(() async {
        await TrustActions(state.den).setKidSwitch(kid, KidSwitch.reminders, false);
        await TrustActions(state.den).setKidSwitch(kid, KidSwitch.parentsReminded, true);
      });
      expect(on(KidSwitch.reminders), isFalse);
      expect(on(KidSwitch.parentsReminded), isTrue);
    });
  });

  testWidgets('Picture pattern pad', (tester) async {
    final state = await demo(tester);
    await pumpScreen(tester, Center(child: PatternPad(onComplete: (_) {})), state: state);
    await tester.tap(find.bySemanticsLabel('Fish'));
    await tester.tap(find.bySemanticsLabel('Cat'));
    await tester.pumpAndSettle();
    await matchShot('family_pattern_pad_phone');
  });

  testWidgets('PIN pad, night', (tester) async {
    final state = await demo(tester);
    await pumpScreen(tester, Center(child: PinPad(onComplete: (_) {})), state: state, night: true);
    await tester.tap(find.bySemanticsLabel('4'));
    await tester.pumpAndSettle();
    await matchShot('family_pin_pad_phone_night');
  });
}
