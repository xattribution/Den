import 'package:den_app/screens/chores/chore_editor.dart';
import 'package:den_app/screens/today/today_screen.dart';
import 'package:den_app/state/app_state.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// What the engine takes only from a parent's own device, or only from whoever may set prices,
/// isn't offered anywhere else.
void main() {
  testWidgets("A parent signed in on a shared screen isn't offered to approve: only their own device can", (tester) async {
    final state = await kitchen(tester);
    final den = state.den;
    final parent = den.members.firstWhere((m) => m.isParent);
    await real(tester, () async {
      final asking = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
      await asking.requestJoin(
        familyId: den.familyId!,
        founderPubkey: den.founderPubkey!,
        deviceName: "Grandma's iPhone",
        kind: DeviceKind.phone,
      );
      await den.ingest(asking.changesSince(const {}));
    });
    expect(den.pendingDevices, isNotEmpty);
    den.actAs(parent.id);
    expect(state.allows(DenAction.manageFamily), isTrue);
    expect(state.allowsTrust(DenAction.manageFamily), isFalse);
    await pumpScreen(tester, const TodayScreen(), state: state);
    expect(find.textContaining('wants to join'), findsNothing);
    den.actAs(null);
  });

  testWidgets('The same parent on their own phone is', (tester) async {
    final state = await demo(tester);
    expect(state.allowsTrust(DenAction.manageFamily), isTrue);
  });

  testWidgets('Someone who may add chores but not set prices is offered no Points', (tester) async {
    final state = await real(tester, () async {
      final phone = await createDemoFamily(now: demoNow);
      final rosa = phone.members.firstWhere((m) => m.role == Role.adult);
      final own = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => demoNow.millisecondsSinceEpoch);
      await own.requestJoin(
        familyId: phone.familyId!,
        founderPubkey: phone.founderPubkey!,
        deviceName: "Rosa's phone",
        kind: DeviceKind.phone,
        memberId: rosa.id,
      );
      await phone.ingest(own.changesSince(phone.versionVector));
      await phone.approveDevice(own.deviceId, member: rosa.id);
      await own.ingest(
        phone.changesSince(own.versionVector, spaces: phone.spacesForDevice(own.deviceId)),
        through: phone.completeVector,
      );
      return AppState(own);
    });
    expect(state.allows(DenAction.editChores), isTrue);
    expect(state.allows(DenAction.managePoints), isFalse);
    await pumpScreen(tester, const ChoreEditorScreen(), state: state, size: const Size(390, 2400));
    expect(find.text('Points'), findsNothing);
  });
}
