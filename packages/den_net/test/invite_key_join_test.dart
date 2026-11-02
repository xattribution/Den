@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/channels.dart';
import 'support/family.dart';

/// Invites that let someone in at once: the parent's phone makes the key (from four words, or
/// at random to seal to a device) and writes its public half into the family's log; the new
/// device proves the key with one pairing message to any device that serves the family, and
/// lets itself in. Nobody taps Approve.
void main() {
  group('invite words', () {
    test('four words from the list; the same words always give the same slot and key', () async {
      final code = InviteWords.generate();
      expect(normalizeCode(code), code);
      final again = code.split(' ').map((w) => w.toUpperCase()).join('-');
      expect(await InviteWords.slot(again), await InviteWords.slot(code));
      expect((await InviteWords.key(again)).publicKey, (await InviteWords.key(code)).publicKey);
      expect(await InviteWords.slot(code), hasLength(64));
      final other = InviteWords.generate();
      expect(await InviteWords.slot(other), isNot(await InviteWords.slot(code)));
    });
  });

  group('joining with an invite key', () {
    late TestFamily fam;
    late Den hub;
    late SyncNode hubNode;
    late SyncNode parentNode;
    late String leo;

    setUp(() async {
      if (await skipUnlessDenCore()) return;
      fam = await TestFamily.create();
      leo = await fam.founder.addMember(name: 'Leo', role: Role.kid);
      hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
      hubNode = SyncNode(hub);
      parentNode = SyncNode(fam.founder);
      await (await link(parentNode, hubNode)).live;
      await converge([fam.founder, hub]);
      addTearDown(hubNode.close);
      addTearDown(parentNode.close);
    });

    /// What the parent's phone does: a key, its public half into the family's log, synced.
    Future<InviteKey> invite({String? member, Set<DeviceMode> modes = const {DeviceMode.personal}, bool wait = true}) async {
      final key = await InviteWords.key(InviteWords.generate());
      await fam.founder.createInviteKey(
        member: member,
        publicKey: key.publicKey,
        modes: modes,
        expires: DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch,
      );
      if (wait) await eventually(() => hub.inviteKey(key.id) != null);
      return key;
    }

    Future<(Den, SyncNode)> newDevice() async {
      final den = await openDen();
      final node = SyncNode(den);
      addTearDown(node.close);
      return (den, node);
    }

    Future<JoinAttempt> joinThrough(SyncNode server, SyncNode node, InviteKey key, {DeviceKind kind = DeviceKind.tablet}) async {
      final p = pipe<dynamic>();
      unawaited(server.serve(p.b, client: '198.51.100.7'));
      return node.joinWithInviteKey(p.a, key, deviceName: (name) => name == null ? 'Kitchen' : "$name's iPad", kind: kind);
    }

    test("the key alone lets the device in as the invite's person, with nothing kept at the hub", () async {
      if (await skipUnlessDenCore()) return;
      final key = await invite(member: leo);
      expect(hubNode.invites.live, isEmpty, reason: 'no invite of its own: the family log is enough');
      final (ipad, node) = await newDevice();
      final attempt = await joinThrough(hubNode, node, key);
      final who = await attempt.admittedAs;
      expect(who.memberName, 'Leo');
      expect(who.mode, DeviceMode.personal);
      expect(who.familyName, 'The Parks');
      await attempt.completed;
      expect(ipad.isApproved, isTrue);
      expect(ipad.owner?.name, 'Leo');
      expect(ipad.thisDevice?.name, "Leo's iPad");
      expect(hubNode.pendingJoins, isEmpty, reason: 'nobody had to approve it');
      expect(inviteOf(hub.device(ipad.deviceId)!)?.member, leo);
      await eventually(() => fam.founder.device(ipad.deviceId)?.approved ?? false);
    });

    test("any device serving the family takes the same message: here, the parent's phone", () async {
      if (await skipUnlessDenCore()) return;
      final key = await invite(member: leo, wait: false);
      final (ipad, node) = await newDevice();
      await (await joinThrough(parentNode, node, key)).completed;
      expect(ipad.isApproved, isTrue);
    });

    test('a key bound to no one lets in a hub for the family, the way a group admits a hub', () async {
      if (await skipUnlessDenCore()) return;
      final key = await invite(modes: {DeviceMode.hub});
      // A key made at random travels sealed to a device as well as in words.
      final sealed = await InviteKey.fromSeed(await key.seed());
      final (second, node) = await newDevice();
      final attempt = await joinThrough(hubNode, node, sealed, kind: DeviceKind.hub);
      expect((await attempt.admittedAs).mode, DeviceMode.hub);
      await attempt.completed;
      expect(second.thisDevice?.mode, DeviceMode.hub);
      expect(second.thisDevice?.member, isNull);
    });

    test('a used key is turned away at the door', () async {
      if (await skipUnlessDenCore()) return;
      final key = await invite(member: leo);
      final (_, first) = await newDevice();
      await (await joinThrough(hubNode, first, key)).completed;
      final (second, node) = await newDevice();
      final attempt = await joinThrough(hubNode, node, key);
      await expectLater(attempt.completed, throwsA(isA<JoinException>().having((e) => e.reason, 'reason', 'bad-proof')));
      expect(hub.device(second.deviceId), isNull);
    });

    test('keys that name nothing count against the client, then it waits', () async {
      if (await skipUnlessDenCore()) return;
      for (var i = 0; i < SyncNode.maxKeyGuessesPerClient; i++) {
        final (_, node) = await newDevice();
        final attempt = await joinThrough(hubNode, node, await InviteKey.generate());
        await expectLater(attempt.completed, throwsA(isA<JoinException>().having((e) => e.reason, 'reason', 'bad-proof')));
      }
      // Now even the right key waits, from that client.
      final key = await invite(member: leo);
      final (_, node) = await newDevice();
      final attempt = await joinThrough(hubNode, node, key);
      await expectLater(attempt.completed, throwsA(isA<JoinException>().having((e) => e.reason, 'reason', 'rate-limited')));
    });
  });
}
