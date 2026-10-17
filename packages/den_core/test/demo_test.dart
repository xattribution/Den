import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

void main() {
  late Den den;
  final watch = Stopwatch();

  setUpAll(() async {
    watch.start();
    den = await createDemoFamily(now: DateTime(2026, 10, 16, 8));
    watch.stop();
  });

  test('today is the given date in the family zone', () {
    expect(den.family!.timezone, 'America/Chicago');
    expect(den.todayDate(), '2026-10-16');
  });

  test('today has events, chores, pinned lists and at least one gap', () {
    final today = den.today();
    expect(today.events.map((o) => o.title), containsAll(['School drop-off', 'Swim lesson']));
    expect(today.chores, isNotEmpty);
    expect(today.lists.map((l) => l.list.title), contains('Groceries'));
    expect(today.gaps, isNotEmpty);
    expect(today.gaps.map((g) => g.message), contains('Nobody is driving Zoe to Swim lesson'));
    expect(today.gaps.map((g) => g.message), contains('Nobody has taken Bring in the mail'));
  });

  test('the week has soccer with nobody picking up, and family columns', () {
    final week = den.week('2026-10-11');
    expect(week.people.map((m) => m.name), ['Alex', 'Priya', 'Maya', 'Leo', 'Zoe', 'Grandma Rosa']);
    final leo = den.members.firstWhere((m) => m.name == 'Leo').id;
    final tuesday = week.cells[('2026-10-13', leo)]!;
    expect(tuesday.events.map((o) => o.title), contains('Soccer practice'));
    expect(week.everyone['2026-10-17'], isEmpty);
    final gaps = den.gaps(den.dayStart('2026-10-11'), den.dayStart('2026-10-18'));
    expect(gaps.map((g) => g.message), contains('Nobody is picking up Leo from Soccer practice'));
    expect(den.occurrences(den.dayStart('2026-10-18'), den.dayStart('2026-10-19')).map((o) => o.title),
        contains('Dinner at Grandma\'s'));
  });

  test('chores carry completions from the kitchen display, with points and history', () {
    final today = den.choresOn('2026-10-16');
    final zoe = den.members.firstWhere((m) => m.name == 'Zoe').id;
    final bed = today.firstWhere((c) => c.chore.title == 'Make bed' && c.owner == zoe);
    expect(bed.done, isTrue);
    expect(bed.doneBy, zoe);
    final books = today.firstWhere((c) => c.chore.title == 'Return library books');
    expect(books.late, isTrue);
    final points = den.points();
    final maya = den.members.firstWhere((m) => m.name == 'Maya').id;
    expect(points.totals[maya], greaterThan(0));
    expect(points.pending, hasLength(1));
    expect(points.goals, hasLength(2));
    expect(den.history().any((h) => h.deviceName == 'Kitchen display' && h.verb == 'completed'), isTrue);
    expect(den.devices.map((d) => d.name), containsAll(['Alex\'s phone', 'Kitchen display']));
  });

  test('lists are realistic', () {
    final groceries = den.lists.firstWhere((l) => l.list.title == 'Groceries');
    expect(groceries.items.length, greaterThanOrEqualTo(14));
    expect(groceries.items.where((i) => i.checked), isNotEmpty);
    expect(groceries.items.map((i) => i.text), contains('Taco shells'));
    expect(den.stores.take(3).toSet(), {'Costco', 'Target', 'Trader Joe\'s'});
    final science = den.lists.firstWhere((l) => l.list.title == 'Science fair supplies');
    expect(science.list.needBy, '2026-10-19');
  });

  test('builds quickly enough for screenshots', () {
    expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
  });

  test('works on any day, including a Sunday on the day clocks change', () async {
    final sunday = await createDemoFamily(now: DateTime.utc(2026, 3, 8, 15));
    expect(sunday.todayDate(), '2026-03-08');
    expect(sunday.today().gaps, isNotEmpty);
    expect(sunday.today().events, isNotEmpty);
    expect(sunday.points().pending, hasLength(1));
    expect(sunday.history().where((h) => h.verb == 'completed').length, greaterThan(20));
  });

  test('without a time, follows the real clock', () async {
    final live = await createDemoFamily();
    expect(live.today().chores, isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(live.history().first.when.millis, lessThanOrEqualTo(now));
  });
}
