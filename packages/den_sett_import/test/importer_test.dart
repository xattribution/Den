import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_sett_import/den_sett_import.dart';
import 'package:test/test.dart';

import 'sett_fixture.dart';

void main() {
  late Directory tmp;
  late Den den;
  late SettImportReport report;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('den_sett_import');
    final path = '${tmp.path}${Platform.pathSeparator}coord.db';
    writeSettFixture(path);
    den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    await den.createFamily(
      familyName: 'Rivera',
      timezone: 'America/Chicago',
      yourName: 'Sam',
      marker: Marker.sky,
      animal: Animal.cat,
      deviceName: "Sam's phone",
      deviceKind: DeviceKind.phone,
    );
    report = await importSettDatabase(path, den);
  });

  tearDownAll(() => tmp.delete(recursive: true));

  Member named(String name) => den.members.firstWhere((m) => m.name == name);

  test('merges the importing parent and adds everyone else once', () {
    expect(den.members.map((m) => m.name), unorderedEquals(['Sam', 'Alex', 'Mia', 'Leo']));
    expect(report.imported['people matched by name'], 1);
    expect(report.imported['people'], 3);
  });

  test('maps roles, tiers, grants and avatars', () {
    expect(named('Alex').role, Role.parent);
    expect(named('Mia').tier, Tier.little);
    expect(named('Leo').tier, Tier.teen);
    expect(named('Leo').grants, {Grant.chores});
    expect(named('Mia').animal, Animal.rabbit);
    expect(named('Leo').animal, Animal.dog);
  });

  test('repeating events keep their rule, people, reminders and exceptions', () {
    final soccer = den.occurrences(
      DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
      DateTime.utc(2026, 10, 11).millisecondsSinceEpoch,
    ).where((o) => o.title == 'Soccer practice').toList();
    // Oct 1, 6 (canceled), 8 (moved), and nothing else before Oct 11 besides Oct 1 and 8.
    expect(soccer.length, 2);
    expect(soccer.first.event.assignees, [named('Leo').id]);
    expect(soccer.first.event.reminders, [60]);
    final moved = soccer.last;
    expect(moved.start - DateTime.utc(2026, 10, 8, 22).millisecondsSinceEpoch, 3600000);
  });

  test("private events go to the parents' space; subscribed and deleted events stay behind", () {
    final surprise = den.occurrences(0, DateTime.utc(2027).millisecondsSinceEpoch)
        .firstWhere((o) => o.title == 'Plan the surprise party');
    expect(surprise.event.space, Space.parents);
    expect(den.occurrences(0, DateTime.utc(2027).millisecondsSinceEpoch).any((o) => o.title == 'Team game'), isFalse);
    expect(den.occurrences(0, DateTime.utc(2027).millisecondsSinceEpoch).any((o) => o.title == 'Gone'), isFalse);
    expect(report.skipped.keys.any((k) => k.startsWith('events from subscribed')), isTrue);
  });

  test('chores keep schedules, steps, points and check-offs', () {
    final bed = den.chores.firstWhere((c) => c.title == 'Make bed');
    expect(bed.schedule.rrule, 'FREQ=DAILY');
    expect(bed.icon, 'bed');
    final dishes = den.chores.firstWhere((c) => c.title == 'Dishes');
    expect(dishes.schedule.rrule, 'FREQ=WEEKLY;BYDAY=MO,WE,FR');
    expect(dishes.steps.map((s) => s.text), ['Load', 'Wipe counters']);
    expect(dishes.steps.first.owner, named('Leo').id);
    final trash = den.chores.firstWhere((c) => c.title == 'Take out trash');
    expect(trash.owner, isA<OwnerAnyone>());
    expect(trash.schedule.once, '2026-10-04');

    expect(den.choresOn('2026-10-02').firstWhere((d) => d.chore.id == bed.id).done, isTrue);
    final trashDay = den.choresOn('2026-10-04').firstWhere((d) => d.chore.id == trash.id);
    expect(trashDay.done, isTrue);
    expect(trashDay.owner, named('Leo').id);
  });

  test("points: chore points are derived again, manual adjustments carry over, goals too", () {
    final totals = den.points().totals;
    expect(totals[named('Mia').id], 1);
    expect(totals[named('Leo').id], 3 + 5);
    expect(den.points().goals.single.goal.title, 'Movie pick');
    expect(den.points().goals.single.goal.repeat, GoalRepeat.monthly);
  });

  test('lists keep kinds, lifecycles, stores, quantities and checks', () {
    final groceries = den.lists.firstWhere((l) => l.list.title == 'Groceries');
    expect(groceries.list.pinned, isTrue);
    expect(groceries.items.map((i) => i.text), ['Milk', 'Eggs']);
    expect(groceries.items.first.store, 'Costco');
    expect(groceries.items.first.qty, '2 gal');
    expect(groceries.items.last.checked, isTrue);
    final bag = den.lists.firstWhere((l) => l.list.title == 'Soccer bag');
    expect(bag.list.lifecycle, ListLifecycle.event);
    expect(den.event(bag.list.event!)?.title, 'Soccer practice');
  });

  test('reports what stayed behind', () {
    expect(report.skipped.length, greaterThanOrEqualTo(4));
    expect(report.notes.any((n) => n.contains('PINs')), isTrue);
  });
}
