@Timeout(Duration(seconds: 60))
library;

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/channels.dart';
import 'support/family.dart';

/// A device whose join request is already in the family's log, connecting again (after its app
/// was closed, say) without asking again.
void main() {
  late TestFamily fam;
  late SyncNode phoneNode;
  late Den waiting;
  late SyncNode waitingNode;

  Future<bool> setUpWaiting() async {
    if (await skipUnlessDenCore()) return false;
    fam = await TestFamily.create();
    phoneNode = SyncNode(fam.founder);
    addTearDown(phoneNode.close);
    waiting = await openDen();
    await waiting.requestJoin(
      familyId: fam.founder.familyId!,
      founderPubkey: fam.founderPubkey,
      deviceName: "Grandma's iPad",
      kind: DeviceKind.tablet,
    );
    await fam.founder.ingest(waiting.changesSince(const {}));
    waitingNode = SyncNode(waiting);
    addTearDown(waitingNode.close);
    return true;
  }

  test('hears its approval on the connection it waits on', () async {
    if (!await setUpWaiting()) return;
    final peer = await link(phoneNode, waitingNode);
    await eventually(() => peer.awaitingApproval);
    await fam.founder.approveDevice(waiting.deviceId, member: fam.parent);
    await eventually(() => waiting.isApproved);
    await peer.close();
  });

  test('hears at once that it was turned away, instead of being timed out', () async {
    if (!await setUpWaiting()) return;
    await fam.founder.revokeDevice(waiting.deviceId);
    final peer = await link(phoneNode, waitingNode);
    await peer.closed.timeout(const Duration(seconds: 5));
    expect(peer.closeReason, 'declined');
    expect(waiting.isApproved, isFalse);
  });
}
