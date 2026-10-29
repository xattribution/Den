// Several families on one device (FAMILY-LINKS-PLAN §2.10): one engine per family, each with its
// own keys, change log and change counter; the first family keeps the names Den always used, so
// a device in one family is untouched by the upgrade.
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
      const smith = Membership(id: 'smithfamily23456');
      expect(first.storage, 'den');
      expect(first.keys, 'den.device.keys');
      expect(first.keys, Boot.keysName);
      expect(first.pref('den.hubs'), 'den.hubs');
      expect(smith.storage, 'den-smithfamily23456');
      expect(smith.keys, 'den.device.keys.smithfamily23456');
      expect(smith.pref('den.hubs'), 'den.hubs.smithfamily23456');
    });

    test('the list reads back as saved, and leaves out what is not a log', () async {
      const logs = [
        Membership(id: 'kotvasfamily2345', primary: true, label: 'Kotvas', hub: 'https://den.kotvas.app', color: 'sky'),
        Membership(id: 'smithfamily23456', label: 'Smith family', hub: 'https://den.kotvas.app', color: 'grass'),
      ];
      await Memberships.save(logs);
      expect(await Memberships.load(), logs);
      SharedPreferences.setMockInitialValues({
        Memberships.key: '[{"id":"../etc"},{"id":"ok"},{"id":"ok"},{"id":"a","primary":true},{"id":"b","primary":true},7]',
      });
      expect([for (final m in await Memberships.load()) m.id], ['ok', 'a'], reason: 'one engine per log, one first log');
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

    // Separate keys: different devices in each family, kept under their own keychain items.
    expect(smith.den.deviceId, isNot(kotvas.den.deviceId));
    expect(store.keys.values.keys, containsAll(['den.device.keys', 'den.device.keys.${dana.familyId}']));
    expect(store.keys.values['den.device.keys'], isNot(store.keys.values['den.device.keys.${dana.familyId}']));

    // Separate logs, and each counter counts only its own changes.
    expect(store.storages.keys, containsAll(['den', 'den-${dana.familyId}']));
    final kotvasChanges = await store.storages['den']!.loadChanges();
    final smithChanges = await store.storages['den-${dana.familyId}']!.loadChanges();
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
      (dana.familyId!, false, 'den-${dana.familyId}'),
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
    store.storages.remove('den-${dana.familyId}');
    final again = await Household.boot(store);
    expect(again.logs, hasLength(1));
    expect(again.active.den.family?.name, 'Kotvas');
    expect(store.forgotten.map((m) => m.id), [dana.familyId]);
    expect(store.saved!.map((m) => m.id), [home.logs.first.den.familyId]);
    await dana.close();
  });
}
