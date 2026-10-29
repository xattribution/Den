// Several families on one device (FAMILY-LINKS-PLAN §2.10): one engine per family, each with its
// own keys, change log and change counter; the first family keeps the names Den always used, so
// a device in one family is untouched by the upgrade.
import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/household.dart';
import 'package:den_app/platform/storage/boot.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../helpers/households.dart';

/// Lets [device] (a fresh engine) into [family]'s family as a new grown-up, [name], approved by
/// the family's founder on [family] itself.
Future<void> admit(Den device, Den family, String name) async {
  final member = await family.addMember(name: name, role: Role.adult);
  await device.requestJoin(
    familyId: family.familyId!,
    founderPubkey: family.founderPubkey!,
    deviceName: "$name's phone",
    kind: DeviceKind.phone,
  );
  await family.ingest(device.changesSince(const {}));
  await family.approveDevice(device.deviceId, member: member);
  await device.ingest(family.changesSince(const {}));
  for (final space in family.spacesForDevice(device.deviceId)) {
    final key = await family.spaceKey(space);
    if (key != null) await device.setSpaceKey(space, key);
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('where each family is kept', () {
    test('the first family keeps den and den.device.keys; each other one has names of its own', () {
      const first = Membership(id: 'kotvasfamily2345', primary: true);
      const smith = Membership(id: 'smithfamily23456', slot: 'qrstqrstqrstqrst');
      expect(first.storage, 'den');
      expect(first.keys, 'den.device.keys');
      expect(first.keys, Boot.keysName);
      expect(first.pref('den.hubs'), 'den.hubs');
      expect(first.hubData, 'hub');
      // Named by a slot the device picked, never by the family id a server answered.
      expect(smith.storage, 'den-qrstqrstqrstqrst');
      expect(smith.keys, 'den.device.keys.qrstqrstqrstqrst');
      expect(smith.pref('den.hubs'), 'den.hubs.qrstqrstqrstqrst');
      expect(smith.hubData, 'hub-qrstqrstqrstqrst');
      expect(Membership.validSlot(Membership.newSlot()), isTrue);
    });

    test('family ids are den_core ids: 16 lowercase base32 letters, an upper-case twin refused', () {
      expect(Membership.validId('smithfamily23456'), isTrue);
      expect(Membership.validId('SMITHFAMILY23456'), isFalse);
      expect(Membership.validId('Smithfamily23456'), isFalse);
      expect(Membership.validId('smithfamily2345'), isFalse);
      expect(Membership.validId('smithfamily23451'), isFalse, reason: '1 is no base32 letter');
      expect(Membership.validId('../etc/passwd0000'), isFalse);
      const a = Membership(id: 'smithfamily23456', slot: 'aaaaaaaaaaaaaaaa');
      const b = Membership(id: 'jonesfamily23456', slot: 'aaaaaaaaaaaaaaaa');
      expect(a.sharesStorageWith(b), isTrue);
    });

    test('the list reads back as saved, and leaves out what is not a log', () async {
      const logs = [
        Membership(id: 'kotvasfamily2345', primary: true, label: 'Kotvas', hub: 'https://den.kotvas.app', color: 'sky'),
        Membership(id: 'smithfamily23456', label: 'Smith family', hub: 'https://den.kotvas.app', color: 'grass', slot: 'qrstqrstqrstqrst'),
      ];
      await Memberships.save(logs);
      expect(await Memberships.load(), logs);
      SharedPreferences.setMockInitialValues({
        Memberships.key: jsonEncode([
          {'id': '../etc', 'slot': 'aaaaaaaaaaaaaaaa'},
          {'id': 'SMITHFAMILY23456', 'slot': 'aaaaaaaaaaaaaaaa'},
          {'id': 'smithfamily23456', 'slot': '../../x'},
          {'id': 'smithfamily23456', 'slot': 'slotslotslotslot'},
          {'id': 'smithfamily23456', 'slot': 'otherslotaaaaaaa'},
          {'id': 'jonesfamily23456', 'slot': 'SLOTSLOTSLOTSLOT'},
          {'id': 'jonesfamily23456', 'slot': 'slotslotslotslot'},
          {'id': 'a', 'primary': true},
          {'id': 'b', 'primary': true},
          7,
          // Listed before slots were kept: named by its (lowercase) id.
          {'id': 'leegacyfamily234'},
        ]),
      });
      final loaded = await Memberships.load();
      expect([for (final m in loaded) m.id], ['smithfamily23456', 'a', 'leegacyfamily234'],
          reason: 'one engine per log, one first log, never two under one name, nothing named from outside');
      expect(loaded.last.storage, 'den-leegacyfamily234');
    });
  });

  test('two families: two engines with their own keys, change counters and logs', () async {
    final store = MemoryHouseholdStore(networks: false);
    final home = await Household.boot(store);
    final kotvas = home.active;
    expect(kotvas.membership.primary, isTrue);
    await found(kotvas.den, 'Kotvas', you: 'Grandma');

    // The Smiths, founded on Dana's phone, let Grandma's device in.
    final dana = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await found(dana, 'Smith family', you: 'Dana');
    final smith = await home.prepare(dana.familyId!, label: 'Smith family');
    await admit(smith.den, dana, 'Grandma');
    await home.adopt(smith);

    expect(home.several, isTrue);
    expect(identical(home.active, smith), isTrue, reason: 'the family just joined shows');
    expect(smith.den.isApproved, isTrue);

    // Separate keys: different devices in each family, kept under their own keychain items,
    // named by a slot this device picked.
    final slot = smith.membership.slot!;
    expect(Membership.validSlot(slot), isTrue);
    expect(slot, isNot(dana.familyId));
    expect(smith.den.deviceId, isNot(kotvas.den.deviceId));
    expect(store.keys.values.keys, containsAll(['den.device.keys', 'den.device.keys.$slot']));
    expect(store.keys.values['den.device.keys'], isNot(store.keys.values['den.device.keys.$slot']));

    // Separate logs, and each counter counts only its own changes.
    expect(store.storages.keys, containsAll(['den', 'den-$slot']));
    final kotvasChanges = await store.storages['den']!.loadChanges();
    final smithChanges = await store.storages['den-$slot']!.loadChanges();
    expect(kotvasChanges.every((c) => c.device != smith.den.deviceId), isTrue);
    expect(smithChanges.every((c) => c.device != kotvas.den.deviceId), isTrue);
    expect(kotvasChanges.every((c) => c.id.startsWith('${kotvas.den.deviceId}:')), isTrue);
    final ownSmith = smithChanges.where((c) => c.device == smith.den.deviceId).map((c) => c.id).toList();
    expect(ownSmith, isNotEmpty);
    expect(ownSmith.first, '${smith.den.deviceId}:1', reason: 'its own counter, from one');
    expect(kotvas.den.familyId, isNot(smith.den.familyId));

    // The list names both, the first one by its family now.
    expect(store.saved!.map((m) => (m.id, m.primary, m.storage)), [
      (kotvas.den.familyId!, true, 'den'),
      (dana.familyId!, false, 'den-$slot'),
    ]);
    expect(store.savedActive, dana.familyId);

    // One engine per family: the same family can't be prepared twice.
    await expectLater(home.prepare(dana.familyId!), throwsStateError);
    await expectLater(home.prepare(kotvas.den.familyId!), throwsStateError);

    // Opened again later, the device holds both, showing the one it showed.
    final again = await Household.boot(store);
    expect([for (final l in again.logs) l.den.deviceId], [kotvas.den.deviceId, smith.den.deviceId]);
    expect(again.active.den.familyId, dana.familyId);
    await again.chooseAll();
    expect(again.showingAll, isTrue);
    expect(await Memberships.loadActive(), Memberships.all);
    await dana.close();
  });

  test('the upgrade: a device in one family opens exactly as before, and nothing is written', () async {
    // A device from before households: its family in `den`, its keys in `den.device.keys`, and
    // its settings under Den's own names.
    final store = MemoryHouseholdStore(networks: false);
    final before = await Boot.open(storage: store.storage('den'), keys: store.keys);
    await found(before, 'Kotvas');
    final event = await before.addEvent(title: 'Soccer', start: 1800000000000, end: 1800003600000);
    final deviceId = before.deviceId;
    await before.close();
    final prefs = {
      'den.hubs': ['wss://den.kotvas.app/ws'],
      'den.seen': ['privacy:1'],
      'den.theme': 'night',
    };
    SharedPreferences.setMockInitialValues(prefs);
    final changes = [for (final c in await store.storage('den').loadChanges()) c.id];
    final keys = {...store.keys.values};

    final home = await Household.boot(store);
    expect(home.logs, hasLength(1));
    expect(home.several, isFalse);
    expect(home.showingAll, isFalse);
    final log = home.active;
    expect(log.membership.primary, isTrue);
    expect(log.den.deviceId, deviceId, reason: 'the same device, with the same keys');
    expect(log.den.event(event)?.title, 'Soccer');
    expect(log.state.theme, ThemeChoice.night);
    expect(log.state.seen('privacy:1'), isTrue);
    expect(store.keys.values, keys, reason: 'the keychain is untouched');
    expect([for (final c in await store.storage('den').loadChanges()) c.id], changes, reason: 'the log is untouched');
    expect(store.storages.keys, ['den']);
    final after = await SharedPreferences.getInstance();
    expect(after.getKeys(), prefs.keys.toSet(), reason: 'no list and no choice written for one family');
    expect(store.saved, isNull);
  });

  test('a listed family whose log is gone is let go; the others open', () async {
    final store = MemoryHouseholdStore(networks: false);
    final home = await Household.boot(store);
    await found(home.active.den, 'Kotvas');
    final dana = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await found(dana, 'Smith family', you: 'Dana');
    final smith = await home.prepare(dana.familyId!);
    await admit(smith.den, dana, 'Grandma');
    await home.adopt(smith);

    // The browser evicted the Smiths' database, keychain kept.
    store.storages.remove(smith.membership.storage);
    final again = await Household.boot(store);
    expect(again.logs, hasLength(1));
    expect(again.active.den.family?.name, 'Kotvas');
    expect(store.forgotten.map((m) => m.id), [dana.familyId]);
    expect(store.saved!.map((m) => m.id), [home.logs.first.den.familyId]);
    await dana.close();
  });

  // Review regressions (case-variant ids, concurrent prepares).
  group('one engine per family, whatever the id looks like', () {
    Future<(Household, MemoryHouseholdStore, Den)> twoFamilies() async {
      final store = MemoryHouseholdStore(networks: false);
      final home = await Household.boot(store);
      await found(home.active.den, 'Kotvas', you: 'Grandma');
      final dana = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      await found(dana, 'Smith family', you: 'Dana');
      return (home, store, dana);
    }

    test('an upper-case twin of a family this device holds is refused, and nothing is made for it', () async {
      final (home, store, dana) = await twoFamilies();
      final smith = await home.prepare(dana.familyId!);
      await admit(smith.den, dana, 'Grandma');
      await home.adopt(smith);
      final storages = {...store.storages.keys};
      final keys = {...store.keys.values.keys};
      await expectLater(home.prepare(dana.familyId!.toUpperCase()), throwsStateError);
      await expectLater(home.prepare('${dana.familyId!.substring(0, 15)}A'), throwsStateError);
      expect(home.byId(dana.familyId!.toUpperCase()), same(smith), reason: 'the twin names the same family');
      expect(store.storages.keys.toSet(), storages);
      expect(store.keys.values.keys.toSet(), keys);
      await dana.close();
    });

    test('two prepares of one family at once: the second is refused, the first keeps its keys', () async {
      final (home, store, dana) = await twoFamilies();
      final id = dana.familyId!;
      final first = home.prepare(id);
      await expectLater(home.prepare(id), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('joining that family'))));
      final a = await first;
      // One new log and one new keychain item: the refused prepare made nothing, and took
      // nothing of the first's.
      expect(store.storages.keys.toSet(), {'den', a.membership.storage});
      expect(store.keys.values.keys.toSet(), {'den.device.keys', a.membership.keys});
      final keys = store.keys.values[a.membership.keys];
      // The first engine joins with its keys.
      await admit(a.den, dana, 'Grandma');
      expect(a.den.isApproved, isTrue);
      expect(store.keys.values[a.membership.keys], keys);
      // Once it is let go, the family can be prepared again, under a new slot.
      await home.discard(a);
      expect(store.storages.containsKey(a.membership.storage), isFalse);
      final b = await home.prepare(id);
      expect(b.membership.slot, isNot(a.membership.slot));
      await home.discard(b);
      await dana.close();
    });

    test('a prepare that fails once its log was made takes it away again', () async {
      final store = _FailingStore();
      final home = await Household.boot(store);
      await found(home.active.den, 'Kotvas', you: 'Grandma');
      final dana = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      await found(dana, 'Smith family', you: 'Dana');
      store.failNext = true;
      await expectLater(home.prepare(dana.familyId!), throwsA(isA<FileSystemException>()));
      expect(store.storages.keys, ['den'], reason: 'nothing left under the new slot');
      expect(store.keys.values.keys, ['den.device.keys']);
      // And the family can be joined after all.
      final smith = await home.prepare(dana.familyId!);
      await home.discard(smith);
      await dana.close();
    });

    test("a family whose engine didn't open stays listed, and isn't prepared again", () async {
      final (home, store, dana) = await twoFamilies();
      final smith = await home.prepare(dana.familyId!, label: 'Smith family');
      await admit(smith.den, dana, 'Grandma');
      await home.adopt(smith);
      await smith.den.close();
      final locked = _LockedStore(store, smith.membership.id);
      final again = await Household.boot(locked);
      expect(again.logs, hasLength(1));
      expect(again.unopened.map((m) => m.id), [dana.familyId]);
      await expectLater(again.prepare(dana.familyId!), throwsStateError);
      await again.choose(again.logs.single);
      expect(store.saved!.map((m) => m.id), containsAll([again.logs.single.id, dana.familyId]), reason: 'still listed');
      expect(store.storages.containsKey(smith.membership.storage), isTrue, reason: 'its log is kept');
      await dana.close();
    });
  });
}

/// A device whose next new log fails right after it was made (a full disk).
class _FailingStore extends MemoryHouseholdStore {
  _FailingStore() : super(networks: false);

  bool failNext = false;

  @override
  Future<FamilyLog> open(Membership log, {bool fresh = false}) async {
    if (failNext && fresh) {
      failNext = false;
      storage(log.storage);
      await keys.write(log.keys, 'half-written');
      throw const FileSystemException('No space left on device');
    }
    return super.open(log, fresh: fresh);
  }
}

/// [store], with the keychain item of the family [locked] not readable yet (a locked phone).
class _LockedStore implements HouseholdStore {
  _LockedStore(this.store, this.locked);

  final MemoryHouseholdStore store;
  final String locked;

  @override
  Future<FamilyLog> open(Membership log, {bool fresh = false}) {
    if (log.id == locked) throw StateError('The keychain is locked');
    return store.open(log, fresh: fresh);
  }

  @override
  Future<void> forget(Membership log) => store.forget(log);

  @override
  Future<void> save(List<Membership> logs, String? active) => store.save(logs, active);
}
