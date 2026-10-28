import 'model.dart';
import 'rrule.dart';
import 'time.dart';
import 'views.dart';

/// The zone an event repeats in: its own, else the family's.
String eventZone(Event e, String familyZone) {
  final tz = e.rec.fields['tz'];
  return tz is String && tz.isNotEmpty ? tz : familyZone;
}

RecurrenceRule? ruleOf(Event e) {
  final text = e.rrule;
  if (text == null || text.isEmpty) return null;
  try {
    return RecurrenceRule.parse(text);
  } on FormatException {
    return null;
  }
}

/// Series starts (UTC ms, before any exception moves them) from [notBefore] on, in order.
/// The wall-clock expansion keeps a 7:00 AM event at 7:00 AM across DST changes.
Iterable<int> seriesStarts(Event e, String familyZone, {int? notBefore}) sync* {
  final rule = ruleOf(e);
  if (rule == null) {
    if (notBefore == null || e.start >= notBefore) yield e.start;
    return;
  }
  final zoneName = eventZone(e, familyZone);
  final first = wallTime(zoneName, e.start);
  final from = notBefore == null ? null : wallTime(zoneName, notBefore).subtract(const Duration(days: 2));
  for (final wall in rule.expand(first, from: from, toUtc: (w) => wallToUtc(zoneName, w))) {
    final utc = wallToUtc(zoneName, wall);
    if (notBefore != null && utc < notBefore) continue;
    yield utc;
  }
}

/// Whether [start] is one of the series' original starts.
bool isSeriesStart(Event e, String familyZone, int start) {
  for (final s in seriesStarts(e, familyZone, notBefore: start)) {
    if (s == start) return true;
    if (s > start) return false;
  }
  return false;
}

int? firstSeriesStart(Event e, String familyZone) {
  for (final s in seriesStarts(e, familyZone)) {
    return s;
  }
  return null;
}

/// How many occurrences of the series come before [start].
int countBefore(Event e, String familyZone, int start) {
  var n = 0;
  for (final s in seriesStarts(e, familyZone)) {
    if (s >= start) break;
    n++;
  }
  return n;
}

const int _dstSlack = 3 * 60 * 60 * 1000;

bool _overlaps(int s, int e, int start, int end) => e > s ? s < end && e > start : s >= start && s < end;

/// Where an occurrence of [e] starting at [start] ends: an all-day event spans as many local
/// days as the event does, ending at local midnight; a timed one lasts as long on the wall clock
/// of the event's zone. So neither gains or loses an hour, or spills into the next day, across a
/// DST change.
int occurrenceEnd(Event e, int start, String familyZone) {
  if (start == e.start || e.end <= e.start) return start + (e.end - e.start);
  final zoneName = eventZone(e, familyZone);
  if (e.allDay) {
    final first = dateIn(zoneName, e.start);
    final days = daysBetween(first, dateIn(zoneName, e.end - 1)) + 1;
    return dayStartIn(zoneName, addDays(dateIn(zoneName, start), days));
  }
  return shiftWall(zoneName, start, wallDelta(zoneName, e.start, e.end));
}

/// One occurrence with an exception's patch applied. [familyZone] is the zone an event without
/// its own repeats in.
Occurrence buildOccurrence(Event e, int seriesStart, EventException? exception, {String familyZone = 'UTC'}) {
  final patch = {
    for (final e in (exception?.patch ?? const <String, Object?>{}).entries)
      if (e.value != null) e.key: e.value,
  };
  final start = (patch['start'] as num?)?.toInt() ?? seriesStart;
  final end = (patch['end'] as num?)?.toInt() ?? occurrenceEnd(e, start, familyZone);
  T pick<T>(String name, T fallback) => patch.containsKey(name) ? patch[name] as T : fallback;
  return Occurrence(
    event: e,
    start: start,
    end: end < start ? start : end,
    title: pick<String?>('title', null) ?? e.title,
    location: pick<String?>('location', null) ?? e.location,
    notes: pick<String?>('notes', null) ?? e.notes,
    assignees: patch.containsKey('assignees')
        ? [...(patch['assignees'] as List? ?? const []).cast<String>()]
        : e.assignees,
    allDay: pick<bool?>('allDay', null) ?? e.allDay,
    exceptionId: exception?.id,
    seriesStart: seriesStart,
    rides: patch.containsKey('rides')
        ? [
            for (final r in (patch['rides'] as List? ?? const []))
              Ride((r as Map)['leg'] as String? ?? 'to', r['driver'] as String?),
          ]
        : e.rides,
    reminders: patch.containsKey('reminders')
        ? [...(patch['reminders'] as List? ?? const []).map((v) => (v as num).toInt())]
        : e.reminders,
    category: pick<String?>('category', null) ?? e.category,
  );
}

/// Occurrences of one event overlapping [start, end) with its exceptions (keyed by original
/// start) applied, including occurrences moved into the window and excluding ones moved out.
List<Occurrence> occurrencesOf(
  Event e,
  Map<int, EventException> exceptions,
  int start,
  int end,
  String familyZone,
) {
  final out = <Occurrence>[];
  // Occurrences can run up to a DST shift longer than the event itself; look back that far too.
  final duration = (e.end - e.start < 0 ? 0 : e.end - e.start) + _dstSlack;
  final seen = <int>{};
  for (final s in seriesStarts(e, familyZone, notBefore: start - duration)) {
    if (s >= end) break;
    seen.add(s);
    final x = exceptions[s];
    if (x != null && x.cancelled) continue;
    final o = buildOccurrence(e, s, x, familyZone: familyZone);
    if (_overlaps(o.start, o.end, start, end)) out.add(o);
  }
  for (final x in exceptions.values) {
    if (x.cancelled || seen.contains(x.occurrence) || !x.patch.containsKey('start')) continue;
    final o = buildOccurrence(e, x.occurrence, x, familyZone: familyZone);
    if (!_overlaps(o.start, o.end, start, end)) continue;
    if (!isSeriesStart(e, familyZone, x.occurrence)) continue;
    out.add(o);
  }
  return out;
}

int compareOccurrences(Occurrence a, Occurrence b) {
  if (a.start != b.start) return a.start.compareTo(b.start);
  if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
  final t = a.title.compareTo(b.title);
  return t != 0 ? t : a.event.id.compareTo(b.event.id);
}

/// The rides of an occurrence with one leg's driver set (adding the leg when it's missing).
List<Map<String, Object?>> ridesWith(List<Ride> rides, String leg, String? driver) {
  final out = [for (final r in rides) {'leg': r.leg, 'driver': r.driver}];
  final i = out.indexWhere((r) => r['leg'] == leg);
  if (i >= 0) {
    out[i] = {'leg': leg, 'driver': driver};
  } else {
    out.add({'leg': leg, 'driver': driver});
  }
  return out;
}
