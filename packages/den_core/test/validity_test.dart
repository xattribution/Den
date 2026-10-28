import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

int maxCounter(Den den) =>
    den.changesSince(const {}).where((c) => c.device == den.deviceId).fold(0, (m, c) => c.counter > m ? c.counter : m);

void main() {
  late TestClock clock;
  late Den parent;
  late String dana;
  late String leo;
  late String maya;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 3, 2, 14));
    parent = await foundFamily(clock);
    dana = parent.actor!.id;
    leo = await parent.addMember(name: 'Leo', role: Role.kid, tier: Tier.little);
    maya = await parent.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen);
  });

  group('device approval', () {
    test('a device can never approve itself', () async {
      final joiner = await joinDevice(parent, clock, member: leo, approve: false);
      expect(parent.pendingDevices.map((d) => d.id), [joiner.deviceId]);
      expect(joiner.isApproved, isFalse);

      await expectLater(
        joiner.approveDevice(joiner.deviceId, mode: DeviceMode.shared),
        throwsA(isA<PermissionDenied>()),
      );
      await expectLater(
        joiner.updateDevice(joiner.deviceId, {'mode': DeviceMode.hub}),
        throwsA(isA<PermissionDenied>()),
      );
      await joiner.updateDevice(joiner.deviceId, {'name': 'Leo\'s tablet'});
      expect(joiner.thisDevice!.approved, isFalse, reason: 'renaming its own request is fine');

      clock.advance(const Duration(seconds: 5));
      final selfApproval = await forge(
        joiner.keys,
        counter: 50,
        millis: clock.now,
        type: RecordType.device,
        rid: joiner.deviceId,
        fields: {'approved': true, 'approvedBy': dana},
      );
      final asParent = await forge(
        joiner.keys,
        counter: 51,
        millis: clock.now + 1,
        type: RecordType.device,
        rid: joiner.deviceId,
        fields: {'approved': true},
        actor: dana,
      );
      final then = await forge(
        joiner.keys,
        counter: 52,
        millis: clock.now + 2,
        type: RecordType.event,
        rid: 'abcdefghijklmnop',
        fields: {'title': 'Hi', 'start': 0, 'end': 0, 'tz': 'UTC'},
      );
      final result = await parent.ingest([selfApproval, asParent, then]);
      expect(result.added, 3);
      expect(result.invalid.keys, unorderedEquals([selfApproval.id, asParent.id, then.id]));
      expect(result.invalid[selfApproval.id], contains('never approve itself'));
      expect(parent.device(joiner.deviceId)!.approved, isFalse);
      expect(parent.events, isEmpty);
      expect(parent.spacesForDevice(joiner.deviceId), isEmpty);
    });

    test('a join request that claims approval is never valid', () async {
      final keys = await DeviceKeys.generate();
      final id = await keys.deviceId();
      final join = await forge(
        keys,
        counter: 1,
        millis: clock.now,
        type: RecordType.device,
        rid: id,
        fields: {
          'name': 'Sneaky',
          'kind': 'phone',
          'pubkey': keys.pubkey,
          'mode': 'personal',
          'member': dana,
          'approved': true,
        },
      );
      final result = await parent.ingest([join]);
      expect(result.invalid.keys, [join.id]);
      expect(parent.device(id), isNull);
    });

    test('a join request must carry the key its id hashes', () async {
      final keys = await DeviceKeys.generate();
      final other = await DeviceKeys.generate();
      final join = await forge(
        keys,
        counter: 1,
        millis: clock.now,
        type: RecordType.device,
        rid: await keys.deviceId(),
        fields: {'name': 'Mismatch', 'kind': 'phone', 'pubkey': other.pubkey, 'mode': 'personal', 'approved': false},
      );
      final result = await parent.ingest([join]);
      expect(result.added, 0, reason: 'nothing vouches for the key that signed it');
      expect(result.pending, 1);
      expect(parent.device(await keys.deviceId()), isNull);
    });

    test('approval by a kid\'s device is refused; by another parent\'s device it counts', () async {
      final kidTablet = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
      final joiner = await joinDevice(parent, clock, member: maya, name: 'Maya phone', approve: false);
      await sync(parent, kidTablet);
      expect(kidTablet.device(joiner.deviceId), isNotNull);
      await expectLater(kidTablet.approveDevice(joiner.deviceId, member: maya), throwsA(isA<PermissionDenied>()));

      final forged = await forge(
        kidTablet.keys,
        counter: 90,
        millis: clock.now + 10,
        type: RecordType.device,
        rid: joiner.deviceId,
        fields: {'approved': true, 'approvedBy': leo},
        actor: leo,
      );
      final result = await parent.ingest([forged]);
      expect(result.invalid[forged.id], contains('parents'));
      expect(parent.device(joiner.deviceId)!.approved, isFalse);

      final priya = await parent.addMember(name: 'Priya', role: Role.parent);
      final second = await joinDevice(parent, clock, member: priya, name: 'Priya phone');
      await sync(parent, second);
      await second.approveDevice(joiner.deviceId, member: maya);
      await sync(second, parent);
      expect(parent.device(joiner.deviceId)!.approved, isTrue);
      expect(parent.spacesForDevice(joiner.deviceId), {Space.family, Space.member(maya)});
    });

    test('a revoked device can\'t re-approve itself, and its later changes don\'t count', () async {
      final priya = await parent.addMember(name: 'Priya', role: Role.parent);
      final second = await joinDevice(parent, clock, member: priya, name: 'Priya phone');
      clock.advance(const Duration(minutes: 1));
      final before = await forge(
        second.keys,
        counter: 100,
        millis: clock.now,
        type: RecordType.category,
        rid: 'beforerevocation',
        fields: {'name': 'Before'},
        actor: priya,
      );
      await parent.ingest([before]);
      clock.advance(const Duration(minutes: 1));
      await parent.revokeDevice(second.deviceId);
      expect(parent.device(second.deviceId)!.revokedAfter, 100, reason: 'the last change the parent held');
      clock.advance(const Duration(minutes: 1));
      final after = await forge(
        second.keys,
        counter: 101,
        millis: clock.now,
        type: RecordType.category,
        rid: 'afterrevocation',
        fields: {'name': 'After'},
        actor: priya,
      );
      final unrevoke = await forge(
        second.keys,
        counter: 102,
        millis: clock.now + 1,
        type: RecordType.device,
        rid: second.deviceId,
        fields: {'revoked': false, 'approved': true},
        actor: priya,
      );
      final result = await parent.ingest([after, unrevoke]);
      expect(result.invalid.keys, unorderedEquals([after.id, unrevoke.id]));
      expect(parent.categories.map((c) => c.name), ['Before']);
      expect(parent.device(second.deviceId)!.revoked, isTrue);
      expect(parent.spacesForDevice(second.deviceId), isEmpty);
    });

    test('a revoked device can\'t backdate a change to before its revocation', () async {
      final priya = await parent.addMember(name: 'Priya', role: Role.parent);
      final second = await joinDevice(parent, clock, member: priya, name: 'Priya phone');
      final observer = await joinDevice(parent, clock, member: dana, name: 'Dana laptop');
      clock.advance(const Duration(minutes: 1));
      await second.addCategory(name: 'Sent before');
      await sync(second, parent);
      final revokedAt = clock.now + const Duration(minutes: 1).inMilliseconds;
      clock.set(DateTime.fromMillisecondsSinceEpoch(revokedAt, isUtc: true));
      await parent.revokeDevice(second.deviceId);

      // The stolen phone signs a new change, claiming a clock from before the revocation.
      clock.advance(const Duration(hours: 1));
      final backdated = await forge(
        second.keys,
        counter: maxCounter(second) + 1,
        millis: revokedAt - const Duration(seconds: 30).inMilliseconds,
        type: RecordType.category,
        rid: 'backdatedcategory',
        fields: {'name': 'Backdated'},
        actor: priya,
      );
      final result = await parent.ingest([backdated]);
      expect(result.invalid[backdated.id], contains('removed'));
      expect(parent.categories.map((c) => c.name), ['Sent before']);

      // A replica that takes the backdated change before it hears of the revocation drops it
      // once the revocation arrives, and agrees with the parent.
      final early = await observer.ingest([backdated]);
      expect(early.invalid, isEmpty);
      expect(observer.categories.map((c) => c.name), contains('Backdated'));
      await sync(parent, observer);
      expect(observer.categories.map((c) => c.name), ['Sent before']);
      expect(observer.exportJson(), parent.exportJson());
    });

    test('a personal device acts only for its owner', () async {
      final kidTablet = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
      expect(() => kidTablet.actAs(dana), throwsA(isA<PermissionDenied>()));
      final forged = await forge(
        kidTablet.keys,
        counter: 70,
        millis: clock.now + 5,
        type: RecordType.adjustment,
        rid: 'parentpretender',
        fields: {'member': leo, 'delta': 100, 'reason': 'I said so', 'by': dana},
        actor: dana,
      );
      final result = await parent.ingest([forged]);
      expect(result.invalid[forged.id], contains('owner'));
      expect(parent.points().totals[leo], 0);
    });

    test('a forged genesis with the family id but another key is invalid', () async {
      final keys = await DeviceKeys.generate();
      final forged = await forge(
        keys,
        counter: 1,
        millis: clock.now,
        type: RecordType.family,
        rid: parent.familyId!,
        fields: {'name': 'Hijacked', 'timezone': 'UTC', 'founderDevice': await keys.deviceId()},
      );
      final join = await forge(
        keys,
        counter: 2,
        millis: clock.now + 1,
        type: RecordType.device,
        rid: await keys.deviceId(),
        fields: {'name': 'Mallory', 'kind': 'phone', 'pubkey': keys.pubkey, 'mode': 'personal', 'approved': false},
      );
      final result = await parent.ingest([forged, join]);
      expect(result.invalid.keys, [forged.id]);
      expect(parent.family!.name, 'Rivera family');
    });

    test('a device trusting the wrong founder key accepts nothing', () async {
      final impostor = await DeviceKeys.generate();
      final device = await openDen(clock);
      await device.requestJoin(
        familyId: parent.familyId!,
        founderPubkey: impostor.pubkey,
        deviceName: 'Confused',
        kind: DeviceKind.phone,
      );
      final result = await device.ingest(parent.changesSince({}));
      expect(result.rejected, isEmpty);
      expect(result.invalid, isNotEmpty);
      expect(device.family, isNull);
      expect(device.members, isEmpty);
    });
  });

  group('kid permissions', () {
    late Den tablet;
    late String mayaChore;
    late String leoChore;

    setUp(() async {
      mayaChore = await parent.addChore(
        title: 'Dishes',
        owner: OwnerMember(maya),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-03-01'),
        points: 2,
      );
      leoChore = await parent.addChore(
        title: 'Feed the cat',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-03-01'),
        points: 1,
      );
      tablet = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
    });

    test('Leo can complete his own chore but not Maya\'s', () async {
      await tablet.setChoreDone(leoChore, '2026-03-02', true);
      await expectLater(tablet.setChoreDone(mayaChore, '2026-03-02', true), throwsA(isA<PermissionDenied>()));
      final forged = await forge(
        tablet.keys,
        counter: 500,
        millis: clock.now + 1000,
        type: RecordType.completion,
        rid: '$mayaChore@2026-03-02',
        fields: {'chore': mayaChore, 'date': '2026-03-02', 'done': true, 'doneBy': leo},
        actor: leo,
      );
      await sync(tablet, parent);
      final result = await parent.ingest([forged]);
      expect(result.invalid.keys, [forged.id]);
      expect(parent.points().totals, containsPair(leo, 1));
      expect(parent.points().totals, containsPair(maya, 0));
    });

    test('Leo can\'t write to the parents\' space, approve devices, or adjust points', () async {
      await expectLater(
        tablet.addEvent(title: 'Secret', start: 0, end: 1, audience: Audience.parents),
        throwsA(isA<PermissionDenied>()),
      );
      await expectLater(tablet.adjustPoints(leo, 50, 'Because'), throwsA(isA<PermissionDenied>()));
      final joiner = await joinDevice(parent, clock, member: maya, approve: false);
      await sync(parent, tablet);
      await expectLater(tablet.approveDevice(joiner.deviceId, member: maya), throwsA(isA<PermissionDenied>()));
      await expectLater(tablet.addMember(name: 'Friend', role: Role.kid), throwsA(isA<PermissionDenied>()));
      await expectLater(tablet.updateFamily({'name': 'Leo land'}), throwsA(isA<PermissionDenied>()));
      await expectLater(
        tablet.addEvent(title: 'Party', start: 0, end: 1),
        throwsA(isA<PermissionDenied>()),
        reason: 'kids need the events grant',
      );
      final forged = await forge(
        tablet.keys,
        counter: 600,
        millis: clock.now + 1000,
        type: RecordType.event,
        rid: 'secretplansabcd',
        space: Space.parents,
        fields: {'title': 'Secret', 'start': 0, 'end': 1, 'tz': 'UTC'},
        actor: leo,
      );
      final result = await parent.ingest([forged]);
      expect(result.invalid.keys, [forged.id]);
    });

    test('a kid with the events grant can add events', () async {
      await parent.updateMember(leo, {'grants': [Grant.events]});
      await sync(parent, tablet);
      await tablet.addEvent(title: 'Lego club', start: clock.now, end: clock.now + 3600000);
      await sync(tablet, parent);
      expect(parent.events.map((e) => e.title), ['Lego club']);
    });

    test('kids swap only their own chores and ask for rewards only for themselves', () async {
      await tablet.swapForDay(leoChore, '2026-03-02', maya);
      await expectLater(tablet.swapForDay(mayaChore, '2026-03-02', leo), throwsA(isA<PermissionDenied>()));
      final reward = await parent.addReward(title: 'Later bedtime', cost: 0, needsApproval: false);
      await sync(parent, tablet);
      await tablet.requestReward(reward);
      await expectLater(tablet.requestReward(reward, member: maya), throwsA(isA<PermissionDenied>()));
      final big = await parent.addReward(title: '\$5', cost: 0);
      await sync(parent, tablet);
      final request = await tablet.requestReward(big);
      await expectLater(tablet.decideRedemption(request, approve: true), throwsA(isA<PermissionDenied>()));
    });

    test('a kid may check his own step on someone else\'s chore, and that can complete it', () async {
      final kitchen = await parent.addChore(
        title: 'Clean the kitchen',
        owner: OwnerMember(dana),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-03-01'),
        steps: [
          ChoreStep(id: 'sweep', text: 'Sweep', owner: maya, points: 2),
          ChoreStep(id: 'table', text: 'Wipe the table', owner: leo, points: 1),
        ],
      );
      await parent.setStep(kitchen, '2026-03-02', 'sweep', true);
      await sync(parent, tablet);
      await expectLater(tablet.setStep(kitchen, '2026-03-02', 'sweep', false), throwsA(isA<PermissionDenied>()));
      await tablet.setStep(kitchen, '2026-03-02', 'table', true);
      expect(tablet.choresOn('2026-03-02').firstWhere((c) => c.chore.id == kitchen).done, isTrue);
      await expectLater(tablet.setChoreDone(kitchen, '2026-03-02', false), throwsA(isA<PermissionDenied>()));
      await sync(tablet, parent);
      expect(parent.points().totals[leo], 1);
    });

    test('guests can complete their own chores and check items, nothing else', () async {
      final rosa = await parent.addMember(name: 'Rosa', role: Role.guest);
      final walk = await parent.addChore(
        title: 'Walk the dog',
        owner: OwnerMember(rosa),
        schedule: const ChoreSchedule.once('2026-03-02'),
      );
      final groceries = await parent.addList(title: 'Groceries', kind: ListKind.shopping);
      final milk = await parent.addItem(groceries, text: 'Milk');
      final phone = await joinDevice(parent, clock, member: rosa, name: 'Rosa phone');
      await phone.setChoreDone(walk, '2026-03-02', true);
      await phone.setItemChecked(milk, true);
      await expectLater(phone.addItem(groceries, text: 'Cookies'), throwsA(isA<PermissionDenied>()));
      await expectLater(phone.setChoreDone(leoChore, '2026-03-02', true), throwsA(isA<PermissionDenied>()));
      await expectLater(phone.swapForDay(walk, '2026-03-02', leo), throwsA(isA<PermissionDenied>()));
    });
  });

  group('shared displays and hubs', () {
    test('open check-off works only when the display allows it, and only for checking off', () async {
      final chore = await parent.addChore(
        title: 'Bring in the mail',
        owner: const OwnerAnyone(),
        schedule: const ChoreSchedule.once('2026-03-02'),
      );
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      expect(display.actor, isNull);
      await expectLater(display.setChoreDone(chore, '2026-03-02', true), throwsA(isA<PermissionDenied>()));
      await parent.updateDevice(display.deviceId, {
        'display': {'layout': 'week', 'openCheckoff': true},
      });
      await sync(parent, display);
      await display.setChoreDone(chore, '2026-03-02', true);
      await expectLater(display.addEvent(title: 'Nope', start: 0, end: 1), throwsA(isA<PermissionDenied>()));
      display.actAs(dana);
      expect(display.actor?.name, 'Dana');
      await display.addEvent(title: 'Pizza night', start: clock.now, end: clock.now + 3600000);
      display.actAs(leo);
      await expectLater(display.adjustPoints(leo, 5, 'x'), throwsA(isA<PermissionDenied>()));
      clock.advance(const Duration(minutes: 2));
      expect(display.actor, isNull, reason: 'the acting window ended');
      await sync(display, parent);
      expect(parent.events.single.title, 'Pizza night');
      expect(parent.history().firstWhere((h) => h.title == 'Bring in the mail').actorName, 'Kitchen');
    });

    test('a hub records its caller and can\'t approve devices or activate access', () async {
      final hub = await joinDevice(parent, clock, mode: DeviceMode.hub, name: 'Den hub', kind: DeviceKind.hub);
      hub.actAs(null, via: 'Home Assistant');
      final id = await hub.addEvent(title: 'Trash pickup', start: clock.now, end: clock.now + 600000);
      final pending = await hub.requestOAuthConnection(label: 'Claude', client: 'claude.ai', scopes: {Scope.read});
      await expectLater(hub.approveConnection(pending), throwsA(isA<PermissionDenied>()));
      final joiner = await joinDevice(parent, clock, member: leo, approve: false);
      await sync(parent, hub);
      await expectLater(hub.approveDevice(joiner.deviceId, member: leo), throwsA(isA<PermissionDenied>()));
      await sync(hub, parent);
      expect(parent.event(id)!.title, 'Trash pickup');
      final entry = parent.history().firstWhere((h) => h.title == 'Trash pickup');
      expect(entry.via, 'Home Assistant');
      expect(entry.actorName, 'Den hub');
      await parent.approveConnection(pending, member: leo);
      await sync(parent, hub);
      await hub.setConnectionToken(pending, hashToken('oauth-token'));
      await sync(hub, parent);
      expect(parent.connectionForToken('oauth-token')?.member, leo);
    });

    test('even a parent verified on a shared display can\'t administer the family', () async {
      final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      final joiner = await joinDevice(parent, clock, member: leo, approve: false);
      await sync(parent, display);
      display.actAs(dana);
      await expectLater(display.approveDevice(joiner.deviceId, member: leo), throwsA(isA<PermissionDenied>()));
      await expectLater(display.addMember(name: 'Visitor', role: Role.guest), throwsA(isA<PermissionDenied>()));
      await display.adjustPoints(leo, 2, 'Set the table without being asked');
      await sync(display, parent);
      expect(parent.points().totals[leo], 2);
    });

    test('a change nobody may make doesn\'t move this device\'s clock', () async {
      final stranger = await DeviceKeys.generate();
      final strangerId = await stranger.deviceId();
      final future = DateTime.utc(2099, 1, 1).millisecondsSinceEpoch;
      final join = await forge(
        stranger,
        counter: 1,
        millis: clock.now,
        type: RecordType.device,
        rid: strangerId,
        fields: {'name': 'Stranger', 'kind': 'phone', 'pubkey': stranger.pubkey, 'mode': 'personal', 'approved': false},
      );
      final far = await forge(
        stranger,
        counter: 2,
        millis: future,
        type: RecordType.category,
        rid: 'fromthefuture',
        fields: {'name': 'Future'},
      );
      final result = await parent.ingest([join, far]);
      expect(result.invalid.keys, [far.id]);
      await parent.addCategory(name: 'Now');
      final mine = parent.changesSince({}).lastWhere((c) => c.device == parent.deviceId);
      expect(mine.hlc.millis, lessThan(future));
    });

    test('only a hub may record a caller label', () async {
      final forged = await forge(
        parent.keys,
        counter: 900,
        millis: clock.now + 10,
        type: RecordType.category,
        rid: 'labelledcategory',
        fields: {'name': 'Sports', '_via': 'Pretend API'},
        actor: dana,
      );
      final other = await joinDevice(parent, clock, member: dana, name: 'Second');
      final result = await other.ingest([forged]);
      expect(result.invalid.keys, [forged.id]);
    });
  });

  group('schema', () {
    test('rejects bad fields with messages for people', () async {
      await expectLater(
        parent.addEvent(title: 'x' * 201, start: 0, end: 1),
        throwsA(isA<InvalidInput>().having((e) => e.message, 'message', contains('200'))),
      );
      await expectLater(parent.addEvent(title: 'Backwards', start: 10, end: 1), throwsA(isA<InvalidInput>()));
      await expectLater(parent.addEvent(title: 'Notes', start: 0, end: 1, notes: 'n' * 5001), throwsA(isA<InvalidInput>()));
      await expectLater(parent.addEvent(title: 'Rule', start: 0, end: 1, rrule: 'FREQ=HOURLY'), throwsA(isA<InvalidInput>()));
      await expectLater(
        parent.addChore(
          title: 'Too many steps',
          owner: OwnerMember(leo),
          schedule: const ChoreSchedule.once('2026-03-02'),
          steps: [for (var i = 0; i < 31; i++) ChoreStep(id: 's$i', text: 'Step $i')],
        ),
        throwsA(isA<InvalidInput>()),
      );
      await expectLater(
        parent.addChore(title: 'Late', owner: OwnerMember(leo), schedule: const ChoreSchedule.once('2026-02-30')),
        throwsA(isA<InvalidInput>()),
      );
      final list = await parent.addList(title: 'Groceries');
      await expectLater(parent.addItem(list, text: 'i' * 301), throwsA(isA<InvalidInput>()));
      await expectLater(parent.updateMember(leo, {'role': 'wizard'}), throwsA(isA<InvalidInput>()));
      await expectLater(parent.updateList(list, {'color': 'red'}), throwsA(isA<InvalidInput>()));
      final forged = await forge(
        parent.keys,
        counter: 950,
        millis: clock.now + 10,
        type: RecordType.list,
        rid: list,
        fields: {'title': 'Groceries', 'surprise': true},
        actor: dana,
      );
      final other = await joinDevice(parent, clock, member: dana, name: 'Second');
      expect((await other.ingest([forged])).invalid.keys, [forged.id]);
    });

    test('the family keeps at least one parent', () async {
      await expectLater(parent.removeMember(dana), throwsA(isA<PermissionDenied>()));
      await expectLater(parent.updateMember(dana, {'role': Role.adult}), throwsA(isA<PermissionDenied>()));
      final priya = await parent.addMember(name: 'Priya', role: Role.parent);
      await parent.updateMember(priya, {'role': Role.adult});
      expect(parent.member(priya)!.role, Role.adult);
    });
  });

  test('every replica reaches the same verdicts whatever order changes arrive in', () async {
    final kidTablet = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
    final observerA = await joinDevice(parent, clock, member: dana, name: 'A');
    final observerB = await joinDevice(parent, clock, member: dana, name: 'B');
    await sync(parent, observerA);
    await sync(parent, observerB);
    final chore = await parent.addChore(
      title: 'Dishes',
      owner: OwnerMember(maya),
      schedule: const ChoreSchedule.once('2026-03-02'),
    );
    await sync(parent, kidTablet);
    final forged = [
      for (var i = 0; i < 4; i++)
        await forge(
          kidTablet.keys,
          counter: 700 + i,
          millis: clock.now + 100 + i,
          type: RecordType.completion,
          rid: '$chore@2026-03-02',
          fields: {'chore': chore, 'date': '2026-03-02', 'done': i.isEven, 'doneBy': leo},
          actor: leo,
        ),
    ];
    await parent.revokeDevice(kidTablet.deviceId);
    final all = [...parent.changesSince(observerA.versionVector), ...forged];
    final a = await observerA.ingest(all);
    final b = await observerB.ingest(all.reversed.toList());
    expect(a.invalid.keys.toSet(), b.invalid.keys.toSet());
    expect(a.invalid.keys.toSet(), containsAll(forged.map((c) => c.id)));
    expect(observerA.exportJson(), observerB.exportJson());
  });
}
