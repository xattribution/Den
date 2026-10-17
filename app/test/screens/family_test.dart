import 'package:den_app/design/parts/family_pattern_pad.dart';
import 'package:den_app/design/parts/family_pin_pad.dart';
import 'package:den_app/net/pairing.dart';
import 'package:den_app/screens/family/device_screen.dart';
import 'package:den_app/screens/family/family_screen.dart';
import 'package:den_app/screens/family/member_editor.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

void main() {
  final leo = const PendingJoin(deviceId: 'LEOIPAD', deviceName: "Leo's iPad", kind: DeviceKind.tablet, words: ['maple', 'river', 'candle']);

  testWidgets('Family, phone, day', (tester) async {
    final state = await demo(tester);
    await shootWith(tester, 'family_phone', const FamilyScreen(), state: state);
  });

  testWidgets('Family with a device waiting, phone, night', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_pending_phone_night',
      const FamilyScreen(),
      state: state,
      night: true,
      pairing: FakePairing(now: demoNow, pending: [leo]),
    );
  });

  testWidgets('Family, tablet', (tester) async {
    final state = await demo(tester);
    await shootWith(tester, 'family_tablet', const FamilyScreen(), state: state, size: tablet, pairing: FakePairing(now: demoNow, pending: [leo]));
  });

  testWidgets('Approving asks whose device it is', (tester) async {
    final state = await demo(tester);
    await pumpScreen(tester, const FamilyScreen(), state: state, pairing: FakePairing(now: demoNow, pending: [leo]));
    await tester.tap(find.text("Approve Leo's iPad"));
    await tester.pumpAndSettle();
    await matchShot('family_approve_sheet_phone');
  });

  testWidgets('A kid, phone', (tester) async {
    final state = await demo(tester);
    final kid = kidOf(state);
    await shootWith(tester, 'family_member_kid_phone', MemberEditor(memberId: kid.id), state: state);
  });

  testWidgets('A kid, scrolled to sign-in and privacy, night', (tester) async {
    final state = await demo(tester);
    final kid = kidOf(state);
    await pumpScreen(tester, MemberEditor(memberId: kid.id), state: state, night: true);
    await tester.drag(find.byType(ListView).first, const Offset(0, -900));
    await tester.pumpAndSettle();
    await matchShot('family_member_kid_lower_phone_night');
  });

  testWidgets('A parent, tablet', (tester) async {
    final state = await demo(tester);
    await shootWith(tester, 'family_member_parent_tablet', MemberEditor(memberId: parentOf(state).id), state: state, size: tablet);
  });

  testWidgets('Add person, phone', (tester) async {
    final state = await demo(tester);
    await shootWith(tester, 'family_member_new_phone', const MemberEditor(), state: state);
  });

  testWidgets('A device, phone', (tester) async {
    final state = await demo(tester);
    final device = state.den.devices.firstWhere(
      (d) => d.mode == DeviceMode.shared,
      orElse: () => state.den.thisDevice!,
    );
    await shootWith(tester, 'family_device_phone', DeviceScreen(deviceId: device.id), state: state);
  });

  testWidgets('Add a device, phone', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_add_device_phone',
      AddDeviceScreen(now: () => demoNow),
      state: state,
      pairing: FakePairing(now: demoNow),
    );
  });

  testWidgets('Add a device, tablet, night', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'family_add_device_tablet_night',
      AddDeviceScreen(now: () => demoNow),
      state: state,
      size: tablet,
      night: true,
      pairing: FakePairing(now: demoNow),
    );
  });

  testWidgets('Add a device without a hub', (tester) async {
    final state = await demo(tester);
    await shootWith(tester, 'family_add_device_no_hub_phone', const AddDeviceScreen(), state: state);
    expect(find.text(LocalOnlyPairing.message), findsOneWidget);
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
