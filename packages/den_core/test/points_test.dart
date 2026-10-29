import 'package:den_core/den_core.dart';
import 'package:den_core/src/time.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  const zone = 'America/Los_Angeles';
  late TestClock clock;
  late Den den;
  late String maya;
  late String leo;

  void at(int y, int m, int d, int h, [int min = 0]) =>
      clock.now = wallToUtc(zone, DateTime.utc(y, m, d, h, min));

  setUp(() async {
    clock = TestClock(0);
    at(2026, 10, 1, 8);
    den = await foundFamily(clock, timezone: zone);
    maya = await den.addMember(name: 'Maya', role: Role.kid);
    leo = await den.addMember(name: 'Leo', role: Role.kid);
  });

  test('totals are derived from chores, steps, adjustments and approved rewards', () async {
    final chore = await den.addChore(
      title: 'Dishes',
      owner: OwnerMember(maya),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      points: 3,
    );
    await den.setChoreDone(chore, '2026-10-01', true);
    await den.adjustPoints(leo, 10, 'Helped a neighbor');
    await den.adjustPoints(leo, -2, 'Left the bike out');
    final summary = den.points();
    expect(summary.totals[maya], 3);
    expect(summary.totals[leo], 8);
    expect(summary.recent.first.reason, 'Left the bike out');
    expect(summary.recent.first.source, PointsSource.adjustment);
    expect(summary.recent.map((l) => l.source), contains(PointsSource.chore));
    await den.setChoreDone(chore, '2026-10-01', false);
    expect(den.points().totals[maya], 0);
  });

  test('two devices completing the same chore at once award it once', () async {
    final chore = await den.addChore(
      title: 'Feed the cat',
      owner: OwnerMember(leo),
      schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
      points: 1,
    );
    final tablet = await joinDevice(den, clock, member: leo);
    await tablet.setChoreDone(chore, '2026-10-01', true);
    await den.setChoreDone(chore, '2026-10-01', true);
    await exchange(den, tablet);
    expect(den.points().totals[leo], 1);
    expect(tablet.points().totals[leo], 1);
  });

  test('monthly goal windows follow the family\'s zone at month boundaries', () async {
    final goal = await den.addGoal(title: 'Movie night pick', target: 50, repeat: GoalRepeat.monthly, start: '2026-01-01');
    at(2026, 10, 31, 23, 30);
    await den.adjustPoints(maya, 5, 'Late October');
    expect(DateTime.fromMillisecondsSinceEpoch(clock.now, isUtc: true).month, 11, reason: 'already November in UTC');
    at(2026, 11, 1, 0, 30);
    await den.adjustPoints(maya, 7, 'Early November');

    at(2026, 10, 31, 23, 45);
    var standing = den.points().goals.firstWhere((g) => g.goal.id == goal);
    expect(standing.windowStart, '2026-10-01');
    expect(standing.windowEnd, '2026-11-01');
    expect(standing.standings.firstWhere((s) => s.member == maya).earned, 5);

    at(2026, 11, 15, 12);
    standing = den.points().goals.firstWhere((g) => g.goal.id == goal);
    expect(standing.windowStart, '2026-11-01');
    expect(standing.windowEnd, '2026-12-01');
    expect(standing.standings.firstWhere((s) => s.member == maya).earned, 7);
    expect(standing.standings.map((s) => s.member), unorderedEquals([maya, leo]), reason: 'null members means every kid');
  });

  test('weekly goals follow the family\'s week start, and fixed goals their dates', () async {
    final weekly = await den.addGoal(title: 'Week', target: 10, repeat: GoalRepeat.weekly, start: '2026-01-01');
    final fixed = await den.addGoal(title: 'Fall', target: 10, start: '2026-10-05', end: '2026-10-10');
    at(2026, 10, 4, 9);
    await den.adjustPoints(leo, 2, 'Sunday');
    at(2026, 10, 5, 9);
    await den.adjustPoints(leo, 3, 'Monday');
    at(2026, 10, 11, 9);
    await den.adjustPoints(leo, 4, 'Next Sunday');
    at(2026, 10, 7, 9);
    GoalStanding of(String id) => den.points().goals.firstWhere((g) => g.goal.id == id);
    expect(of(weekly).windowStart, '2026-10-04');
    expect(of(weekly).standings.firstWhere((s) => s.member == leo).earned, 5);
    await den.updateFamily({'weekStart': 1});
    expect(of(weekly).windowStart, '2026-10-05');
    expect(of(weekly).standings.firstWhere((s) => s.member == leo).earned, 7, reason: 'Monday 3 and the Sunday after 4');
    expect(of(fixed).windowStart, '2026-10-05');
    expect(of(fixed).windowEnd, '2026-10-11');
    expect(of(fixed).standings.firstWhere((s) => s.member == leo).earned, 3);
  });

  test('a race goes to whoever crossed the target and stayed there first', () async {
    final race = await den.addGoal(title: 'First to 10', target: 10, mode: GoalMode.race, members: [maya, leo], start: '2026-10-01');
    at(2026, 10, 2, 9);
    await den.adjustPoints(maya, 10, 'Big help');
    at(2026, 10, 2, 10);
    expect(den.points().goals.single.winner, maya);
    await den.adjustPoints(maya, -3, 'Oops');
    at(2026, 10, 3, 9);
    await den.adjustPoints(leo, 11, 'Science fair');
    final leoTime = clock.now;
    at(2026, 10, 4, 9);
    await den.adjustPoints(maya, 5, 'Back on track');
    final standing = den.points().goals.firstWhere((g) => g.goal.id == race);
    expect(standing.winner, leo, reason: 'Maya dropped below the line before Leo crossed it');
    expect(standing.standings.firstWhere((s) => s.member == leo).reachedAt, leoTime);
    expect(standing.standings.firstWhere((s) => s.member == maya).reachedAt, clock.now);
    expect(standing.standings.first.member, maya, reason: 'standings sort by points earned');
  });

  group('what a chore is worth', () {
    test('a kid who may edit chores still can\'t set what they\'re worth', () async {
      await den.updateMember(leo, {
        'grants': [Grant.chores],
      });
      final tablet = await joinDevice(den, clock, member: leo);
      await expectLater(
        tablet.addChore(title: 'Free money', owner: OwnerMember(leo), schedule: const ChoreSchedule.once('2026-10-01'), points: 50),
        throwsA(isA<PermissionDenied>()),
      );
      final room = await tablet.addChore(title: 'Tidy my room', owner: OwnerMember(leo), schedule: const ChoreSchedule.once('2026-10-01'));
      await expectLater(tablet.updateChore(room, {'points': 50}), throwsA(isA<PermissionDenied>()));
      await expectLater(
        tablet.updateChore(room, {
          'steps': [const ChoreStep(id: 'bed', text: 'Make the bed', points: 5)],
        }),
        throwsA(isA<PermissionDenied>()),
      );
      await tablet.updateChore(room, {
        'title': 'Tidy my room!',
        'steps': [const ChoreStep(id: 'bed', text: 'Make the bed')],
      });
      await sync(tablet, den);
      await den.updateChore(room, {'points': 2});
      await sync(den, tablet);
      await tablet.updateChore(room, {'title': 'Tidy my room, please'});
      expect(tablet.chore(room)!.points, 2, reason: 'editing the rest keeps the price');

      // Nor can a kid record more than the price on a completion.
      final greedy = await forge(
        tablet.keys,
        counter: 500,
        millis: clock.now + 1000,
        type: RecordType.completion,
        rid: '$room@2026-10-01',
        space: Space.family,
        fields: {'chore': room, 'date': '2026-10-01', 'done': true, 'doneBy': leo, 'points': 99},
        actor: leo,
      );
      final result = await den.ingest([greedy]);
      expect(result.invalid[greedy.id], contains('worth'));
      expect(den.points().totals[leo], 0);
    });

    test('a new price doesn\'t change what was already earned', () async {
      final dishes = await den.addChore(
        title: 'Dishes',
        owner: OwnerMember(maya),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
        points: 2,
        steps: [ChoreStep(id: 'dry', text: 'Dry', owner: leo, points: 1)],
      );
      await den.setChoreDone(dishes, '2026-10-01', true);
      expect(den.points().totals, containsPair(maya, 2));
      expect(den.points().totals, containsPair(leo, 1));
      await den.updateChore(dishes, {
        'points': 10,
        'steps': [ChoreStep(id: 'dry', text: 'Dry', owner: leo, points: 5)],
      });
      expect(den.points().totals[maya], 2, reason: 'done when it was worth 2');
      expect(den.points().totals[leo], 1);
      await den.setChoreDone(dishes, '2026-10-02', true);
      expect(den.points().totals[maya], 12);
      expect(den.points().totals[leo], 6);
      await den.updateChore(dishes, {'points': 0});
      expect(den.points().totals[maya], 12, reason: 'a lower price takes nothing back either');
    });

    test('a completion from before Den kept prices is worth what the chore is worth now', () async {
      final cat = await den.addChore(
        title: 'Feed the cat',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
        points: 1,
      );
      final tablet = await joinDevice(den, clock, member: leo);
      final legacy = await forge(
        tablet.keys,
        counter: 400,
        millis: clock.now + 1000,
        type: RecordType.completion,
        rid: '$cat@2026-10-01',
        fields: {'chore': cat, 'date': '2026-10-01', 'done': true, 'doneBy': leo},
        actor: leo,
      );
      expect((await den.ingest([legacy])).invalid, isEmpty);
      expect(den.points().totals[leo], 1);
      await den.updateChore(cat, {'points': 3});
      expect(den.points().totals[leo], 3);
    });
  });

  group('moving a chore to another space', () {
    test('keeps when its completions were done, so this week\'s goals don\'t fill up', () async {
      final goal = await den.addGoal(title: 'Three a week', target: 3, repeat: GoalRepeat.weekly, start: '2026-01-01');
      final bed = await den.addChore(
        title: 'Make the bed',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
        points: 1,
      );
      at(2026, 10, 8, 18);
      for (final d in ['2026-10-06', '2026-10-07', '2026-10-08']) {
        await den.setChoreDone(bed, d, true);
      }
      int thisWeek() => den.points().goals.firstWhere((g) => g.goal.id == goal).standings.firstWhere((s) => s.member == leo).earned;
      expect(thisWeek(), 3);
      at(2026, 10, 12, 9);
      expect(thisWeek(), 0, reason: 'a new week');
      await den.updateChore(bed, {'audience': Audience.parents});
      expect(den.chore(bed)!.space, Space.parents);
      expect(den.points().totals[leo], 3);
      expect(thisWeek(), 0, reason: 'last week\'s beds still count for last week');

      // Finishing an old day late counts for that day too.
      await den.setChoreDone(bed, '2026-10-09', true);
      expect(thisWeek(), 0);
      await den.setChoreDone(bed, '2026-10-12', true);
      expect(thisWeek(), 1);
    });

    test('a device that hadn\'t heard of the move is paid once', () async {
      final cat = await den.addChore(
        title: 'Feed the cat',
        owner: OwnerMember(leo),
        schedule: const ChoreSchedule.repeating('FREQ=DAILY', '2026-10-01'),
        points: 2,
      );
      final tablet = await joinDevice(den, clock, member: leo);
      // Offline, the tablet checks off the 5th, before a parent moves the chore and checks off
      // the 5th again; then it checks off the 6th on the copy that's gone.
      at(2026, 10, 5, 7);
      await tablet.setChoreDone(cat, '2026-10-05', true);
      at(2026, 10, 5, 8);
      await den.updateChore(cat, {'audience': Audience.parents});
      await den.setChoreDone(cat, '2026-10-05', true);
      at(2026, 10, 6, 7);
      await tablet.setChoreDone(cat, '2026-10-06', true);
      final late = tablet.changesSince(const {}).last;
      final result = await sync(tablet, den);
      expect(result.invalid[late.id], contains('removed'));
      expect(den.points().totals[leo], 2);
      expect(den.points().recent.where((l) => l.source == PointsSource.chore), hasLength(1));
    });
  });

  group('rewards', () {
    late Den tablet;
    late String bedtime;
    late String money;

    setUp(() async {
      bedtime = await den.addReward(title: 'Later bedtime', cost: 20, needsApproval: false);
      money = await den.addReward(title: '\$5', cost: 30);
      await den.adjustPoints(leo, 40, 'Summer reading');
      tablet = await joinDevice(den, clock, member: leo);
    });

    test('rewards that need no approval are approved at once', () async {
      await tablet.requestReward(bedtime);
      await sync(tablet, den);
      expect(den.points().totals[leo], 20);
      expect(den.points().pending, isEmpty);
      expect(den.points().recent.first.source, PointsSource.reward);
    });

    test('others wait for a parent, who approves or declines', () async {
      final request = await tablet.requestReward(money);
      await sync(tablet, den);
      expect(den.points().pending.single.id, request);
      expect(den.points().totals[leo], 40);
      await expectLater(tablet.decideRedemption(request, approve: true), throwsA(isA<PermissionDenied>()));
      await den.decideRedemption(request, approve: false);
      expect(den.points().totals[leo], 40);
      expect(den.history().first.verb, 'declined');
      await sync(den, tablet);
      final second = await tablet.requestReward(money);
      await sync(tablet, den);
      await den.decideRedemption(second, approve: true);
      expect(den.points().totals[leo], 10);
      expect(den.points().pending, isEmpty);
      expect(den.history().first.verb, 'approved');
    });

    test('a request needs enough stars, and kids ask only for themselves', () async {
      await expectLater(
        tablet.requestReward(money, member: maya),
        throwsA(isA<InvalidInput>()),
        reason: 'Maya has no stars',
      );
      await den.adjustPoints(maya, 40, 'Chores');
      await sync(den, tablet);
      await expectLater(tablet.requestReward(money, member: maya), throwsA(isA<PermissionDenied>()));
      await expectLater(
        tablet.requestReward(money),
        completes,
      );
      await expectLater(
        tablet.requestReward(money),
        throwsA(isA<InvalidInput>()),
        reason: 'a request waiting for a parent counts against what Leo can spend',
      );
      await expectLater(tablet.requestReward(bedtime), throwsA(isA<InvalidInput>()));
      expect(tablet.points().available(leo), 10);
      expect(tablet.points().totals[leo], 40);
    });

    test('approving can\'t overdraw a balance, however many requests were made at once', () async {
      final laptop = await joinDevice(den, clock, member: leo, name: 'Leo laptop');
      final first = await tablet.requestReward(money);
      final second = await laptop.requestReward(money);
      await sync(tablet, den);
      await sync(laptop, den);
      expect(den.points().pending.map((r) => r.id), unorderedEquals([first, second]));
      await den.decideRedemption(first, approve: true);
      await expectLater(den.decideRedemption(second, approve: true), throwsA(isA<InvalidInput>()));
      await den.decideRedemption(second, approve: false);
      expect(den.points().totals[leo], 10);
    });

    test('nobody gives themselves points or approves their own reward', () async {
      await den.updateMember(leo, {'grants': [Grant.points]});
      await sync(den, tablet);
      await expectLater(tablet.adjustPoints(leo, 50, 'Because'), throwsA(isA<PermissionDenied>()));
      await tablet.adjustPoints(maya, 2, 'Helped me');
      final request = await tablet.requestReward(money);
      expect(tablet.points().pending.single.id, request, reason: 'a points manager still asks');
      await expectLater(tablet.decideRedemption(request, approve: true), throwsA(isA<PermissionDenied>()));
      await sync(tablet, den);
      await expectLater(den.adjustPoints(den.actor!.id, 5, 'Me'), throwsA(isA<PermissionDenied>()));
      await den.decideRedemption(request, approve: true);
      expect(den.points().totals[leo], 10);
    });

    test('a points manager asking for themselves waits for someone else, even for a reward that needs no asking', () async {
      await den.updateMember(leo, {'grants': [Grant.points]});
      await sync(den, tablet);
      // Leo may change rewards: he makes this one need no asking, and free.
      await tablet.updateReward(money, {'needsApproval': false, 'cost': 0});
      final free = await tablet.requestReward(money);
      await tablet.updateReward(money, {'cost': 30});
      final priced = await tablet.requestReward(money);
      expect(tablet.points().pending.map((r) => r.id), unorderedEquals([free, priced]));
      await expectLater(tablet.decideRedemption(priced, approve: true), throwsA(isA<PermissionDenied>()));
      // Nor can a device of his write one approved at once.
      clock.advance(const Duration(minutes: 1));
      final forged = await forge(
        tablet.keys,
        counter: 900,
        millis: clock.now,
        type: RecordType.redemption,
        rid: 'forgedtreat',
        actor: leo,
        fields: {'reward': money, 'member': leo, 'cost': 30, 'status': 'approved', 'decidedBy': null},
      );
      expect((await den.ingest([forged])).invalid[forged.id], contains('Someone else needs to approve'));
      await sync(tablet, den);
      expect(den.points().totals[leo], 40, reason: 'nothing spent until a parent says yes');
      await den.decideRedemption(priced, approve: true);
      expect(den.points().totals[leo], 10);
      // Anyone else's "no asking" rewards stay granted at once.
      await den.updateMember(leo, {'grants': <Grant>[]});
      await den.updateReward(bedtime, {'cost': 5});
      await sync(den, tablet);
      await tablet.requestReward(bedtime);
      await sync(tablet, den);
      expect(den.points().totals[leo], 5);
    });
  });
}
