import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../state/format.dart';
import '../calendar/calendar_time.dart';

enum RepeatFrequency { daily, weekly, monthly, yearly }

/// A monthly rule repeats on a day number ("the 16th") or on a weekday's place in the month
/// ("the third Friday", "the last Friday").
enum MonthlyBy { day, weekday }

/// RFC 5545 weekday codes, indexed 0 = Sunday like `family.weekStart`.
const List<String> weekdayCodes = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

/// A repeat rule Den's editor can show and change without losing anything. Rules it can't
/// express stay as [CustomRule] text and are written back untouched.
class Recurrence {
  const Recurrence({
    required this.frequency,
    this.interval = 1,
    this.weekdays = const {},
    this.monthlyBy = MonthlyBy.day,
    this.monthDay,
    this.ordinal,
    this.ordinalWeekday,
    this.until,
    this.count,
    this.weekStartCode,
  });

  final RepeatFrequency frequency;
  final int interval;

  /// Weekly: the days, 0 = Sunday.
  final Set<int> weekdays;
  final MonthlyBy monthlyBy;

  /// Monthly by day: 1..31.
  final int? monthDay;

  /// Monthly by weekday: 1..5, or -1 for the last.
  final int? ordinal;
  final int? ordinalWeekday;

  /// Last local date it may happen on, inclusive.
  final String? until;

  /// How many times it happens in all.
  final int? count;

  /// WKST as the rule gave it, kept so a rewrite means the same thing.
  final String? weekStartCode;

  /// A sensible rule of [frequency] for an event starting on [startDate].
  factory Recurrence.starting(RepeatFrequency frequency, String startDate, Formats f) {
    final d = f.dateTime(startDate);
    return Recurrence(
      frequency: frequency,
      weekdays: {d.weekday % 7},
      monthDay: d.day,
      ordinal: ordinalFor(startDate, f).first,
      ordinalWeekday: d.weekday % 7,
    );
  }

  Recurrence copyWith({
    RepeatFrequency? frequency,
    int? interval,
    Set<int>? weekdays,
    MonthlyBy? monthlyBy,
    int? monthDay,
    int? ordinal,
    int? ordinalWeekday,
    String? until,
    int? count,
    bool clearEnd = false,
  }) => Recurrence(
    frequency: frequency ?? this.frequency,
    interval: interval ?? this.interval,
    weekdays: weekdays ?? this.weekdays,
    monthlyBy: monthlyBy ?? this.monthlyBy,
    monthDay: monthDay ?? this.monthDay,
    ordinal: ordinal ?? this.ordinal,
    ordinalWeekday: ordinalWeekday ?? this.ordinalWeekday,
    until: clearEnd ? until : (until ?? this.until),
    count: clearEnd ? count : (count ?? this.count),
    weekStartCode: weekStartCode,
  );

  @override
  bool operator ==(Object other) =>
      other is Recurrence &&
      other.frequency == frequency &&
      other.interval == interval &&
      other.weekdays.length == weekdays.length &&
      other.weekdays.containsAll(weekdays) &&
      other.monthlyBy == monthlyBy &&
      other.monthDay == monthDay &&
      other.ordinal == ordinal &&
      other.ordinalWeekday == ordinalWeekday &&
      other.until == until &&
      other.count == count &&
      other.weekStartCode == weekStartCode;

  @override
  int get hashCode => Object.hash(
    frequency,
    interval,
    Object.hashAllUnordered(weekdays),
    monthlyBy,
    monthDay,
    ordinal,
    ordinalWeekday,
    until,
    count,
    weekStartCode,
  );
}

/// The weekday places that describe [date] in its month: its ordinal (1..5) and, in the
/// month's last seven days, -1 ("last").
List<int> ordinalFor(String date, Formats f) {
  final d = f.dateTime(date);
  final days = f.daysInMonth(date);
  return [(d.day - 1) ~/ 7 + 1, if (d.day + 7 > days) -1];
}

/// What a stored rule turned out to be.
sealed class ParsedRule {
  const ParsedRule();
}

class SupportedRule extends ParsedRule {
  const SupportedRule(this.rule);
  final Recurrence rule;
}

/// A rule from another app that Den shows read-only and writes back exactly as it came.
class CustomRule extends ParsedRule {
  const CustomRule(this.raw);
  final String raw;
}

final _until = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$');
final _byday = RegExp(r'^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$');

/// Reads an RRULE (with or without the `RRULE:` prefix) for an event starting on [startDate].
/// Returns null for no rule.
ParsedRule? parseRrule(String? raw, {required String startDate, required Formats f}) {
  if (raw == null || raw.trim().isEmpty) return null;
  final custom = CustomRule(raw);
  var text = raw.trim();
  if (text.toUpperCase().startsWith('RRULE:')) text = text.substring(6);
  final parts = <String, String>{};
  for (final piece in text.split(';')) {
    if (piece.isEmpty) continue;
    final eq = piece.indexOf('=');
    if (eq <= 0) return custom;
    final key = piece.substring(0, eq).toUpperCase();
    if (parts.containsKey(key)) return custom;
    parts[key] = piece.substring(eq + 1).toUpperCase();
  }
  const known = {'FREQ', 'INTERVAL', 'BYDAY', 'BYMONTHDAY', 'BYSETPOS', 'BYMONTH', 'COUNT', 'UNTIL', 'WKST'};
  if (parts.keys.any((k) => !known.contains(k))) return custom;

  final frequency = switch (parts['FREQ']) {
    'DAILY' => RepeatFrequency.daily,
    'WEEKLY' => RepeatFrequency.weekly,
    'MONTHLY' => RepeatFrequency.monthly,
    'YEARLY' => RepeatFrequency.yearly,
    _ => null,
  };
  if (frequency == null) return custom;

  final interval = parts['INTERVAL'] == null ? 1 : int.tryParse(parts['INTERVAL']!);
  if (interval == null || interval < 1) return custom;

  if (parts.containsKey('COUNT') && parts.containsKey('UNTIL')) return custom;
  int? count;
  if (parts.containsKey('COUNT')) {
    count = int.tryParse(parts['COUNT']!);
    if (count == null || count < 1) return custom;
  }
  String? until;
  if (parts.containsKey('UNTIL')) {
    final m = _until.firstMatch(parts['UNTIL']!);
    if (m == null) return custom;
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    if (m[4] != null && m[7] == 'Z') {
      final utc = DateTime.utc(y, mo, d, int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
      until = f.localDate(utc.millisecondsSinceEpoch);
    } else {
      until = DateFormat('yyyy-MM-dd').format(DateTime.utc(y, mo, d));
    }
  }

  final wkst = parts['WKST'];
  if (wkst != null && !weekdayCodes.contains(wkst)) return custom;

  // BYDAY entries as (ordinal or null, weekday index).
  final byday = <(int?, int)>[];
  if (parts['BYDAY'] != null) {
    for (final token in parts['BYDAY']!.split(',')) {
      final m = _byday.firstMatch(token);
      if (m == null) return custom;
      byday.add((m[1] == null ? null : int.parse(m[1]!), weekdayCodes.indexOf(m[2]!)));
    }
  }
  int? single(String key) {
    final value = parts[key];
    if (value == null) return null;
    if (value.contains(',')) return -999;
    return int.tryParse(value) ?? -999;
  }

  final monthDay = single('BYMONTHDAY');
  final setPos = single('BYSETPOS');
  final byMonth = single('BYMONTH');
  final start = f.dateTime(startDate);

  switch (frequency) {
    case RepeatFrequency.daily:
      if (monthDay != null || setPos != null || byMonth != null) return custom;
      if (byday.isEmpty) {
        return SupportedRule(
          Recurrence(frequency: frequency, interval: interval, until: until, count: count, weekStartCode: wkst),
        );
      }
      // "Every day on Mon to Fri" is the same as weekly on those days when it's every day.
      if (interval != 1 || byday.any((b) => b.$1 != null)) return custom;
      return SupportedRule(
        Recurrence(
          frequency: RepeatFrequency.weekly,
          weekdays: {for (final b in byday) b.$2},
          until: until,
          count: count,
          weekStartCode: wkst,
        ),
      );
    case RepeatFrequency.weekly:
      if (monthDay != null || setPos != null || byMonth != null) return custom;
      if (byday.any((b) => b.$1 != null)) return custom;
      return SupportedRule(
        Recurrence(
          frequency: frequency,
          interval: interval,
          weekdays: byday.isEmpty ? {start.weekday % 7} : {for (final b in byday) b.$2},
          until: until,
          count: count,
          weekStartCode: wkst,
        ),
      );
    case RepeatFrequency.monthly:
      if (byMonth != null) return custom;
      if (byday.isEmpty) {
        if (setPos != null) return custom;
        final day = monthDay ?? start.day;
        if (day < 1 || day > 31) return custom;
        return SupportedRule(
          Recurrence(
            frequency: frequency,
            interval: interval,
            monthDay: day,
            until: until,
            count: count,
            weekStartCode: wkst,
          ),
        );
      }
      if (monthDay != null || byday.length != 1) return custom;
      final (ord, weekday) = byday.single;
      final position = ord ?? setPos;
      if (ord != null && setPos != null) return custom;
      if (position == null || !(position == -1 || (position >= 1 && position <= 5))) return custom;
      return SupportedRule(
        Recurrence(
          frequency: frequency,
          interval: interval,
          monthlyBy: MonthlyBy.weekday,
          ordinal: position,
          ordinalWeekday: weekday,
          until: until,
          count: count,
          weekStartCode: wkst,
        ),
      );
    case RepeatFrequency.yearly:
      if (byday.isNotEmpty || setPos != null) return custom;
      if (byMonth != null && byMonth != start.month) return custom;
      if (monthDay != null && monthDay != start.day) return custom;
      return SupportedRule(
        Recurrence(frequency: frequency, interval: interval, until: until, count: count, weekStartCode: wkst),
      );
  }
}

/// Writes [rule] as an RRULE without DTSTART, the form den_core stores. UNTIL is the end of the
/// last day in the family's time zone, in UTC.
String toRrule(Recurrence rule, Formats f) {
  final parts = <String>[
    'FREQ=${rule.frequency.name.toUpperCase()}',
    if (rule.interval > 1) 'INTERVAL=${rule.interval}',
  ];
  switch (rule.frequency) {
    case RepeatFrequency.daily:
    case RepeatFrequency.yearly:
      break;
    case RepeatFrequency.weekly:
      final days = rule.weekdays.toList()..sort((a, b) => ((a + 6) % 7).compareTo((b + 6) % 7));
      if (days.isNotEmpty) parts.add('BYDAY=${days.map((d) => weekdayCodes[d]).join(',')}');
    case RepeatFrequency.monthly:
      if (rule.monthlyBy == MonthlyBy.day) {
        parts.add('BYMONTHDAY=${rule.monthDay ?? 1}');
      } else {
        parts.add('BYDAY=${rule.ordinal ?? 1}${weekdayCodes[rule.ordinalWeekday ?? 0]}');
      }
  }
  if (rule.weekStartCode != null) parts.add('WKST=${rule.weekStartCode}');
  if (rule.count != null) {
    parts.add('COUNT=${rule.count}');
  } else if (rule.until != null) {
    final d = f.dateTime(rule.until!);
    final endOfDay = tz.TZDateTime(f.location, d.year, d.month, d.day, 23, 59, 59).toUtc();
    parts.add('UNTIL=${DateFormat("yyyyMMdd'T'HHmmss'Z'").format(endOfDay)}');
  }
  return parts.join(';');
}

const _ordinalWords = {1: 'first', 2: 'second', 3: 'third', 4: 'fourth', 5: 'fifth', -1: 'last'};

String _nth(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}

/// "Monday, Wednesday, and Friday"
String joinWords(List<String> words) => switch (words.length) {
  0 => '',
  1 => words.single,
  2 => '${words[0]} and ${words[1]}',
  _ => '${words.sublist(0, words.length - 1).join(', ')}, and ${words.last}',
};

/// The rule in words: "Every Tuesday and Thursday until Dec 18", "Every 2 weeks on Monday",
/// "Every month on the third Friday, 10 times".
String describeRecurrence(Recurrence rule, Formats f, {required String startDate, int weekStart = 0}) {
  final n = rule.interval;
  String every(String one, String many) => n == 1 ? 'Every $one' : 'Every $n $many';
  final String base;
  switch (rule.frequency) {
    case RepeatFrequency.daily:
      base = every('day', 'days');
    case RepeatFrequency.weekly:
      final days = rule.weekdays.toList()..sort((a, b) => ((a - weekStart + 7) % 7).compareTo((b - weekStart + 7) % 7));
      final names = days.map((d) => f.weekdayName(d, long: true)).toList();
      final weekdaysOnly = days.length == 5 && !days.contains(0) && !days.contains(6);
      if (n == 1 && days.length == 7) {
        base = 'Every day';
      } else if (n == 1 && weekdaysOnly) {
        base = 'Every weekday';
      } else if (n == 1) {
        base = 'Every ${joinWords(names)}';
      } else {
        base = 'Every $n weeks on ${weekdaysOnly ? 'weekdays' : joinWords(names)}';
      }
    case RepeatFrequency.monthly:
      final on = rule.monthlyBy == MonthlyBy.day
          ? 'the ${_nth(rule.monthDay ?? 1)}'
          : 'the ${_ordinalWords[rule.ordinal ?? 1]} ${f.weekdayName(rule.ordinalWeekday ?? 0, long: true)}';
      base = '${every('month', 'months')} on $on';
    case RepeatFrequency.yearly:
      base = '${every('year', 'years')} on ${DateFormat('MMMM d').format(f.dateTime(startDate))}';
  }
  if (rule.count != null) return '$base, ${rule.count == 1 ? 'once' : '${rule.count} times'}';
  if (rule.until != null) return '$base until ${f.monthDay(rule.until!, relativeTo: startDate)}';
  return base;
}

/// Any stored rule in words, or null when the event doesn't repeat. Rules Den can't express
/// read "Repeats on a custom schedule".
String? describeRrule(String? raw, Formats f, {required String startDate, int weekStart = 0}) {
  final parsed = parseRrule(raw, startDate: startDate, f: f);
  return switch (parsed) {
    null => null,
    SupportedRule(:final rule) => describeRecurrence(rule, f, startDate: startDate, weekStart: weekStart),
    CustomRule() => 'Repeats on a custom schedule',
  };
}
