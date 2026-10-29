@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/channels.dart';
import 'support/family.dart';

void main() {
  group('recovery words', () {
    test('twelve words with a BIP-39 checksum, so a mistyped word is caught', () {
      expect(RecoveryWords.valid([...List.filled(11, 'abandon'), 'about']), isTrue, reason: 'BIP-39\'s zero vector');
      expect(RecoveryWords.valid(List.filled(12, 'abandon')), isFalse);
      for (var i = 0; i < 20; i++) {
        final words = RecoveryWords.generate();
        expect(words, hasLength(12));
        expect(RecoveryWords.valid(words), isTrue);
        final typo = [...words]..[3] = words[3] == 'zoo' ? 'zone' : 'zoo';
        // One in sixteen typos still checks out, the way BIP-39's checksum works; never this one.
        if (RecoveryWords.valid(typo)) continue;
        expect(RecoveryWords.parse(typo.join(' ')), isNull);
      }
    });

    test('pasted from wherever they were kept: spaces, new lines, dashes, numbers, a title', () {
      final words = RecoveryWords.generate();
      final forms = [
        words.join(' '),
        words.join('\n'),
        words.join('-'),
        words.join(', '),
        '  ${words.map((w) => w.toUpperCase()).join('   ')}  ',
        [for (final (i, w) in words.indexed) '${i + 1}. $w'].join('\n'),
        'Den recovery words for Dana\n\n${words.join(' ')}\n\nKeep them private.',
        words.map((w) => w.length > 4 ? w.substring(0, 4) : w).join(' '),
      ];
      for (final text in forms) {
        expect(RecoveryWords.parse(text), words, reason: text);
      }
      expect(RecoveryWords.parse(words.take(11).join(' ')), isNull);
      expect(RecoveryWords.countIn(words.take(7).join(' ')), 7);
    });

    test('the same words always stretch to the same key, and other words to another', () async {
      final words = RecoveryWords.generate();
      final a = await RecoveryWords.key(words);
      final b = await RecoveryWords.key(words.map((w) => w.toUpperCase()).toList());
      expect(a.publicKey, b.publicKey);
      final other = await RecoveryWords.key(RecoveryWords.generate());
      expect(other.publicKey, isNot(a.publicKey));
    });
  });

  group('joining with recovery', () {
    late TestFamily fam;
    late Den hub;
    late SyncNode hubNode;
    late List<String> words;

    setUp(() async {
      if (await skipUnlessDenCore()) return;
      fam = await TestFamily.create();
      await fam.founder.addEvent(title: 'Dentist', start: at(15), end: at(16));
      await fam.founder.addEvent(title: 'Date night', start: at(20), end: at(22), audience: Audience.parents);
      words = RecoveryWords.generate();
      await fam.founder.setRecoveryKey(fam.parent, (await RecoveryWords.key(words)).publicKey);
      hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
      hubNode = SyncNode(hub);
      final phoneNode = SyncNode(fam.founder);
      await (await link(phoneNode, hubNode)).live;
      await converge([fam.founder, hub]);
      // Pat's phone is gone, and no other parent device is left.
      await phoneNode.close();
      addTearDown(hubNode.close);
    });

    Future<(Den, SyncNode)> newPhone() async {
      final den = await openDen();
      final node = SyncNode(den);
      addTearDown(node.close);
      return (den, node);
    }

    test('the words say whose they are; once confirmed, the new phone is in as that parent', () async {
      if (await skipUnlessDenCore()) return;
      final (phone, node) = await newPhone();
      final p = pipe<dynamic>();
      unawaited(hubNode.serve(p.b));
      final attempt = await node.joinWithRecoveryWords(p.a, words, deviceName: 'Pat new phone', kind: DeviceKind.phone);
      final who = await attempt.recoveringAs;
      expect(who.name, 'Pat');
      expect(who.member, fam.parent);
      expect(who.familyName, 'The Parks');
      expect(who.familyId, fam.founder.familyId);
      expect(phone.hasFamily, isFalse, reason: 'nothing is written until the person says it\'s them');
      await attempt.confirmRecovery();
      await attempt.completed;
      expect(phone.isApproved, isTrue);
      expect(phone.owner?.name, 'Pat');
      expect(await phone.spaceKey(Space.parents), await hub.spaceKey(Space.parents));
      expect(jsonEncode(phone.exportJson()), contains('Date night'));
      expect(recoveryOf(hub.device(phone.deviceId)!)?.kind, RecoveryKind.words);
      expect(hubNode.pendingJoins, isEmpty, reason: 'nobody had to approve it');
    });

    test('words that belong to nobody here are refused, and nothing is learned', () async {
      if (await skipUnlessDenCore()) return;
      final (phone, node) = await newPhone();
      final p = pipe<dynamic>();
      unawaited(hubNode.serve(p.b));
      final attempt = await node.joinWithRecoveryWords(p.a, RecoveryWords.generate(), deviceName: 'x', kind: DeviceKind.phone);
      await expectLater(attempt.recoveringAs, throwsA(isA<JoinException>().having((e) => e.reason, 'reason', 'bad-proof')));
      expect(phone.hasFamily, isFalse);
      expect(hub.devices.where((d) => d.id == phone.deviceId), isEmpty);
    });

    test('the joiner trusts nothing from a side that can\'t show it holds the family\'s record', () async {
      if (await skipUnlessDenCore()) return;
      final impostor = await TestFamily.create(name: 'Mallory');
      final (phone, node) = await newPhone();
      final p = pipe<dynamic>();
      final fake = Session.accept(p.b, keys: impostor.founder.keys, familyId: impostor.founder.familyId);
      final attempt = await node.joinWithRecoveryWords(p.a, words, deviceName: 'Pat new phone', kind: DeviceKind.phone);
      final server = await fake;
      await server.send({
        't': 'pair_ok',
        'family': impostor.founder.familyId,
        'founder': impostor.founder.keys.pubkey,
        'proof': b64e(List.filled(32, 7)),
        'member': {'id': 'abc', 'name': 'Pat'},
      }).catchError((Object _) {});
      await expectLater(attempt.recoveringAs, throwsA(isA<JoinException>()));
      expect(phone.hasFamily, isFalse);
    });

    test('a proof the hub signed with the key the family trusts lets the new phone in', () async {
      if (await skipUnlessDenCore()) return;
      final server = await RecoveryKey.generate();
      await hub.ingest(await _serverKeyOn(fam, server));
      final (phone, node) = await newPhone();
      final invite = Invite.create(
        familyId: hub.familyId!,
        founderPubkey: fam.founderPubkey,
        inviterDevice: hub.deviceId,
        inviterPubkey: hub.keys.pubkey,
        validFor: const Duration(minutes: 30),
      );
      hubNode.invites.add(invite);
      final proof = await server.prove(
        family: hub.familyId!,
        kind: RecoveryKind.hub,
        member: fam.parent,
        devicePubkey: phone.keys.pubkey,
        expires: DateTime.now().toUtc().add(const Duration(minutes: 30)).millisecondsSinceEpoch,
      );
      final p = pipe<dynamic>();
      unawaited(hubNode.serve(p.b));
      final attempt = await node.joinWithRecoveryProof(p.a, invite, proof, deviceName: 'Pat new phone', kind: DeviceKind.phone);
      await attempt.completed;
      expect(phone.isApproved, isTrue);
      expect(phone.owner?.name, 'Pat');
      expect(recoveryOf(hub.device(phone.deviceId)!)?.kind, RecoveryKind.hub);
    });

    test('a proof past its expiry is turned away at the door', () async {
      if (await skipUnlessDenCore()) return;
      final server = await RecoveryKey.generate();
      await hub.ingest(await _serverKeyOn(fam, server));
      final (phone, node) = await newPhone();
      final invite = Invite.create(
        familyId: hub.familyId!,
        founderPubkey: fam.founderPubkey,
        inviterDevice: hub.deviceId,
        inviterPubkey: hub.keys.pubkey,
      );
      hubNode.invites.add(invite);
      final proof = await server.prove(
        family: hub.familyId!,
        kind: RecoveryKind.hub,
        member: fam.parent,
        devicePubkey: phone.keys.pubkey,
        expires: DateTime.now().toUtc().subtract(const Duration(seconds: 1)).millisecondsSinceEpoch,
      );
      final p = pipe<dynamic>();
      unawaited(hubNode.serve(p.b));
      final attempt = await node.joinWithRecoveryProof(p.a, invite, proof, deviceName: 'x', kind: DeviceKind.phone);
      await expectLater(attempt.completed, throwsA(isA<JoinException>().having((e) => e.reason, 'reason', 'bad-request')));
      expect(hub.device(phone.deviceId), isNull);
    });

    test('with server help off, the hub\'s proof lets nobody in', () async {
      if (await skipUnlessDenCore()) return;
      final server = await RecoveryKey.generate();
      final (phone, node) = await newPhone();
      final invite = Invite.create(
        familyId: hub.familyId!,
        founderPubkey: fam.founderPubkey,
        inviterDevice: hub.deviceId,
        inviterPubkey: hub.keys.pubkey,
      );
      hubNode.invites.add(invite);
      final proof = await server.prove(
        family: hub.familyId!,
        kind: RecoveryKind.hub,
        member: fam.parent,
        devicePubkey: phone.keys.pubkey,
        expires: DateTime.now().toUtc().add(const Duration(minutes: 30)).millisecondsSinceEpoch,
      );
      final p = pipe<dynamic>();
      unawaited(hubNode.serve(p.b));
      final attempt = await node.joinWithRecoveryProof(p.a, invite, proof, deviceName: 'x', kind: DeviceKind.phone);
      await expectLater(attempt.completed, throwsA(isA<JoinException>().having((e) => e.reason, 'reason', 'invalid')));
      expect(hub.device(phone.deviceId)?.approved ?? false, isFalse);
    });
  });
}

/// The founder's change turning server help on with [server]'s key.
Future<List<Change>> _serverKeyOn(TestFamily fam, RecoveryKey server) async {
  final before = fam.founder.versionVector;
  await fam.founder.setServerRecoveryKey(server.publicKey);
  return fam.founder.changesSince(before);
}
