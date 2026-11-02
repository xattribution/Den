import 'package:den_app/platform/storage/boot.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

class MemoryKeys implements KeyStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Future<Den> founded(DenStorage storage, MemoryKeys keys) async {
  final den = await Boot.open(storage: storage, keys: keys);
  await den.createFamily(
    familyName: 'The Testers',
    timezone: 'America/Chicago',
    yourName: 'Sam',
    marker: Marker.sky,
    animal: Animal.cat,
    deviceName: "Sam's iPhone",
    deviceKind: DeviceKind.phone,
  );
  return den;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('opens the same device and family again', () async {
    final storage = MemoryStorage();
    final keys = MemoryKeys();
    final first = await founded(storage, keys);
    final again = await Boot.open(storage: storage, keys: keys);
    expect(again.deviceId, first.deviceId);
    expect(again.family?.name, 'The Testers');
    expect(again.isApproved, isTrue);
  });

  test('a browser whose storage was cleared but kept its keys starts over as a new device', () async {
    final keys = MemoryKeys();
    final first = await founded(MemoryStorage(), keys);
    final saved = keys.values[Boot.keysName];

    // Storage evicted, keychain kept: the old id is already approved in the family, and its
    // counter would restart at 1 under ids the hub already holds.
    final again = await Boot.open(storage: MemoryStorage(), keys: keys);
    expect(again.deviceId, isNot(first.deviceId));
    expect(again.hasFamily, isFalse);
    expect(keys.values[Boot.keysName], isNot(saved), reason: 'the fresh keys are kept for next time');

    final third = await Boot.open(storage: MemoryStorage(), keys: keys);
    expect(third.deviceId, isNot(again.deviceId), reason: 'a device still not in a family has nothing to lose');
  });

  test('a log whose keys are gone is cleared', () async {
    final storage = MemoryStorage();
    final first = await founded(storage, MemoryKeys());
    final again = await Boot.open(storage: storage, keys: MemoryKeys());
    expect(again.deviceId, isNot(first.deviceId));
    expect(again.hasFamily, isFalse);
    expect(await storage.loadMeta(), isNull);
    expect(await storage.loadChanges(), isEmpty);
  });

  test('a device that left its family joins again with new keys', () async {
    final storage = MemoryStorage();
    final keys = MemoryKeys();
    final first = await founded(storage, keys);
    await first.leaveFamily();
    final again = await Boot.open(storage: storage, keys: keys);
    expect(again.deviceId, isNot(first.deviceId));
    expect(again.hasFamily, isFalse);
  });

  test('a background refresh never starts the device over', () async {
    final storage = MemoryStorage();
    await founded(storage, MemoryKeys());
    final before = (await storage.loadChanges()).length;
    await expectLater(Boot.open(storage: storage, keys: MemoryKeys(), background: true), throwsStateError);
    expect((await storage.loadChanges()).length, before);
    expect(await storage.loadMeta(), isNotNull);
  });
}
