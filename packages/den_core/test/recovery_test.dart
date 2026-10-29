import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Recovery (recovery.dart): a parent whose phone is gone, with no other parent device left to
/// approve a new one, lets the new phone in with their recovery words, or with the hub's key
/// when the family turned that on. Every replica decides by the same rules.
void main() {
  late TestClock clock;
  late Den parent;
  late Den hub;
  late String dana;
  late String leo;
  late RecoveryKey words;

  const minute = 60000;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 28, 15));
    parent = await foundFamily(clock);
    dana = parent.actor!.id;
    leo = await parent.addMember(name: 'Leo', role: Role.kid);
    hub = await joinDevice(parent, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
    words = await RecoveryKey.fromSeed(List.generate(32, (i) => i));
    await parent.setRecoveryKey(dana, words.publicKey);
    await sync(parent, hub);
  });

  /// A fresh phone, its proof signed by [key] for [member], and the replica [to] ingesting its
  /// recovery change.
  Future<(Den phone, IngestResult result)> recover(
    RecoveryKey key, {
    Den? to,
    String? member,
    RecoveryKind kind = RecoveryKind.words,
    Duration life = const Duration(minutes: 15),
  }) async {
    final target = to ?? hub;
    // A new phone's clock reads later than what the family wrote before it was lost.
    clock.advance(const Duration(seconds: 1));
    final phone = await openDen(clock);
    final proof = await key.prove(
      family: parent.familyId!,
      kind: kind,
      member: member ?? dana,
      devicePubkey: phone.keys.pubkey,
      expires: clock.now + life.inMilliseconds,
    );
    await phone.requestRecovery(
      familyId: parent.familyId!,
      founderPubkey: parent.founderPubkey!,
      deviceName: 'Dana\'s new phone',
      kind: DeviceKind.phone,
      proof: proof,
    );
    final result = await target.ingest(phone.changesSince(target.versionVector));
    return (phone, result);
  }

  /// A recovery change [phoneKeys] signs itself, clocked at [millis], with [proof].
  Future<Change> recoveryChange(DeviceKeys phoneKeys, RecoveryProof proof, {required int millis, int counter = 1}) async =>
      forge(
        phoneKeys,
        counter: counter,
        millis: millis,
        type: RecordType.device,
        rid: await phoneKeys.deviceId(),
        fields: {
          'name': 'Phone',
          'kind': 'phone',
          'pubkey': phoneKeys.pubkey,
          'xpub': phoneKeys.xpub,
          'member': proof.member,
          'mode': 'personal',
          'approved': true,
          'recovery': proof.toJson(),
        },
      );

  group('recovery words', () {
    test('a valid proof lets a new phone in as the parent\'s own, and it can act as them', () async {
      final (phone, result) = await recover(words);
      expect(result.invalid, isEmpty);
      final d = hub.device(phone.deviceId)!;
      expect(d.approved, isTrue);
      expect(d.member, dana);
      expect(d.mode, DeviceMode.personal);
      expect(recoveryOf(d)?.kind, RecoveryKind.words);
      expect(phone.isApproved, isFalse, reason: 'it holds none of the log yet, so it can\'t tell');
      await sync(hub, phone);
      expect(phone.isApproved, isTrue);
      expect(phone.owner?.name, 'Dana');
      expect(phone.readableSpaces, containsAll([Space.family, Space.parents, Space.member(dana)]));
      // A parent again: a trust decision on their own device.
      await phone.setSignIn(leo, kind: 'pin', secret: '1234');
      await sync(phone, hub);
      expect(hub.member(leo)!.signIn.kind, 'pin');
      // History says how it got in: the new phone, with no one acting for it.
      final entry = hub.history().firstWhere((h) => h.rid == phone.deviceId && h.type == RecordType.device);
      expect(entry.actor, isNull);
      expect(entry.actorName, 'Dana\'s new phone');
      expect(entry.diffs.firstWhere((d) => d.field == 'recovery').after, {'kind': 'words', 'member': dana});
    });

    test('the same rules hold on every replica, the new phone\'s own included', () async {
      final (phone, _) = await recover(words, to: parent);
      await sync(parent, hub);
      await sync(parent, phone);
      for (final den in [parent, hub, phone]) {
        expect(den.device(phone.deviceId)!.approved, isTrue);
      }
    });

    test('words that aren\'t the parent\'s let nobody in', () async {
      final other = await RecoveryKey.generate();
      final (phone, result) = await recover(other);
      expect(result.invalid.values.single, contains('aren\'t Dana\'s recovery words'));
      expect(hub.device(phone.deviceId), isNull);
    });

    test('a proof that claims the parent\'s key but was signed by another is refused on arrival', () async {
      clock.advance(const Duration(seconds: 1));
      final phone = await DeviceKeys.generate();
      final other = await RecoveryKey.generate();
      final real = await other.prove(
        family: parent.familyId!,
        kind: RecoveryKind.words,
        member: dana,
        devicePubkey: phone.pubkey,
        expires: clock.now + 10 * minute,
      );
      final claimed = RecoveryProof(
        kind: real.kind,
        member: real.member,
        key: words.publicKey,
        nonce: real.nonce,
        expires: real.expires,
        sig: real.sig,
      );
      final change = await recoveryChange(phone, claimed, millis: clock.now);
      final result = await hub.ingest([change]);
      expect(result.rejected.keys, [change.id], reason: 'never stored, like a forged signature');
      expect(hub.device(change.rid), isNull);
    });

    test('a proof is used once: its nonce is in the log', () async {
      clock.advance(const Duration(seconds: 1));
      final first = await DeviceKeys.generate();
      final second = await DeviceKeys.generate();
      final proof = await words.prove(
        family: parent.familyId!,
        kind: RecoveryKind.words,
        member: dana,
        devicePubkey: first.pubkey,
        expires: clock.now + 10 * minute,
      );
      expect((await hub.ingest([await recoveryChange(first, proof, millis: clock.now)])).invalid, isEmpty);
      // The same words, nonce and expiry signed again for another device.
      final again = RecoveryProof(
        kind: RecoveryKind.words,
        member: dana,
        key: words.publicKey,
        nonce: proof.nonce,
        expires: proof.expires,
        sig: await words.sign(RecoveryProof.bytes(
          family: parent.familyId!,
          kind: RecoveryKind.words,
          member: dana,
          devicePubkey: second.pubkey,
          nonce: proof.nonce,
          expires: proof.expires,
        )),
      );
      clock.advance(const Duration(seconds: 5));
      final result = await hub.ingest([await recoveryChange(second, again, millis: clock.now)]);
      expect(result.invalid.values.single, contains('already used'));
      // Nor can the first device let itself in a second time.
      final twice = await recoveryChange(first, proof, millis: clock.now + 1, counter: 2);
      expect((await hub.ingest([twice])).invalid.values.single, contains('only a new device'));
    });

    test('an expired proof, or one that claims too long a life, lets nobody in', () async {
      clock.advance(const Duration(seconds: 1));
      final phone = await DeviceKeys.generate();
      final proof = await words.prove(
        family: parent.familyId!,
        kind: RecoveryKind.words,
        member: dana,
        devicePubkey: phone.pubkey,
        expires: clock.now + 10 * minute,
      );
      final late = await recoveryChange(phone, proof, millis: clock.now + 11 * minute);
      expect((await hub.ingest([late])).invalid.values.single, contains('expired'));
      final (_, long) = await recover(words, life: const Duration(hours: 2));
      expect(long.invalid.values.single, contains('an hour at most'));
    });

    test('recovery lets in a phone only for someone who already is a parent', () async {
      final (_, forKid) = await recover(words, member: leo);
      expect(forKid.invalid.values.single, contains('only for a parent'));
      // Dana is a parent no more: her words let nobody in.
      final sam = await parent.addMember(name: 'Sam', role: Role.parent);
      final samPhone = await joinDevice(parent, clock, member: sam, name: 'Sam phone', kind: DeviceKind.phone);
      await sync(parent, samPhone);
      await samPhone.updateMember(dana, {'role': Role.adult.name});
      await sync(samPhone, hub);
      final (_, adult) = await recover(words);
      expect(adult.invalid.values.single, contains('only for a parent'));
    });

    test('a recovery change can\'t make the device shared, someone else\'s, or act for anyone', () async {
      clock.advance(const Duration(seconds: 1));
      final phone = await DeviceKeys.generate();
      final proof = await words.prove(
        family: parent.familyId!,
        kind: RecoveryKind.words,
        member: dana,
        devicePubkey: phone.pubkey,
        expires: clock.now + 10 * minute,
      );
      final good = await recoveryChange(phone, proof, millis: clock.now);
      Future<String> refused(Map<String, Object?> fields, {String? actor}) async {
        final c = await forge(
          phone,
          counter: 1,
          millis: clock.now,
          type: RecordType.device,
          rid: good.rid,
          fields: {...good.fields, ...fields},
          actor: actor,
        );
        final den = await hub.fork();
        return (await den.ingest([c])).invalid.values.single;
      }

      expect(await refused({'mode': 'shared'}), contains('own device'));
      expect(await refused({'member': leo}), contains('someone else'));
      expect(await refused({'approvedBy': dana}), contains('only its own name'));
      expect(await refused({}, actor: dana), contains('can\'t act for anyone'));
    });

    test('new words replace the old: old words let nobody in, even clocked before the change', () async {
      // Dana's phone made new words; it knew of no phone the old ones let in.
      final before = clock.now;
      clock.advance(const Duration(minutes: 5));
      final fresh = await RecoveryKey.generate();
      await parent.setRecoveryKey(dana, fresh.publicKey);
      await sync(parent, hub);
      final (_, now) = await recover(words);
      expect(now.invalid.values.single, contains('aren\'t Dana\'s recovery words'));
      // Someone who kept the old words signs a change dated before the new ones.
      final phone = await DeviceKeys.generate();
      final proof = await words.prove(
        family: parent.familyId!,
        kind: RecoveryKind.words,
        member: dana,
        devicePubkey: phone.pubkey,
        expires: before + 10 * minute,
      );
      final backdated = await recoveryChange(phone, proof, millis: before + 1000);
      final result = await hub.ingest([backdated]);
      expect(result.invalid.values.single, contains('replaced'));
      expect(hub.device(backdated.rid), isNull);
      // The new words work.
      final (phone2, ok) = await recover(fresh);
      expect(ok.invalid, isEmpty);
      expect(hub.device(phone2.deviceId)!.approved, isTrue);
    });

    test('a phone the old words let in stays in when the new words name it', () async {
      final (phone, _) = await recover(words);
      await sync(hub, phone);
      clock.advance(const Duration(minutes: 1));
      final fresh = await RecoveryKey.generate();
      await phone.setRecoveryKey(dana, fresh.publicKey);
      await sync(phone, hub);
      expect(hub.member(dana)!.rec.fields['recovery'], {
        'key': fresh.publicKey,
        'kept': [phone.deviceId],
      });
      expect(hub.device(phone.deviceId)!.approved, isTrue);
      expect(hub.isApproved, isTrue);
    });

    test('only the parent sets up their own words, on their own device', () async {
      final sam = await parent.addMember(name: 'Sam', role: Role.parent);
      await expectLater(parent.setRecoveryKey(sam, words.publicKey), throwsA(isA<PermissionDenied>()));
      await expectLater(parent.setRecoveryKey(leo, words.publicKey), throwsA(isA<PermissionDenied>()));
      // Any parent on their own device may take someone's words away.
      await parent.setRecoveryKey(dana, null);
      expect(recoveryKeyOf(parent.member(dana)!), isNull);
      // Not a shared screen, and never the hub, whoever it acts for.
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      display.actAs(dana);
      await expectLater(display.setRecoveryKey(dana, words.publicKey), throwsA(isA<PermissionDenied>()));
      hub.actAs(dana, via: 'Claude');
      await expectLater(hub.setRecoveryKey(dana, words.publicKey), throwsA(isA<PermissionDenied>()));
      hub.actAs(null);
    });
  });

  group('"That wasn\'t us"', () {
    late String sam;
    late Den samPhone;

    setUp(() async {
      sam = await parent.addMember(name: 'Sam', role: Role.parent);
      samPhone = await joinDevice(parent, clock, member: sam, name: 'Sam phone', kind: DeviceKind.phone);
      await exchange(parent, hub);
      await exchange(samPhone, hub);
    });

    test('removes the phone, turns off the words it used, and lists what it let in', () async {
      // Someone with Dana's words gets a phone in, and before anyone looks, lets in an iPad as
      // Sam's, which lets in one more.
      final (intruder, _) = await recover(words);
      await exchange(hub, intruder);
      final ipad = await joinDevice(intruder, clock, member: sam, name: 'Sam iPad');
      final laptop = await joinDevice(ipad, clock, member: sam, name: 'Sam laptop', kind: DeviceKind.desktop);
      await exchange(ipad, intruder);
      await exchange(intruder, hub);
      await exchange(hub, samPhone);
      final before = clock.now;
      clock.advance(const Duration(minutes: 2));

      final done = await samPhone.disownRecovery(intruder.deviceId);
      expect(done.kind, RecoveryKind.words);
      expect(done.member, dana);
      expect(done.retired, isTrue);
      expect(done.letIn.map((d) => d.id), [ipad.deviceId, laptop.deviceId]);
      expect(samPhone.device(intruder.deviceId)!.revoked, isTrue);
      expect(samPhone.member(dana)!.rec.fields['recovery'], {
        'key': null,
        'kept': [intruder.deviceId],
      });
      for (final d in done.letIn) {
        await samPhone.revokeDevice(d.id);
      }
      await exchange(samPhone, hub);
      expect(hub.device(ipad.deviceId)!.revoked, isTrue);
      expect(hub.device(laptop.deviceId)!.revoked, isTrue);
      expect(samPhone.letInBy(intruder.deviceId), isEmpty);

      // The same words let nobody in now, nor clocked before the change.
      final (_, again) = await recover(words);
      expect(again.invalid.values.single, contains('no recovery words'));
      final phone = await DeviceKeys.generate();
      final proof = await words.prove(
        family: parent.familyId!,
        kind: RecoveryKind.words,
        member: dana,
        devicePubkey: phone.pubkey,
        expires: before + 10 * minute,
      );
      final backdated = await recoveryChange(phone, proof, millis: before + 1000);
      expect((await hub.ingest([backdated])).invalid.values.single, contains('replaced'));
    });

    test('turns off the hub\'s help when the hub let the phone in', () async {
      final server = await RecoveryKey.generate();
      await parent.setServerRecoveryKey(server.publicKey);
      await exchange(parent, hub);
      final (intruder, _) = await recover(server, kind: RecoveryKind.hub);
      await exchange(hub, samPhone);
      clock.advance(const Duration(minutes: 1));
      final done = await samPhone.disownRecovery(intruder.deviceId);
      expect(done.kind, RecoveryKind.hub);
      expect(done.retired, isTrue);
      expect(done.letIn, isEmpty);
      expect(serverRecoveryKeyOf(samPhone.family!), isNull);
      await exchange(samPhone, hub);
      final (_, again) = await recover(server, kind: RecoveryKind.hub);
      expect(again.invalid.values.single, contains('hasn\'t let the hub help'));
    });

    test('leaves words alone that were already replaced', () async {
      final (intruder, _) = await recover(words);
      await exchange(hub, parent);
      clock.advance(const Duration(minutes: 1));
      final fresh = await RecoveryKey.generate();
      await parent.setRecoveryKey(dana, fresh.publicKey);
      final done = await parent.disownRecovery(intruder.deviceId);
      expect(done.retired, isFalse);
      expect(recoveryKeyOf(parent.member(dana)!), fresh.publicKey);
      expect(parent.device(intruder.deviceId)!.revoked, isTrue);
    });
  });

  group('someone who is a parent no longer', () {
    late String sam;
    late Den samPhone;

    setUp(() async {
      sam = await parent.addMember(name: 'Sam', role: Role.parent);
      samPhone = await joinDevice(parent, clock, member: sam, name: 'Sam phone', kind: DeviceKind.phone);
      await exchange(parent, hub);
      await exchange(samPhone, hub);
      clock.advance(const Duration(days: 3));
    });

    for (final how in ['made an adult', 'removed']) {
      test('$how, their old words let nobody in, even with changes clocked before, and approve nothing', () async {
        final t1 = clock.now;
        if (how == 'made an adult') {
          await samPhone.updateMember(dana, {'role': Role.adult.name});
          expect(recoveryKeyOf(samPhone.member(dana)!), isNull, reason: 'their words go in the same change');
        } else {
          await samPhone.removeMember(dana);
        }
        await exchange(samPhone, hub);
        clock.advance(const Duration(days: 20));
        // Weeks later, with the words: a new device D clocked just before, which approves Y as
        // Sam's own phone, and Y, now, as Sam, gives Dana back what she had.
        final d = await DeviceKeys.generate();
        final y = await DeviceKeys.generate();
        final yId = await y.deviceId();
        final proof = await words.prove(
          family: parent.familyId!,
          kind: RecoveryKind.words,
          member: dana,
          devicePubkey: d.pubkey,
          expires: t1 + 5 * minute,
        );
        final rec = await recoveryChange(d, proof, millis: t1 - 30000);
        final yJoin = await forge(y, counter: 1, millis: t1 - 40000, type: RecordType.device, rid: yId, fields: {
          'name': 'Sam new phone',
          'kind': 'phone',
          'pubkey': y.pubkey,
          'xpub': y.xpub,
          'mode': 'personal',
          'member': null,
          'approved': false,
        });
        final approve = await forge(d, counter: 2, millis: t1 - 20000, type: RecordType.device, rid: yId, actor: dana, fields: {
          'approved': true,
          'approvedBy': dana,
          'member': sam,
          'mode': 'personal',
        });
        final restore = await forge(y, counter: 2, millis: clock.now, type: RecordType.member, rid: dana, actor: sam, fields: {
          if (how == 'removed') '_deleted': false else 'role': 'parent',
        });
        final result = await hub.ingest([yJoin, rec, approve, restore]);
        expect(result.invalid[rec.id], contains('replaced'));
        expect(hub.device(rec.rid)?.approved ?? false, isFalse);
        expect(hub.device(yId)?.approved ?? false, isFalse);
        expect(result.invalid.keys, containsAll([approve.id, restore.id]));
        if (how == 'made an adult') {
          expect(hub.member(dana)!.isParent, isFalse);
        } else {
          expect(hub.member(dana), isNull);
        }
        await exchange(hub, samPhone);
        expect(samPhone.device(yId)?.approved ?? false, isFalse);
      });
    }

    test('a phone their words let in before stays theirs', () async {
      final (phone, _) = await recover(words);
      await exchange(hub, samPhone);
      clock.advance(const Duration(hours: 1));
      await samPhone.updateMember(dana, {'role': Role.adult.name});
      await exchange(samPhone, hub);
      expect(hub.member(dana)!.rec.fields['recovery'], {
        'key': null,
        'kept': [phone.deviceId],
      });
      expect(hub.device(phone.deviceId)!.approved, isTrue);
      // Made a parent again, they need new words: the old ones let nobody in.
      await samPhone.updateMember(dana, {'role': Role.parent.name});
      await exchange(samPhone, hub);
      final (_, again) = await recover(words);
      expect(again.invalid.values.single, contains('no recovery words'));
    });
  });

  group('the hub\'s key', () {
    late RecoveryKey server;

    setUp(() async {
      server = await RecoveryKey.generate();
    });

    test('lets nobody in until a parent turns server help on, and nobody once it is off', () async {
      final (_, off) = await recover(server, kind: RecoveryKind.hub);
      expect(off.invalid.values.single, contains('hasn\'t let the hub help'));
      clock.advance(const Duration(minutes: 1));
      await parent.setServerRecoveryKey(server.publicKey);
      await sync(parent, hub);
      final (phone, on) = await recover(server, kind: RecoveryKind.hub);
      expect(on.invalid, isEmpty);
      expect(recoveryOf(hub.device(phone.deviceId)!)?.kind, RecoveryKind.hub);
      await sync(hub, parent);
      clock.advance(const Duration(minutes: 1));
      await parent.setServerRecoveryKey(null);
      await sync(parent, hub);
      final (_, again) = await recover(server, kind: RecoveryKind.hub);
      expect(again.invalid.values.single, contains('hasn\'t let the hub help'));
      expect(hub.family!.rec.fields['recovery'], {'serverKey': null, 'kept': [phone.deviceId]});
      expect(hub.device(phone.deviceId)!.approved, isTrue, reason: 'Dana\'s phone knew of it, so it stays');
    });

    test('a phone the hub let in that the parent turning it off never heard of is out', () async {
      await parent.setServerRecoveryKey(server.publicKey);
      await sync(parent, hub);
      final (phone, on) = await recover(server, kind: RecoveryKind.hub);
      expect(on.invalid, isEmpty);
      // Dana's phone hasn't synced since, and turns server help off.
      clock.advance(const Duration(minutes: 1));
      await parent.setServerRecoveryKey(null);
      await sync(parent, hub);
      expect(hub.device(phone.deviceId), isNull, reason: 'as if the hub had never let it in');
    });

    test('a key the family turned off stays useless, even for a change clocked while it was on', () async {
      final on = clock.now;
      await parent.setServerRecoveryKey(server.publicKey);
      clock.advance(const Duration(minutes: 5));
      await parent.setServerRecoveryKey(null);
      await sync(parent, hub);
      final phone = await DeviceKeys.generate();
      final proof = await server.prove(
        family: parent.familyId!,
        kind: RecoveryKind.hub,
        member: dana,
        devicePubkey: phone.pubkey,
        expires: on + 30 * minute,
      );
      final backdated = await recoveryChange(phone, proof, millis: on + minute);
      expect((await hub.ingest([backdated])).invalid.values.single, contains('replaced'));
      expect((await parent.ingest([backdated])).invalid.values.single, contains('replaced'));
    });

    test('another key than the one the family trusts lets nobody in', () async {
      await parent.setServerRecoveryKey(server.publicKey);
      await sync(parent, hub);
      final other = await RecoveryKey.generate();
      final (_, result) = await recover(other, kind: RecoveryKind.hub);
      expect(result.invalid.values.single, contains('isn\'t the hub key'));
      final (_, asWords) = await recover(server);
      expect(asWords.invalid.values.single, contains('aren\'t Dana\'s recovery words'));
    });

    test('only a parent on their own device turns server help on or off', () async {
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      display.actAs(dana);
      await expectLater(display.setServerRecoveryKey(server.publicKey), throwsA(isA<PermissionDenied>()));
      hub.actAs(dana, via: 'Claude');
      await expectLater(hub.setServerRecoveryKey(server.publicKey), throwsA(isA<PermissionDenied>()));
      hub.actAs(null);
      await expectLater(hub.setServerRecoveryKey(server.publicKey), throwsA(isA<PermissionDenied>()),
          reason: 'a hub nobody owns never administers the family');
      final leoTablet = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
      await expectLater(leoTablet.setServerRecoveryKey(server.publicKey), throwsA(isA<PermissionDenied>()));
    });
  });
}
