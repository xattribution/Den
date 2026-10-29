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
    rides: exception?.rides(e.rides) ?? e.rides,
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

/// [rides] with one leg's driver set (adding the leg when it's missing).
List<Ride> ridesWith(List<Ride> rides, String leg, String? driver) {
  final out = List.of(rides);
  final i = out.indexWhere((r) => r.leg == leg);
  if (i >= 0) {
    out[i] = Ride(leg, driver);
  } else {
    out.add(Ride(leg, driver));
  }
  return out;
}

/// [rides] as a `rides` list stores them.
List<Map<String, Object?>> ridesJson(List<Ride> rides) => [
      for (final r in rides) {'leg': r.leg, 'driver': r.driver},
    ];

/// [rides] with one entry per leg (the first, when a leg is named twice), as `drivers` can hold
/// them.
List<Ride> uniqueRides(List<Ride> rides) {
  final seen = <String>{};
  return [
    for (final r in rides)
      if (seen.add(r.leg)) r,
  ];
}

/// Each leg of [rides] and its driver (the first, when a leg is named twice).
Map<String, String?> _legs(List<Ride> rides) => {for (final r in uniqueRides(rides)) r.leg: r.driver};

/// Whether [a] and [b] have the same legs with the same drivers, in any order.
bool _sameRides(List<Ride> a, List<Ride> b) {
  final x = _legs(a), y = _legs(b);
  return x.length == y.length && x.entries.every((e) => y.containsKey(e.key) && y[e.key] == e.value);
}

/// The fields that give an event record [rides]. `rides` is written whole, for older versions;
/// then `drivers`: one entry per leg whose driver changes (`drivers.<leg>`), so claims of
/// different legs at once all count, when [existing] already reads its drivers there with the
/// same legs; otherwise the whole map, which also says which legs there are. Empty when nothing
/// would change. [existing] is null for a record being made.
///
/// Den commits `drivers` in a change of its own, after the rest (`Den._olderVersionsFirst`).
Map<String, Object?> eventRideFields(List<Ride> rides, {Event? existing}) {
  final want = _legs(rides);
  final list = [for (final leg in rideLegs) if (want.containsKey(leg)) Ride(leg, want[leg])];
  final whole = {'rides': ridesJson(list), 'drivers': {for (final r in list) r.leg: r.driver}};
  if (existing == null) return whole;
  final now = existing.rides;
  if (_sameRides(now, list)) return const {};
  final have = _legs(now);
  final sameLegs = have.length == want.length && want.keys.every(have.containsKey);
  if (!existing.readsDrivers || !sameLegs) return whole;
  return {
    'rides': ridesJson(list),
    for (final r in list)
      if (have[r.leg] != r.driver) 'drivers.${r.leg}': r.driver,
  };
}

/// The fields of an [EventException] that give one occurrence [rides], over the series'
/// [series]: `patch.rides` whole, for older versions, then `patch.drivers.<leg>` (a member id, or
/// `""` for nobody this time) for each leg that changes, so claims of different legs at once all
/// count. When [x] reads `patch.rides` whole, every leg is written, to take over from it. When
/// [rides] leaves out a leg the series has, which a per-leg driver can't say, `patch.rides` alone.
/// Empty when nothing would change.
Map<String, Object?> occurrenceRideFields(List<Ride> rides, List<Ride> series, EventException? x) {
  final list = uniqueRides(rides);
  final now = x?.rides(series) ?? series;
  if (_sameRides(now, list)) return const {};
  final want = _legs(list), have = _legs(now);
  if (!series.every((s) => want.containsKey(s.leg))) return {'patch.rides': ridesJson(list)};
  final whole = x?.ridesWhole ?? false;
  return {
    'patch.rides': ridesJson(list),
    for (final leg in rideLegs)
      if (whole || want.containsKey(leg) != have.containsKey(leg) || want[leg] != have[leg])
        if (want.containsKey(leg) || x?.patch['drivers.$leg'] != null)
          'patch.drivers.$leg': want.containsKey(leg) ? want[leg] ?? '' : null,
  };
}
