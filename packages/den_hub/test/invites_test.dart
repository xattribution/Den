@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late HubFixture f;

  setUp(() async => f = await HubFixture.start());
  tearDown(() => f.stop());

  Uri sync() => f.base.replace(scheme: 'ws', path: '/ws');

  /// An invite naming the hub, signed by [den] (a parent's phone unless a test says otherwise).
  Future<Map<String, Object?>> grant(Den den, {String context = 'invite', Duration validFor = const Duration(days: 3)}) async {
    final invite = SyncNode(den).createHubInvite(f.hubDen.deviceId, hubs: [sync()], validFor: validFor);
    return (await InviteGrant.sign(invite, keys: den.keys, context: context)).toJson();
  }

  test('a parent invites Zoe by message; her new device joins with the four words', () async {
    final zoe = f.id('Zoe');
    final made = await f.call('POST', '/api/v1/invites', body: await grant(f.phone, context: 'invite:$zoe'));
    expect(made.status, 201, reason: made.text);
    final words = (made.body['words']! as List).cast<String>();
    expect(words, hasLength(4));
    expect(made.body['code'], words.join(' '));
    expect(made.body['link'], '${f.base}/#/join/${words.join('-')}');
    expect(made.body['member'], zoe);

    // Typed loosely, as people do.
    final redeemed = await f.call('POST', '/api/v1/invites/redeem', body: {'code': ' ${words.join(', ').toUpperCase()} '});
    expect(redeemed.status, 200, reason: redeemed.text);
    expect(redeemed.body['member'], zoe);
    expect(redeemed.body['member_name'], 'Zoe');
    expect(redeemed.body['family'], f.phone.family!.name);

    final joiner = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final invite = await Invite.parse(redeemed.body['invite']! as String);
    expect(invite.inviterDevice, f.hubDen.deviceId, reason: "the joiner pins the hub's key");
    final attempt = await SyncNode(joiner).joinWithInvite(
      await connectWebSocket(sync()),
      invite,
      deviceName: "Zoe's iPhone",
      kind: DeviceKind.phone,
      memberId: zoe,
    );
    await eventually(() => attempt.stage == JoinStage.waitingForApproval);
    await eventually(() => f.hubDen.pendingDevices.any((d) => d.id == joiner.deviceId));
    expect(f.hubDen.device(joiner.deviceId)!.member, zoe, reason: 'one tap approves it for her');
    await attempt.cancel();
  });

  test('wrong words, too many of them, and a kid inviting are refused', () async {
    expect((await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'not four words'})).status, 400);
    final wrong = await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'maple river candle tiger'});
    expect(wrong.status, 404);
    expect(wrong.error['code'], 'not_found');

    // A kid's own phone can't make invites.
    final kidPhone = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final kid = f.id('Zoe');
    await kidPhone.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: "Zoe's phone",
      kind: DeviceKind.phone,
      memberId: kid,
    );
    await f.phone.ingest(kidPhone.changesSince(const {}));
    await f.phone.approveDevice(kidPhone.deviceId, member: kid, mode: DeviceMode.personal);
    await f.toHub();
    await kidPhone.ingest(f.phone.changesSince(const {}));
    final byKid = await f.call('POST', '/api/v1/invites', body: await grant(kidPhone));
    expect(byKid.status, 403);

    final tooLong = await f.call('POST', '/api/v1/invites', body: await grant(f.phone, validFor: const Duration(days: 30)));
    expect(tooLong.status, 400);

    for (var i = 0; i < 9; i++) {
      await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'maple river candle tiger'});
    }
    final locked = await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'maple river candle tiger'});
    expect(locked.status, 429);
  });

  test('an invite outlives a restart of the hub', () async {
    final dir = await Directory.systemTemp.createTemp('den-invites');
    addTearDown(() => dir.delete(recursive: true));
    final g = await HubFixture.start(dataDir: dir.path);
    final invite = SyncNode(g.phone).createHubInvite(g.hubDen.deviceId, validFor: const Duration(days: 3));
    final body = (await InviteGrant.sign(invite, keys: g.phone.keys, context: 'invite')).toJson();
    final made = await g.call('POST', '/api/v1/invites', body: body);
    final code = made.body['code']! as String;
    await g.hub.stop();
    final again = await DenHub.start(g.hubDen, g.hub.config);
    addTearDown(() async {
      await again.stop();
      await g.hubDen.close();
      await g.phone.close();
    });
    final redeemed = await apiCall(again.localUrl, 'POST', '/api/v1/invites/redeem', body: {'code': code});
    expect(redeemed.status, 200, reason: redeemed.text);
  });
}
