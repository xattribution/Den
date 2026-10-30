import 'package:den_core/den_core.dart';
import 'package:den_core/src/snapshot.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Invite keys (invite_keys.dart): a parent's own device writes "this key may let in one
/// personal device for Leo until tomorrow", sends the key's secret in the invite, and the new
/// device lets itself in with a proof signed by it. Every replica decides by the same rules.
void main() {
  late TestClock clock;
  late Den parent;
  late Den hub;
  late String dana;
  late String sam;
  late String leo;

  const minute = 60000;
  const hour = 60 * minute;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 28, 15));
    parent = await foundFamily(clock);
    dana = parent.actor!.id;
    sam = await parent.addMember(name: 'Sam', role: Role.parent);
    leo = await parent.addMember(name: 'Leo', role: Role.kid);
    hub = await joinDevice(parent, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
    await sync(parent, hub);
  });

  /// An invite made on [by] (Dana's phone by default) for [member], synced to the hub.
  Future<(InviteKey key, String id)> invite({String? member, Den? by, Duration life = const Duration(hours: 24)}) async {
    final maker = by ?? parent;
    final key = await InviteKey.generate();
    clock.advance(const Duration(seconds: 1));
    final id = await maker.createInviteKey(member: member ?? leo, publicKey: key.publicKey, expires: clock.now + life.inMilliseconds);
    await sync(maker, hub);
    clock.advance(const Duration(seconds: 1));
    return (key, id);
  }

  /// [key]'s proof, signed for [device], naming the record [invite] (the key's own unless given).
  Future<InviteProof> proofFor(
    InviteKey key,
    String devicePubkey, {
    String? invite,
    String? member,
    DeviceMode mode = DeviceMode.personal,
    required int expires,
  }) async {
    final nonce = b64e(randomBytes(16));
    final named = invite ?? key.id;
    final sig = await key.sign(InviteProof.bytes(
      family: parent.familyId!,
      invite: named,
      member: member,
      mode: mode,
      devicePubkey: devicePubkey,
      nonce: nonce,
      expires: expires,
    ));
    return InviteProof(invite: named, member: member, mode: mode, key: key.publicKey, nonce: nonce, expires: expires, sig: sig);
  }

  /// A fresh device's join with [key]'s proof for [member], clocked at [millis] (now by default).
  Future<Change> joinChange(
    DeviceKeys device,
    InviteKey key,
    String invite, {
    String? member,
    int? millis,
    int? expires,
    String? proofMember,
  }) async {
    final at = millis ?? clock.now;
    final proof = await proofFor(key, device.pubkey, invite: invite, member: proofMember ?? member ?? leo, expires: expires ?? at + 10 * minute);
    return forge(
      device,
      counter: 1,
      millis: at,
      type: RecordType.device,
      rid: await device.deviceId(),
      fields: {
        'name': "Leo's iPad",
        'kind': 'tablet',
        'pubkey': device.pubkey,
        'xpub': device.xpub,
        'member': member ?? leo,
        'mode': 'personal',
        'approved': true,
        'invite': proof.toJson(),
      },
    );
  }

  /// A new device joining through [to] with [key], the way den_net does it.
  Future<(Den device, IngestResult result)> join(InviteKey key, String invite, {Den? to, String? member}) async {
    clock.advance(const Duration(seconds: 1));
    final device = await openDen(clock);
    expect(invite, key.id);
    final proof = await key.prove(
      family: parent.familyId!,
      member: member ?? leo,
      devicePubkey: device.keys.pubkey,
      expires: clock.now + 10 * minute,
    );
    await device.requestInviteJoin(
      familyId: parent.familyId!,
      founderPubkey: parent.founderPubkey!,
      deviceName: "Leo's iPad",
      kind: DeviceKind.tablet,
      proof: proof,
    );
    final result = await (to ?? hub).ingest(device.changesSince((to ?? hub).versionVector));
    return (device, result);
  }

  test('a valid proof lets the device in at once, as the person the invite is for', () async {
    final (key, id) = await invite();
    final (ipad, result) = await join(key, id);
    expect(result.invalid, isEmpty);
    final d = hub.device(ipad.deviceId)!;
    expect(d.approved, isTrue);
    expect(d.member, leo);
    expect(d.mode, DeviceMode.personal);
    expect(inviteOf(d)?.invite, id);
    expect(hub.usedInvite(id)?.id, ipad.deviceId);
    // Every replica agrees, the new device's own included once the log reaches it.
    await sync(hub, parent);
    await sync(hub, ipad);
    for (final den in [parent, hub, ipad]) {
      expect(den.device(ipad.deviceId)!.approved, isTrue);
    }
    expect(ipad.isApproved, isTrue);
    expect(ipad.owner?.name, 'Leo');
    // It counts as let in by the phone that made the invite.
    expect([for (final d in parent.letInBy(parent.deviceId)) d.id], contains(ipad.deviceId));
    // History says how: the new device, nobody acting for it, and the invite it used.
    final entry = hub.history().firstWhere((h) => h.rid == ipad.deviceId && h.type == RecordType.device);
    expect(entry.actor, isNull);
    expect(entry.verb, 'approved');
  });

  test('used once: a second device with the same key, or the same device again, is refused', () async {
    final (key, id) = await invite();
    final first = await DeviceKeys.generate();
    final second = await DeviceKeys.generate();
    expect((await hub.ingest([await joinChange(first, key, id)])).invalid, isEmpty);
    clock.advance(const Duration(seconds: 5));
    final result = await hub.ingest([await joinChange(second, key, id)]);
    expect(result.invalid.values.single, contains('used already'));
    expect(hub.device(await second.deviceId()), isNull);
  });

  test('an expired invite or proof lets nobody in, and a proof may not outlast its invite', () async {
    final (key, id) = await invite(life: const Duration(hours: 1));
    final late = await joinChange(await DeviceKeys.generate(), key, id, millis: clock.now + 2 * hour);
    expect((await (await hub.fork()).ingest([late])).invalid.values.single, contains('expired'));
    final stale = await joinChange(await DeviceKeys.generate(), key, id, millis: clock.now + 20 * minute, expires: clock.now + 10 * minute);
    expect((await (await hub.fork()).ingest([stale])).invalid.values.single, contains('expired'));
    final long = await joinChange(await DeviceKeys.generate(), key, id, expires: clock.now + 3 * hour);
    expect((await (await hub.fork()).ingest([long])).invalid.values.single, contains('outlasts'));
  });

  test("the invite's person only: a proof for someone else, or a device asking to be someone else's", () async {
    final (key, id) = await invite();
    final wrongProof = await joinChange(await DeviceKeys.generate(), key, id, proofMember: dana);
    expect((await (await hub.fork()).ingest([wrongProof])).invalid.values.single, contains('someone else'));
    final asDana = await joinChange(await DeviceKeys.generate(), key, id, member: dana);
    expect((await (await hub.fork()).ingest([asDana])).invalid.values.single, contains('someone else'));
    // Nor shared, or acting for anyone.
    final good = await joinChange(await DeviceKeys.generate(), key, id);
    Future<String> refused(Map<String, Object?> fields, {String? actor}) async {
      final keys = await DeviceKeys.generate();
      final c = await joinChange(keys, key, id);
      final forged = await forge(keys, counter: 1, millis: clock.now, type: RecordType.device, rid: c.rid, fields: {...c.fields, ...fields}, actor: actor);
      return (await (await hub.fork()).ingest([forged])).invalid.values.single;
    }

    expect(good.fields['approved'], isTrue);
    expect(await refused({'mode': 'shared'}), contains('another kind of device'));
    expect(await refused({'approvedBy': dana}), contains('only its own name'));
    expect(await refused({}, actor: leo), contains("can't act for anyone"));
  });

  test("a key that isn't the invite's, or a forged proof, lets nobody in", () async {
    final (_, id) = await invite();
    final other = await InviteKey.generate();
    final wrong = await joinChange(await DeviceKeys.generate(), other, id);
    expect((await (await hub.fork()).ingest([wrong])).invalid.values.single, contains("isn't the invite's key"));
    // A proof that names the invite's key but was signed by another is refused on arrival.
    final (real, _) = await invite();
    final phone = await DeviceKeys.generate();
    final signed = await proofFor(other, phone.pubkey, invite: real.id, member: leo, expires: clock.now + minute);
    final claimed = InviteProof(
      invite: real.id,
      member: leo,
      mode: DeviceMode.personal,
      key: real.publicKey,
      nonce: signed.nonce,
      expires: signed.expires,
      sig: signed.sig,
    );
    final c = await forge(phone, counter: 1, millis: clock.now, type: RecordType.device, rid: await phone.deviceId(), fields: {
      'name': 'Phone',
      'kind': 'phone',
      'pubkey': phone.pubkey,
      'member': leo,
      'mode': 'personal',
      'approved': true,
      'invite': claimed.toJson(),
    });
    final result = await hub.ingest([c]);
    expect(result.rejected.keys, [c.id], reason: 'never stored, like a forged signature');
  });

  test('withdrawn: the key lets nobody in, even a join clocked before; a device it let in stays', () async {
    final (key, id) = await invite();
    final before = clock.now + 1000;
    final (kept, ok) = await join(key, id);
    expect(ok.invalid, isEmpty);
    await sync(hub, parent);
    clock.advance(const Duration(minutes: 5));
    await parent.withdrawInviteKey(id);
    expect(parent.inviteKey(id)!.key, isNull);
    expect(parent.inviteKey(id)!.rec.fields['kept'], [kept.deviceId]);
    await sync(parent, hub);
    // Someone who kept the words signs a join dated before the withdrawal.
    final backdated = await joinChange(await DeviceKeys.generate(), key, id, millis: before);
    final result = await hub.ingest([backdated]);
    expect(result.invalid, isNotEmpty);
    expect(hub.device(backdated.rid)?.approved ?? false, isFalse);
    // The device it let in first stays in.
    expect(hub.device(kept.deviceId)!.approved, isTrue);
    // After the withdrawal, plainly refused.
    clock.advance(const Duration(seconds: 1));
    final after = await joinChange(await DeviceKeys.generate(), key, id);
    expect((await (await hub.fork()).ingest([after])).invalid.values.single, contains('withdrawn'));
  });

  test("a join clocked before the withdrawal that its author didn't know of is out", () async {
    final (key, id) = await invite();
    final before = clock.now + 1000;
    clock.advance(const Duration(minutes: 5));
    await parent.withdrawInviteKey(id);
    await sync(parent, hub);
    final backdated = await joinChange(await DeviceKeys.generate(), key, id, millis: before);
    final result = await hub.ingest([backdated]);
    expect(result.invalid.values.single, contains('withdrawn before this device joined'));
  });

  group('the parent who made it', () {
    test('removed before it is used: it lets nobody in', () async {
      final samPhone = await joinDevice(parent, clock, member: sam, name: "Sam's phone", kind: DeviceKind.phone);
      await sync(parent, samPhone);
      final (key, id) = await invite(by: samPhone);
      await sync(hub, parent);
      clock.advance(const Duration(minutes: 1));
      await parent.removeMember(sam);
      await sync(parent, hub);
      expect(hub.inviteKey(id)!.key, isNull, reason: 'taken away in the same commit');
      final (_, result) = await join(key, id);
      expect(result.invalid.values.single, anyOf(contains('withdrawn'), contains("can't let anyone in")));
    });

    test('no longer a parent before it is used: it lets nobody in, backdated or not', () async {
      final samPhone = await joinDevice(parent, clock, member: sam, name: "Sam's phone", kind: DeviceKind.phone);
      await sync(parent, samPhone);
      final (key, id) = await invite(by: samPhone);
      await sync(hub, parent);
      final before = clock.now + 1000;
      clock.advance(const Duration(minutes: 1));
      await parent.updateMember(sam, {'role': Role.adult.name});
      await sync(parent, hub);
      expect(hub.inviteKey(id)!.key, isNull);
      final (_, now) = await join(key, id);
      expect(now.invalid, isNotEmpty);
      final backdated = await joinChange(await DeviceKeys.generate(), key, id, millis: before);
      expect((await hub.ingest([backdated])).invalid.values.single, contains('withdrawn before this device joined'));
    });

    test("demoted on a replica that hadn't heard of the invite yet: still nobody gets in", () async {
      // The role change comes from a phone that never saw the invite, so it names nothing to
      // take away; the join, clocked after it, finds no parent behind the invite.
      final samPhone = await joinDevice(parent, clock, member: sam, name: "Sam's phone", kind: DeviceKind.phone);
      final (key, id) = await invite(by: samPhone);
      clock.advance(const Duration(minutes: 1));
      await parent.updateMember(sam, {'role': Role.adult.name});
      await sync(parent, hub);
      expect(hub.inviteKey(id)!.key, isNotNull);
      final (_, result) = await join(key, id);
      expect(result.invalid.values.single, contains("can't let anyone in any more"));
    });

    test('their device removed before it is used: it lets nobody in, backdated or not', () async {
      final samPhone = await joinDevice(parent, clock, member: sam, name: "Sam's phone", kind: DeviceKind.phone);
      await sync(parent, samPhone);
      final (key, id) = await invite(by: samPhone);
      await sync(hub, parent);
      final before = clock.now + 1000;
      clock.advance(const Duration(minutes: 1));
      await parent.revokeDevice(samPhone.deviceId);
      await sync(parent, hub);
      expect(hub.inviteKey(id)!.key, isNull);
      final backdated = await joinChange(await DeviceKeys.generate(), key, id, millis: before);
      expect((await hub.ingest([backdated])).invalid.values.single, contains('withdrawn before this device joined'));
    });

    test('their device removing itself takes its invites away first, and that counts', () async {
      // The revocation names the change just before it in the same commit, the invite taken
      // away, so that one is among the device's changes that count (Den._Draft.ownLast).
      final samPhone = await joinDevice(parent, clock, member: sam, name: "Sam's phone", kind: DeviceKind.phone);
      await sync(parent, samPhone);
      final (key, id) = await invite(by: samPhone);
      await sync(hub, samPhone);
      final before = clock.now + 1000;
      clock.advance(const Duration(minutes: 1));
      await samPhone.revokeDevice(samPhone.deviceId);
      final mine = [for (final c in samPhone.changesSince(const {})) if (c.device == samPhone.deviceId) c];
      final withdrawal = mine.lastWhere((c) => c.type == RecordType.inviteKey && c.rid == id);
      final revocation = mine.last;
      expect(revocation.type, RecordType.device);
      expect(revocation.fields['revokedAfter'], withdrawal.counter);
      expect(revocation.counter, withdrawal.counter + 1);
      final result = await hub.ingest(samPhone.changesSince(hub.versionVector));
      expect(result.invalid, isEmpty);
      expect(hub.device(samPhone.deviceId)!.revoked, isTrue);
      expect(hub.inviteKey(id)!.key, isNull, reason: 'the withdrawal in the same commit counts');
      final (_, now) = await join(key, id);
      expect(now.invalid, isNotEmpty);
      final backdated = await joinChange(await DeviceKeys.generate(), key, id, millis: before);
      expect((await hub.ingest([backdated])).invalid.values.single, contains('withdrawn before this device joined'));
    });
  });

  group('who may make one', () {
    test("a parent on their own device, for someone in the family, for a week at most", () async {
      final key = await InviteKey.generate();
      await expectLater(
        parent.createInviteKey(member: leo, publicKey: key.publicKey, expires: clock.now + 8 * 24 * hour),
        throwsA(isA<InvalidInput>()),
      );
      await expectLater(
        parent.createInviteKey(member: leo, publicKey: key.publicKey, expires: clock.now - minute),
        throwsA(isA<InvalidInput>()),
      );
      final kidTablet = await joinDevice(parent, clock, member: leo);
      await expectLater(
        kidTablet.createInviteKey(member: leo, publicKey: key.publicKey, expires: clock.now + hour),
        throwsA(isA<PermissionDenied>()),
      );
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      display.actAs(dana);
      await expectLater(
        display.createInviteKey(member: leo, publicKey: key.publicKey, expires: clock.now + hour),
        throwsA(isA<PermissionDenied>()),
      );
      hub.actAs(dana, via: 'Claude');
      await expectLater(
        hub.createInviteKey(member: leo, publicKey: key.publicKey, expires: clock.now + hour),
        throwsA(isA<PermissionDenied>()),
      );
      hub.actAs(null);
    });

    test("an invite can't be changed or brought back, only withdrawn", () async {
      final (key, id) = await invite();
      final other = await InviteKey.generate();
      Future<String> refused(Map<String, Object?> fields) async {
        final c = await forge(
          parent.keys,
          counter: 1000,
          millis: clock.now + 1000,
          type: RecordType.inviteKey,
          rid: id,
          fields: fields,
          actor: dana,
        );
        return (await (await hub.fork()).ingest([c])).invalid.values.single;
      }

      expect(await refused({'key': other.publicKey}), contains('only be withdrawn'));
      expect(await refused({'member': dana}), contains("can't be changed"));
      expect(await refused({'_deleted': true}), contains('only withdrawn'));
      await parent.withdrawInviteKey(id);
      await expectLater(parent.withdrawInviteKey(id), completes, reason: 'nothing left to withdraw');
      expect(key.publicKey, isNot(other.publicKey));
    });
  });

  test("That wasn't Leo: the device is removed and the invite's key taken away", () async {
    final (key, id) = await invite();
    final (ipad, _) = await join(key, id, to: parent);
    await sync(parent, ipad);
    final done = await parent.disownInvite(ipad.deviceId);
    expect(done.member, leo);
    expect(parent.device(ipad.deviceId)!.revoked, isTrue);
    expect(parent.inviteKey(id)!.key, isNull);
    expect(parent.inviteKey(id)!.rec.fields['kept'], [ipad.deviceId], reason: 'what it did stays on record');
    // History keeps its join; nothing more from it counts.
    await sync(parent, hub);
    expect(hub.device(ipad.deviceId)!.revoked, isTrue);
  });

  test('a key with uses lets in that many devices, and no more', () async {
    final key = await InviteKey.generate();
    clock.advance(const Duration(seconds: 1));
    final id = await parent.createInviteKey(member: leo, publicKey: key.publicKey, expires: clock.now + hour, uses: 2);
    expect(parent.inviteKey(id)!.uses, 2);
    await sync(parent, hub);
    clock.advance(const Duration(seconds: 1));
    for (var i = 0; i < 2; i++) {
      clock.advance(const Duration(seconds: 1));
      expect((await hub.ingest([await joinChange(await DeviceKeys.generate(), key, id)])).invalid, isEmpty);
    }
    clock.advance(const Duration(seconds: 1));
    final third = await joinChange(await DeviceKeys.generate(), key, id);
    expect((await hub.ingest([third])).invalid.values.single, contains('used already'));
    expect(hub.inviteUses(hub.inviteKey(id)!), 0);
  });

  test('a key bound to no one lets in a shared screen or the hub, and never someone\'s own device', () async {
    final key = await InviteKey.generate();
    clock.advance(const Duration(seconds: 1));
    final id = await parent.createInviteKey(member: null, publicKey: key.publicKey, expires: clock.now + hour, modes: {DeviceMode.shared});
    expect(parent.inviteKey(id)!.modes, {DeviceMode.shared});
    await sync(parent, hub);
    clock.advance(const Duration(seconds: 1));
    final display = await openDen(clock);
    final proof = await key.prove(
      family: parent.familyId!,
      member: null,
      mode: DeviceMode.shared,
      devicePubkey: display.keys.pubkey,
      expires: clock.now + 10 * minute,
    );
    await display.requestInviteJoin(
      familyId: parent.familyId!,
      founderPubkey: parent.founderPubkey!,
      deviceName: 'Kitchen',
      kind: DeviceKind.display,
      proof: proof,
    );
    expect((await hub.ingest(display.changesSince(hub.versionVector))).invalid, isEmpty);
    final d = hub.device(display.deviceId)!;
    expect(d.approved, isTrue);
    expect(d.mode, DeviceMode.shared);
    expect(d.member, isNull);
    // The same kind of key can't be turned into a parent's phone.
    final other = await InviteKey.generate();
    clock.advance(const Duration(seconds: 1));
    final otherId = await parent.createInviteKey(member: null, publicKey: other.publicKey, expires: clock.now + hour, modes: {DeviceMode.hub});
    await sync(parent, hub);
    clock.advance(const Duration(seconds: 1));
    final asDana = await joinChange(await DeviceKeys.generate(), other, otherId, member: dana);
    expect((await (await hub.fork()).ingest([asDana])).invalid.values.single, contains('someone else'));
    // A key for no one must name what it lets in; a key for someone lets in only their own.
    await expectLater(
      parent.createInviteKey(member: null, publicKey: (await InviteKey.generate()).publicKey, expires: clock.now + hour),
      throwsA(isA<InvalidInput>()),
    );
    await expectLater(
      parent.createInviteKey(member: leo, publicKey: (await InviteKey.generate()).publicKey, expires: clock.now + hour, modes: {DeviceMode.shared}),
      throwsA(isA<InvalidInput>()),
    );
  });

  test('the key is a plain seed: the same seed, sealed or carried, is the same key', () async {
    final key = await InviteKey.generate();
    final again = await InviteKey.fromSeed(await key.seed());
    expect(again.publicKey, key.publicKey);
    expect(again.id, inviteKeyIdOf(key.publicKey));
  });

  test('a device opened from a snapshot still knows which invite keys were taken away', () async {
    snapshotCheckDelay = Duration.zero;
    final storage = SnapshotMemoryStorage();
    final keys = await DeviceKeys.generate();
    final phone = await openDen(clock, storage: storage, keys: keys);
    await phone.createFamily(
      familyName: 'Rivera family',
      timezone: 'America/New_York',
      yourName: 'Dana',
      deviceName: "Dana's phone",
      deviceKind: DeviceKind.phone,
    );
    final kid = await phone.addMember(name: 'Leo', role: Role.kid);
    final key = await InviteKey.generate();
    clock.advance(const Duration(seconds: 1));
    final id = await phone.createInviteKey(member: kid, publicKey: key.publicKey, expires: clock.now + 24 * hour);
    final before = clock.now + 1000;
    clock.advance(const Duration(minutes: 1));
    await phone.withdrawInviteKey(id);
    final list = await phone.addList(title: 'Groceries', kind: ListKind.shopping);
    for (var i = 0; i < snapshotEvery; i++) {
      await phone.addItem(list, text: 'Item $i');
    }
    await phone.debugIdle();
    expect(storage.saves, greaterThan(0));
    final reopened = await openDen(clock, storage: storage, keys: keys);
    expect(reopened.debugOpenedFromSnapshot, isTrue);
    final device = await DeviceKeys.generate();
    expect(id, key.id);
    final proof = await key.prove(family: reopened.familyId!, member: kid, devicePubkey: device.pubkey, expires: before + minute);
    final backdated = await forge(device, counter: 1, millis: before, type: RecordType.device, rid: await device.deviceId(), fields: {
      'name': "Leo's iPad",
      'kind': 'tablet',
      'pubkey': device.pubkey,
      'member': kid,
      'mode': 'personal',
      'approved': true,
      'invite': proof.toJson(),
    });
    final result = await reopened.ingest([backdated]);
    expect(result.invalid.values.single, contains('withdrawn before this device joined'));
    await reopened.close();
  });
}
