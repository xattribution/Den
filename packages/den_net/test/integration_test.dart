// Integration tests that run real den_core engines through den_net. Each test skips itself
// (markTestSkipped) while den_core's engine is unimplemented.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:den_net/io.dart';
import 'package:test/test.dart';

import 'support/channels.dart';
import 'support/fake_relay.dart';
import 'support/family.dart';

void main() {
  group('sync', () {
    test('two dens over an in-memory channel end with identical exports', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
      await fam.founder.addEvent(title: 'Dentist', start: at(15), end: at(16));
      final listId = await fam.founder.addList(title: 'Groceries', kind: ListKind.shopping);

      final phoneNode = SyncNode(fam.founder);
      final laptopNode = SyncNode(laptop);
      addTearDown(phoneNode.close);
      addTearDown(laptopNode.close);
      final peer = await link(phoneNode, laptopNode);
      await peer.live;
      await converge([fam.founder, laptop]);
      expect(laptop.isApproved, isTrue);
      expect(await laptop.spaceKey(Space.family), await fam.founder.spaceKey(Space.family));
      expect(await laptop.spaceKey(Space.parents), await fam.founder.spaceKey(Space.parents));

      // Live changes from both sides, including concurrent edits of one record.
      await laptop.addItem(listId, text: 'Milk');
      await fam.founder.addItem(listId, text: 'Eggs');
      await fam.founder.addEvent(title: 'Soccer', start: at(17), end: at(18), audience: Audience.parents);
      await laptop.updateList(listId, {'title': 'Groceries (Saturday)'});
      await converge([fam.founder, laptop]);
      expect(laptop.list(listId)!.items.map((i) => i.text).toSet(), {'Milk', 'Eggs'});
    });

    test('three dens over in-memory channels converge, forwarding through the middle device', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
      final tablet = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.tablet, name: 'Pat tablet');
      final phoneNode = SyncNode(fam.founder);
      final laptopNode = SyncNode(laptop);
      final tabletNode = SyncNode(tablet);
      addTearDown(() => Future.wait([phoneNode.close(), laptopNode.close(), tabletNode.close()]));
      await fam.founder.addEvent(title: 'Swim', start: at(7), end: at(8));

      // phone <- laptop <- tablet: the tablet never talks to the phone directly.
      await (await link(phoneNode, laptopNode)).live;
      await (await link(laptopNode, tabletNode)).live;
      await converge([fam.founder, laptop, tablet]);

      final listId = await tablet.addList(title: 'Chores board');
      await tablet.addItem(listId, text: 'Feed the cat');
      await fam.founder.addEvent(title: 'Vet', start: at(11), end: at(12), audience: Audience.parents);
      await converge([fam.founder, laptop, tablet]);
      expect(fam.founder.list(listId)!.items.single.text, 'Feed the cat');
    });

    test('three dens through a hub over a localhost WebSocket end with identical exports', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
      final laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
      final phoneNode = SyncNode(fam.founder);
      final hubNode = SyncNode(hub);
      final laptopNode = SyncNode(laptop);
      addTearDown(() async {
        await phoneNode.close();
        await hubNode.close();
        await laptopNode.close();
      });

      // The hub learns the family from the phone that approved it, then serves.
      final boot = await link(phoneNode, hubNode);
      await boot.live;
      await boot.close();
      final server = await serveSync(hubNode, address: InternetAddress.loopbackIPv4, port: 0);
      addTearDown(() => server.close(force: true));
      final endpoint = Uri.parse('ws://127.0.0.1:${server.port}/ws');

      final phoneClient = SyncClient(node: phoneNode, endpoints: [endpoint], expectDevice: hub.deviceId);
      final laptopClient = SyncClient(node: laptopNode, endpoints: [endpoint], expectDevice: hub.deviceId);
      addTearDown(phoneClient.stop);
      addTearDown(laptopClient.stop);
      final statuses = <SyncState>[];
      laptopClient.statusChanges.listen((s) => statuses.add(s.state));
      phoneClient.start();
      laptopClient.start();
      await phoneClient.whenLive();
      await laptopClient.whenLive();
      expect(statuses, containsAllInOrder([SyncState.connecting, SyncState.syncing, SyncState.live]));
      await converge([fam.founder, hub, laptop]);

      // A change on the phone reaches the laptop only through the hub, live.
      final listId = await fam.founder.addList(title: 'Packing', kind: ListKind.packing);
      await fam.founder.addItem(listId, text: 'Sunscreen');
      await laptop.addEvent(title: 'Piano', start: at(18), end: at(19));
      await converge([fam.founder, hub, laptop]);
      expect(laptop.list(listId)!.items.single.text, 'Sunscreen');
    });

    test('holes in a replica are found and filled from either side', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final laptop = await fam.approvedDevice(member: fam.parent, name: 'laptop');
      final tablet = await fam.approvedDevice(member: fam.parent, name: 'tablet');
      final listId = await fam.founder.addList(title: 'Camping');
      for (final item in ['Tent', 'Stove', 'Lantern']) {
        await fam.founder.addItem(listId, text: item);
      }
      final all = fam.founder.changesSince(const {});
      final mine = all.where((c) => c.device == fam.founder.deviceId).toList()
        ..sort((a, b) => a.counter.compareTo(b.counter));
      final hole = mine[mine.length - 3];
      final behind = mine[mine.length - 3].counter;

      // The laptop is ahead but missing one change; the tablet is behind but has it.
      await laptop.ingest(all.where((c) => c.id != hole.id));
      await tablet.ingest(all.where((c) => c.device != fam.founder.deviceId || c.counter <= behind));
      final laptopNode = SyncNode(laptop);
      final tabletNode = SyncNode(tablet);
      addTearDown(laptopNode.close);
      addTearDown(tabletNode.close);
      await (await link(laptopNode, tabletNode)).live;
      await converge([fam.founder, laptop, tablet]);
      expect(laptop.changesSince(const {}).any((c) => c.id == hole.id), isTrue);
    });

    test('a client reconnects with backoff and catches up', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final laptop = await fam.approvedDevice(member: fam.parent, name: 'laptop');
      final phoneNode = SyncNode(fam.founder);
      final laptopNode = SyncNode(laptop);
      addTearDown(phoneNode.close);
      addTearDown(laptopNode.close);
      var connections = 0;
      final client = SyncClient(
        node: laptopNode,
        endpoints: [Uri.parse('memory://phone')],
        expectDevice: fam.founder.deviceId,
        minBackoff: const Duration(milliseconds: 20),
        maxBackoff: const Duration(milliseconds: 100),
        connector: (uri) async {
          connections++;
          if (connections == 2) throw const SocketException('network down');
          final p = pipe<dynamic>();
          unawaited(phoneNode.serve(p.b));
          return p.a;
        },
      );
      addTearDown(client.stop);
      final offline = client.statusChanges.firstWhere((s) => s.state == SyncState.offline);
      client.start();
      await client.whenLive();
      await client.peer!.close();
      final down = await offline;
      expect(down.lastError, isNotNull);
      await fam.founder.addEvent(title: 'While offline', start: at(9), end: at(10));
      await eventually(() => connections >= 3 && client.status.state == SyncState.live);
      await converge([fam.founder, laptop]);
    });

    test('a kid\'s device never receives p or another member\'s private space', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final sam = await fam.founder.addMember(name: 'Sam', role: Role.kid, tier: Tier.big, grants: {Grant.lists});
      final riley = await fam.founder.addMember(name: 'Riley', role: Role.kid, tier: Tier.teen, grants: {Grant.lists});
      final hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
      final samTablet = await fam.approvedDevice(member: sam, kind: DeviceKind.tablet, name: 'Sam tablet');
      final rileyPhone = await fam.approvedDevice(member: riley, name: 'Riley phone');
      await fam.founder.addEvent(title: 'Birthday surprise for Sam', start: at(12), end: at(13), audience: Audience.parents);
      await fam.founder.addEvent(title: 'Pat therapy', start: at(8), end: at(9), audience: Audience.justMe);
      await fam.founder.addEvent(title: 'Family dinner', start: at(18), end: at(19));

      final nodes = [SyncNode(fam.founder), SyncNode(hub), SyncNode(samTablet), SyncNode(rileyPhone)];
      addTearDown(() => Future.wait(nodes.map((n) => n.close())));
      final hubNode = nodes[1];
      await (await link(nodes[0], hubNode)).live;
      for (final kidNode in [nodes[2], nodes[3]]) {
        await (await link(hubNode, kidNode)).live;
      }
      await (await link(hubNode, nodes[0])).live;
      final diaryId = await rileyPhone.addList(title: 'Riley diary', audience: Audience.justMe);
      await samTablet.addList(title: 'Sam wishlist', audience: Audience.justMe);

      await eventually(() =>
          fam.founder.list(diaryId) != null &&
          jsonEncode(hub.exportJson()).contains('Sam wishlist') &&
          jsonEncode(samTablet.exportJson()).contains('Family dinner'));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final samSpaces = samTablet.changesSince(const {}).map((c) => c.space).toSet();
      expect(samSpaces, isNot(contains(Space.parents)));
      expect(samSpaces, isNot(contains(Space.member(riley))));
      expect(samSpaces, isNot(contains(Space.member(fam.parent))));
      expect(samSpaces, containsAll([Space.family, Space.member(sam)]));
      expect(await samTablet.spaceKey(Space.parents), isNull);
      expect(await samTablet.spaceKey(Space.member(riley)), isNull);
      final samTitles = jsonEncode(samTablet.exportJson());
      expect(samTitles, isNot(contains('Birthday surprise')));
      expect(samTitles, isNot(contains('therapy')));
      expect(samTitles, isNot(contains('Riley diary')));
      expect(samTitles, contains('Family dinner'));

      // Parents see the kids' private spaces by default; the hub holds everything.
      expect(jsonEncode(fam.founder.exportJson()), contains('Riley diary'));
      expect(jsonEncode(hub.exportJson()), contains('Sam wishlist'));
    });

    test('a kid\'s device cannot push changes into spaces it may not hold', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final sam = await fam.founder.addMember(name: 'Sam', role: Role.kid, grants: {Grant.events});
      final samTablet = await fam.approvedDevice(member: sam, kind: DeviceKind.tablet, name: 'Sam tablet');
      final phoneNode = SyncNode(fam.founder);
      final samNode = SyncNode(samTablet);
      addTearDown(phoneNode.close);
      addTearDown(samNode.close);
      final peer = await link(phoneNode, samNode);
      await peer.live;
      final sneaky = await forgeChange(
        keys: samTablet.keys,
        deviceId: samTablet.deviceId,
        counter: maxOwnCounter(samTablet) + 1,
        type: RecordType.event,
        rid: newId(),
        space: Space.parents,
        actor: sam,
        fields: {'title': 'Injected into p', 'start': at(1), 'end': at(2)},
      );
      await peer.session.send({'t': 'push', 'list': [sneaky.toJson()]});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fam.founder.changesSince(const {}).any((c) => c.id == sneaky.id), isFalse);
    });
  });

  group('pairing', () {
    test('QR join: pending until a parent approves, nothing before, full sync after', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      await fam.founder.addEvent(title: 'Dentist', start: at(15), end: at(16));
      await fam.founder.addEvent(title: 'Date night', start: at(20), end: at(22), audience: Audience.parents);
      final phoneNode = SyncNode(fam.founder);
      addTearDown(phoneNode.close);
      final invite = await phoneNode.createInvite(relay: Uri.parse('wss://relay.example'));
      final scanned = await Invite.parse(invite.toUrl());

      final tablet = await openDen();
      final tabletNode = SyncNode(tablet);
      addTearDown(tabletNode.close);
      var approved = false;
      final beforeApproval = <int>[];
      final tap = Tap<dynamic>(toClient: (i, m) {
        if (!approved) beforeApproval.add(m is String ? m.length : (m! as List).length);
        return [m];
      });
      unawaited(phoneNode.serve(tap.server));
      final pendingList = phoneNode.pendingJoinsChanges.firstWhere((l) => l.isNotEmpty);
      final attempt = await tabletNode.joinWithInvite(tap.client, scanned, deviceName: 'Pat tablet', kind: DeviceKind.tablet);
      final pending = (await pendingList).single;
      expect(pending.name, 'Pat tablet');
      expect(pending.kind, DeviceKind.tablet);
      expect(pending.via, 'qr');
      expect(pending.matchingWords, attempt.matchingWords);
      await eventually(() => attempt.stage == JoinStage.waitingForApproval);
      expect(fam.founder.pendingDevices.map((d) => d.id), contains(tablet.deviceId));

      // Nothing but pairing messages before approval.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tablet.changesSince(const {}).every((c) => c.device == tablet.deviceId), isTrue);
      expect(await tablet.spaceKey(Space.family), isNull);
      expect(tablet.isApproved, isFalse);
      expect(beforeApproval.length, lessThanOrEqualTo(4), reason: 'hello, pair_ok, unapproved, join_pending');
      expect(beforeApproval.every((n) => n < 1024), isTrue);

      approved = true;
      await phoneNode.approve(pending, member: fam.parent);
      await attempt.completed;
      expect(attempt.stage, JoinStage.done);
      expect(tablet.isApproved, isTrue);
      expect(await tablet.spaceKey(Space.family), await fam.founder.spaceKey(Space.family));
      await converge([fam.founder, tablet]);
      expect(phoneNode.pendingJoins, isEmpty);

      // The invite was single use.
      final again = await openDen();
      final againNode = SyncNode(again);
      addTearDown(againNode.close);
      final p = pipe<dynamic>();
      unawaited(phoneNode.serve(p.b));
      final second = await againNode.joinWithInvite(p.a, scanned, deviceName: 'Copycat', kind: DeviceKind.phone);
      await expectLater(second.completed, throwsA(isA<JoinException>()));
      expect(fam.founder.device(again.deviceId), isNull);
    });

    test('spoken code join: matching words, approval, and the joiner learns the family', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final grandma = await fam.founder.addMember(name: 'Grandma', role: Role.adult);
      await fam.founder.addEvent(title: 'Recital', start: at(18), end: at(19));
      final phoneNode = SyncNode(fam.founder);
      addTearDown(phoneNode.close);
      final code = phoneNode.createSpokenCode();

      final phone = await openDen();
      final grandmaNode = SyncNode(phone);
      addTearDown(grandmaNode.close);

      // One wrong try first: refused and counted against the code.
      final wrongWords = code.words.first == 'zoo' ? 'abandon abandon abandon abandon' : 'zoo zoo zoo zoo';
      final p1 = pipe<dynamic>();
      unawaited(phoneNode.serve(p1.b));
      final wrong = await grandmaNode.joinWithCode(p1.a, wrongWords, deviceName: 'Grandma phone', kind: DeviceKind.phone);
      await expectLater(wrong.completed, throwsA(isA<JoinException>().having((e) => e.reason, 'reason', 'bad-proof')));
      expect(code.failures, 1);
      expect(phone.hasFamily, isFalse);

      final p2 = pipe<dynamic>();
      unawaited(phoneNode.serve(p2.b));
      final pendingList = phoneNode.pendingJoinsChanges.firstWhere((l) => l.isNotEmpty);
      final attempt = await grandmaNode.joinWithCode(p2.a, code.text.toUpperCase(), deviceName: 'Grandma phone', kind: DeviceKind.phone);
      final pending = (await pendingList).single;
      expect(pending.via, 'code');
      expect(pending.matchingWords, attempt.matchingWords, reason: 'both screens show the same three words');
      expect(phone.familyId, fam.founder.familyId);
      expect(phone.isApproved, isFalse);

      await phoneNode.approve(pending, member: grandma);
      await attempt.completed;
      expect(phone.isApproved, isTrue);
      expect(phone.owner?.name, 'Grandma');
      expect(await phone.spaceKey(Space.member(grandma)), await fam.founder.spaceKey(Space.member(grandma)));
      expect(await phone.spaceKey(Space.parents), isNull);
      expect(jsonEncode(phone.exportJson()), contains('Recital'));
    });

    test('spoken codes burn after 5 wrong tries', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final phoneNode = SyncNode(fam.founder);
      addTearDown(phoneNode.close);
      final code = phoneNode.createSpokenCode();
      final joiner = SyncNode(await openDen());
      addTearDown(joiner.close);
      final wrongWords = code.words.first == 'zoo' ? 'abandon abandon abandon abandon' : 'zoo zoo zoo zoo';
      Future<JoinAttempt> attempt(String words) async {
        final p = pipe<dynamic>();
        unawaited(phoneNode.serve(p.b));
        return joiner.joinWithCode(p.a, words, deviceName: 'x', kind: DeviceKind.phone);
      }

      for (var i = 0; i < 5; i++) {
        await expectLater((await attempt(wrongWords)).completed, throwsA(isA<JoinException>()));
      }
      expect(phoneNode.codes.live, isEmpty);
      await expectLater((await attempt(code.text)).completed, throwsA(isA<JoinException>()));
    });

    test('a joiner cannot approve itself, end to end', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final phoneNode = SyncNode(fam.founder);
      addTearDown(phoneNode.close);
      final invite = await phoneNode.createInvite();
      final intruder = await openDen();
      final intruderNode = SyncNode(intruder);
      addTearDown(intruderNode.close);
      final p = pipe<dynamic>();
      unawaited(phoneNode.serve(p.b));
      final pendingList = phoneNode.pendingJoinsChanges.firstWhere((l) => l.isNotEmpty);
      final attempt = await intruderNode.joinWithInvite(p.a, invite, deviceName: 'Totally legit', kind: DeviceKind.phone);
      await pendingList;

      // 1. Through the engine's own API.
      await expectLater(intruder.approveDevice(intruder.deviceId, member: fam.parent), throwsA(anything));

      Future<Change> selfApproval() => forgeChange(
            keys: intruder.keys,
            deviceId: intruder.deviceId,
            counter: maxOwnCounter(intruder) + 1,
            type: RecordType.device,
            rid: intruder.deviceId,
            fields: {'approved': true, 'approvedBy': fam.parent, 'member': fam.parent},
            actor: fam.parent,
          );

      // 2. Pushed as sync data before approval: refused, and the session is closed.
      final forged = await selfApproval();
      await attempt.peer.session.send({'t': 'push', 'list': [forged.toJson()]});
      await attempt.peer.closed.timeout(const Duration(seconds: 5));
      expect(fam.founder.changesSince(const {}).any((c) => c.id == forged.id), isFalse);
      expect(fam.founder.device(intruder.deviceId)!.approved, isFalse);

      // 3. Smuggled inside a (resumed) join request: refused.
      final p2 = pipe<dynamic>();
      unawaited(phoneNode.serve(p2.b));
      final session = await Session.connect(p2.a, keys: intruder.keys, familyId: fam.founder.familyId);
      final replies = session.messages.where((m) => m['t'] == 'join_rejected').first;
      await session.send({'t': 'join', 'changes': [forged.toJson()]});
      expect((await replies)['reason'], 'bad-request');

      // 4. Even if it reached the log directly, the engine would not count it.
      await fam.founder.ingest([forged]);
      expect(fam.founder.device(intruder.deviceId)!.approved, isFalse);
      expect(fam.founder.spacesForDevice(intruder.deviceId), isEmpty);
      expect(intruder.isApproved, isFalse);
      expect(await intruder.spaceKey(Space.family), isNull);
    });
  });

  group('mailbox', () {
    test('two devices with no hub sync through sealed relay mailboxes', () async {
      if (await skipUnlessDenCore()) return;
      final fam = await TestFamily.create();
      final laptop = await fam.approvedDevice(member: fam.parent, name: 'laptop');
      final phoneNode = SyncNode(fam.founder);
      final laptopNode = SyncNode(laptop);
      addTearDown(phoneNode.close);
      addTearDown(laptopNode.close);
      final boot = await link(phoneNode, laptopNode);
      await boot.live;
      await boot.close();

      final relay = FakeRelay();
      final phoneMail = MailboxSync(node: phoneNode, relay: RelayMailbox(Uri.parse('https://relay.test'), client: relay.client));
      final laptopMail = MailboxSync(node: laptopNode, relay: RelayMailbox(Uri.parse('https://relay.test'), client: relay.client));

      final listId = await fam.founder.addList(title: 'Hardware store');
      await fam.founder.addItem(listId, text: 'Hinges');
      await laptop.addEvent(title: 'Plumber', start: at(10), end: at(11), audience: Audience.parents);
      final first = await phoneMail.syncOnce();
      expect(first.posted, greaterThan(0));
      final second = await laptopMail.syncOnce();
      expect(second.received, greaterThan(0));
      await phoneMail.syncOnce();
      await converge([fam.founder, laptop]);
      expect(laptop.list(listId)!.items.single.text, 'Hinges');

      // Repeat rounds move nothing new; blobs are opaque to the relay.
      expect((await laptopMail.syncOnce()).received, 0);
      expect(relay.blobs.values.expand((b) => b).any((blob) => utf8.decode(blob, allowMalformed: true).contains('Hinges')),
          isFalse);
      expect(relay.blobs.keys.every(relayKeyPattern.hasMatch), isTrue);
    });
  });
}
