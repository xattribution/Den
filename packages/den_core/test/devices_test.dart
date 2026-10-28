import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestClock clock;
  late Den parent;
  late String dana;
  late String leo;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 11, 2, 15));
    parent = await foundFamily(clock);
    dana = parent.actor!.id;
    leo = await parent.addMember(name: 'Leo', role: Role.kid);
  });

  group('a device changing what it is for', () {
    test('a parent turns their own tablet into the family hub', () async {
      final tablet = await joinDevice(parent, clock, member: dana, name: 'Dana tablet');
      expect(tablet.readableSpaces, {Space.family, Space.parents, Space.member(dana), Space.member(leo)});
      await tablet.setThisDeviceMode(DeviceMode.hub);
      expect(tablet.thisDevice!.mode, DeviceMode.hub);
      expect(tablet.owner?.name, 'Dana', reason: "it is still Dana's tablet");
      expect(tablet.actor?.name, 'Dana', reason: 'with no call acting through it, the hub acts as its owner');
      tablet.actAs(null, via: 'Home Assistant');
      expect(tablet.actor, isNull, reason: 'an automation acting through the hub is not Dana');
      await tablet.addEvent(title: 'Trash pickup', start: clock.now, end: clock.now + 600000);
      tablet.actAs(null);
      expect(tablet.actor?.name, 'Dana');
      await tablet.addEvent(title: 'Dentist', start: clock.now, end: clock.now + 600000);
      await sync(tablet, parent);
      expect(parent.device(tablet.deviceId)!.mode, DeviceMode.hub);
      expect(parent.spacesForDevice(tablet.deviceId), contains(Space.parents));
      final history = parent.history();
      expect(history.firstWhere((h) => h.title == 'Trash pickup').via, 'Home Assistant');
      expect(history.firstWhere((h) => h.title == 'Dentist').actorName, 'Dana');
    });

    test('a parent switches their own device to a shared display and renames it', () async {
      final tablet = await joinDevice(parent, clock, member: dana, name: 'Dana tablet');
      await tablet.updateDevice(tablet.deviceId, {'name': 'Kitchen'});
      await tablet.setThisDeviceMode(DeviceMode.shared);
      expect(tablet.thisDevice!.layout, DisplayLayout.week);
      expect(tablet.thisDevice!.name, 'Kitchen');
      tablet.actAs(dana);
      await tablet.updateDevice(tablet.deviceId, {
        'display': {'layout': 'today', 'openCheckoff': true},
      });
      await tablet.setThisDeviceMode(DeviceMode.personal);
      expect(tablet.actor?.name, 'Dana');
      await sync(tablet, parent);
      expect(parent.device(tablet.deviceId)!.openCheckoff, isTrue);
      expect(parent.device(tablet.deviceId)!.mode, DeviceMode.personal);
    });

    test('no device approves itself, changes its owner, or changes its mode without a parent', () async {
      final kid = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
      await expectLater(kid.setThisDeviceMode(DeviceMode.hub), throwsA(isA<PermissionDenied>()));
      await expectLater(kid.updateDevice(kid.deviceId, {'mode': 'shared'}), throwsA(isA<PermissionDenied>()));
      final mine = await joinDevice(parent, clock, member: dana, name: 'Dana tablet');
      await expectLater(mine.updateDevice(mine.deviceId, {'member': leo}), throwsA(isA<PermissionDenied>()));
      await mine.setThisDeviceMode(DeviceMode.shared);
      await expectLater(mine.setThisDeviceMode(DeviceMode.hub), throwsA(isA<PermissionDenied>()),
          reason: 'nobody verified on the display');
      final forged = await forge(
        kid.keys,
        counter: 300,
        millis: clock.now + 1000,
        type: RecordType.device,
        rid: kid.deviceId,
        fields: {'mode': 'hub'},
        actor: leo,
      );
      final selfApprove = await forge(
        mine.keys,
        counter: 301,
        millis: clock.now + 1001,
        type: RecordType.device,
        rid: mine.deviceId,
        fields: {'approvedBy': dana, 'mode': 'hub'},
        actor: dana,
      );
      final result = await parent.ingest([forged, selfApprove]);
      expect(result.invalid.keys, unorderedEquals([forged.id, selfApprove.id]));
      expect(parent.device(kid.deviceId)!.mode, DeviceMode.personal);
    });

    test('a personal device needs an owner', () async {
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      display.actAs(dana);
      await expectLater(display.setThisDeviceMode(DeviceMode.personal), throwsA(isA<InvalidInput>()));
      await expectLater(parent.updateDevice(display.deviceId, {'mode': DeviceMode.personal}), throwsA(isA<InvalidInput>()));
    });

    test('an approved device keeps the person it was approved for', () async {
      final ipad = await joinDevice(parent, clock, member: dana, name: 'Dana iPad');
      await expectLater(
        parent.updateDevice(ipad.deviceId, {'member': leo}),
        throwsA(isA<PermissionDenied>()),
        reason: 'it holds the parents\' and Dana\'s private records, which handing it on wouldn\'t remove',
      );
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      await expectLater(
        parent.updateDevice(display.deviceId, {'mode': DeviceMode.personal, 'member': leo}),
        throwsA(isA<PermissionDenied>()),
      );
      expect(parent.device(ipad.deviceId)!.member, dana);
      await parent.updateDevice(ipad.deviceId, {'name': 'Old iPad'});
      expect(parent.device(ipad.deviceId)!.name, 'Old iPad');
    });

    test('approving a shared display shows the week by default', () async {
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      expect(parent.device(display.deviceId)!.layout, DisplayLayout.week);
      expect(parent.device(display.deviceId)!.openCheckoff, isFalse);
    });
  });

  group('the acting window', () {
    test('signing in and the window ending both fire onChange', () async {
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      final seen = <Set<String>>[];
      final sub = display.onChange.listen(seen.add);
      display.actAs(leo, window: const Duration(milliseconds: 30));
      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        {Den.actingChanged},
      ]);
      expect(display.actor?.name, 'Leo');
      clock.advance(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(seen, hasLength(2));
      expect(seen.last, {Den.actingChanged});
      expect(display.actor, isNull);
      display.actAs(leo);
      display.actAs(null);
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(4));
      await sub.cancel();
      await display.close();
    });

    test('someone who starts listening later still hears the window end', () async {
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      display.actAs(leo, window: const Duration(milliseconds: 30));
      final seen = <Set<String>>[];
      final sub = display.onChange.listen(seen.add);
      clock.advance(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(seen, [
        {Den.actingChanged},
      ]);
      expect(display.actor, isNull);
      await sub.cancel();
    });

    test('closing cancels the timer', () async {
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      final seen = <Set<String>>[];
      display.onChange.listen(seen.add);
      display.actAs(leo, window: const Duration(milliseconds: 20));
      await display.close();
      clock.advance(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, [
        {Den.actingChanged},
      ], reason: 'nothing fires after close');
    });

    test('now() is the engine clock', () {
      expect(parent.now(), clock.now);
      clock.advance(const Duration(minutes: 3));
      expect(parent.now(), clock.now);
    });
  });

  group('leaving the family', () {
    test('wipes the log and metadata and starts over as a fresh device', () async {
      final storage = MemoryStorage();
      final keys = await DeviceKeys.generate();
      final joiner = await openDen(clock, storage: storage, keys: keys);
      await joiner.requestJoin(
        familyId: parent.familyId!,
        founderPubkey: parent.founderPubkey!,
        deviceName: 'Declined phone',
        kind: DeviceKind.phone,
      );
      await parent.ingest(joiner.changesSince(parent.versionVector));
      expect(joiner.hasFamily, isTrue);
      final seen = <Set<String>>[];
      final sub = joiner.onChange.listen(seen.add);
      await joiner.leaveFamily();
      await Future<void>.delayed(Duration.zero);
      expect(seen.single, containsAll([RecordType.device, Den.actingChanged]));
      expect(joiner.hasFamily, isFalse);
      expect(joiner.thisDevice, isNull);
      expect(joiner.changesSince({}), isEmpty);
      expect(joiner.versionVector, isEmpty);
      expect(await storage.loadChanges(), isEmpty);
      expect((await storage.loadMeta())!.containsKey('familyId'), isFalse);
      final reopened = await openDen(clock, storage: storage, keys: keys);
      expect(reopened.hasFamily, isFalse);
      await reopened.createFamily(
        familyName: 'Fresh start',
        timezone: 'UTC',
        yourName: 'Sam',
        marker: Marker.olive,
        animal: Animal.cow,
        deviceName: 'Phone',
        deviceKind: DeviceKind.phone,
      );
      expect(reopened.family!.name, 'Fresh start');
      expect(reopened.changesSince({}).first.counter, greaterThan(1), reason: 'change ids are never reused');
      await sub.cancel();
    });

    test('a device leaving can join again with new keys', () async {
      final tablet = await joinDevice(parent, clock, member: leo);
      await parent.revokeDevice(tablet.deviceId);
      await tablet.leaveFamily();
      final again = await joinDevice(parent, clock, member: leo, name: 'Leo tablet, again');
      expect(again.isApproved, isTrue);
      expect(again.owner?.name, 'Leo');
    });
  });

  group('space keys', () {
    test('start at epoch 0 and keep older epochs', () async {
      for (final s in [Space.family, Space.parents, Space.member(dana), Space.member(leo)]) {
        expect(parent.spaceKeyEpoch(s), 0);
        expect(await parent.spaceKey(s), hasLength(32));
      }
      expect(parent.spaceKeyEpoch('m:nobody'), isNull);
      final tablet = await joinDevice(parent, clock, member: leo);
      final zero = (await parent.spaceKey(Space.family))!;
      await tablet.setSpaceKey(Space.family, zero);
      expect(tablet.spaceKeyEpoch(Space.family), 0);
      final one = randomBytes(32);
      await tablet.setSpaceKey(Space.family, one, epoch: 1);
      expect(tablet.spaceKeyEpoch(Space.family), 1);
      expect(await tablet.spaceKey(Space.family), one);
      expect(await tablet.spaceKey(Space.family, epoch: 0), zero);
      expect(await tablet.spaceKey(Space.family, epoch: 7), isNull);
      await expectLater(tablet.setSpaceKey(Space.family, one, epoch: -1), throwsA(isA<InvalidInput>()));
    });

    test('revoking a device rotates every space it held', () async {
      final tablet = await joinDevice(parent, clock, member: leo);
      final before = {
        for (final s in [Space.family, Space.parents, Space.member(dana), Space.member(leo)]) s: await parent.spaceKey(s),
      };
      await parent.revokeDevice(tablet.deviceId);
      expect(parent.spaceKeyEpoch(Space.family), 1);
      expect(parent.spaceKeyEpoch(Space.member(leo)), 1);
      expect(parent.spaceKeyEpoch(Space.parents), 0);
      expect(parent.spaceKeyEpoch(Space.member(dana)), 0);
      expect(await parent.spaceKey(Space.family), isNot(before[Space.family]));
      expect(await parent.spaceKey(Space.family, epoch: 0), before[Space.family]);
      expect(await parent.spaceKey(Space.parents), before[Space.parents]);
    });

    test('removing a member rotates the spaces their devices held; revoking yourself rotates nothing', () async {
      final maya = await parent.addMember(name: 'Maya', role: Role.kid);
      await joinDevice(parent, clock, member: maya, name: 'Maya phone');
      await parent.removeMember(maya);
      expect(parent.spaceKeyEpoch(Space.family), 1);
      expect(parent.spaceKeyEpoch(Space.member(maya)), 1);
      expect(parent.spaceKeyEpoch(Space.member(leo)), 0);
      final second = await joinDevice(parent, clock, member: dana, name: 'Second');
      await second.setSpaceKey(Space.family, randomBytes(32));
      await second.revokeDevice(second.deviceId);
      expect(second.spaceKeyEpoch(Space.family), 0);
    });

    test('keys stored before epochs existed read as epoch 0', () async {
      final storage = MemoryStorage();
      final keys = await DeviceKeys.generate();
      final key = randomBytes(32);
      await storage.saveMeta({
        'spaceKeys': {Space.family: b64e(key)},
      });
      final den = await openDen(clock, storage: storage, keys: keys);
      expect(den.spaceKeyEpoch(Space.family), 0);
      expect(await den.spaceKey(Space.family), key);
    });
  });
}

