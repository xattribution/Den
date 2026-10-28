/// What the calendar's blocks and headings say: who an event is for, until when, a day's name.
/// Plain Dart, so the words can be checked without a screen.
library;

import 'package:den_core/den_core.dart';
import 'package:intl/intl.dart';

import '../../../app/format.dart';
import '../../../design/words.dart';
import 'calendar_time.dart';
import 'recurrence.dart';

/// `tidy` for a title or detail that may sit in a narrow block at large text: units stay
/// together, and the last two words join only when there are at least three and the pair is
/// short, so the join never leaves one long unbreakable piece that would split mid-word.
String tidyLine(String text) {
  final units = keepUnits(text);
  final trimmed = units.trimRight();
  final words = trimmed.split(' ');
  if (words.length < 3 || trimmed.length >= 60) return units;
  final pair = '${words[words.length - 2]} ${words.last}';
  if (pair.length > 14) return units;
  return '${words.sublist(0, words.length - 2).join(' ')} ${words[words.length - 2]}$nbsp${words.last}';
}

/// "Leo", "Leo and Mia", "Leo, Mia and Zoe".
String joinNames(List<String> names) => switch (names.length) {
  0 => '',
  1 => names.single,
  2 => '${names.first} and ${names.last}',
  _ => '${names.take(names.length - 1).join(', ')} and ${names.last}',
};

/// Who an event is for: "Everyone", or the names.
String whoLine(List<Member> people, {required bool everyone}) =>
    everyone || people.isEmpty ? 'Everyone' : joinNames([for (final m in people) m.name]);

/// The heading over a day's events: "Today, Wednesday", "Tomorrow, Thursday",
/// "Friday, October 30", with the year when it isn't this year's.
String dayHeading(Formats f, String date, String today) {
  final weekday = DateFormat('EEEE').format(f.dateTime(date));
  if (date == today) return 'Today, $weekday';
  if (date == f.addDays(today, 1)) return 'Tomorrow, $weekday';
  if (date == f.addDays(today, -1)) return 'Yesterday, $weekday';
  return f.longWithYear(date, relativeTo: today);
}

/// A day's full name: "Wednesday".
String weekdayLong(Formats f, String date) => DateFormat('EEEE').format(f.dateTime(date));

/// The time a block shows in its time column on [date], or null for one that is all day there:
/// "3:30 PM", or "Until 11:00 AM" on the last day of something that started earlier.
String? blockTime(Formats f, Occurrence occ, String date) {
  final first = f.localDate(occ.start);
  final last = f.lastDate(occ.start, occ.end);
  if (occ.allDay) return null;
  if (first == last || date == first) return f.time(occ.start);
  if (date == last) return 'Until ${f.time(occ.end)}';
  return null;
}

/// The second line of a block: who, and until when ("Leo, until 5:00 PM"), or which day of a
/// longer one it is ("Everyone, day 2 of 3").
String blockDetail(Formats f, Occurrence occ, String date, String who) {
  final first = f.localDate(occ.start);
  final last = f.lastDate(occ.start, occ.end);
  if (first != last) return '$who, day ${f.daysFrom(first, date) + 1} of ${f.daysFrom(first, last) + 1}';
  if (occ.allDay) return '$who, all day';
  if (occ.end <= occ.start) return who;
  return '$who, until ${f.time(occ.end)}';
}

/// A dense week cell's time: "3:30" (the hour is enough there; the event's page says the rest).
String cellTime(Formats f, int ms) => DateFormat('h:mm').format(f.at(ms));

/// Events that happen at the same time, combined into one line: "Soccer and Piano lesson".
String combinedTitle(List<String> titles) => joinNames([for (final t in titles) t.split(',').first.trim()]);

/// The week's title on iPad: "Oct 25 to 31", or "Oct 29 to Nov 4" across months.
String weekTitle(Formats f, String start, String today) {
  final end = f.addDays(start, 6);
  final a = f.dateTime(start);
  final b = f.dateTime(end);
  final year = a.year != int.parse(today.substring(0, 4)) ? ', ${a.year}' : '';
  final from = DateFormat('MMM d').format(a);
  final to = a.month == b.month ? '${b.day}' : DateFormat('MMM d').format(b);
  return '$from to $to$year';
}

/// The month as a title: "October", with the year when it isn't this year's.
String monthTitle(Formats f, String date, String today) {
  final d = f.dateTime(date);
  return d.year == int.parse(today.substring(0, 4)) ? DateFormat('MMMM').format(d) : DateFormat('MMMM y').format(d);
}

/// What the scope question asks about a repeating event: "Change just this Wednesday, or every
/// Wednesday?" for a weekly one on one day, otherwise "Change just this one, or all of them?".
/// Returns the question and the label of the "all" answer.
(String, String) scopeQuestion(Formats f, Occurrence occ, {String verb = 'Change'}) {
  final rule = occ.event.rrule ?? '';
  final weekly = rule.contains('FREQ=WEEKLY') && !rule.contains('INTERVAL=');
  final day = weekdayLong(f, f.localDate(occ.start));
  if (weekly && (!rule.contains('BYDAY=') || !RegExp(r'BYDAY=[^;]*,').hasMatch(rule))) {
    return ('$verb just this $day, or every $day?', 'Every $day');
  }
  if (weekly) {
    // "Every Tuesday and Thursday": the question names it; the button stays short.
    final every = describeRrule(rule, f, startDate: f.localDate(occ.event.start), weekStart: 0);
    if (every != null && every.startsWith('Every ')) {
      return ('$verb just this $day, or e${every.substring(1)}?', 'All of them');
    }
  }
  return ('$verb just this one, or all of them?', 'All of them');
}
