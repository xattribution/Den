import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import '../recurrence.dart';
import 'expand.dart';
import 'parse.dart';

/// Older than this, events that ended aren't imported.
const Duration feedHistory = Duration(days: 90);

/// Most series imported from one feed.
const int maxFeedSeries = 1500;

/// What one feed should put on the calendar, by UID.
class FeedPlan {
  /// Creates a plan.
  FeedPlan(this.series, this.fields, {this.skipped = 0});

  /// Series kept after filters.
  final Map<String, IcsSeries> series;

  /// Den event fields per UID.
  final Map<String, Map<String, Object?>> fields;

  /// Series left out because Den couldn't read them (a start it can't place, a repeat it can't
  /// expand).
  final int skipped;
}

String _cut(String s, int max) => s.length <= max ? s : s.substring(0, max);

bool _matches(String text, List<String> words) {
  final t = text.toLowerCase();
  return words.any((w) => w.trim().isNotEmpty && t.contains(w.trim().toLowerCase()));
}

/// The events [calendar] should become under [sub]: cancelled series dropped, include and
/// exclude words applied to titles, all-day events skipped when asked, and series that ended
/// before [now] minus [feedHistory] left out. A series Den can't read is skipped and counted,
/// never thrown: one bad event must not stop the rest of the feed.
FeedPlan planFeed(IcsCalendar calendar, Subscription sub, {required int now, required String label}) {
  final kept = <String, IcsSeries>{};
  final fields = <String, Map<String, Object?>>{};
  var skipped = calendar.skipped;
  for (final s in groupSeries(calendar).values) {
    final m = s.master;
    if (m.cancelled || m.start == null) continue;
    final title = m.summary.isEmpty ? 'Busy' : m.summary;
    if (sub.include.any((w) => w.trim().isNotEmpty) && !_matches(title, sub.include)) continue;
    if (_matches(title, sub.exclude)) continue;
    if (sub.skipAllDay && m.allDay) continue;
    if (kept.length >= maxFeedSeries) break;
    final Map<String, Object?> want;
    try {
      final length = m.endUtc - m.start!.utc;
      if (s.starts(notBefore: now - feedHistory.inMilliseconds - length).isEmpty) continue;
      want = {
        'title': _cut(title, 200),
        'notes': _cut(m.description, 5000),
        'location': _cut(m.location, 300),
        'category': sub.category,
        'start': m.start!.utc,
        'end': m.endUtc,
        'allDay': m.allDay,
        'tz': m.start!.zone,
        'rrule': s.rule == null ? null : RecurrenceRule.parse(s.rule!).toString(),
        'assignees': [?sub.assignee],
        'source': {'kind': 'ics', 'ref': feedRef(m.uid), 'label': _cut(label, 200)},
      };
    } on Object {
      skipped++;
      continue;
    }
    kept[m.uid] = s;
    fields[m.uid] = want;
  }
  return FeedPlan(kept, fields, skipped: skipped);
}

/// The `source.ref` an imported event carries for the feed event with [uid]: how the hub finds
/// the events a feed already wrote.
String feedRef(String uid) => _cut(uid, 1000);

/// The fields of [event] that differ from [want].
Map<String, Object?> eventChanges(Event event, Map<String, Object?> want) {
  final have = event.rec.fields;
  final out = <String, Object?>{};
  for (final e in want.entries) {
    final current = have[e.key];
    if (!const DeepCollectionEquality().equals(current, e.value)) out[e.key] = e.value;
  }
  return out;
}

/// The occurrence changes a series wants: cancelled original starts, and patches by original
/// start, for occurrences of [event].
({Set<int> cancel, Map<int, Map<String, Object?>> patch}) wantedExceptions(IcsSeries s, Event event, String familyZone) {
  final cancel = <int>{};
  final patch = <int, Map<String, Object?>>{};
  final length = event.end - event.start;
  for (final x in s.excluded) {
    if (isOccurrenceOf(event, familyZone, x)) cancel.add(x);
  }
  for (final e in s.overrides.entries) {
    if (!isOccurrenceOf(event, familyZone, e.key)) continue;
    final o = e.value;
    if (o.cancelled) {
      cancel.add(e.key);
      continue;
    }
    final p = <String, Object?>{};
    if (o.summary.isNotEmpty && o.summary != event.title) p['title'] = _cut(o.summary, 200);
    if (o.location != event.location && o.location.isNotEmpty) p['location'] = _cut(o.location, 300);
    if (o.description != event.notes && o.description.isNotEmpty) p['notes'] = _cut(o.description, 5000);
    final start = o.start?.utc ?? e.key;
    final end = o.start == null ? start + length : o.endUtc;
    if (start != e.key) p['start'] = start;
    if (end != e.key + length) p['end'] = end;
    if (o.start != null && o.allDay != event.allDay) p['allDay'] = o.allDay;
    if (p.isNotEmpty) patch[e.key] = p;
  }
  patch.removeWhere((k, _) => cancel.contains(k));
  return (cancel: cancel, patch: patch);
}

/// The exceptions [den] holds for [eventId] in [space], by original start.
Map<int, ({bool cancelled, Map<String, Object?> patch})> heldExceptions(Den den, String eventId, String space) {
  final records = ((den.exportJson()['records'] as Map?)?['eventException'] as Map?) ?? const {};
  final out = <int, ({bool cancelled, Map<String, Object?> patch})>{};
  for (final r in records.values) {
    if (r is! Map || r['space'] != space) continue;
    final f = (r['fields'] as Map?)?.cast<String, Object?>() ?? const {};
    if (f['event'] != eventId || f['occurrence'] is! int) continue;
    out[f['occurrence'] as int] = (
      cancelled: f['cancelled'] == true,
      patch: {for (final e in ((f['patch'] as Map?) ?? const {}).entries) if (e.value != null) '${e.key}': e.value},
    );
  }
  return out;
}
