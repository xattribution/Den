// Space-key epochs: rotation on revocation, over sessions and relay mailboxes. Each test skips
// itself (markTestSkipped) while den_core's engine is unimplemented.
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/channels.dart';
import 'support/fake_relay.dart';
import 'support/family.dart';

final Uri relayUrl = Uri.parse('https://relay.test');

void main() {
  test('a revocation rotates keys, which reach the remaining devices through the hub and never the revoked one',
      () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final phone = fam.founder;
    final sam = await phone.addMember(name: 'Sam', role: Role.kid, grants: {Grant.lists});
    final hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
    final laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
    final tablet = await fam.approvedDevice(member: sam, kind: DeviceKind.tablet, name: 'Sam tablet');
    final oldPhone = await fam.approvedDevice(member: fam.parent, name: 'Pat old phone');
    final spaces = [Space.family, Space.parents, Space.member(fam.parent), Space.member(sam)];
    final before = {for (final s in spaces) s: await phone.spaceKey(s)};

    final phoneNode = SyncNode(phone);
    final hubNode = SyncNode(hub);
    final laptopNode = SyncNode(laptop);
    final tabletNode = SyncNode(tablet);
    final oldNode = SyncNode(oldPhone);
    addTearDown(() => Future.wait([for (final n in [phoneNode, hubNode, laptopNode, tabletNode, oldNode]) n.close()]));

    await (await link(phoneNode, hubNode)).live;
    final laptopPeer = await link(hubNode, laptopNode);
    await laptopPeer.live;
    await (await link(hubNode, tabletNode)).live;
    final oldPeer = await link(hubNode, oldNode);
    await oldPeer.live;
    for (final s in spaces) {
      expect(laptop.spaceKeyEpoch(s), 0, reason: s);
      expect(oldPhone.spaceKeyEpoch(s), 0, reason: s);
    }
    expect(tablet.spaceKeyEpoch(Space.family), 0);
    expect(tablet.spaceKeyEpoch(Space.parents), isNull);

    // The laptop is away while the old phone is revoked.
    await laptopPeer.close();
    await phone.revokeDevice(oldPhone.deviceId);
    for (final s in spaces) {
      expect(phone.spaceKeyEpoch(s), 1, reason: s);
    }

    // Pushed live: phone -> hub -> tablet.
    await eventually(() => spaces.every((s) => hub.spaceKeyEpoch(s) == 1));
    await eventually(() => tablet.spaceKeyEpoch(Space.family) == 1 && tablet.spaceKeyEpoch(Space.member(sam)) == 1);
    expect(await tablet.spaceKey(Space.family), await phone.spaceKey(Space.family));
    expect(tablet.spaceKeyEpoch(Space.parents), isNull, reason: 'a kid never gets p, rotated or not');
    expect(await hub.spaceKey(Space.family, epoch: 0), before[Space.family], reason: 'older epochs are kept');

    // Offered at reconnect: the laptop's have says epoch 0, so the hub sends epoch 1.
    await (await link(hubNode, laptopNode)).live;
    await eventually(() => spaces.every((s) => laptop.spaceKeyEpoch(s) == 1));
    for (final s in spaces) {
      expect(await laptop.spaceKey(s), await phone.spaceKey(s), reason: s);
      expect(await laptop.spaceKey(s, epoch: 0), before[s], reason: s);
    }

    // The revoked phone was cut off and never saw a new key.
    await oldPeer.closed.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    for (final s in spaces) {
      expect(oldPhone.spaceKeyEpoch(s), 0, reason: s);
      expect(await oldPhone.spaceKey(s, epoch: 1), isNull, reason: s);
    }
    final oldAgain = await link(hubNode, oldNode);
    await oldAgain.closed.timeout(const Duration(seconds: 10));
    expect(oldPhone.spaceKeyEpoch(Space.family), 0);
  });

  group('relay mailbox', () {
    late TestFamily fam;
    late Den laptop;
    late Den oldPhone;
    late FakeRelay relay;
    late SyncNode phoneNode;
    late SyncNode laptopNode;
    late SyncNode oldNode;
    late int clock;
    late MailboxSync phoneMail;
    late MailboxSync laptopMail;
    late MailboxSync oldMail;

    MailboxSync mailFor(SyncNode node, {int Function()? now}) =>
        MailboxSync(node: node, relay: RelayMailbox(relayUrl, client: relay.client), now: now);

    Future<bool> setUpFamily() async {
      if (await skipUnlessDenCore()) return false;
      fam = await TestFamily.create();
      laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
      oldPhone = await fam.approvedDevice(member: fam.parent, name: 'Pat old phone');
      phoneNode = SyncNode(fam.founder);
      laptopNode = SyncNode(laptop);
      oldNode = SyncNode(oldPhone);
      addTearDown(() => Future.wait([phoneNode.close(), laptopNode.close(), oldNode.close()]));
      for (final node in [laptopNode, oldNode]) {
        final peer = await link(phoneNode, node);
        await peer.live;
        await peer.close();
      }
      relay = FakeRelay();
      clock = DateTime.now().millisecondsSinceEpoch;
      phoneMail = mailFor(phoneNode, now: () => clock);
      laptopMail = mailFor(laptopNode);
      oldMail = mailFor(oldNode);
      for (final m in [phoneMail, laptopMail, oldMail]) {
        await m.syncOnce();
      }
      return true;
    }

    test('rotation reaches the remaining devices, and the revoked one can\'t read what follows', () async {
      if (!await setUpFamily()) return;
      final oldInbox = await deviceInboxId(oldPhone.keys.xpub);
      final oldInboxBefore = relay.blobs[oldInbox]?.length ?? 0;
      final oldKey = (await oldPhone.spaceKey(Space.family))!;

      await fam.founder.revokeDevice(oldPhone.deviceId);
      await fam.founder.addEvent(title: 'After the revocation', start: at(18), end: at(19));
      final sent = await phoneMail.syncOnce();
      expect(sent.keysDelivered, greaterThan(0));
      expect(relay.blobs[oldInbox]?.length ?? 0, oldInboxBefore, reason: 'no new key is sealed to the revoked phone');

      final got = await laptopMail.syncOnce();
      expect(got.keysStored, 3, reason: 'f, p and the parent\'s own space');
      expect(laptop.spaceKeyEpoch(Space.family), 1);
      expect(await laptop.spaceKey(Space.family), await fam.founder.spaceKey(Space.family));
      expect(laptop.device(oldPhone.deviceId)!.revoked, isTrue);
      await converge([fam.founder, laptop]);

      await oldMail.syncOnce();
      expect(oldPhone.spaceKeyEpoch(Space.family), 0);
      expect(jsonEncode(oldPhone.exportJson()), isNot(contains('After the revocation')));

      // What was sealed after the rotation doesn't open with the old key, and the old key
      // doesn't even lead to the new mailbox.
      final newKey = (await fam.founder.spaceKey(Space.family))!;
      final newMailbox = await mailboxId(newKey, 1);
      expect(relay.blobs[newMailbox], isNotEmpty);
      for (final blob in relay.blobs[newMailbox]!) {
        await expectLater(openChanges(blob, oldKey, space: Space.family, epoch: 1), throwsA(isA<SealException>()));
        await expectLater(openChanges(blob, oldKey, space: Space.family, epoch: 0), throwsA(isA<SealException>()));
      }
      expect(relay.blobs.containsKey(await mailboxId(oldKey, 1)), isFalse);
    });

    test('nothing in flight is lost across an epoch change, and old mailboxes are drained for 30 days', () async {
      if (!await setUpFamily()) return;
      final oldF = (await fam.founder.spaceKey(Space.family))!;
      final epoch0 = await mailboxId(oldF, 0);

      // The phone rotates, but the laptop hasn't heard yet and keeps posting under epoch 0.
      await fam.founder.revokeDevice(oldPhone.deviceId);
      final listId = await laptop.addList(title: 'Written before the switch');
      await laptopMail.syncOnce();
      expect(laptop.spaceKeyEpoch(Space.family), 0);

      // The phone, on epoch 1, still reads the epoch-0 mailbox.
      await phoneMail.syncOnce();
      expect(fam.founder.list(listId), isNotNull);

      // Once the laptop has the new key, both post under epoch 1 and converge.
      await laptopMail.syncOnce();
      expect(laptop.spaceKeyEpoch(Space.family), 1);
      await laptop.addItem(listId, text: 'Written after the switch');
      await laptopMail.syncOnce();
      await phoneMail.syncOnce();
      await converge([fam.founder, laptop]);
      expect(fam.founder.list(listId)!.items.single.text, 'Written after the switch');

      // A month after it first saw epoch 1, the phone stops reading epoch 0.
      relay.reads.clear();
      await phoneMail.syncOnce();
      expect(relay.reads, contains(epoch0));
      clock += const Duration(days: 31).inMilliseconds;
      relay.reads.clear();
      await phoneMail.syncOnce();
      expect(relay.reads, isNot(contains(epoch0)));
      expect(relay.reads, contains(await mailboxId((await fam.founder.spaceKey(Space.family))!, 1)));
    });
  });
}
