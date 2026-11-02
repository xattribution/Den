@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/src/invites.dart' show HubInvites;
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
    expect(made.body['link'], '${f.base}/join/${words.join('-')}');
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

  test('words the hub picked answer their slot too, so the app never sends the words', () async {
    final zoe = f.id('Zoe');
    final made = await f.call('POST', '/api/v1/invites', body: await grant(f.phone, context: 'invite:$zoe'));
    expect(made.status, 201, reason: made.text);
    final code = made.body['code']! as String;
    final bySlot = await f.call('POST', '/api/v1/invites/redeem', body: {'slot': await InviteWords.slot(code)});
    expect(bySlot.status, 200, reason: bySlot.text);
    expect(bySlot.body['member'], zoe);
    expect(f.hub.invites.holds('slot:${await InviteWords.slot(code)}'), isTrue);
    // The same invite, typed as words into an older app.
    final byWords = await f.call('POST', '/api/v1/invites/redeem', body: {'code': code});
    expect(byWords.status, 200, reason: byWords.text);
    expect(byWords.body['invite'], bySlot.body['invite']);
  });

  test('wrong words, too many of them, and a kid inviting are refused', () async {
    expect((await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'not four words'})).status, 400);
    final wrong = await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'maple river canoe tiger'});
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
      await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'maple river canoe tiger'});
    }
    final locked = await f.call('POST', '/api/v1/invites/redeem', body: {'code': 'maple river canoe tiger'});
    expect(locked.status, 429);
  });

  /// Redeems [code] and asks to join with what it gives, as a new device; returns the device once
  /// its request waits for a parent.
  Future<Den> join(String code) async {
    final redeemed = await f.call('POST', '/api/v1/invites/redeem', body: {'code': code});
    expect(redeemed.status, 200, reason: redeemed.text);
    final joiner = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final node = SyncNode(joiner);
    addTearDown(() async {
      await node.close();
      await joiner.close();
    });
    final invite = await Invite.parse(redeemed.body['invite']! as String);
    final attempt = await node.joinWithInvite(await connectWebSocket(sync()), invite, deviceName: 'New phone', kind: DeviceKind.phone);
    await eventually(() => attempt.stage == JoinStage.waitingForApproval);
    await eventually(() => f.hubDen.pendingDevices.any((d) => d.id == joiner.deviceId));
    await attempt.cancel();
    return joiner;
  }

  test('an invite is used up once a parent approves a device that joined with it', () async {
    final made = await f.call('POST', '/api/v1/invites', body: await grant(f.phone, context: 'invite:${f.id('Zoe')}'));
    final code = made.body['code']! as String;
    final first = await join(code);
    await f.toPhone();
    await f.phone.approveDevice(first.deviceId, member: f.id('Zoe'));
    await f.toHub();
    final again = await f.call('POST', '/api/v1/invites/redeem', body: {'code': code});
    expect(again.status, 404);
    expect(again.error['message'], contains('used already'));
  });

  test('an invite stops after ${HubInvites.maxJoins} devices joined with it and none was approved', () async {
    final made = await f.call('POST', '/api/v1/invites', body: await grant(f.phone));
    final code = made.body['code']! as String;
    for (var i = 0; i < HubInvites.maxJoins; i++) {
      await join(code);
    }
    final more = await f.call('POST', '/api/v1/invites/redeem', body: {'code': code});
    expect(more.status, 404);
    expect(more.error['message'], contains('used already'));
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
