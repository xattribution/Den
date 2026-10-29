import 'dart:convert';

import 'package:den_app/app/app_state.dart';
import 'package:den_app/design/pickers/pin_pad.dart';
import 'package:den_app/features/advanced/screens/history_screen.dart';
import 'package:den_app/features/shared_screens/screens/kid_screen.dart';
import 'package:den_app/features/shared_screens/state/sign_in_actions.dart';
import 'package:den_app/features/shared_screens/state/sign_in_guard.dart';
import 'package:den_app/features/shared_screens/widgets/sign_in.dart';
import 'package:den_app/features/today/screens/today_screen.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// Alex's phone and the kitchen display it approved, each with the family space.
Future<(Den, Den)> _phoneAndDisplay() async {
  final phone = await createDemoFamily(now: demoNow);
  final display = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
  await display.requestJoin(
    familyId: phone.familyId!,
    founderPubkey: phone.founderPubkey!,
    deviceName: 'Kitchen wall',
    kind: DeviceKind.display,
    mode: DeviceMode.shared,
  );
  await phone.ingest(display.changesSince(phone.versionVector));
  await phone.approveDevice(display.deviceId, mode: DeviceMode.shared);
  await display.ingest(phone.changesSince(display.versionVector, spaces: phone.spacesForDevice(display.deviceId)));
  return (phone, display);
}

String _id(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;

/// Types [pin] on the pad on the real clock, so the engine can check it, then lets the sheet
/// catch up.
Future<void> _type(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.descendant(of: find.byType(PinPad), matching: find.bySemanticsLabel(d)));
    await tester.pump();
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
  await tester.pumpAndSettle();
}

/// The display's own sheet: "Who's using Den?", opened from a button.
Future<void> _openWho(WidgetTester tester, AppState state) async {
  await pumpScreen(
    tester,
    Builder(
      builder: (context) => Center(
        child: FilledButton(onPressed: () => showWhoSheet(context), child: const Text('Open')),
      ),
    ),
    state: state,
    size: tablet,
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  group('the wait after a wrong try', () {
    test('20 seconds after each wrong one, the same every time; a right one starts over', () {
      var now = 1000000;
      final kept = <String>[];
      final guard = SignInGuard(now: () => now, onChange: kept.add);
      expect(guard.left('alex'), Duration.zero);
      expect(guard.failed('alex'), 1);
      expect(guard.left('alex'), const Duration(seconds: 20));
      expect(guard.left('leo'), Duration.zero, reason: 'one person at a time');
      now += 5000;
      expect(guard.left('alex'), const Duration(seconds: 15));
      now += 15000;
      expect(guard.left('alex'), Duration.zero);
      for (var i = 2; i <= 12; i++) {
        expect(guard.failed('alex'), i);
        expect(guard.left('alex'), const Duration(seconds: 20), reason: 'no lockout, however many');
        now += 20000;
      }
      now -= 3600000;
      expect(guard.left('alex'), const Duration(seconds: 20), reason: 'a clock set back never makes it longer');
      final again = SignInGuard.fromJson(kept.last, now: () => now);
      expect(again.wrong('alex'), 12, reason: 'restarting Den keeps the count');
      guard.succeeded('alex');
      expect([guard.wrong('alex'), guard.left('alex')], [0, Duration.zero]);
      expect(SignInGuard.fromJson('{"alex": "no"}', now: () => now).wrong('alex'), 0);
      expect(SignInGuard.fromJson('not json', now: () => now).wrong('alex'), 0);
    });

    test('said plainly, rounded up', () {
      expect(tryAgainIn(const Duration(seconds: 20)), 'Try again in 20 seconds');
      expect(tryAgainIn(const Duration(milliseconds: 14200)), 'Try again in 15 seconds');
      expect(tryAgainIn(const Duration(milliseconds: 400)), 'Try again in 1 second');
    });

    testWidgets('restarting Den keeps the wait', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final den = await real(tester, () async => (await _phoneAndDisplay()).$2);
      final alex = _id(den, 'Alex');
      final first = (await tester.runAsync(() => AppState.load(den)))!;
      await tester.runAsync(() async {
        expect((await SignInActions(den, first.signInGuard).verify(alex, '1111')).wait, const Duration(seconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final restarted = (await tester.runAsync(() => AppState.load(den)))!;
      expect(restarted.signInGuard.left(alex), const Duration(seconds: 20));
      final check = (await tester.runAsync(() => SignInActions(den, restarted.signInGuard).verify(alex, demoSignIns['Alex']!)))!;
      expect(check.ok, isFalse, reason: 'while it waits, not even the right PIN is checked');
    });
  });

  group('signing in on a shared screen', () {
    testWidgets('a wrong PIN: the pad waits 20 seconds and says so, in ink', (tester) async {
      final den = await real(tester, () async => (await _phoneAndDisplay()).$2);
      await _openWho(tester, AppState(den, wall: true));
      await tester.tap(find.text('Alex'));
      await tester.pumpAndSettle();
      await _type(tester, '1111');
      expect(findWords("That's not Alex's PIN. Try again in 20 seconds"), findsOneWidget);
      final key = find.ancestor(of: find.descendant(of: find.byType(PinPad), matching: find.text('2')), matching: find.byType(InkWell));
      expect(tester.widget<InkWell>(key).onTap, isNull, reason: 'the keys wait too');
      await matchShot('sign_in_wait_tablet');
    });

    testWidgets('someone already waiting sees how long, and nothing else', (tester) async {
      final den = await real(tester, () async => (await _phoneAndDisplay()).$2);
      final alex = _id(den, 'Alex');
      final state = AppState(den, wall: true, signInTries: jsonEncode({alex: [1, demoNow.millisecondsSinceEpoch - 8000]}));
      await _openWho(tester, state);
      await tester.tap(find.text('Alex'));
      await tester.pumpAndSettle();
      expect(findWords('Try again in 12 seconds'), findsOneWidget);
    });

    testWidgets('handed a parent\'s phone, a wrong PIN waits too', (tester) async {
      final state = await demo(tester);
      final leo = state.den.members.firstWhere((m) => m.name == 'Leo');
      await pumpScreen(tester, KidScreen(memberId: leo.id, handed: true), state: state);
      await tester.tap(find.text('Grown-ups'));
      await tester.pumpAndSettle();
      await _type(tester, '0000');
      expect(findWords("That's not Alex's PIN. Try again in 20 seconds"), findsOneWidget);
    });

    testWidgets('the tenth wrong try in a row tells the parents, on their own phones and in History', (tester) async {
      final (phone, display) = await real(tester, _phoneAndDisplay);
      final priya = _id(display, 'Priya');
      // Nine wrong tries, the last a minute ago: the wait is over, the count isn't.
      final state = AppState(display, wall: true, signInTries: jsonEncode({priya: [9, demoNow.millisecondsSinceEpoch - 60000]}));
      await tester.runAsync(() async {
        final check = await SignInActions(display, state.signInGuard).verify(priya, '0000');
        expect([check.ok, check.wait], [false, SignInGuard.wait]);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final told = display.signInTries.single;
      expect([told.member, told.tries, told.device], [priya, 10, display.deviceId]);
      await real(tester, () => phone.ingest(display.changesSince(phone.versionVector)));

      final parent = AppState(phone);
      await pumpScreen(tester, const TodayScreen(), state: parent, size: const Size(390, 2400));
      expect(findWords("Someone tried Priya's PIN on Kitchen wall 10 times"), findsOneWidget);
      expect(findWords('Today, 8:00 AM'), findsOneWidget);
      await matchShot('today_sign_in_tries_phone');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Got it'));
      await tester.pumpAndSettle();
      expect(findWords("Someone tried Priya's PIN on Kitchen wall 10 times"), findsNothing);
      expect(parent.seen('tries:${told.id}'), isTrue);

      await pumpScreen(tester, const HistoryScreen(), state: parent, pushed: true);
      expect(find.bySemanticsLabel(RegExp("^Kitchen wall counted 10 wrong tries at Priya's PIN")), findsOneWidget);
    });
  });
}
