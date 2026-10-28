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

  test('putting back one removed occurrence, or the rest of a series, keeps their changes', () async {
    final start = DateTime.utc(2026, 4, 7, 21).millisecondsSinceEpoch;
    final id = await den.addEvent(title: 'Soccer', start: start, end: start + hour, rrule: 'FREQ=WEEKLY', assignees: [leo]);
    List<String> shown() => [for (final o in den.occurrences(start, start + 60 * 24 * hour)) '${o.title} ${o.start}'];
    final occ = den.occurrences(start, start + 60 * 24 * hour);
    await den.updateEvent(id, {'title': 'Soccer (away)'}, scope: EditScope.one, occurrence: occ[1].seriesStart);
    await den.claimRide(id, occurrence: occ[3].seriesStart, leg: 'to', driver: leo);
    final before = shown();

    await den.deleteEvent(id, scope: EditScope.one, occurrence: occ[1].seriesStart);
    expect(shown(), isNot(contains('Soccer (away) ${occ[1].start}')));
    await den.restoreEvent(id, scope: EditScope.one, occurrence: occ[1].seriesStart);
    expect(shown(), before, reason: 'it comes back with its own title');

    final rule = den.event(id)!.rrule;
    await den.deleteEvent(id, scope: EditScope.following, occurrence: occ[2].seriesStart);
    expect(shown(), hasLength(2));
    final changes = den.history().length;
    await den.restoreEvent(id, scope: EditScope.following, occurrence: occ[2].seriesStart, rrule: rule);
    expect(shown(), before);
    expect(den.occurrences(occ[3].start, occ[3].end).single.rides.single.driver, leo,
        reason: 'the changed occurrence comes back with its ride');
    expect(den.history().length - changes, 2, reason: 'the rule and the one changed occurrence, in one go');
  });

  test('restoring several items is one commit, and they keep their places', () async {
    final list = await den.addList(title: 'Groceries', kind: ListKind.shopping);
    final ids = [for (final text in ['Milk', 'Eggs', 'Bread', 'Apples']) await den.addItem(list, text: text)];
    await den.setItemChecked(ids[0], true);
    await den.setItemChecked(ids[2], true);
    final heard = <Set<String>>[];
    final sub = den.onChange.listen(heard.add);
    expect(await den.clearChecked(list), 2);
    await Future<void>.delayed(Duration.zero);
    heard.clear();
    await den.restoreAll(RecordType.item, [ids[0], ids[2]]);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(heard, hasLength(1));
    expect(den.list(list)!.items.map((i) => i.id), ids);
    expect(den.list(list)!.items.where((i) => i.checked).map((i) => i.text), ['Milk', 'Bread']);
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
