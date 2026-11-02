import 'package:den_core/den_core.dart';
import 'package:intl/intl.dart';

import '../../../app/format.dart';

/// "This month", "This week", "Week of Oct 12", "Since Oct 1", "Oct 1 to Oct 31".
String windowWords(GoalStanding g, String today, Formats f) {
  final start = g.windowStart;
  final end = g.windowEnd;
  final holdsToday = start.compareTo(today) <= 0 && (end == null || today.compareTo(end) < 0);
  String md(String d) => DateFormat('MMM d').format(f.dateTime(d));
  switch (g.goal.repeat) {
    case GoalRepeat.weekly:
      return holdsToday ? 'This week' : 'Week of ${md(start)}';
    case GoalRepeat.monthly:
      return holdsToday ? 'This month' : f.month(start);
    case GoalRepeat.none:
      if (end == null) return 'Since ${md(start)}';
      return '${md(start)} to ${md(f.addDays(end, -1))}';
  }
}

/// "+2", "−10" with a true minus sign.
String deltaWords(int delta) => delta >= 0 ? '+$delta' : '−${-delta}';

/// The goal [member] is working toward now: the first one running today that counts them.
(GoalStanding, Standing)? currentGoal(PointsSummary points, String member, String today) {
  for (final g in points.goals) {
    final runs = g.windowStart.compareTo(today) <= 0 && (g.windowEnd == null || today.compareTo(g.windowEnd!) < 0);
    if (!runs) continue;
    final s = g.standings.where((s) => s.member == member).firstOrNull;
    if (s != null) return (g, s);
  }
  return null;
}

/// How far [s] is toward [g]'s target, 0 to 1.
double goalFraction(GoalStanding g, Standing s) => (s.earned / (g.goal.target < 1 ? 1 : g.goal.target)).clamp(0.0, 1.0);

/// Under a person's goal bar: "36 more for Movie night pick this month", "Reached Movie night
/// pick this week", "14 more for Saturday breakfast by Sunday".
String goalLine(GoalStanding g, Standing s, String today, Formats f) {
  final target = g.goal.target < 1 ? 1 : g.goal.target;
  final left = target - s.earned;
  final when = switch (windowWords(g, today, f)) {
    'This week' => 'this week',
    'This month' => 'this month',
    _ => g.windowEnd == null ? '' : 'by ${DateFormat('EEEE').format(f.dateTime(f.addDays(g.windowEnd!, -1)))}',
  };
  final tail = when.isEmpty ? '' : ' $when';
  return left <= 0 ? 'Reached ${g.goal.title}$tail' : '$left more for ${g.goal.title}$tail';
}
