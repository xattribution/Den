import 'package:den_actions/times.dart';
import 'package:den_core/den_core.dart';

import 'parse.dart';

/// One occurrence of a parsed calendar.
class IcsOccurrence {
  /// Creates an occurrence.
  const IcsOccurrence(this.uid, this.start, this.end, this.title, this.allDay);

  /// The series' UID.
  final String uid;

  /// Start (UTC ms).
  final int start;

  /// End (UTC ms).
  final int end;

  /// Title.
  final String title;

  /// Whether it is all-day.
  final bool allDay;

  @override
  String toString() => '$uid $start-$end $title';
}

/// A series and its per-occurrence overrides, grouped by UID.
class IcsSeries {
  /// Creates a series.
  IcsSeries(this.master);

  /// The VEVENT without RECURRENCE-ID.
  final IcsEvent master;

  /// Overrides by original start (UTC ms).
  final Map<int, IcsEvent> overrides = {};

  /// The RRULE when Den can repeat it, else null.
  String? get rule {
    final r = master.rrule;
    if (r == null) return null;
    final text = r.toUpperCase().startsWith('RRULE:') ? r.substring(6) : r;
    return RecurrenceRule.isValid(text) ? text : null;
  }

  /// Original starts of the series (UTC ms) from [notBefore], expanded as wall-clock times in
  /// the start's zone; just the start when it doesn't repeat (or Den can't repeat its rule).
  Iterable<int> starts({int? notBefore}) sync* {
    final s = master.start!;
    final r = rule;
    if (r == null) {
      if (notBefore == null || s.utc >= notBefore) yield s.utc;
      return;
    }
    final parsed = RecurrenceRule.parse(r);
    final from = notBefore == null ? null : wallOf(s.zone, notBefore).subtract(const Duration(days: 2));
    for (final wall in parsed.expand(s.wall, from: from, toUtc: (w) => utcOfWall(s.zone, w))) {
      final utc = utcOfWall(s.zone, wall);
      if (notBefore != null && utc < notBefore) continue;
      yield utc;
    }
  }

  /// Original starts the EXDATEs cancel.
  Set<int> get excluded => {for (final x in master.exdates) x.utc};
}

/// Groups [calendar]'s events by UID, attaching RECURRENCE-ID overrides to their series.
/// Overrides without a series are dropped.
Map<String, IcsSeries> groupSeries(IcsCalendar calendar) {
  final out = <String, IcsSeries>{};
  for (final e in calendar.events) {
    if (e.recurrenceId == null) out.putIfAbsent(e.uid, () => IcsSeries(e));
  }
  for (final e in calendar.events) {
    final id = e.recurrenceId;
    if (id != null) out[e.uid]?.overrides[id.utc] = e;
  }
  return out;
}

/// Occurrences of [calendar] overlapping [from, to), with EXDATEs, cancellations and overrides
/// applied, by start.
List<IcsOccurrence> expandCalendar(IcsCalendar calendar, int from, int to) {
  final out = <IcsOccurrence>[];
  for (final series in groupSeries(calendar).values) {
    final m = series.master;
    if (m.cancelled) continue;
    final length = m.endUtc - m.start!.utc;
    final excluded = series.excluded;
    for (final s in series.starts(notBefore: from - length - 86400000)) {
      if (s >= to + 86400000 * 400) break;
      if (excluded.contains(s)) continue;
      final o = series.overrides[s];
      if (o != null && o.cancelled) continue;
      final start = o?.start?.utc ?? s;
      final end = o == null ? s + length : o.endUtc;
      final overlaps = end > start ? start < to && end > from : start >= from && start < to;
      if (overlaps) out.add(IcsOccurrence(m.uid, start, end, (o?.summary.isNotEmpty ?? false) ? o!.summary : m.summary, m.allDay));
      if (s >= to) break;
    }
  }
  out.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.title.compareTo(b.title));
  return out;
}
