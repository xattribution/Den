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

  test('kids don\'t see calendar feeds and can\'t add them', () async {
    final tablet = await joinDevice(phone, clock, member: leo, name: 'Leo tablet');
    await phone.addSubscription(url: 'https://school.example/calendar.ics');
    await sync(phone, tablet);
    expect(tablet.subscriptions, isEmpty);
    await expectLater(tablet.addSubscription(url: 'https://x.example/a.ics'), throwsA(isA<PermissionDenied>()));
  });
}
