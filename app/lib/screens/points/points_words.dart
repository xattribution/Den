import 'package:den_core/den_core.dart';
import 'package:intl/intl.dart';

import '../../state/format.dart';

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

/// Who takes part in a goal: its members, or every kid when it names none.
List<Member> goalPeople(Goal goal, List<Member> members) {
  final ids = goal.members;
  if (ids == null) return members.where((m) => m.isKid).toList();
  return members.where((m) => ids.contains(m.id)).toList();
}
