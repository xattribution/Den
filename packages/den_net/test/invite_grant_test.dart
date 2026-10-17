// A parent's phone hands an invite to the hub, which admits the joiner on the phone's behalf.
@Timeout(Duration(seconds: 60))
library;

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/channels.dart';
import 'support/family.dart';

void main() {
  late TestFamily fam;
  late Den hub;
  late SyncNode phoneNode;
  late SyncNode hubNode;

  setUp(() async {
    fam = await TestFamily.create();
    hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
    phoneNode = SyncNode(fam.founder);
    hubNode = SyncNode(hub);
    final boot = await link(phoneNode, hubNode);
    await boot.live;
    await converge([fam.founder, hub]);
  });

  tearDown(() async {
    await phoneNode.close();
    await hubNode.close();
  });

  test('a joiner pairs with the hub on an invite a parent device granted, and the parent approves it', () async {
    final invite = phoneNode.createHubInvite(hub.deviceId);
    expect(invite.inviterDevice, hub.deviceId);
    expect(invite.inviterPubkey, hub.keys.pubkey);
    expect(phoneNode.invites.live, isEmpty, reason: 'the phone never accepts it itself');
    final grant = await InviteGrant.sign(invite, keys: fam.founder.keys, context: 'link:slot1');
    final received = InviteGrant.fromJson(grant.toJson());
    expect(await hubNode.acceptInviteGrant(received, context: 'link:slot1'), isNull);

    final browser = await openDen();
    final browserNode = SyncNode(browser);
    addTearDown(browserNode.close);
    final scanned = await Invite.parse(received.invite.toUrl());
    final p = pipe<dynamic>();
    final served = hubNode.serve(p.b);
    final attempt = await browserNode.joinWithInvite(p.a, scanned, deviceName: 'Browser', kind: DeviceKind.browser);
    await attempt.stages.firstWhere((s) => s == JoinStage.waitingForApproval);
    await eventually(() => fam.founder.pendingDevices.any((d) => d.id == browser.deviceId));
    await fam.founder.approveDevice(browser.deviceId, member: fam.parent);
    await attempt.completed;
    await converge([fam.founder, hub, browser]);
    expect(browser.owner?.id, fam.parent);
    await attempt.peer.close();
    await served;
  });

  test('the hub refuses grants it can\'t trust', () async {
    final kid = await fam.founder.addMember(name: 'Kit', role: Role.kid);
    final kidPhone = await fam.approvedDevice(member: kid, name: 'Kit phone');
    await converge([fam.founder, hub]);
    final invite = phoneNode.createHubInvite(hub.deviceId);

    Future<String?> accept(InviteGrant g, [String context = 'link:a']) => hubNode.acceptInviteGrant(g, context: context);

    final good = await InviteGrant.sign(invite, keys: fam.founder.keys, context: 'link:a');
    expect(await accept(good, 'link:b'), 'wrong-context');
    expect(await accept(await InviteGrant.sign(invite, keys: kidPhone.keys, context: 'link:a')), 'not-a-parent-device');
    final stranger = await DeviceKeys.generate();
    expect(await accept(await InviteGrant.sign(invite, keys: stranger, context: 'link:a')), 'not-a-parent-device');
    final forged = InviteGrant(invite: invite, grantor: fam.founder.deviceId, context: 'link:a', sig: good.sig.replaceRange(0, 2, 'AA'));
    expect(await accept(forged), 'bad-signature');
    final forPhone = await fam.founder.keys.deviceId();
    final elsewhere = Invite.create(
      familyId: invite.familyId,
      founderPubkey: invite.founderPubkey,
      inviterDevice: forPhone,
      inviterPubkey: fam.founder.keys.pubkey,
    );
    expect(await accept(await InviteGrant.sign(elsewhere, keys: fam.founder.keys, context: 'link:a')), 'wrong-device');
    final stale = Invite.create(
      familyId: invite.familyId,
      founderPubkey: invite.founderPubkey,
      inviterDevice: hub.deviceId,
      inviterPubkey: hub.keys.pubkey,
      now: DateTime.now().subtract(const Duration(hours: 2)),
    );
    expect(await accept(await InviteGrant.sign(stale, keys: fam.founder.keys, context: 'link:a')), 'expired');
    expect(hubNode.invites.live, isEmpty);
    expect(await accept(good), isNull);
    expect(hubNode.invites.live, hasLength(1));
    expect(() => phoneNode.createHubInvite(kidPhone.deviceId), throwsStateError);
  });
}
