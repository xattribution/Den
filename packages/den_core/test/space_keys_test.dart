import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Hands [to] every bound key [from] holds for the spaces [from] says [to] may hold, the way
/// sessions and the relay pass keys on.
Future<void> passKeys(Den from, Den to) async {
  for (final space in from.spacesForDevice(to.deviceId)) {
    for (final epoch in from.spaceKeyEpochs(space)) {
      for (final k in from.spaceKeysAt(space, epoch)) {
        if (k.bound) await to.addSpaceKey(k);
      }
    }
  }
}

/// Gives a newly joined device the keys of its spaces.
Future<Den> withKeys(Den parent, Den device) async {
  await passKeys(parent, device);
  return device;
}

/// A key [keys] signs as its own, the way a misbehaving device would mint one.
Future<SpaceKey> mint(Den family, DeviceKeys keys, {required String space, required int epoch}) async {
  final by = await keys.deviceId();
  final draft = SpaceKey(space: space, epoch: epoch, key: randomBytes(32), by: by, sig: '');
  return draft.signed(by: by, revoked: const [], sig: await keys.sign(draft.statementBytes(family.familyId!)));
}

void main() {
  late TestClock clock;
  late Den dana;
  late String alex;
  late String leo;
  late Den alexPhone;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 11, 2, 15));
    dana = await foundFamily(clock);
    alex = await dana.addMember(name: 'Alex', role: Role.parent);
    leo = await dana.addMember(name: 'Leo', role: Role.kid);
    alexPhone = await withKeys(dana, await joinDevice(dana, clock, member: alex, name: 'Alex phone', kind: DeviceKind.phone));
  });

  group('a space key and its maker', () {
    test('every key is signed by the device that made it, listing the devices revoked by then', () async {
      final genesis = dana.currentSpaceKey(Space.family)!;
      expect(genesis.bound, isTrue);
      expect(genesis.by, dana.deviceId);
      expect(genesis.epoch, 0);
      expect(genesis.revoked, isEmpty);
      expect(await verifySignature(genesis.statementBytes(dana.familyId!), genesis.sig!, dana.keys.pubkey), isTrue);
      expect(dana.currentSpaceKey(Space.member(leo))!.by, dana.deviceId, reason: 'a new member\'s space key too');

      final tablet = await joinDevice(dana, clock, member: leo);
      await dana.revokeDevice(tablet.deviceId);
      final rotated = dana.currentSpaceKey(Space.family)!;
      expect(rotated.epoch, 1);
      expect(rotated.revoked, [tablet.deviceId]);
      expect(await verifySignature(rotated.statementBytes(dana.familyId!), rotated.sig!, dana.keys.pubkey), isTrue);

      final again = SpaceKey.fromJson(rotated.toJson())!;
      expect(again.hash, rotated.hash);
      expect(again.by, rotated.by);
      expect(again.revoked, rotated.revoked);
      expect(again.sig, rotated.sig);
    });

    test('a key passes between devices only with a statement from a parent\'s device or a hub', () async {
      final tablet = await withKeys(dana, await joinDevice(dana, clock, member: leo));
      expect(tablet.spaceKeyEpoch(Space.family), 0);
      expect(await tablet.addSpaceKey(dana.currentSpaceKey(Space.family)!), SpaceKeyOutcome.duplicate);

      final spare = await joinDevice(dana, clock, member: leo, name: 'Spare');
      await dana.revokeDevice(spare.deviceId);
      await sync(dana, tablet);
      final rotated = dana.currentSpaceKey(Space.family)!;
      final json = rotated.toJson();
      expect(await tablet.addSpaceKey(SpaceKey.fromJson({...json, 'epoch': 7})!), SpaceKeyOutcome.refused);
      expect(await tablet.addSpaceKey(SpaceKey.fromJson({...json, 'revoked': <String>[]})!), SpaceKeyOutcome.refused,
          reason: 'the revoked list is signed too');
      expect(await tablet.addSpaceKey(SpaceKey(space: Space.family, epoch: 1, key: rotated.key)), SpaceKeyOutcome.refused,
          reason: 'a key without a statement stays on the device that stored it');
      expect(SpaceKey.fromJson({...json, 'revoked': ['z', 'a']}), isNull, reason: 'revoked lists are sorted');

      final kidsKey = await mint(dana, tablet.keys, space: Space.family, epoch: 1);
      await sync(dana, alexPhone);
      expect(await alexPhone.addSpaceKey(kidsKey), SpaceKeyOutcome.refused, reason: 'a kid\'s tablet makes no keys');
      expect(await tablet.addSpaceKey(rotated), SpaceKeyOutcome.stored);
      expect(tablet.spaceKeyEpoch(Space.family), 1);
      expect(await tablet.spaceKey(Space.family), rotated.key);
    });

    test('a key from a device this one hasn\'t heard of yet waits for its device record', () async {
      final laptop = await withKeys(dana, await joinDevice(dana, clock, member: alex, name: 'Alex laptop', kind: DeviceKind.desktop));
      final spare = await joinDevice(dana, clock, member: leo, name: 'Spare');
      await sync(dana, laptop);
      await laptop.revokeDevice(spare.deviceId);
      final made = laptop.currentSpaceKey(Space.family)!;
      expect(made.by, laptop.deviceId);

      expect(await alexPhone.addSpaceKey(made), SpaceKeyOutcome.waiting);
      expect(alexPhone.spaceKeyEpoch(Space.family), 0);
      await sync(laptop, alexPhone);
      await sync(dana, alexPhone);
      expect(alexPhone.spaceKeyEpoch(Space.family), 1, reason: 'admitted once the laptop\'s record arrived');
      expect(alexPhone.currentSpaceKey(Space.family)!.hash, made.hash);
    });

    test('a key made by a device after it was revoked never wins', () async {
      final laptop = await withKeys(dana, await joinDevice(dana, clock, member: alex, name: 'Alex laptop', kind: DeviceKind.desktop));
      final tablet = await withKeys(dana, await joinDevice(dana, clock, member: leo));
      await sync(dana, alexPhone);
      final rogue = await mint(dana, laptop.keys, space: Space.family, epoch: 5);
      expect(await tablet.addSpaceKey(rogue), SpaceKeyOutcome.stored, reason: 'the tablet hasn\'t heard yet');
      expect(tablet.spaceKeyEpoch(Space.family), 5);

      await dana.revokeDevice(laptop.deviceId);
      await sync(dana, alexPhone);
      expect(await alexPhone.addSpaceKey(rogue), SpaceKeyOutcome.refused);
      await sync(dana, tablet);
      expect(tablet.spaceKeyEpoch(Space.family), 0, reason: 'nothing seals with the revoked laptop\'s key');
      await passKeys(dana, tablet);
      expect(tablet.currentSpaceKey(Space.family)!.by, dana.deviceId);
      expect(tablet.spaceKeyEpoch(Space.family), dana.spaceKeyEpoch(Space.family));
      expect(await tablet.spaceKey(Space.family), await dana.spaceKey(Space.family));
    });

    test('a key stored without a statement is signed by a parent\'s device before it is passed on', () async {
      final key = randomBytes(32);
      await alexPhone.setSpaceKey(Space.family, key, epoch: 3);
      final shared = (await alexPhone.spaceKeyToShare(Space.family))!;
      expect(shared.bound, isTrue);
      expect(shared.by, alexPhone.deviceId);
      expect(shared.key, key);
      expect(shared.revoked, isEmpty, reason: 'it can\'t vouch for what the key\'s maker knew');
      expect(await dana.addSpaceKey(shared), SpaceKeyOutcome.stored);
      expect(await dana.spaceKey(Space.family), key);

      final tablet = await withKeys(dana, await joinDevice(dana, clock, member: leo));
      await tablet.setSpaceKey(Space.family, randomBytes(32), epoch: 9);
      expect(await tablet.spaceKeyToShare(Space.family), isNull, reason: 'a kid\'s tablet can\'t vouch for a key');
    });

    test('statements survive reopening', () async {
      final storage = MemoryStorage();
      final keys = await DeviceKeys.generate();
      final first = await openDen(clock, storage: storage, keys: keys);
      await first.createFamily(
        familyName: 'Lee family',
        timezone: 'America/Chicago',
        yourName: 'Sam',
        marker: Marker.sunshine,
        animal: Animal.cow,
        deviceName: 'Sam\'s laptop',
        deviceKind: DeviceKind.desktop,
      );
      final tablet = await joinDevice(first, clock, member: first.actor!.id);
      await first.revokeDevice(tablet.deviceId);
      final second = await openDen(clock, storage: storage, keys: keys);
      for (final s in [Space.family, Space.parents]) {
        expect(second.spaceKeyEpochs(s), [0, 1]);
        final k = second.currentSpaceKey(s)!;
        expect(k.hash, first.currentSpaceKey(s)!.hash);
        expect(k.revoked, [tablet.deviceId]);
        expect(k.sig, first.currentSpaceKey(s)!.sig);
      }
    });
  });

  group('two parents rotating at once', () {
    late Den tabletA;
    late Den tabletB;

    setUp(() async {
      tabletA = await withKeys(dana, await joinDevice(dana, clock, member: leo, name: 'Leo tablet'));
      tabletB = await withKeys(dana, await joinDevice(dana, clock, member: leo, name: 'Leo old phone'));
      await sync(dana, alexPhone);
      await passKeys(dana, alexPhone);
    });

    test('every device picks the same key for the epoch, in whatever order the keys arrive', () async {
      // Two kids' devices that make no keys of their own will hear of both, in opposite orders.
      final first = await withKeys(dana, await joinDevice(dana, clock, member: leo, name: 'Leo watch'));
      final second = await withKeys(dana, await joinDevice(dana, clock, member: leo, name: 'Leo laptop'));
      await sync(dana, alexPhone);
      await dana.revokeDevice(tabletA.deviceId);
      await alexPhone.revokeDevice(tabletB.deviceId);
      final fromDana = dana.currentSpaceKey(Space.family)!;
      final fromAlex = alexPhone.currentSpaceKey(Space.family)!;
      expect(fromDana.epoch, 1);
      expect(fromAlex.epoch, 1);
      expect(fromDana.hash, isNot(fromAlex.hash));
      final lower = fromDana.hash.compareTo(fromAlex.hash) < 0 ? fromDana : fromAlex;

      expect(await first.addSpaceKey(fromDana), SpaceKeyOutcome.stored);
      expect(await first.addSpaceKey(fromAlex), SpaceKeyOutcome.stored);
      expect(await second.addSpaceKey(fromAlex), SpaceKeyOutcome.stored);
      expect(await second.addSpaceKey(fromDana), SpaceKeyOutcome.stored);
      for (final d in [first, second]) {
        expect(d.spaceKeyEpoch(Space.family), 1);
        expect(d.currentSpaceKey(Space.family)!.hash, lower.hash, reason: 'the lowest hash wins everywhere');
        expect(d.spaceKeysAt(Space.family, 1).map((k) => k.hash), unorderedEquals([fromDana.hash, fromAlex.hash]),
            reason: 'the other is kept to read what was posted with it');
        expect(d.spaceKeysAt(Space.family, 1).first.hash, lower.hash);
      }
    });

    test('a key that may have reached the other parent\'s revoked device is rotated again, once', () async {
      await dana.revokeDevice(tabletA.deviceId);
      await alexPhone.revokeDevice(tabletB.deviceId);

      // The changes meet first: each parent now knows both revocations, but each key in use
      // still only knows its own maker's, and nothing says it's stale yet.
      await exchange(dana, alexPhone);
      expect(dana.spaceKeyEpoch(Space.family), 1);
      expect(alexPhone.spaceKeyEpoch(Space.family), 1);
      expect(dana.staleSpaceKeys, isEmpty);

      // Then the keys: whichever wins epoch 1 was handed to a device the other parent revoked,
      // so both parents rotate the spaces both tablets held.
      await passKeys(dana, alexPhone);
      await passKeys(alexPhone, dana);
      expect(dana.currentSpaceKey(Space.family, epoch: 1)!.hash, alexPhone.currentSpaceKey(Space.family, epoch: 1)!.hash);
      for (final d in [dana, alexPhone]) {
        for (final s in [Space.family, Space.member(leo)]) {
          expect(d.spaceKeyEpoch(s), 2, reason: s);
          expect(d.currentSpaceKey(s)!.revoked, unorderedEquals([tabletA.deviceId, tabletB.deviceId]), reason: s);
        }
        expect(d.spaceKeyEpoch(Space.parents), 0, reason: 'kids\' devices never held p');
      }

      // The two epoch-2 keys meet; they knew of both revocations, so that's the end of it.
      await passKeys(dana, alexPhone);
      await passKeys(alexPhone, dana);
      for (final d in [dana, alexPhone]) {
        expect(d.staleSpaceKeys, isEmpty);
        expect(d.spaceKeyEpoch(Space.family), 2);
        expect(d.spaceKeysAt(Space.family, 2), hasLength(2));
      }
      expect(await dana.spaceKey(Space.family), await alexPhone.spaceKey(Space.family));
      expect(await dana.spaceKey(Space.member(leo)), await alexPhone.spaceKey(Space.member(leo)));

      // Neither revoked tablet can be handed the key in use: no device lists them as entitled.
      expect(dana.spacesForDevice(tabletA.deviceId), isEmpty);
      expect(dana.spacesForDevice(tabletB.deviceId), isEmpty);
      expect(tabletA.spaceKeyEpoch(Space.family), 0);
      expect(tabletB.spaceKeyEpoch(Space.family), 0);
    });

    test('a parent who hears of a revocation before its key doesn\'t rotate on its own', () async {
      await dana.revokeDevice(tabletA.deviceId);
      await sync(dana, alexPhone);
      expect(alexPhone.spaceKeyEpoch(Space.family), 0);
      await passKeys(dana, alexPhone);
      expect(alexPhone.spaceKeyEpoch(Space.family), 1);
      expect(alexPhone.currentSpaceKey(Space.family)!.by, dana.deviceId);
      expect(alexPhone.staleSpaceKeys, isEmpty);
    });

    test('a rotation made before the news of a revocation arrived is rotated again', () async {
      await dana.revokeDevice(tabletA.deviceId);
      // Alex's phone gets Dana's new key through the relay before the revocation itself...
      expect(await alexPhone.addSpaceKey(dana.currentSpaceKey(Space.family)!), SpaceKeyOutcome.stored);
      // ...then revokes another device, rotating to an epoch whose key doesn't know tablet A is
      // gone.
      await alexPhone.revokeDevice(tabletB.deviceId);
      expect(alexPhone.spaceKeyEpoch(Space.family), 2);
      expect(alexPhone.currentSpaceKey(Space.family)!.revoked, [tabletB.deviceId]);
      await sync(dana, alexPhone);
      expect(alexPhone.spaceKeyEpoch(Space.family), 3);
      expect(alexPhone.currentSpaceKey(Space.family)!.revoked, unorderedEquals([tabletA.deviceId, tabletB.deviceId]));
    });

    test('kids\' devices never rotate keys, whatever they hear', () async {
      final watch = await withKeys(dana, await joinDevice(dana, clock, member: leo, name: 'Leo watch'));
      await sync(dana, alexPhone);
      await dana.revokeDevice(tabletA.deviceId);
      await alexPhone.revokeDevice(tabletB.deviceId);
      await sync(dana, watch);
      await sync(alexPhone, watch);
      await passKeys(dana, watch);
      await passKeys(alexPhone, watch);
      expect(watch.makesSpaceKeys, isFalse);
      expect(watch.staleSpaceKeys, contains(Space.family));
      expect(watch.spaceKeyEpoch(Space.family), 1);
      expect(watch.currentSpaceKey(Space.family)!.by, isNot(watch.deviceId));
    });
  });
}
