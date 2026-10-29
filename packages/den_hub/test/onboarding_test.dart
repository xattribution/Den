@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';

import 'support/fixture.dart';
import 'support/test.dart';

/// Onboarding with nothing to type and no tap to wait for: invites that let someone in at once,
/// and the setup link that starts a family on a fresh hub.
void main() {
  group('an invite that lets someone in at once', () {
    late HubFixture f;

    setUp(() async => f = await HubFixture.start());
    tearDown(() => f.stop());

    Uri sync() => f.base.replace(scheme: 'ws', path: '/ws');

    /// What the app does on Alex's phone: four words, their key into the family's log, and the
    /// invite with only the words' slot to the hub.
    Future<(String code, ApiResult made)> invite(String member, {bool key = true, bool synced = true}) async {
      final code = InviteWords.generate();
      final inviteKey = await InviteWords.key(code);
      final joinInvite = SyncNode(f.phone).createHubInvite(f.hubDen.deviceId, hubs: [sync()], validFor: inviteKeyDefaultLife);
      if (key) {
        await f.phone.createInviteKey(member: member, publicKey: inviteKey.publicKey, expires: joinInvite.expires.millisecondsSinceEpoch);
        if (synced) await f.toHub();
      }
      final grant = await InviteGrant.sign(joinInvite, keys: f.phone.keys, context: 'invite:$member');
      final made = await f.call('POST', '/api/v1/invites', body: {
        ...grant.toJson(),
        'slot': await InviteWords.slot(code),
        if (key) 'key': inviteKey.publicKey,
      });
      return (code, made);
    }

    test("Grandma's words let her iPhone in, and nobody taps Approve", () async {
      final zoe = f.id('Zoe');
      final (code, made) = await invite(zoe);
      expect(made.status, 201, reason: made.text);
      expect(made.body['preapproved'], isTrue);
      expect(made.body.containsKey('words'), isFalse, reason: 'the hub never learns the words');
      expect(made.body['base'], f.base.toString());

      final redeemed = await f.call('POST', '/api/v1/invites/redeem', body: {'slot': await InviteWords.slot(code)});
      expect(redeemed.status, 200, reason: redeemed.text);
      expect(redeemed.body['preapproved'], isTrue);
      expect(redeemed.body['member'], zoe);

      final joiner = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      final node = SyncNode(joiner);
      addTearDown(() async {
        await node.close();
        await joiner.close();
      });
      final hubInvite = await Invite.parse(redeemed.body['invite']! as String);
      final attempt = await node.joinWithInviteKey(
        await connectWebSocket(sync()),
        await InviteWords.key(code),
        deviceName: (name) => "$name's iPhone",
        kind: DeviceKind.phone,
        expectFamily: hubInvite.familyId,
        expectDevice: hubInvite.inviterDevice,
        expectPubkey: hubInvite.inviterPubkey,
      );
      await attempt.completed;
      expect(joiner.isApproved, isTrue);
      expect(joiner.owner?.name, 'Zoe');
      expect(joiner.thisDevice?.name, "Zoe's iPhone");
      expect(f.hubDen.pendingDevices, isEmpty);
      // Used once: the same words now find nothing.
      final again = await f.call('POST', '/api/v1/invites/redeem', body: {'slot': await InviteWords.slot(code)});
      expect(again.status, 404);
    });

    test('words typed into an older app still find it: the hub stretches them', () async {
      final zoe = f.id('Zoe');
      final (code, made) = await invite(zoe);
      expect(made.status, 201, reason: made.text);
      final redeemed = await f.call('POST', '/api/v1/invites/redeem', body: {'code': code.toUpperCase()});
      expect(redeemed.status, 200, reason: redeemed.text);
      expect(redeemed.body['member'], zoe);
    });

    test("the hub waits for the key to reach it, and checks it's the family's for that person", () async {
      final zoe = f.id('Zoe');
      final (_, early) = await invite(zoe, synced: false);
      expect(early.status, 409);
      expect(early.error['code'], 'not_synced');
      await f.toHub();
      // A key the family made for someone else.
      final code = InviteWords.generate();
      final other = await InviteWords.key(code);
      await f.phone.createInviteKey(member: f.id('Maya'), publicKey: other.publicKey, expires: f.hubDen.now() + 3600000);
      await f.toHub();
      final joinInvite = SyncNode(f.phone).createHubInvite(f.hubDen.deviceId, validFor: const Duration(hours: 1));
      final grant = await InviteGrant.sign(joinInvite, keys: f.phone.keys, context: 'invite:$zoe');
      final wrong = await f.call('POST', '/api/v1/invites', body: {...grant.toJson(), 'slot': await InviteWords.slot(code), 'key': other.publicKey});
      expect(wrong.status, 400);
    });

    test('an invite without a key keeps its words from the hub too, and waits for a parent', () async {
      final zoe = f.id('Zoe');
      final (code, made) = await invite(zoe, key: false);
      expect(made.status, 201, reason: made.text);
      expect(made.body['preapproved'], isFalse);
      final redeemed = await f.call('POST', '/api/v1/invites/redeem', body: {'slot': await InviteWords.slot(code)});
      expect(redeemed.body['preapproved'], isFalse);
    });

    test('wrong slots count against the client like wrong words', () async {
      for (var i = 0; i < 10; i++) {
        final miss = await f.call('POST', '/api/v1/invites/redeem', body: {'slot': 'ab' * 32});
        expect(miss.status, 404);
      }
      final locked = await f.call('POST', '/api/v1/invites/redeem', body: {'slot': 'ab' * 32});
      expect(locked.status, 429);
      expect((await f.call('POST', '/api/v1/invites/redeem', body: {'slot': 'not hex'})).status, anyOf(400, 429));
    });
  });

  test('the setup link: the code and the hub it names, which a phone checks before it takes the hub in', () async {
    final logged = <String>[];
    final codes = <String>[];
    final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final hub = await DenHub.start(den, HubConfig(
      port: 0,
      host: InternetAddress.loopbackIPv4,
      mdns: false,
      name: 'Den hub',
      publicUrl: Uri.parse('https://den.example.com'),
      log: HubLog(level: LogLevel.info, sink: logged.add),
      onSetupCode: codes.add,
    ));
    addTearDown(hub.stop);
    final link = setupLink(Uri.parse('https://den.example.com'), codes.single, den.deviceId);
    expect(link.toString(), 'https://den.example.com/#/setup/${codes.single}/${den.deviceId}');
    expect(logged.where((l) => l.contains(link.toString())), hasLength(1), reason: 'the log shows it beside the code');

    // The phone reads the link: the code it sends, and the hub it expects.
    final parts = link.fragment.split('/');
    final code = parts[2], expected = parts[3];
    final status = await apiCall(hub.localUrl, 'GET', '/api/v1/hub/status');
    expect(status.body['device'], expected, reason: "the hub that answers is the one that printed the link");

    final phone = await createDemoFamily();
    final phoneNode = SyncNode(phone);
    addTearDown(phoneNode.close);
    final invite = await phoneNode.createInvite();
    final accepted = await apiCall(hub.localUrl, 'POST', '/api/v1/hub/setup', body: {'code': code, 'invite': invite.toUrl(), 'direct': true});
    expect(accepted.status, 202, reason: accepted.text);
    final joins = phoneNode.pendingJoinsChanges.firstWhere((j) => j.isNotEmpty);
    final socket = await connectWebSocket(Uri.parse('ws://127.0.0.1:${hub.port}/api/v1/hub/setup/ws'));
    final served = phoneNode.serve(socket);
    final join = (await joins).single;
    // The session proved the hub's key, and its id is the one in the link: no words to compare.
    expect(join.deviceId, expected);
    await phoneNode.approve(join, mode: DeviceMode.hub);
    await eventually(() async => (await apiCall(hub.localUrl, 'GET', '/health')).body['ready'] == true);
    await socket.sink.close();
    await served;
  });
}
