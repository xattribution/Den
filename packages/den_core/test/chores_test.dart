import 'package:den_core/den_core.dart';
import 'package:den_core/src/time.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  const zone = 'America/Chicago';
  late TestClock clock;
  late Den den;
  late String maya;
  late String leo;
  late String zoe;

  setUp(() async {
    clock = TestClock(wallToUtc(zone, DateTime.utc(2026, 10, 14, 10)));
    den = await foundFamily(clock, timezone: zone);
    maya = await den.addMember(name: 'Maya', role: Role.kid);
    leo = await den.addMember(name: 'Leo', role: Role.kid);
    zoe = await den.addMember(name: 'Zoe', role: Role.kid);
  });

  ChoreDay on(String date, String chore) => den.choresOn(date).firstWhere((c) => c.chore.id == chore);

  group('rotations', () {
    test('weekly rotations turn at the family\'s week start', () async {
      final dishes = await den.addChore(
        title: 'Dishes',
        owner: OwnerRotation([maya, leo, zoe], 'week', '2026-10-14'),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      );
      expect(on('2026-10-14', dishes).owner, maya);
      expect(on('2026-10-17', dishes).owner, maya, reason: 'Saturday is still the anchor week');
      expect(on('2026-10-18', dishes).owner, leo, reason: 'Sunday starts a new week');
      expect(on('2026-10-25', dishes).owner, zoe);
      expect(on('2026-11-01', dishes).owner, maya);
      expect(on('2026-10-11', dishes).owner, maya, reason: 'same week as the anchor');
      expect(on('2026-10-10', dishes).owner, zoe, reason: 'the week before wraps around');
      await den.updateFamily({'weekStart': 1});
      expect(on('2026-10-18', dishes).owner, maya, reason: 'with Monday weeks, Sunday is still the anchor week');
      expect(on('2026-10-19', dishes).owner, leo);
    });

    test('daily rotations turn every day', () async {
      final trash = await den.addChore(
        title: 'Trash',
        owner: OwnerRotation([maya, leo], 'day', '2026-10-14'),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-14'),
      );
      expect([for (final d in ['2026-10-14', '2026-10-15', '2026-10-16']) on(d, trash).owner], [maya, leo, maya]);
    });
  });

  test('schedules: weekly days, once, and inactive chores', () async {
    final trash = await den.addChore(
      title: 'Take out the trash',
      owner: OwnerMember(maya),
      schedule: const ChoreSchedule.repeating('FREQ=WEEKLY;BYDAY=TH', '2026-10-01'),
    );
    expect(den.choresOn('2026-10-15').map((c) => c.chore.id), [trash]);
    expect(den.choresOn('2026-10-14'), isEmpty);
    expect(den.choresOn('2026-09-24'), isEmpty, reason: 'before the schedule starts');
    await den.updateChore(trash, {'active': false});
    expect(den.choresOn('2026-10-15'), isEmpty);
  });

  test('a one-day swap changes the owner, and points follow it', () async {
    final cat = await den.addChore(
      title: 'Feed the cat',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      points: 2,
    );
    await den.swapForDay(cat, '2026-10-14', maya);
    expect(on('2026-10-14', cat).owner, maya);
    expect(on('2026-10-15', cat).owner, leo);
    await den.setChoreDone(cat, '2026-10-14', true);
    expect(den.points().totals[maya], 2);
    expect(den.points().totals[leo], 0);
    await den.swapForDay(cat, '2026-10-15', null);
    expect(on('2026-10-15', cat).owner, isNull);
    clock.set(DateTime.fromMillisecondsSinceEpoch(wallToUtc(zone, DateTime.utc(2026, 10, 15, 9)), isUtc: true));
    expect(den.today().gaps.map((g) => g.message), ['Feed the cat is up for grabs']);
  });

  test('a chore\'s completions by date range, and whether a day was swapped', () async {
    final cat = await den.addChore(
      title: 'Feed the cat',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
    );
    for (final d in ['2026-10-10', '2026-10-12', '2026-10-13']) {
      await den.setChoreDone(cat, d, true);
    }
    await den.swapForDay(cat, '2026-10-11', maya);
    expect(den.completionsFor(cat).map((c) => c.date), ['2026-10-10', '2026-10-11', '2026-10-12', '2026-10-13']);
    expect(den.completionsFor(cat, from: '2026-10-11', to: '2026-10-12').map((c) => c.date), ['2026-10-11', '2026-10-12']);
    expect(den.completionsFor('nosuchchoreabcd'), isEmpty);
    expect(on('2026-10-11', cat).swapped, isTrue);
    expect(on('2026-10-11', cat).owner, maya);
    expect(on('2026-10-12', cat).swapped, isFalse);
  });

  test('steps carry a pictogram for people who can\'t read yet', () async {
    final kitchen = await den.addChore(
      title: 'Clean the kitchen',
      owner: OwnerMember(zoe),
      schedule: const ChoreSchedule.once('2026-10-14'),
      steps: const [
        ChoreStep(id: 'sweep', text: 'Sweep', icon: 'broom'),
        ChoreStep(id: 'wipe', text: 'Wipe the table'),
      ],
    );
    final steps = den.chore(kitchen)!.steps;
    expect(steps.map((s) => s.icon), ['broom', null]);
    expect(steps.first.toJson(), containsPair('icon', 'broom'));
    expect(steps.last.toJson().containsKey('icon'), isFalse);
    await expectLater(
      den.updateChore(kitchen, {
        'steps': [
          {'id': 'x', 'text': 'Long', 'icon': 'i' * 41},
        ],
      }),
      throwsA(isA<InvalidInput>()),
    );
  });

  test('anyone chores credit whoever did them', () async {
    final mail = await den.addChore(
      title: 'Bring in the mail',
      owner: const OwnerAnyone(),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      points: 1,
    );
    final tablet = await joinDevice(den, clock, member: zoe);
    await tablet.setChoreDone(mail, '2026-10-14', true);
    await sync(tablet, den);
    expect(on('2026-10-14', mail).doneBy, zoe);
    expect(den.points().totals[zoe], 1);
    expect(den.today().gaps, isEmpty);
  });

  test('one-off chores carry over, late, until they\'re done', () async {
    final books = await den.addChore(
      title: 'Return library books',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.once('2026-10-12'),
    );
    expect(den.choresOn('2026-10-11'), isEmpty);
    expect(on('2026-10-12', books).late, isTrue);
    final carried = on('2026-10-14', books);
    expect(carried.date, '2026-10-12');
    expect(carried.late, isTrue);
    await den.setChoreDone(books, '2026-10-12', true);
    expect(den.choresOn('2026-10-14'), isEmpty);
    expect(on('2026-10-12', books).done, isTrue);
  });

  test('late after the due time in the family\'s zone, or on any earlier day', () async {
    final bed = await den.addChore(
      title: 'Make bed',
      owner: OwnerMember(zoe),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      dueTime: '09:00',
    );
    final dinner = await den.addChore(
      title: 'Set the table',
      owner: OwnerMember(zoe),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      dueTime: '18:00',
    );
    expect(on('2026-10-14', bed).late, isTrue, reason: 'it is 10 AM in Chicago');
    expect(on('2026-10-14', dinner).late, isFalse);
    expect(on('2026-10-13', dinner).late, isTrue);
    expect(on('2026-10-15', bed).late, isFalse);
    await den.setChoreDone(bed, '2026-10-14', true);
    expect(on('2026-10-14', bed).late, isFalse);
  });

  group('steps', () {
    late String dishes;

    setUp(() async {
      dishes = await den.addChore(
        title: 'Dishes',
        owner: OwnerMember(maya),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
        points: 2,
        steps: [
          const ChoreStep(id: 'clear', text: 'Clear the table'),
          const ChoreStep(id: 'load', text: 'Load the dishwasher', points: 1),
          ChoreStep(id: 'wipe', text: 'Wipe the counters', owner: leo, points: 1),
        ],
      );
    });

    test('checking the last step completes the chore; unchecking one reopens it', () async {
      final parentId = den.actor!.id;
      await den.setStep(dishes, '2026-10-14', 'clear', true);
      await den.setStep(dishes, '2026-10-14', 'load', true);
      expect(on('2026-10-14', dishes).done, isFalse);
      expect(on('2026-10-14', dishes).stepsDone, 2);
      await den.setStep(dishes, '2026-10-14', 'wipe', true);
      final done = on('2026-10-14', dishes);
      expect(done.done, isTrue);
      expect(done.doneBy, parentId);
      await den.setStep(dishes, '2026-10-14', 'load', false);
      final reopened = on('2026-10-14', dishes);
      expect(reopened.done, isFalse);
      expect(reopened.steps, {'clear': parentId, 'load': null, 'wipe': parentId});
      expect(den.history().first.verb, 'reopened');
    });

    test('marking done checks every step, keeping who checked; not done clears them', () async {
      final tablet = await joinDevice(den, clock, member: leo);
      await tablet.setStep(dishes, '2026-10-14', 'wipe', true);
      await sync(tablet, den);
      await den.setChoreDone(dishes, '2026-10-14', true);
      final done = on('2026-10-14', dishes);
      expect(done.steps['wipe'], leo);
      expect(done.steps['clear'], den.actor!.id);
      expect(done.stepsDone, 3);
      final points = den.points();
      expect(points.totals[maya], 2, reason: 'the chore\'s points go to the day\'s owner');
      expect(points.totals[leo], 1, reason: 'his step\'s points go to him');
      expect(points.totals[den.actor!.id], 1, reason: 'an unowned step goes to whoever checked it');
      await den.setChoreDone(dishes, '2026-10-14', false);
      expect(on('2026-10-14', dishes).stepsDone, 0);
      expect(den.points().totals.values.every((v) => v == 0), isTrue, reason: 'undoing undoes the points');
    });

    test('steps carry a count and points available', () {
      final day = on('2026-10-14', dishes);
      expect(day.stepCount, 3);
      expect(day.pointsAvailable, 4);
    });
  });
}
