import 'package:den_app/app/app_state.dart';
import 'package:den_app/features/family/family.dart';
import 'package:den_app/features/family/screens/family_screen.dart';
import 'package:den_app/features/settings/screens/family_settings_screen.dart';
import 'package:den_app/features/today/screens/today_screen.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

const Size _tall = Size(390, 2000);
const int _day = 86400000;

String _id(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;

/// A device that joins [den]'s family and is approved, for [member] or as [mode].
Future<Den> _join(Den den, {String? member, DeviceMode mode = DeviceMode.personal, String name = 'Phone'}) async {
  final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
  await d.requestJoin(
    familyId: den.familyId!,
    founderPubkey: den.founderPubkey!,
    deviceName: name,
    kind: mode == DeviceMode.hub ? DeviceKind.hub : DeviceKind.phone,
    mode: mode,
    memberId: member,
  );
  await den.ingest(d.changesSince(const {}));
  await den.approveDevice(d.deviceId, member: member, mode: mode);
  await d.ingest(den.changesSince(const {}, spaces: den.spacesForDevice(d.deviceId)));
  return d;
}

/// The demo family on Alex's phone, the family's only parent device, before Alex saved
/// recovery words; with a hub in the closet when [hub].
Future<AppState> _alone(WidgetTester tester, {bool hub = false}) => real(tester, () async {
      final den = await createDemoFamily(now: demoNow);
      await den.setRecoveryKey(den.actor!.id, null);
      if (hub) await _join(den, mode: DeviceMode.hub, name: 'Closet hub');
      return AppState(den);
    });

/// Taps on the real clock, so the engine can stretch and write what the tap saves.
Future<void> _tapAndWait(WidgetTester tester, Finder finder, {int ms = 3000}) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(Duration(milliseconds: ms));
  });
  await tester.pumpAndSettle();
}

void main() {
  group('when Den asks a parent to save their recovery words', () {
    testWidgets('until they have, or another parent has a device of their own', (tester) async {
      final state = await _alone(tester);
      final den = state.den;
      final now = den.now();
      expect(RecoveryReminder.parentsWithOwnDevice(den), 1);
      expect(RecoveryReminder.due(state, now: now), isTrue);

      // A device of Grandma's or a shared screen doesn't let anyone back in.
      await real(tester, () async {
        await _join(den, member: _id(den, 'Grandma Rosa'));
        await _join(den, mode: DeviceMode.shared, name: 'Kitchen wall');
      });
      expect(RecoveryReminder.due(state, now: now), isTrue);

      // Priya's own phone does: either parent can let the other back in.
      final priyas = await real(tester, () => _join(den, member: _id(den, 'Priya'), name: "Priya's phone"));
      expect(RecoveryReminder.parentsWithOwnDevice(den), 2);
      expect(RecoveryReminder.due(state, now: now), isFalse);
      expect(RecoveryReminder.due(AppState(priyas), now: now), isFalse);
      // Removed, it no longer counts.
      await real(tester, () => den.revokeDevice(priyas.deviceId));
      expect(RecoveryReminder.due(state, now: now), isTrue);

      // Saved words end it.
      await real(tester, () async => den.setRecoveryKey(den.actor!.id, (await RecoveryKey.generate()).publicKey));
      expect(RecoveryReminder.due(state, now: now), isFalse);
    });

    testWidgets('only on a parent\'s own device', (tester) async {
      final state = await _alone(tester);
      final den = state.den;
      final (display, maya) = await real(tester, () async {
        final display = await _join(den, mode: DeviceMode.shared, name: 'Kitchen wall');
        final maya = await _join(den, member: _id(den, 'Maya'), name: "Maya's phone");
        return (display, maya);
      });
      display.actAs(_id(display, 'Alex'));
      expect(RecoveryReminder.due(AppState(display), now: den.now()), isFalse, reason: 'a shared screen makes no trust decision');
      display.actAs(null);
      expect(RecoveryReminder.due(AppState(maya), now: den.now()), isFalse);
    });

    testWidgets('Remind me later hides it from Needs you for 3 days, never for good, and never in Settings', (tester) async {
      final state = await _alone(tester);
      final now = state.den.now();
      state.snooze(RecoveryReminder.snoozeKey(state.me!.id), now + 3 * _day);
      expect(RecoveryReminder.due(state, now: now), isFalse);
      expect(RecoveryReminder.due(state, now: now + 3 * _day - 1), isFalse);
      expect(RecoveryReminder.due(state, now: now + 3 * _day), isTrue);
      expect(RecoveryReminder.due(state), isTrue, reason: 'Settings shows it all along');
    });
  });

  group('the card', () {
    testWidgets('on Today: Save your recovery words, and Remind me later says when it comes back', (tester) async {
      final state = await _alone(tester);
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall);
      expect(findWords('Save your recovery words'), findsOneWidget);
      expect(findWords("If this phone is lost, they're the only way back in."), findsOneWidget);
      expect(find.text('Save them'), findsOneWidget);
      await matchShot('today_recovery_words_phone');
      await tester.tap(find.text('Remind me later'));
      await tester.pumpAndSettle();
      expect(findWords('Den will ask again in 3 days'), findsOneWidget);
      expect(state.snoozedUntil(RecoveryReminder.snoozeKey(state.me!.id)), state.den.now() + 3 * _day);
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall);
      expect(findWords('Save your recovery words'), findsNothing);
    });

    testWidgets('on Today, night', (tester) async {
      final state = await _alone(tester);
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall, night: true);
      await matchShot('today_recovery_words_phone_night');
    });

    testWidgets('at 200 % text the buttons go under the words', (tester) async {
      final state = await _alone(tester);
      withTextScale(tester, 2);
      await pumpScreen(tester, const TodayScreen(), state: state, size: const Size(390, 3000));
      await matchShot('today_recovery_words_phone_200');
    });

    testWidgets('Save them shows the twelve words, and saving them settles it in place', (tester) async {
      final state = await _alone(tester);
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall);
      await tester.tap(find.text('Save them'));
      await tester.pumpAndSettle();
      expect(findWords('Save these 12 words'), findsOneWidget);
      await _tapAndWait(tester, find.text('I wrote them down'));
      expect(recoveryKeyOf(state.den.member(state.me!.id)!), isNotNull);
      expect(findWords('Your recovery words are saved. Keep them safe.'), findsOneWidget);
      expect(find.text('Save them'), findsNothing);
    });

    testWidgets('in Family, at the top of Needs you', (tester) async {
      final state = await _alone(tester);
      await shootWith(tester, 'family_recovery_words_phone', FamilyScreen(selected: state.me!.id), state: state, pushed: true);
      expect(find.text('Needs you'), findsOneWidget);
      expect(findWords('Save your recovery words'), findsOneWidget);
      await tester.tap(find.text('Remind me later'));
      await tester.pumpAndSettle();
      expect(findWords('Den will ask again in 3 days'), findsOneWidget);
    });

    testWidgets('in Settings, Family: beside the hub\'s help, even while Needs you puts it off', (tester) async {
      final state = await _alone(tester, hub: true);
      state.snooze(RecoveryReminder.snoozeKey(state.me!.id), state.den.now() + 3 * _day);
      await shootWith(tester, 'settings_family_recovery_words_phone', const FamilySettingsScreen(), state: state, size: _tall, pushed: true);
      expect(findWords('Save your recovery words'), findsOneWidget);
      expect(findWords('Let the hub help us get back in'), findsOneWidget);
      expect(find.text('Remind me later'), findsNothing, reason: 'Settings is where it stays');
    });

    testWidgets('not once the words are saved', (tester) async {
      final state = await demo(tester);
      await pumpScreen(tester, const FamilySettingsScreen(), state: state, size: _tall, pushed: true);
      expect(findWords('Save your recovery words'), findsNothing);
      await pumpScreen(tester, const TodayScreen(), state: state, size: _tall);
      expect(findWords('Save your recovery words'), findsNothing);
    });
  });
}
