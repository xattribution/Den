import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The writes a hub makes for API tokens, MCP clients and calendar feeds.
void main() {
  late TestClock clock;
  late Den phone;
  late Den hub;
  late String dana;
  late String leo;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 14, 15));
    phone = await foundFamily(clock, timezone: 'America/Chicago');
    dana = phone.actor!.id;
    leo = await phone.addMember(name: 'Leo', role: Role.kid, tier: Tier.big);
    hub = await joinDevice(phone, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
  });

  test('a hub places events, chores and lists in a member\'s private space', () async {
    hub.actAs(null, via: 'Home Assistant');
    final event = await hub.addEvent(
      title: 'Orthodontist',
      start: clock.now + 86400000,
      end: clock.now + 90000000,
      space: Space.member(leo),
    );
    final chore = await hub.addChore(
      title: 'Practice piano',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.once('2026-10-15'),
      space: Space.member(leo),
    );
    final list = await hub.addList(title: 'Birthday wishes', space: Space.member(leo));
    hub.actAs(null);
    expect(hub.event(event)!.space, Space.member(leo));
    expect(hub.chore(chore)!.space, Space.member(leo));
    expect(hub.list(list)!.list.space, Space.member(leo));
    await sync(hub, phone);
    expect(phone.event(event)!.title, 'Orthodontist');
    expect(phone.history(type: RecordType.event).first.via, 'Home Assistant');
  });

  test('acting for a connection, a hub writes only where the person it acts for could read', () async {
    final maya = await phone.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen, grants: {Grant.events});
    await phone.updateMember(leo, {'grants': [Grant.events]});
    await phone.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
    await sync(phone, hub);
    Future<String> add(String space) => hub.addEvent(title: 'Note', start: clock.now, end: clock.now + 1, space: space);
    // Leo's token: his own space and everyone's, never the parents' or his sister's.
    hub.actAs(leo, via: 'Leo\'s assistant');
    await add(Space.member(leo));
    await add(Space.family);
    await expectLater(add(Space.parents), throwsA(isA<PermissionDenied>()));
    await expectLater(add(Space.member(maya)), throwsA(isA<PermissionDenied>()));
    // A parent-level connection: everything parents see, not a teen's own space when parents
    // don't see it.
    hub.actAs(null, via: 'Home Assistant');
    await add(Space.parents);
    await add(Space.member(leo));
    await expectLater(add(Space.member(maya)), throwsA(isA<PermissionDenied>()));
    // The hub's own writes (feeds, say) name no connection and go anywhere.
    hub.actAs(null);
    await add(Space.member(maya));
    // A forged one says the same on every replica.
    final forged = await forge(
      hub.keys,
      counter: 900,
      millis: clock.now + 5,
      type: RecordType.event,
      rid: 'forgedintoparents',
      space: Space.parents,
      actor: leo,
      fields: {'title': 'Sneaky', 'start': clock.now, 'end': clock.now + 1, '_via': 'Leo\'s assistant'},
    );
    expect((await phone.ingest([forged])).invalid[forged.id], contains('can\'t see that'));
  });

  test('imported events carry their source and stay readable as such', () async {
    final id = await hub.addEvent(
      title: 'Picture day',
      start: clock.now,
      end: clock.now + 3600000,
      source: const EventSource('ics', 'uid-1@school', 'School calendar'),
      space: Space.parents,
    );
    final event = hub.event(id)!;
    expect(event.source.kind, 'ics');
    expect(event.source.ref, 'uid-1@school');
    expect(event.source.label, 'School calendar');
    expect(event.source.readOnly, isTrue);
    expect(event.space, Space.parents);
    final manual = await hub.addEvent(title: 'Dentist', start: clock.now, end: clock.now + 1);
    expect(hub.event(manual)!.source.kind, 'manual');
  });

  test('a parent records that someone else did a chore or a step', () async {
    final chore = await phone.addChore(
      title: 'Dishes',
      owner: const OwnerAnyone(),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      points: 3,
      steps: const [ChoreStep(id: 'load', text: 'Load'), ChoreStep(id: 'wipe', text: 'Wipe')],
    );
    await phone.setChoreDoneBy(chore, '2026-10-14', true, leo);
    var day = phone.choresOn('2026-10-14').firstWhere((c) => c.chore.id == chore);
    expect(day.done, isTrue);
    expect(day.doneBy, leo);
    expect(day.steps.values.toSet(), {leo});
    expect(phone.points().totals[leo], 3);
    await phone.setChoreDoneBy(chore, '2026-10-14', false, null);
    await phone.setStepBy(chore, '2026-10-14', 'load', true, leo);
    day = phone.choresOn('2026-10-14').firstWhere((c) => c.chore.id == chore);
    expect(day.steps['load'], leo);
    expect(day.done, isFalse);
    expect(() => phone.setChoreDoneBy(chore, '2026-10-14', true, 'nobody'), throwsA(isA<InvalidInput>()));
  });

  test('a kid can\'t credit someone else, even through the credited methods', () async {
    final tablet = await joinDevice(phone, clock, member: leo, name: 'Leo tablet');
    final chore = await phone.addChore(
      title: 'Feed the cat',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
    );
    await sync(phone, tablet);
    await expectLater(tablet.setChoreDoneBy(chore, '2026-10-14', true, dana), throwsA(isA<PermissionDenied>()));
    await tablet.setChoreDoneBy(chore, '2026-10-14', true, leo);
    expect(tablet.choresOn('2026-10-14').single.done, isTrue);
  });

  test('calendar feeds: parents manage them, the hub only reports status', () async {
    final id = await phone.addSubscription(
      url: 'https://school.example/calendar.ics',
      label: 'School',
      assignee: leo,
      include: const ['Grade 3'],
      skipAllDay: true,
    );
    expect(phone.subscriptions.single.label, 'School');
    expect(phone.subscription(id)!.targetSpace, Space.family);
    await phone.updateSubscription(id, {'label': 'Oak Grove', 'space': Space.parents});
    expect(phone.subscription(id)!.label, 'Oak Grove');
    expect(phone.subscription(id)!.targetSpace, Space.parents);
    await sync(phone, hub);
    expect(hub.subscriptions.single.include, ['Grade 3']);
    await hub.setSubscriptionStatus(id, '12 events, updated 3:42 PM');
    expect(hub.subscription(id)!.status, '12 events, updated 3:42 PM');
    await expectLater(hub.updateSubscription(id, {'url': 'https://elsewhere.example/x.ics'}), throwsA(isA<PermissionDenied>()));
    await sync(hub, phone);
    expect(phone.subscription(id)!.status, '12 events, updated 3:42 PM');
    await phone.removeSubscription(id);
    expect(phone.subscriptions, isEmpty);
  });

  group('trust decisions are made only on a parent\'s own device', () {
    late Den ownHub;
    late Den waiting;

    setUp(() async {
      // A parent's own phone running as the family's hub ("Keep the family online").
      ownHub = await joinDevice(phone, clock, member: dana, mode: DeviceMode.hub, name: 'Dana phone (hub)');
      waiting = await joinDevice(phone, clock, member: leo, name: 'Leo tablet', approve: false);
      await sync(phone, ownHub);
      expect(ownHub.owner?.id, dana);
    });

    test('an assistant acting through the hub as its owner can\'t make any of them', () async {
      final kidTablet = await joinDevice(phone, clock, member: leo, name: 'Leo old tablet');
      final pending = await phone.requestOAuthConnection(label: 'Claude', client: 'https://claude.ai', scopes: {Scope.read});
      await sync(phone, ownHub);
      ownHub.actAs(dana, via: 'Claude');
      expect(ownHub.actor?.id, dana);
      final refused = <String, Future<Object?> Function()>{
        'approve a device': () => ownHub.approveDevice(waiting.deviceId, member: leo),
        'revoke a device': () => ownHub.revokeDevice(kidTablet.deviceId),
        'rename another device': () => ownHub.updateDevice(kidTablet.deviceId, {'name': 'Mine now'}),
        'switch the hub to a personal device': () => ownHub.setThisDeviceMode(DeviceMode.personal),
        'change a role': () => ownHub.updateMember(leo, {'role': Role.parent}),
        'change grants': () => ownHub.updateMember(leo, {'grants': [Grant.points]}),
        'remove a person': () => ownHub.removeMember(leo),
        'set a sign-in': () => ownHub.setSignIn(leo, kind: 'none'),
        'change oversight': () => ownHub.updateFamily({
              'oversight': {leo: {'parentsSeePrivate': false}},
            }),
        'make a token': () => ownHub.addTokenConnection(label: 'Backdoor', scopes: {Scope.admin}),
        'approve access': () => ownHub.approveConnection(pending, scopes: {Scope.admin}),
      };
      for (final e in refused.entries) {
        await expectLater(e.value(), throwsA(isA<PermissionDenied>()), reason: e.key);
      }
      // Everyday writes through the hub still work, adding someone included: nothing acts for
      // them until a parent approves a device or an assistant for them.
      await ownHub.updateMember(leo, {'name': 'Leonardo'});
      final grandpa = await ownHub.addMember(name: 'Grandpa Joe', role: Role.adult);
      await expectLater(ownHub.updateMember(grandpa, {'role': Role.parent}), throwsA(isA<PermissionDenied>()));
      await ownHub.updateFamily({'name': 'The Riveras'});
      ownHub.actAs(null);
      await sync(ownHub, phone);
      expect(phone.member(leo)!.name, 'Leonardo');
      expect(phone.member(leo)!.role, Role.kid);
      expect(phone.device(waiting.deviceId)!.approved, isFalse);
    });

    test('a change from the hub that names its connection can\'t lose that name on the way', () async {
      ownHub.actAs(dana, via: 'Claude');
      await ownHub.updateMember(leo, {'name': 'Leonardo'});
      ownHub.actAs(null);
      final signed = ownHub.changesSince(const {}).lastWhere((c) => c.device == ownHub.deviceId);
      expect(signed.fields['_via'], 'Claude');
      final stripped = Change(
        id: signed.id,
        space: signed.space,
        hlc: signed.hlc,
        type: signed.type,
        rid: signed.rid,
        fields: {...signed.fields}..remove('_via'),
        device: signed.device,
        actor: signed.actor,
        sig: signed.sig,
      );
      final result = await phone.ingest([stripped]);
      expect(result.rejected.keys, [stripped.id]);
      expect(phone.member(leo)!.name, 'Leo');
    });

    test('a forged approval signed by the hub for a connection is invalid on every replica', () async {
      final forged = await forge(
        ownHub.keys,
        counter: 900,
        millis: clock.now + 10,
        type: RecordType.device,
        rid: waiting.deviceId,
        fields: {'approved': true, 'approvedBy': dana, 'member': leo, 'mode': 'personal', '_via': 'Claude'},
        actor: dana,
      );
      final result = await phone.ingest([forged]);
      expect(result.invalid.keys, [forged.id]);
      expect(phone.device(waiting.deviceId)!.approved, isFalse);
    });

    test('the parent using their own hub phone still can; a hub nobody owns and a shared screen can\'t', () async {
      await ownHub.approveDevice(waiting.deviceId, member: leo);
      expect(ownHub.device(waiting.deviceId)!.approved, isTrue);
      await ownHub.setThisDeviceMode(DeviceMode.personal);

      final joiner = await joinDevice(phone, clock, member: leo, name: 'Leo phone', approve: false);
      await sync(phone, hub);
      await expectLater(hub.approveDevice(joiner.deviceId, member: leo), throwsA(isA<PermissionDenied>()));
      hub.actAs(dana, via: 'Home Assistant');
      await expectLater(hub.approveDevice(joiner.deviceId, member: leo), throwsA(isA<PermissionDenied>()));
      hub.actAs(null);

      final display = await joinDevice(phone, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
      await sync(phone, display);
      display.actAs(dana);
      await expectLater(display.setSignIn(leo, kind: 'none'), throwsA(isA<PermissionDenied>()));
      await expectLater(display.updateMember(leo, {'role': Role.adult}), throwsA(isA<PermissionDenied>()));
      await expectLater(display.addTokenConnection(label: 'x', scopes: {Scope.read}), throwsA(isA<PermissionDenied>()));
    });
  });

  test('kids don\'t see calendar feeds and can\'t add them', () async {
    final tablet = await joinDevice(phone, clock, member: leo, name: 'Leo tablet');
    await phone.addSubscription(url: 'https://school.example/calendar.ics');
    await sync(phone, tablet);
    expect(tablet.subscriptions, isEmpty);
    await expectLater(tablet.addSubscription(url: 'https://x.example/a.ics'), throwsA(isA<PermissionDenied>()));
  });
}
