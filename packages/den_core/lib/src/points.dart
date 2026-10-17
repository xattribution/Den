import 'package:collection/collection.dart';

import 'chores.dart';
import 'hlc.dart';
import 'model.dart';
import 'time.dart';
import 'views.dart';

/// Everything points are derived from.
class PointsInput {
  const PointsInput({
    required this.members,
    required this.completions,
    required this.choreFor,
    required this.adjustments,
    required this.redemptions,
    required this.rewards,
    required this.goals,
    required this.zone,
    required this.weekStart,
    required this.today,
  });

  final List<Member> members;
  final List<Completion> completions;

  /// The chore a completion belongs to, looked up in the completion's space, deleted or not.
  final Chore? Function(Completion) choreFor;
  final List<Adjustment> adjustments;
  final List<Redemption> redemptions;
  final List<Reward> rewards;
  final List<Goal> goals;
  final String zone;
  final int weekStart;
  final String today;
}

const Hlc _origin = Hlc(0, 0, '');

/// Every points line: done chores to the day's owner (else whoever did it), checked steps to the
/// step's owner (else whoever checked it), adjustments, and approved rewards as negatives. In the
/// order the changes behind them were made.
List<PointsLine> pointsLines(PointsInput input) {
  final lines = <(Hlc, PointsLine)>[];
  final live = {for (final m in input.members) m.id};
  void add(Hlc at, String member, int delta, String reason, PointsSource source, String ref) => lines.add((
        at,
        PointsLine(member: member, delta: delta, reason: reason, when: at.millis, source: source, ref: ref),
      ));
  for (final completion in input.completions) {
    final chore = input.choreFor(completion);
    if (chore == null) continue;
    final times = completion.rec.fieldTimes;
    final checked = completion.steps;
    Hlc stepTime(String id) => times['steps.$id'] ?? times['steps'] ?? completion.rec.updated;
    if (isDone(chore, completion) && chore.points > 0) {
      final owner = dayOwner(chore, completion.date, completion, input.weekStart) ?? completion.doneBy;
      final at = completion.done
          ? times['done'] ?? completion.rec.updated
          : chore.steps.map((s) => stepTime(s.id)).fold(_origin, (a, b) => a > b ? a : b);
      if (owner != null && live.contains(owner)) {
        add(at, owner, chore.points, chore.title, PointsSource.chore, completion.id);
      }
    }
    for (final step in chore.steps) {
      final by = checked[step.id];
      if (by == null || step.points <= 0) continue;
      final owner = step.owner ?? (by.isEmpty ? null : by);
      if (owner == null || !live.contains(owner)) continue;
      add(stepTime(step.id), owner, step.points, '${chore.title}: ${step.text}', PointsSource.step,
          '${completion.id}#${step.id}');
    }
  }
  for (final a in input.adjustments) {
    add(a.rec.created, a.member, a.delta, a.reason, PointsSource.adjustment, a.id);
  }
  final rewards = {for (final r in input.rewards) r.id: r};
  for (final r in input.redemptions) {
    if (r.status != RedemptionStatus.approved) continue;
    add(r.rec.fieldTimes['status'] ?? r.rec.updated, r.member, -r.cost, rewards[r.reward]?.title ?? 'Reward',
        PointsSource.reward, r.id);
  }
  lines.sort((a, b) {
    final w = a.$1.compareTo(b.$1);
    return w != 0 ? w : (a.$2.ref ?? '').compareTo(b.$2.ref ?? '');
  });
  return [for (final l in lines) l.$2];
}

/// The window a goal measures today: local dates, end exclusive.
(String, String?) goalWindow(Goal goal, String today, int weekStart) {
  final start = isLocalDate(goal.start) ? goal.start : today;
  final end = goal.end != null && isLocalDate(goal.end) ? addDays(goal.end!, 1) : null;
  final anchor = end != null && today.compareTo(end) >= 0 ? addDays(end, -1) : today;
  String clipStart(String s) => s.compareTo(start) < 0 ? start : s;
  String? clipEnd(String e) => end != null && end.compareTo(e) < 0 ? end : e;
  switch (goal.repeat) {
    case GoalRepeat.none:
      return (start, end);
    case GoalRepeat.weekly:
      final ws = startOfWeek(anchor, weekStart);
      return (clipStart(ws), clipEnd(addDays(ws, 7)));
    case GoalRepeat.monthly:
      final ms = startOfMonth(anchor);
      return (clipStart(ms), clipEnd(addMonths(ms, 1)));
  }
}

/// Earned points in the goal's window per member, and when each reached the target and stayed.
GoalStanding goalStanding(Goal goal, List<PointsLine> lines, PointsInput input) {
  final (windowStart, windowEnd) = goalWindow(goal, input.today, input.weekStart);
  final who = goal.members ??
      [for (final m in input.members) if (m.role == Role.kid) m.id];
  final standings = <Standing>[];
  for (final member in who) {
    var total = 0;
    int? reachedAt;
    for (final line in lines) {
      if (line.member != member || line.source == PointsSource.reward) continue;
      final date = dateIn(input.zone, line.when);
      if (date.compareTo(windowStart) < 0) continue;
      if (windowEnd != null && date.compareTo(windowEnd) >= 0) continue;
      final was = total;
      total += line.delta;
      if (was < goal.target && total >= goal.target) reachedAt = line.when;
      if (total < goal.target) reachedAt = null;
    }
    standings.add(Standing(member, total, reachedAt));
  }
  standings.sort((a, b) {
    final e = b.earned.compareTo(a.earned);
    return e != 0 ? e : who.indexOf(a.member).compareTo(who.indexOf(b.member));
  });
  return GoalStanding(goal, windowStart, windowEnd, standings);
}

PointsSummary pointsSummary(PointsInput input) {
  final lines = pointsLines(input);
  final totals = {for (final m in input.members) m.id: 0};
  for (final line in lines) {
    if (totals.containsKey(line.member)) totals[line.member] = totals[line.member]! + line.delta;
  }
  final goals = input.goals.sortedBy((g) => g.title).map((g) => goalStanding(g, lines, input)).toList();
  return PointsSummary(
    totals: totals,
    goals: goals,
    recent: lines.reversed.take(100).toList(),
    rewards: input.rewards.where((r) => r.active).sortedBy<num>((r) => r.cost).toList(),
    pending: input.redemptions
        .where((r) => r.status == RedemptionStatus.requested)
        .sortedBy((r) => r.rec.created)
        .toList(),
  );
}
