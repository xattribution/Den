import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('found a family, add people, events, chores and lists', () async {
    final clock = TestClock.at(DateTime.utc(2026, 10, 16, 13));
    final den = await foundFamily(clock);
    expect(den.isApproved, isTrue);
    expect(den.actor?.name, 'Dana');
    expect(den.family?.name, 'Rivera family');
    final leo = await den.addMember(name: 'Leo', role: Role.kid, tier: Tier.little);
    expect(den.members.map((m) => m.name), ['Dana', 'Leo']);
    final start = DateTime.utc(2026, 10, 16, 21).millisecondsSinceEpoch;
    await den.addEvent(
      title: 'Soccer',
      start: start,
      end: start + 3600000,
      assignees: [leo],
      rides: const [Ride('from', null)],
    );
    final today = den.today();
    expect(today.date, '2026-10-16');
    expect(today.events.single.title, 'Soccer');
    expect(today.gaps.single.message, 'Nobody is picking up Leo from Soccer');
    final chore = await den.addChore(
      title: 'Feed the cat',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      points: 2,
    );
    expect(den.choresOn('2026-10-16').single.chore.id, chore);
    await den.setChoreDone(chore, '2026-10-16', true);
    expect(den.points().totals[leo], 2);
    final list = await den.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
    await den.addItem(list, text: 'Milk', store: 'Costco');
    expect(den.list(list)!.items.single.text, 'Milk');
    expect(den.history().first.verb, 'added');
  });
}
