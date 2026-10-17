import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const hour = 3600000;

void main() {
  late TestClock clock;
  late Den den;
  late String leo;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 4, 6, 14));
    den = await foundFamily(clock);
    leo = await den.addMember(name: 'Leo', role: Role.kid);
  });

  test('restoring an event brings back its changed and canceled occurrences', () async {
    final start = DateTime.utc(2026, 4, 7, 21).millisecondsSinceEpoch;
    final id = await den.addEvent(title: 'Soccer', start: start, end: start + hour, rrule: 'FREQ=WEEKLY', assignees: [leo]);
    final occ = den.occurrences(start, start + 30 * 24 * hour);
    await den.updateEvent(id, {'title': 'Soccer (away)'}, scope: EditScope.one, occurrence: occ[1].seriesStart);
    await den.deleteEvent(id, scope: EditScope.one, occurrence: occ[2].seriesStart);
    final before = jsonEncode([for (final o in den.occurrences(start, start + 30 * 24 * hour)) [o.title, o.start]]);
    await den.deleteEvent(id);
    expect(den.event(id), isNull);
    expect(den.occurrences(start, start + 30 * 24 * hour), isEmpty);
    await den.restore(RecordType.event, id);
    final after = jsonEncode([for (final o in den.occurrences(start, start + 30 * 24 * hour)) [o.title, o.start]]);
    expect(after, before);
    expect(den.history().first.verb, 'restored');
  });

  test('restoring a chore brings back its completions and points', () async {
    final chore = await den.addChore(
      title: 'Feed the cat',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-04-01'),
      points: 2,
    );
    await den.setChoreDone(chore, '2026-04-05', true);
    await den.deleteChore(chore);
    expect(den.choresOn('2026-04-06'), isEmpty);
    await den.restore(RecordType.chore, chore);
    expect(den.choresOn('2026-04-06').single.chore.id, chore);
    expect(den.choresOn('2026-04-05').single.done, isTrue);
    expect(den.points().totals[leo], 2);
  });

  test('restoring a list brings back its items; restoring an item brings back just that item', () async {
    final list = await den.addList(title: 'Groceries', kind: ListKind.shopping);
    final milk = await den.addItem(list, text: 'Milk', store: 'Costco');
    await den.addItem(list, text: 'Eggs', store: 'Costco');
    await den.deleteList(list);
    expect(den.list(list), isNull);
    expect(den.stores, isEmpty, reason: 'items on a removed list don\'t count');
    await den.restore(RecordType.list, list);
    expect(den.list(list)!.items.map((i) => i.text), ['Milk', 'Eggs']);
    await den.removeItem(milk);
    await den.restore(RecordType.item, milk);
    expect(den.list(list)!.items.map((i) => i.text), ['Milk', 'Eggs'], reason: 'back in its place');
    await den.restore(RecordType.item, milk);
    await expectLater(den.restore(RecordType.item, 'nosuchitemhere1'), throwsA(isA<InvalidInput>()));
  });

  test('restoring needs the permission editing would', () async {
    final start = DateTime.utc(2026, 4, 7, 21).millisecondsSinceEpoch;
    final id = await den.addEvent(title: 'Dentist', start: start, end: start + hour);
    final list = await den.addList(title: 'Groceries');
    final milk = await den.addItem(list, text: 'Milk');
    await den.deleteEvent(id);
    await den.removeItem(milk);
    final tablet = await joinDevice(den, clock, member: leo);
    await expectLater(tablet.restore(RecordType.event, id), throwsA(isA<PermissionDenied>()));
    await expectLater(tablet.restore(RecordType.item, milk), throwsA(isA<PermissionDenied>()));
  });
}
