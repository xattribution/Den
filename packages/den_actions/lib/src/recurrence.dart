import 'package:den_core/den_core.dart';

import 'times.dart';

/// The zone [e] repeats in: its own, else [familyZone].
String zoneOfEvent(Event e, String familyZone) {
  final tz = e.rec.fields['tz'];
  return tz is String && tz.isNotEmpty ? tz : familyZone;
}

/// Original starts (UTC ms) of [e]'s occurrences from [notBefore] on, as den_core expands them:
/// wall-clock times in the event's zone, so a 7:00 AM series stays at 7:00 AM across DST.
Iterable<int> seriesStartsOf(Event e, String familyZone, {int? notBefore}) sync* {
  final text = e.rrule;
  RecurrenceRule? rule;
  if (text != null && text.isNotEmpty) {
    try {
      rule = RecurrenceRule.parse(text);
    } on FormatException {
      rule = null;
    }
  }
  if (rule == null) {
    if (notBefore == null || e.start >= notBefore) yield e.start;
    return;
  }
  final zone = zoneOfEvent(e, familyZone);
  final first = wallOf(zone, e.start);
  final from = notBefore == null ? null : wallOf(zone, notBefore).subtract(const Duration(days: 2));
  for (final wall in rule.expand(first, from: from, toUtc: (w) => utcOfWall(zone, w))) {
    final utc = utcOfWall(zone, wall);
    if (notBefore != null && utc < notBefore) continue;
    yield utc;
  }
}

/// Whether [start] is one of [e]'s original occurrence starts.
bool isOccurrenceOf(Event e, String familyZone, int start) {
  for (final s in seriesStartsOf(e, familyZone, notBefore: start)) {
    if (s == start) return true;
    if (s > start) return false;
  }
  return false;
}
