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
///
/// A chore or step is worth what the completion recorded when it was done (what the chore was
/// worth then), else what it is worth now. Its line is dated when it was done, but never after
/// the end of the completion's own day: finishing an old chore late, or moving a chore to
/// another space (which writes its completions again), doesn't count toward this week's goals.
/// A chore moved while a device that hadn't heard of it checked it off can have a completion
/// for the same day in both spaces; it is paid once.
List<PointsLine> pointsLines(PointsInput input) {
  final lines = <(Hlc, PointsLine)>[];
  final live = {for (final m in input.members) m.id};
  void add(Hlc at, String member, int delta, String reason, PointsSource source, String ref) => lines.add((
        at,
        PointsLine(member: member, delta: delta, reason: reason, when: at.millis, source: source, ref: ref),
      ));
  final byDay = <String, (Completion, Chore)>{};
  for (final completion in input.completions) {
    final chore = input.choreFor(completion);
    if (chore == null) continue;
    final kept = byDay[completion.id];
    if (kept == null || _preferred(completion, chore, kept.$1, kept.$2)) byDay[completion.id] = (completion, chore);
  }
  for (final (completion, chore) in byDay.values) {
    final times = completion.rec.fieldTimes;
    final checked = completion.steps;
    final dayEnd = isLocalDate(completion.date) ? dayStartIn(input.zone, addDays(completion.date, 1)) - 1 : null;
    Hlc dated(Hlc at) => dayEnd != null && at.millis > dayEnd ? Hlc(dayEnd, at.counter, at.device) : at;
    Hlc stepTime(String id) => times['steps.$id'] ?? times['steps'] ?? completion.rec.updated;
    // The recorded price counts when it was written as (or after) it was done; an older one
    // never pays more than the chore is worth now.
    int worth(int? recorded, Hlc? recordedAt, Hlc doneAt, int now) {
      if (recorded == null) return now;
      if (recordedAt != null && recordedAt.compareTo(doneAt) >= 0) return recorded;
      return recorded < now ? recorded : now;
    }

    if (isDone(chore, completion)) {
      final owner = dayOwner(chore, completion.date, completion, input.weekStart) ?? completion.doneBy;
      final at = completion.done
          ? times['done'] ?? completion.rec.updated
          : chore.steps.map((s) => stepTime(s.id)).fold(_origin, (a, b) => a > b ? a : b);
      final points = worth(completion.points, times['points'], at, chore.points);
      if (points > 0 && owner != null && live.contains(owner)) {
        add(dated(at), owner, points, chore.title, PointsSource.chore, completion.id);
      }
    }
    final stepWorth = completion.stepPoints;
    for (final step in chore.steps) {
      final by = checked[step.id];
      if (by == null) continue;
      final at = stepTime(step.id);
      final points = worth(stepWorth[step.id], times['stepPoints.${step.id}'] ?? times['stepPoints'], at, step.points);
      if (points <= 0) continue;
      final owner = step.owner ?? (by.isEmpty ? null : by);
      if (owner == null || !live.contains(owner)) continue;
      add(dated(at), owner, points, '${chore.title}: ${step.text}', PointsSource.step, '${completion.id}#${step.id}');
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

/// Of two completions for the same chore and day in different spaces (a chore moved while a
/// device that hadn't heard of the move checked it off), the one whose chore is still there,
/// else the one made last.
bool _preferred(Completion a, Chore aChore, Completion b, Chore bChore) {
  if (aChore.rec.deleted != bChore.rec.deleted) return !aChore.rec.deleted;
  final created = a.rec.created.compareTo(b.rec.created);
  if (created != 0) return created > 0;
  return a.space.compareTo(b.space) > 0;
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
