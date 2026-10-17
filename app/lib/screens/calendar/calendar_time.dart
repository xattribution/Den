import 'package:den_core/den_core.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../state/format.dart';

/// Calendar arithmetic on top of [Formats], always in the family's time zone. Local dates are
/// `YYYY-MM-DD` strings, which sort the same way as the days they name.
extension CalendarTime on Formats {
  /// Minutes past local midnight.
  int minuteOfDay(int ms) {
    final t = at(ms);
    return t.hour * 60 + t.minute;
  }

  /// UTC milliseconds for a local date and minutes past its midnight.
  int msAt(String date, int minutes) {
    final d = dateTime(date);
    return tz.TZDateTime(location, d.year, d.month, d.day, minutes ~/ 60, minutes % 60).millisecondsSinceEpoch;
  }

  /// 0 for Sunday through 6 for Saturday, matching `family.weekStart`.
  int weekdayIndex(String date) => dateTime(date).weekday % 7;

  /// The first day of the week holding [date].
  String weekStartOf(String date, int weekStart) => addDays(date, -((weekdayIndex(date) - weekStart + 7) % 7));

  String firstOfMonth(String date) => '${date.substring(0, 8)}01';

  int daysInMonth(String date) {
    final d = dateTime(date);
    return DateTime.utc(d.year, d.month + 1, 0).day;
  }

  /// The same day [months] months away, clamped to the end of shorter months.
  String addMonths(String date, int months) {
    final d = dateTime(date);
    final first = DateTime.utc(d.year, d.month + months, 1);
    final last = DateTime.utc(first.year, first.month + 1, 0).day;
    return _iso(first.year, first.month, d.day > last ? last : d.day);
  }

  /// The last local date an occurrence touches; ends are exclusive.
  String lastDate(int start, int end) {
    final first = localDate(start);
    if (end <= start) return first;
    final last = localDate(end - 1);
    return last.compareTo(first) < 0 ? first : last;
  }

  /// Every date from [from] to [to], both included.
  List<String> datesBetween(String from, String to) {
    final out = <String>[];
    for (var d = from; d.compareTo(to) <= 0; d = addDays(d, 1)) {
      out.add(d);
      if (out.length > 400) break;
    }
    return out;
  }

  /// Whole days from [from] to [to].
  int daysFrom(String from, String to) {
    final a = DateTime.utc(
      int.parse(from.substring(0, 4)),
      int.parse(from.substring(5, 7)),
      int.parse(from.substring(8)),
    );
    final b = DateTime.utc(int.parse(to.substring(0, 4)), int.parse(to.substring(5, 7)), int.parse(to.substring(8)));
    return b.difference(a).inDays;
  }

  /// "7 AM", "12 PM".
  String hourLabel(int hour) {
    final h = hour % 24;
    final suffix = h < 12 ? 'AM' : 'PM';
    final twelve = h % 12 == 0 ? 12 : h % 12;
    return '$twelve $suffix';
  }

  /// "3:30 PM" for minutes past midnight.
  String clock(int minutes) => DateFormat.jm().format(DateTime(2000, 1, 1, minutes ~/ 60, minutes % 60));

  /// "15:30" for routes and storage.
  String hhmm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  /// Minutes past midnight from "15:30", or null.
  int? parseHhmm(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
    return h * 60 + m;
  }

  /// "Oct 16", with the year when it isn't [thisYear]'s.
  String monthDay(String date, {String? relativeTo}) {
    final d = dateTime(date);
    final year = relativeTo == null ? null : int.parse(relativeTo.substring(0, 4));
    return year == null || year == d.year ? DateFormat('MMM d').format(d) : DateFormat('MMM d, y').format(d);
  }

  /// "Fri, Oct 16", with the year when it isn't [relativeTo]'s.
  String shortWithYear(String date, {required String relativeTo}) {
    final d = dateTime(date);
    return d.year == int.parse(relativeTo.substring(0, 4)) ? short(date) : DateFormat('EEE, MMM d, y').format(d);
  }

  /// "Friday, October 16", with the year when it isn't [relativeTo]'s.
  String longWithYear(String date, {required String relativeTo}) {
    final d = dateTime(date);
    return d.year == int.parse(relativeTo.substring(0, 4)) ? long(date) : DateFormat('EEEE, MMMM d, y').format(d);
  }

  /// "Sun" ... "Sat" for an index 0..6.
  String weekdayName(int index, {bool long = false}) {
    // 2023-01-01 was a Sunday.
    final d = DateTime.utc(2023, 1, 1 + index);
    return DateFormat(long ? 'EEEE' : 'EEE').format(d);
  }

  /// When an occurrence happens, in words: "3:30 PM to 5:00 PM", "All day",
  /// "Fri, Oct 16, 3:30 PM to Sun, Oct 18, 11:00 AM", "Fri, Oct 16 to Sun, Oct 18".
  String occurrenceSpan(Occurrence occ, {required String today}) {
    final first = localDate(occ.start);
    final last = lastDate(occ.start, occ.end);
    if (occ.allDay) {
      return first == last
          ? 'All day'
          : '${shortWithYear(first, relativeTo: today)} to ${shortWithYear(last, relativeTo: today)}';
    }
    if (first == localDate(occ.end) || occ.end <= occ.start) {
      return occ.end <= occ.start ? time(occ.start) : '${time(occ.start)} to ${time(occ.end)}';
    }
    return '${shortWithYear(first, relativeTo: today)}, ${time(occ.start)} to '
        '${shortWithYear(localDate(occ.end), relativeTo: today)}, ${time(occ.end)}';
  }

  static String _iso(int y, int m, int d) =>
      '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
}

/// Occurrences sorted for a day's list: all-day and multi-day first (longest first), then by
/// start time, then by title.
int compareForDay(Occurrence a, Occurrence b, Formats f) {
  final aLong = a.allDay || f.localDate(a.start) != f.lastDate(a.start, a.end);
  final bLong = b.allDay || f.localDate(b.start) != f.lastDate(b.start, b.end);
  if (aLong != bLong) return aLong ? -1 : 1;
  if (aLong) {
    final byLength = (b.end - b.start).compareTo(a.end - a.start);
    if (byLength != 0) return byLength;
  }
  final byStart = a.start.compareTo(b.start);
  if (byStart != 0) return byStart;
  return a.title.compareTo(b.title);
}

/// Groups occurrences by every local date they touch within [from]..[to].
Map<String, List<Occurrence>> occurrencesByDate(
  List<Occurrence> occurrences,
  Formats f, {
  required String from,
  required String to,
}) {
  final out = <String, List<Occurrence>>{};
  for (final occ in occurrences) {
    var first = f.localDate(occ.start);
    var last = f.lastDate(occ.start, occ.end);
    if (first.compareTo(from) < 0) first = from;
    if (last.compareTo(to) > 0) last = to;
    for (var d = first; d.compareTo(last) <= 0; d = f.addDays(d, 1)) {
      out.putIfAbsent(d, () => []).add(occ);
    }
  }
  for (final list in out.values) {
    list.sort((a, b) => compareForDay(a, b, f));
  }
  return out;
}
