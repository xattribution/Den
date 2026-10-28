import 'package:den_core/den_core.dart';
import 'package:intl/intl.dart';

import '../../../app/format.dart';

/// How a chore repeats, as the editor offers it. Reads and writes the subset of RFC 5545
/// RRULEs the editor produces; anything else is kept as is and described as "Repeats".
enum Repeat { daily, weekdays, days, everyWeeks, monthly, once }

const _codes = {1: 'MO', 2: 'TU', 3: 'WE', 4: 'TH', 5: 'FR', 6: 'SA', 7: 'SU'};
const _dayNames = {1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday', 5: 'Friday', 6: 'Saturday', 7: 'Sunday'};
const _dayShort = {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun'};

class ScheduleSpec {
  ScheduleSpec({
    required this.repeat,
    required this.start,
    Set<int>? days,
    this.interval = 1,
    this.monthDay = 1,
    String? once,
    this.raw,
  }) : days = days ?? <int>{},
       once = once ?? start;

  Repeat repeat;

  /// Local date the schedule starts.
  String start;

  /// `DateTime.weekday` values for [Repeat.days] and [Repeat.everyWeeks].
  Set<int> days;

  /// Weeks between occurrences for [Repeat.everyWeeks], days for a daily rule.
  int interval;
  int monthDay;
  String once;

  /// An RRULE this editor can't express, kept untouched unless the person changes the schedule.
  String? raw;

  static ScheduleSpec fromSchedule(ChoreSchedule s, {required String today}) {
    if (s.once != null) return ScheduleSpec(repeat: Repeat.once, start: s.once!, once: s.once);
    final parts = <String, String>{};
    for (final part in (s.rrule ?? 'FREQ=DAILY').split(';')) {
      final i = part.indexOf('=');
      if (i > 0) parts[part.substring(0, i).toUpperCase()] = part.substring(i + 1).toUpperCase();
    }
    final start = s.start ?? today;
    final interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 1;
    final byDay = (parts['BYDAY'] ?? '')
        .split(',')
        .where((d) => d.isNotEmpty)
        .map((d) => _codes.entries.where((e) => e.value == d).map((e) => e.key).firstOrNull)
        .whereType<int>()
        .toSet();
    final known = {'FREQ', 'INTERVAL', 'BYDAY', 'BYMONTHDAY'};
    final unknown = parts.keys.any((k) => !known.contains(k)) || (parts['BYDAY'] ?? '').contains(RegExp(r'\d'));
    final spec = switch (parts['FREQ']) {
      'DAILY' => ScheduleSpec(repeat: Repeat.daily, start: start, interval: interval),
      'WEEKLY' when byDay.isEmpty => ScheduleSpec(
        repeat: interval > 1 ? Repeat.everyWeeks : Repeat.days,
        start: start,
        days: {_weekdayOf(start)},
        interval: interval,
      ),
      'WEEKLY' when interval > 1 => ScheduleSpec(
        repeat: Repeat.everyWeeks,
        start: start,
        days: byDay,
        interval: interval,
      ),
      'WEEKLY' when byDay.length == 7 => ScheduleSpec(repeat: Repeat.daily, start: start),
      'WEEKLY' when byDay.length == 5 && byDay.containsAll([1, 2, 3, 4, 5]) => ScheduleSpec(
        repeat: Repeat.weekdays,
        start: start,
        days: byDay,
      ),
      'WEEKLY' => ScheduleSpec(repeat: Repeat.days, start: start, days: byDay),
      'MONTHLY' => ScheduleSpec(
        repeat: Repeat.monthly,
        start: start,
        monthDay: int.tryParse(parts['BYMONTHDAY'] ?? '') ?? int.parse(start.substring(8)),
      ),
      _ => ScheduleSpec(repeat: Repeat.daily, start: start, raw: s.rrule),
    };
    if (unknown) spec.raw = s.rrule;
    return spec;
  }

  ChoreSchedule toSchedule() {
    if (repeat == Repeat.once) return ChoreSchedule.once(once);
    if (raw != null) return ChoreSchedule.repeating(raw!, start);
    final sorted = (days.toList()..sort()).map((d) => _codes[d]).join(',');
    final rule = switch (repeat) {
      Repeat.daily => interval > 1 ? 'FREQ=DAILY;INTERVAL=$interval' : 'FREQ=DAILY',
      Repeat.weekdays => 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      Repeat.days => 'FREQ=WEEKLY;BYDAY=$sorted',
      Repeat.everyWeeks => 'FREQ=WEEKLY;INTERVAL=$interval;BYDAY=$sorted',
      Repeat.monthly => 'FREQ=MONTHLY;BYMONTHDAY=$monthDay',
      Repeat.once => '',
    };
    return ChoreSchedule.repeating(rule, start);
  }

  /// "Every day", "Weekdays", "Every Mon, Thu", "Every 2 weeks on Saturday",
  /// "Monthly on the 15th", "Once, on Sat, Oct 24".
  String words(Formats f) {
    if (raw != null) return 'Repeats on a custom schedule';
    return switch (repeat) {
      Repeat.daily => interval > 1 ? 'Every $interval days' : 'Every day',
      Repeat.weekdays => 'Weekdays',
      Repeat.days => _daysWords(days, single: 'Every'),
      Repeat.everyWeeks => 'Every $interval weeks on ${_daysList(days)}',
      Repeat.monthly => 'Monthly on the ${ordinal(monthDay)}',
      Repeat.once => 'Once, on ${f.short(once)}',
    };
  }

  static String _daysWords(Set<int> days, {required String single}) {
    if (days.length == 7) return 'Every day';
    if (days.length == 2 && days.containsAll([6, 7])) return 'Weekends';
    if (days.length == 5 && days.containsAll([1, 2, 3, 4, 5])) return 'Weekdays';
    return '$single ${_daysList(days)}';
  }

  static String _daysList(Set<int> days) {
    final sorted = days.toList()..sort();
    if (sorted.isEmpty) return 'no days';
    if (sorted.length == 1) return _dayNames[sorted.first]!;
    return sorted.map((d) => _dayShort[d]).join(', ');
  }

  static int _weekdayOf(String date) {
    final p = date.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]).weekday;
  }
}

String ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

/// "7:00 PM" from a stored `HH:mm`.
String clockWords(String hhmm) {
  final p = hhmm.split(':');
  final h = int.tryParse(p.first) ?? 0;
  final m = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
  return DateFormat.jm().format(DateTime(2000, 1, 1, h, m));
}

/// Whole days from [a] to [b], both local dates.
int daysBetween(String a, String b) {
  DateTime d(String s) {
    final p = s.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }

  return d(b).difference(d(a)).inDays;
}

/// The local date the week holding [date] starts, given the family's week start (0 Sunday).
String weekStartOf(String date, int weekStart) {
  final p = date.split('-').map(int.parse).toList();
  final d = DateTime.utc(p[0], p[1], p[2]);
  final back = (d.weekday % 7 - weekStart + 7) % 7;
  final s = d.subtract(Duration(days: back));
  return '${s.year.toString().padLeft(4, '0')}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}';
}

/// Who a rotation gives the chore to on [date]: the index into [OwnerRotation.ids]. Matches the
/// engine: days since the anchor, or weeks between the weeks holding the anchor and the date.
int rotationIndex(OwnerRotation r, String date, int weekStart) {
  if (r.ids.isEmpty) return 0;
  final periods = r.every == 'day'
      ? daysBetween(r.anchor, date)
      : daysBetween(weekStartOf(r.anchor, weekStart), weekStartOf(date, weekStart)) ~/ 7;
  return periods % r.ids.length;
}

/// "Rotates weekly: Mia this week, Leo next", "Rotates daily: Mia today, Leo tomorrow, then Ava".
String rotationWords(
  OwnerRotation r,
  String date,
  String today,
  Formats f,
  String Function(String id) name, {
  int weekStart = 0,
}) {
  if (r.ids.isEmpty) return 'Takes turns';
  final i = rotationIndex(r, date, weekStart);
  final order = [for (var k = 0; k < r.ids.length; k++) r.ids[(i + k) % r.ids.length]];
  final weekly = r.every != 'day';
  final String now;
  final String next;
  if (weekly) {
    final week = weekStartOf(date, weekStart);
    final samePeriod = week == weekStartOf(today, weekStart);
    now = samePeriod ? 'this week' : 'the week of ${DateFormat('MMM d').format(f.dateTime(week))}';
    next = samePeriod ? 'next' : 'the week after';
  } else {
    now = date == today ? 'today' : 'on ${f.short(date)}';
    next = date == today ? 'tomorrow' : 'the day after';
  }
  final parts = <String>['${name(order[0])} $now'];
  if (order.length > 1) parts.add('${name(order[1])} $next');
  if (order.length > 2) parts.add('then ${order.skip(2).map(name).join(', ')}');
  return 'Rotates ${weekly ? 'weekly' : 'daily'}: ${parts.join(', ')}';
}

/// Reminder offsets offered for a chore, in minutes before its due time.
const reminderChoices = <int, String>{
  0: 'At due time',
  15: '15 min before',
  30: '30 min before',
  60: '1 hour before',
  120: '2 hours before',
};

String reminderWords(int minutes) =>
    reminderChoices[minutes] ?? (minutes % 60 == 0 ? '${minutes ~/ 60} hours before' : '$minutes min before');
