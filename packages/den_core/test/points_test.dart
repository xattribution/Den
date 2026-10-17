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
        completes,
        reason: 'pending requests don\'t spend points yet',
      );
    });
  });
}
