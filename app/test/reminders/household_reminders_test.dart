// One reminder budget across every family on the device (FAMILY-LINKS-PLAN §4.4): the 60 nearest
// of all of them, ids made with the family's id for all but the first, titles that say whose
// once there are several, and taps that open the family's own page.
import 'package:den_app/platform/notifications/reminder_plan.dart';
import 'package:den_app/platform/notifications/reminder_scheduler.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_outlet.dart';

const _minute = 60000;

/// Friday, October 16, 2026, 8 AM in Chicago.
final int _start = DateTime.utc(2026, 10, 16, 13).millisecondsSinceEpoch;

Future<Den> family(String name) async {
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => _start);
  await den.createFamily(
    familyName: name,
    timezone: 'America/Chicago',
    yourName: 'Grandma',
    marker: Marker.sky,
    animal: Animal.cat,
    deviceName: "Grandma's phone",
    deviceKind: DeviceKind.phone,
  );
  return den;
}

/// [count] events, one every [every] from [from] past the start, each reminding 0 minutes before.
Future<void> events(Den den, String title, int count, {required Duration from, required Duration every}) async {
  for (var i = 0; i < count; i++) {
    final start = _start + from.inMilliseconds + every.inMilliseconds * i;
    await den.addEvent(title: '$title ${i + 1}', start: start, end: start + 30 * _minute, reminders: const [0]);
  }
}

void main() {
  test('one family plans exactly as it always has', () async {
    final kotvas = await family('Kotvas');
    await events(kotvas, 'Soccer', 3, from: const Duration(hours: 1), every: const Duration(hours: 2));
    final alone = planHouseholdReminders([ReminderLog(den: kotvas, id: kotvas.familyId!, label: 'Kotvas')], now: _start);
    expect(alone, planReminders(kotvas, now: _start));
    expect(alone.first.title, 'Soccer 1');
    expect(alone.first.route, startsWith('/event/'));
  });

  test('two families share one budget of 60, nearest first, each tap in its own family', () async {
    final kotvas = await family('Kotvas');
    final smith = await family('Smith family');
    // 40 each, interleaved: Kotvas on the hour, the Smiths on the half hour.
    await events(kotvas, 'Kotvas', 40, from: const Duration(hours: 1), every: const Duration(minutes: 60));
    await events(smith, 'Swim', 40, from: const Duration(minutes: 90), every: const Duration(minutes: 60));
    final logs = [
      ReminderLog(den: kotvas, id: kotvas.familyId!, label: 'Kotvas'),
      ReminderLog(den: smith, id: smith.familyId!, label: 'Smith family', first: false),
    ];
    final plan = planHouseholdReminders(logs, now: _start);
    expect(plan, hasLength(maxScheduledReminders));
    expect([for (final r in plan) r.at], [for (final r in plan) r.at]..sort(), reason: 'nearest first');
    expect(plan.where((r) => r.title.startsWith('Kotvas: ')), hasLength(30));
    expect(plan.where((r) => r.title.startsWith('Smith family: ')), hasLength(30));
    expect(plan.first.title, 'Kotvas: Kotvas 1');
    expect(plan[1].title, 'Smith family: Swim 1');
    expect(plan.last.at, lessThan(_start + const Duration(hours: 32).inMilliseconds));

    // Ids: the first family's are what they always were; the other family's are made with its id.
    final own = {for (final r in planReminders(kotvas, now: _start)) r.key: r.id};
    for (final r in plan.where((r) => r.title.startsWith('Kotvas: '))) {
      expect(r.id, own[r.key], reason: 'the first family keeps its ids');
    }
    for (final r in plan.where((r) => r.title.startsWith('Smith family: '))) {
      expect(r.key, startsWith('${smith.familyId}|'));
      expect(r.id, reminderId(r.key));
      expect(r.route, startsWith('/l/${smith.familyId}/event/'));
    }
    expect(plan.map((r) => r.id).toSet(), hasLength(plan.length), reason: 'no two share an id');
    expect(plan.firstWhere((r) => r.title.startsWith('Kotvas: ')).route, startsWith('/l/${kotvas.familyId}/event/'));
  });

  test('a family still waiting for a parent plans nothing, but the rest still say whose', () async {
    final kotvas = await family('Kotvas');
    final smith = await family('Smith family');
    await events(kotvas, 'Soccer', 1, from: const Duration(hours: 1), every: const Duration(hours: 1));
    final waiting = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: () => _start);
    await waiting.requestJoin(familyId: smith.familyId!, founderPubkey: smith.founderPubkey!, deviceName: 'iPhone', kind: DeviceKind.phone);
    expect(waiting.hasFamily && !waiting.isApproved, isTrue);
    final plan = planHouseholdReminders([
      ReminderLog(den: kotvas, id: kotvas.familyId!, label: 'Kotvas'),
      ReminderLog(den: waiting, id: smith.familyId!, label: 'Smith family', first: false),
    ], now: _start);
    expect(plan.map((r) => r.title), ['Kotvas: Soccer 1']);
    expect(plan.single.route, startsWith('/l/${kotvas.familyId}/event/'),
        reason: 'the device may be showing the Smiths: a tap opens the Kotvases');
  });

  test("with a family that didn't open, the budget leaves room for what the OS holds for it", () async {
    final kotvas = await family('Kotvas');
    await events(kotvas, 'Kotvas', 70, from: const Duration(hours: 1), every: const Duration(minutes: 30));
    final kept = {for (var i = 0; i < 10; i++) 1000 + i};
    final outlet = FakeOutlet()
      ..leftover = {...kept}
      ..leftoverRoutes = {for (final id in kept) id: '/l/smithfamily23456/event/E$id'};
    final scheduler = ReminderScheduler.logs(
      () => [ReminderLog(den: kotvas, id: kotvas.familyId!, label: 'Kotvas')],
      outlet,
      enabled: true,
      unopened: () => ['smithfamily23456'],
      now: () => _start,
      settle: Duration.zero,
    );
    await scheduler.start();
    expect(outlet.cancelled, isEmpty);
    expect(outlet.held.length, maxScheduledReminders - kept.length, reason: 'one budget, theirs counted');
    expect(outlet.held.keys.toSet().intersection(kept), isEmpty, reason: 'no id of theirs taken');
    expect(outlet.held.values.first.title, startsWith('Kotvas: '));
    await scheduler.dispose();
  });

  test('the scheduler follows families as they join and leave the device', () async {
    final kotvas = await family('Kotvas');
    final smith = await family('Smith family');
    await events(kotvas, 'Soccer', 2, from: const Duration(hours: 1), every: const Duration(hours: 3));
    await events(smith, 'Swim', 2, from: const Duration(hours: 2), every: const Duration(hours: 3));
    final logs = <ReminderLog>[ReminderLog(den: kotvas, id: kotvas.familyId!, label: 'Kotvas')];
    final changed = ChangeNotifier();
    final outlet = FakeOutlet();
    final scheduler = ReminderScheduler.logs(
      () => [...logs],
      outlet,
      enabled: true,
      logsChanged: changed,
      now: () => _start,
      settle: Duration.zero,
    );
    await scheduler.start();
    expect(outlet.held.values.map((r) => r.title), unorderedEquals(['Soccer 1', 'Soccer 2']));

    // The Smiths join: their reminders come in, and every title now says whose.
    logs.add(ReminderLog(den: smith, id: smith.familyId!, label: 'Smith family', first: false));
    changed.notifyListeners();
    await _settled(() => outlet.held.length == 4);
    expect(outlet.held.values.map((r) => r.title),
        unorderedEquals(['Kotvas: Soccer 1', 'Kotvas: Soccer 2', 'Smith family: Swim 1', 'Smith family: Swim 2']));

    // A change in the Smiths' engine is followed too.
    final start = _start + const Duration(hours: 5).inMilliseconds;
    await smith.addEvent(title: 'Lake day', start: start, end: start + 3600000, reminders: const [0]);
    await _settled(() => outlet.held.length == 5);

    // They leave: theirs are withdrawn, and the Kotvas titles are as they were.
    logs.removeLast();
    changed.notifyListeners();
    await _settled(() => outlet.held.length == 2);
    expect(outlet.held.values.map((r) => r.title), unorderedEquals(['Soccer 1', 'Soccer 2']));
    await scheduler.dispose();
  });
}

Future<void> _settled(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'timed out');
}
