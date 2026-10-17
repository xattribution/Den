import 'package:collection/collection.dart';

enum Frequency { daily, weekly, monthly, yearly }

/// A BYDAY entry: an ISO weekday (1 Monday to 7 Sunday) and an optional ordinal such as the 2 in
/// `2TU` (negative counts from the end; 0 means every such weekday).
class WeekdayNum {
  const WeekdayNum(this.weekday, [this.ordinal = 0]);
  final int weekday;
  final int ordinal;

  @override
  bool operator ==(Object other) =>
      other is WeekdayNum && other.weekday == weekday && other.ordinal == ordinal;

  @override
  int get hashCode => Object.hash(weekday, ordinal);

  @override
  String toString() => '${ordinal == 0 ? '' : ordinal}${_dayCodes[weekday - 1]}';
}

const _dayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
const _listEq = ListEquality<Object?>();

/// An RFC 5545 recurrence rule (the RRULE value, without DTSTART). Supports FREQ DAILY, WEEKLY,
/// MONTHLY and YEARLY with INTERVAL, COUNT, UNTIL, BYDAY (with ordinals), BYMONTHDAY, BYMONTH,
/// BYSETPOS and WKST. Expansion happens in wall-clock time; callers convert each occurrence to
/// UTC in the event's own zone.
class RecurrenceRule {
  const RecurrenceRule({
    required this.frequency,
    this.interval = 1,
    this.count,
    this.until,
    this.untilKind = UntilKind.utc,
    this.byDay = const [],
    this.byMonthDay = const [],
    this.byMonth = const [],
    this.bySetPos = const [],
    this.weekStart = DateTime.monday,
  });

  final Frequency frequency;
  final int interval;
  final int? count;

  /// For [UntilKind.utc] an instant (a UTC [DateTime]); otherwise a floating wall-clock time or
  /// date.
  final DateTime? until;
  final UntilKind untilKind;
  final List<WeekdayNum> byDay;
  final List<int> byMonthDay;
  final List<int> byMonth;
  final List<int> bySetPos;
  final int weekStart;

  static final Map<String, RecurrenceRule> _cache = {};

  /// Parses and memoizes; throws [FormatException] for anything unsupported.
  static RecurrenceRule parse(String text) {
    final cached = _cache[text];
    if (cached != null) return cached;
    final rule = _parse(text);
    if (_cache.length > 2000) _cache.clear();
    return _cache[text] = rule;
  }

  static bool isValid(String text) {
    try {
      parse(text);
      return true;
    } on FormatException {
      return false;
    }
  }

  static RecurrenceRule _parse(String text) {
    var s = text.trim();
    if (s.toUpperCase().startsWith('RRULE:')) s = s.substring(6);
    if (s.isEmpty) throw FormatException('Empty rule', text);
    Frequency? freq;
    var interval = 1;
    int? count;
    DateTime? until;
    var untilKind = UntilKind.utc;
    var byDay = <WeekdayNum>[];
    var byMonthDay = <int>[];
    var byMonth = <int>[];
    var bySetPos = <int>[];
    var weekStart = DateTime.monday;
    final seen = <String>{};
    for (final part in s.split(';')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      if (eq <= 0) throw FormatException('Bad rule part', part);
      final key = part.substring(0, eq).toUpperCase();
      final value = part.substring(eq + 1).toUpperCase();
      if (!seen.add(key)) throw FormatException('Repeated rule part', key);
      switch (key) {
        case 'FREQ':
          freq = switch (value) {
            'DAILY' => Frequency.daily,
            'WEEKLY' => Frequency.weekly,
            'MONTHLY' => Frequency.monthly,
            'YEARLY' => Frequency.yearly,
            _ => throw FormatException('Unsupported frequency', value),
          };
        case 'INTERVAL':
          interval = _int(value, 1, 1000);
        case 'COUNT':
          count = _int(value, 1, 100000);
        case 'UNTIL':
          (until, untilKind) = _until(value);
        case 'BYDAY':
          byDay = value.split(',').map(_weekdayNum).toList();
        case 'BYMONTHDAY':
          byMonthDay = value.split(',').map((v) => _nonZero(v, 31)).toList();
        case 'BYMONTH':
          byMonth = value.split(',').map((v) => _int(v, 1, 12)).toList();
        case 'BYSETPOS':
          bySetPos = value.split(',').map((v) => _nonZero(v, 366)).toList();
        case 'WKST':
          weekStart = _weekday(value);
        default:
          throw FormatException('Unsupported rule part', key);
      }
    }
    if (freq == null) throw FormatException('Rule has no FREQ', text);
    if (count != null && until != null) throw FormatException('COUNT and UNTIL together', text);
    return RecurrenceRule(
      frequency: freq,
      interval: interval,
      count: count,
      until: until,
      untilKind: untilKind,
      byDay: byDay,
      byMonthDay: byMonthDay,
      byMonth: byMonth,
      bySetPos: bySetPos,
      weekStart: weekStart,
    );
  }

  static int _int(String v, int min, int max) {
    final n = int.tryParse(v);
    if (n == null || n < min || n > max) throw FormatException('Number out of range', v);
    return n;
  }

  static int _nonZero(String v, int max) {
    final n = int.tryParse(v);
    if (n == null || n == 0 || n.abs() > max) throw FormatException('Number out of range', v);
    return n;
  }

  static int _weekday(String code) {
    final i = _dayCodes.indexOf(code);
    if (i < 0) throw FormatException('Not a weekday', code);
    return i + 1;
  }

  static WeekdayNum _weekdayNum(String v) {
    final m = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$').firstMatch(v);
    if (m == null) throw FormatException('Not a BYDAY value', v);
    final ordinal = m[1] == null ? 0 : int.parse(m[1]!);
    if (m[1] != null && (ordinal == 0 || ordinal.abs() > 53)) {
      throw FormatException('BYDAY ordinal out of range', v);
    }
    return WeekdayNum(_weekday(m[2]!), ordinal);
  }

  static (DateTime, UntilKind) _until(String v) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$').firstMatch(v);
    if (m == null) throw FormatException('Not an UNTIL value', v);
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) throw FormatException('Not an UNTIL value', v);
    if (m[4] == null) return (DateTime.utc(y, mo, d), UntilKind.date);
    final h = int.parse(m[4]!), mi = int.parse(m[5]!), sec = int.parse(m[6]!);
    if (h > 23 || mi > 59 || sec > 60) throw FormatException('Not an UNTIL value', v);
    return (DateTime.utc(y, mo, d, h, mi, sec), m[7] == null ? UntilKind.floating : UntilKind.utc);
  }

  RecurrenceRule copyWith({
    Frequency? frequency,
    int? interval,
    int? Function()? count,
    DateTime? Function()? until,
    UntilKind? untilKind,
    List<WeekdayNum>? byDay,
    List<int>? byMonthDay,
    List<int>? byMonth,
    List<int>? bySetPos,
    int? weekStart,
  }) =>
      RecurrenceRule(
        frequency: frequency ?? this.frequency,
        interval: interval ?? this.interval,
        count: count == null ? this.count : count(),
        until: until == null ? this.until : until(),
        untilKind: untilKind ?? this.untilKind,
        byDay: byDay ?? this.byDay,
        byMonthDay: byMonthDay ?? this.byMonthDay,
        byMonth: byMonth ?? this.byMonth,
        bySetPos: bySetPos ?? this.bySetPos,
        weekStart: weekStart ?? this.weekStart,
      );

  /// The same rule ending just before the UTC instant [utcMillis].
  RecurrenceRule endingBefore(int utcMillis) => copyWith(
        count: () => null,
        until: () => DateTime.fromMillisecondsSinceEpoch(utcMillis - 1000, isUtc: true),
        untilKind: UntilKind.utc,
      );

  @override
  String toString() {
    final parts = ['FREQ=${frequency.name.toUpperCase()}'];
    if (interval != 1) parts.add('INTERVAL=$interval');
    if (count != null) parts.add('COUNT=$count');
    if (until != null) parts.add('UNTIL=${_untilText()}');
    if (byMonth.isNotEmpty) parts.add('BYMONTH=${byMonth.join(',')}');
    if (byMonthDay.isNotEmpty) parts.add('BYMONTHDAY=${byMonthDay.join(',')}');
    if (byDay.isNotEmpty) parts.add('BYDAY=${byDay.join(',')}');
    if (bySetPos.isNotEmpty) parts.add('BYSETPOS=${bySetPos.join(',')}');
    if (weekStart != DateTime.monday) parts.add('WKST=${_dayCodes[weekStart - 1]}');
    return parts.join(';');
  }

  String _untilText() {
    final u = until!;
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}';
    return switch (untilKind) {
      UntilKind.date => date,
      UntilKind.floating => '${date}T${two(u.hour)}${two(u.minute)}${two(u.second)}',
      UntilKind.utc => '${date}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z',
    };
  }

  @override
  bool operator ==(Object other) =>
      other is RecurrenceRule &&
      other.frequency == frequency &&
      other.interval == interval &&
      other.count == count &&
      other.until == until &&
      (until == null || other.untilKind == untilKind) &&
      _listEq.equals(other.byDay, byDay) &&
      _listEq.equals(other.byMonthDay, byMonthDay) &&
      _listEq.equals(other.byMonth, byMonth) &&
      _listEq.equals(other.bySetPos, bySetPos) &&
      other.weekStart == weekStart;

  @override
  int get hashCode => Object.hash(frequency, interval, count, until, Object.hashAll(byDay),
      Object.hashAll(byMonthDay), Object.hashAll(byMonth), Object.hashAll(bySetPos), weekStart);

  /// Wall-clock occurrences starting at or after [start] (the series' first wall-clock time), in
  /// order. [from] lets an open-ended rule skip whole periods before it; occurrences before it
  /// may still be produced. [toUtc] converts a wall time to UTC for a UTC-form UNTIL.
  Iterable<DateTime> expand(DateTime start, {DateTime? from, int Function(DateTime wall)? toUtc}) sync* {
    var period = 0;
    if (count == null && from != null && from.isAfter(start)) period = _periodsBefore(start, from);
    final timeOfDay = Duration(
      hours: start.hour,
      minutes: start.minute,
      seconds: start.second,
      milliseconds: start.millisecond,
    );
    var produced = 0;
    var barren = 0;
    while (true) {
      final days = _candidates(start, period++);
      if (days == null) return;
      if (days.isEmpty) {
        if (++barren > 3000) return;
        continue;
      }
      barren = 0;
      for (final day in days) {
        final occurrence = day.add(timeOfDay);
        if (occurrence.isBefore(start)) continue;
        if (_pastUntil(occurrence, toUtc)) return;
        yield occurrence;
        if (count != null && ++produced >= count!) return;
      }
    }
  }

  bool _pastUntil(DateTime occurrence, int Function(DateTime)? toUtc) {
    final u = until;
    if (u == null) return false;
    return switch (untilKind) {
      UntilKind.date => DateTime.utc(occurrence.year, occurrence.month, occurrence.day).isAfter(u),
      UntilKind.floating => occurrence.isAfter(u),
      UntilKind.utc => (toUtc?.call(occurrence) ?? occurrence.millisecondsSinceEpoch) >
          u.millisecondsSinceEpoch,
    };
  }

  int _periodsBefore(DateTime start, DateTime from) {
    final int periods;
    switch (frequency) {
      case Frequency.daily:
        periods = _dayNumber(from) - _dayNumber(start);
      case Frequency.weekly:
        periods = (_dayNumber(_weekStartOf(from)) - _dayNumber(_weekStartOf(start))) ~/ 7;
      case Frequency.monthly:
        periods = (from.year - start.year) * 12 + from.month - start.month;
      case Frequency.yearly:
        periods = from.year - start.year;
    }
    return periods ~/ interval - 1 < 0 ? 0 : periods ~/ interval - 1;
  }

  static int _dayNumber(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  DateTime _weekStartOf(DateTime d) {
    final back = (d.weekday - weekStart) % 7;
    return DateTime.utc(d.year, d.month, d.day - back);
  }

  /// Candidate days (midnight, floating) of one period, sorted, after BYSETPOS; null when the
  /// period lies beyond year 9999.
  List<DateTime>? _candidates(DateTime start, int period) {
    List<DateTime> days;
    switch (frequency) {
      case Frequency.daily:
        final d = DateTime.utc(start.year, start.month, start.day + period * interval);
        if (d.year > 9999) return null;
        days = _dailyMatch(d) ? [d] : const [];
      case Frequency.weekly:
        final first = _weekStartOf(start);
        final ws = DateTime.utc(first.year, first.month, first.day + period * interval * 7);
        if (ws.year > 9999) return null;
        final weekdays = byDay.isEmpty ? {start.weekday} : byDay.map((w) => w.weekday).toSet();
        days = [
          for (var i = 0; i < 7; i++)
            if (weekdays.contains(DateTime.utc(ws.year, ws.month, ws.day + i).weekday) &&
                (byMonth.isEmpty || byMonth.contains(DateTime.utc(ws.year, ws.month, ws.day + i).month)))
              DateTime.utc(ws.year, ws.month, ws.day + i),
        ];
      case Frequency.monthly:
        final m = DateTime.utc(start.year, start.month + period * interval, 1);
        if (m.year > 9999) return null;
        days = byMonth.isNotEmpty && !byMonth.contains(m.month)
            ? const []
            : _monthDays(m.year, m.month, start.day);
      case Frequency.yearly:
        final y = start.year + period * interval;
        if (y > 9999) return null;
        if (byDay.isNotEmpty && byMonth.isEmpty && byMonthDay.isEmpty) {
          days = _yearWeekdays(y);
        } else {
          final months = byMonth.isNotEmpty
              ? (List.of(byMonth)..sort())
              : (byMonthDay.isNotEmpty || byDay.isNotEmpty)
                  ? [for (var i = 1; i <= 12; i++) i]
                  : [start.month];
          days = [for (final month in months) ..._monthDays(y, month, start.day)];
        }
    }
    if (bySetPos.isEmpty || days.isEmpty) return days;
    final picked = <DateTime>{};
    for (final pos in bySetPos) {
      final i = pos > 0 ? pos - 1 : days.length + pos;
      if (i >= 0 && i < days.length) picked.add(days[i]);
    }
    return picked.toList()..sort();
  }

  bool _dailyMatch(DateTime d) {
    if (byMonth.isNotEmpty && !byMonth.contains(d.month)) return false;
    if (byMonthDay.isNotEmpty) {
      final last = DateTime.utc(d.year, d.month + 1, 0).day;
      if (!byMonthDay.any((n) => n > 0 ? n == d.day : last + n + 1 == d.day)) return false;
    }
    if (byDay.isNotEmpty && !byDay.any((w) => w.weekday == d.weekday)) return false;
    return true;
  }

  List<DateTime> _monthDays(int year, int month, int defaultDay) {
    final last = DateTime.utc(year, month + 1, 0).day;
    Set<int> days;
    if (byMonthDay.isNotEmpty) {
      days = {
        for (final n in byMonthDay)
          if (n > 0 && n <= last) n else if (n < 0 && -n <= last) last + n + 1,
      };
      if (byDay.isNotEmpty) days = days.intersection(_byDayInMonth(year, month, last));
    } else if (byDay.isNotEmpty) {
      days = _byDayInMonth(year, month, last);
    } else {
      days = defaultDay <= last ? {defaultDay} : {};
    }
    return [for (final d in days.toList()..sort()) DateTime.utc(year, month, d)];
  }

  Set<int> _byDayInMonth(int year, int month, int last) {
    final out = <int>{};
    for (final w in byDay) {
      final matching = [
        for (var d = 1; d <= last; d++)
          if (DateTime.utc(year, month, d).weekday == w.weekday) d,
      ];
      if (w.ordinal == 0) {
        out.addAll(matching);
      } else if (w.ordinal > 0 && w.ordinal <= matching.length) {
        out.add(matching[w.ordinal - 1]);
      } else if (w.ordinal < 0 && -w.ordinal <= matching.length) {
        out.add(matching[matching.length + w.ordinal]);
      }
    }
    return out;
  }

  List<DateTime> _yearWeekdays(int year) {
    final out = <DateTime>{};
    final length = DateTime.utc(year + 1, 1, 1).difference(DateTime.utc(year, 1, 1)).inDays;
    for (final w in byDay) {
      final matching = [
        for (var i = 0; i < length; i++)
          if (DateTime.utc(year, 1, 1 + i).weekday == w.weekday) DateTime.utc(year, 1, 1 + i),
      ];
      if (w.ordinal == 0) {
        out.addAll(matching);
      } else if (w.ordinal > 0 && w.ordinal <= matching.length) {
        out.add(matching[w.ordinal - 1]);
      } else if (w.ordinal < 0 && -w.ordinal <= matching.length) {
        out.add(matching[matching.length + w.ordinal]);
      }
    }
    return out.toList()..sort();
  }
}

/// How an UNTIL value is written: a UTC instant (`...Z`), a floating wall time, or a date.
enum UntilKind { utc, floating, date }
