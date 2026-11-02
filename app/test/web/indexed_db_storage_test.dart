// Runs in a real browser: flutter test --platform chrome test/web
@TestOn('browser')
library;

import 'package:den_app/platform/storage/storage_web.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('a reopened browser has its family, and its next change continues the counter', () async {
    final name = 'den-test-${DateTime.now().microsecondsSinceEpoch}';
    final keys = await DeviceKeys.generate();

    final first = await IndexedDbStorage.open(name: name);
    final den = await Den.open(storage: first, keys: keys);
    await den.createFamily(
      familyName: 'The Testers',
      timezone: 'America/Chicago',
      yourName: 'Sam',
      marker: Marker.sky,
      animal: Animal.cat,
      deviceName: "Sam's iPhone",
      deviceKind: DeviceKind.phone,
    );
    final held = den.changesSince(const {}).length;
    first.close();

    final second = await IndexedDbStorage.open(name: name);
    final again = await Den.open(storage: second, keys: keys);
    expect(again.familyId, den.familyId);
    expect(again.family?.name, 'The Testers');
    expect(again.isApproved, isTrue);
    expect(again.changesSince(const {}), hasLength(held));

    await again.updateFamily({'name': 'The Riveras'});
    final ids = again.changesSince(const {}).map((c) => c.id).toSet();
    expect(ids, hasLength(held + 1), reason: 'no change id is reused after reopening');
    second.close();

    final third = await IndexedDbStorage.open(name: name);
    expect((await Den.open(storage: third, keys: keys)).family?.name, 'The Riveras');
    await third.clear();
    expect(await third.loadMeta(), isNull);
    expect(await third.loadChanges(), isEmpty);
    third.close();
  });

  test('storing the same change twice keeps one', () async {
    final storage = await IndexedDbStorage.open(name: 'den-test-twice-${DateTime.now().microsecondsSinceEpoch}');
    final keys = await DeviceKeys.generate();
    final den = await Den.open(storage: MemoryStorage(), keys: keys);
    await den.createFamily(
      familyName: 'The Testers',
      timezone: 'America/Chicago',
      yourName: 'Sam',
      marker: Marker.sky,
      animal: Animal.cat,
      deviceName: "Sam's laptop",
      deviceKind: DeviceKind.browser,
    );
    final changes = den.changesSince(const {});
    await storage.appendChanges(changes);
    await storage.appendChanges(changes);
    expect(await storage.loadChanges(), hasLength(changes.length));
    storage.close();
  });

  test('a snapshot is kept beside the metadata, replaced whole, and cleared with it', () async {
    final storage = await IndexedDbStorage.open(name: 'den-test-snapshot-${DateTime.now().microsecondsSinceEpoch}');
    expect(await storage.loadSnapshot(), isNull);
    await storage.saveMeta({'familyId': 'f'});
    await storage.saveSnapshot('first');
    await storage.saveSnapshot('second\nline');
    expect(await storage.loadSnapshot(), 'second\nline');
    expect(await storage.loadMeta(), {'familyId': 'f'});
    await storage.clear();
    expect(await storage.loadSnapshot(), isNull);
    storage.close();
  });

  test("two families in one browser: a database each, and leaving one deletes only it, open or not", () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final firstName = 'den-test-first-$stamp', secondName = 'den-test-second-$stamp';
    Future<Den> founded(IndexedDbStorage storage, String name) async {
      final den = await Den.open(storage: storage, keys: await DeviceKeys.generate());
      await den.createFamily(
        familyName: name,
        timezone: 'America/Chicago',
        yourName: 'Grandma',
        marker: Marker.sky,
        animal: Animal.cat,
        deviceName: "Grandma's iPhone",
        deviceKind: DeviceKind.phone,
      );
      return den;
    }

    final kotvasDb = await openDeviceStorage(name: firstName) as IndexedDbStorage;
    final smithDb = await openDeviceStorage(name: secondName) as IndexedDbStorage;
    final kotvas = await founded(kotvasDb, 'Kotvas');
    final smith = await founded(smithDb, 'Smith family');
    expect((await kotvasDb.loadMeta())!['familyId'], kotvas.familyId);
    expect((await smithDb.loadMeta())!['familyId'], smith.familyId);
    expect((await kotvasDb.loadChanges()).every((c) => c.device == kotvas.deviceId), isTrue);
    expect((await smithDb.loadChanges()).every((c) => c.device == smith.deviceId), isTrue);

    // Leaving the Smiths deletes their database, though this page still holds it open.
    await deleteDeviceStorage(secondName);
    final reopened = await IndexedDbStorage.open(name: secondName);
    expect(await reopened.loadMeta(), isNull);
    expect(await reopened.loadChanges(), isEmpty);
    reopened.close();
    expect((await kotvasDb.loadMeta())!['familyId'], kotvas.familyId, reason: 'the other family stays');
    kotvasDb.close();
    await deleteDeviceStorage(firstName);
    await deleteDeviceStorage(secondName);
  });
}
