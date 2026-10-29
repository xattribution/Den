import 'dart:convert';

import 'package:den_actions/times.dart';
import 'package:den_core/den_core.dart';

/// One occurrence of an event changed or cancelled on its own.
class IcsException {
  /// Creates an exception for the occurrence originally starting at [occurrence].
  const IcsException(this.occurrence, {this.cancelled = false, this.patch = const {}});

  /// Original start (UTC ms).
  final int occurrence;

  /// Cancelled (written as EXDATE).
  final bool cancelled;

  /// Changed event fields (written as a RECURRENCE-ID override).
  final Map<String, Object?> patch;
}

/// An event to write, with its exceptions.
class IcsExportEvent {
  /// Creates an export entry.
  const IcsExportEvent(this.event, {this.zone = 'UTC', this.exceptions = const [], this.category});

  /// The series.
  final Event event;

  /// The zone it repeats in.
  final String zone;

  /// Per-occurrence changes.
  final List<IcsException> exceptions;

  /// Its category's name.
  final String? category;
}

String _escape(String text) =>
    text.replaceAll('\\', '\\\\').replaceAll(';', '\\;').replaceAll(',', '\\,').replaceAll('\r\n', '\n').replaceAll('\n', '\\n');

/// Folds a content line at 75 octets.
String _fold(String line) {
  final bytes = utf8.encode(line);
  if (bytes.length <= 75) return line;
  final out = StringBuffer();
  var count = 0;
  var limit = 75;
  for (final rune in line.runes) {
    final ch = String.fromCharCode(rune);
    final n = utf8.encode(ch).length;
    if (count + n > limit) {
      out.write('\r\n ');
      count = 0;
      limit = 74;
    }
    out.write(ch);
    count += n;
  }
  return out.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime w) => '${w.year.toString().padLeft(4, '0')}${_two(w.month)}${_two(w.day)}T${_two(w.hour)}${_two(w.minute)}${_two(w.second)}';

String _dateStamp(DateTime w) => '${w.year.toString().padLeft(4, '0')}${_two(w.month)}${_two(w.day)}';

/// A DTSTART-style property for an instant in [zone].
String _timeProp(String name, int utc, String zone, {required bool allDay}) {
  if (allDay) return '$name;VALUE=DATE:${_dateStamp(wallOf(zone, utc))}';
  if (zone == 'UTC') return '$name:${_stamp(DateTime.fromMillisecondsSinceEpoch(utc, isUtc: true))}Z';
  return '$name;TZID=$zone:${_stamp(wallOf(zone, utc))}';
}

/// VTIMEZONE for [zone] with every offset change in [from, to] (UTC ms).
List<String> _vtimezone(String zone, int from, int to) {
  final location = zoneOf(zone);
  final lines = ['BEGIN:VTIMEZONE', 'TZID:$zone'];
  var any = false;
  for (var i = 0; i < location.transitionAt.length; i++) {
    final at = location.transitionAt[i];
    if (at < from || at > to) continue;
    final next = location.zones[location.transitionZone[i]];
    final prev = i == 0 ? next : location.zones[location.transitionZone[i - 1]];
    final kind = next.isDst ? 'DAYLIGHT' : 'STANDARD';
    lines
      ..add('BEGIN:$kind')
      ..add('DTSTART:${_stamp(DateTime.fromMillisecondsSinceEpoch(at + prev.offset.inMilliseconds, isUtc: true))}')
      ..add('TZOFFSETFROM:${_offset(prev.offset)}')
      ..add('TZOFFSETTO:${_offset(next.offset)}')
      ..add('TZNAME:${next.abbreviation}')
      ..add('END:$kind');
    any = true;
  }
  if (!any) {
    final offset = offsetAt(zone, from);
    lines.addAll(['BEGIN:STANDARD', 'DTSTART:19700101T000000', 'TZOFFSETFROM:${_offset(offset)}', 'TZOFFSETTO:${_offset(offset)}', 'END:STANDARD']);
  }
  return lines..add('END:VTIMEZONE');
}

String _offset(Duration d) {
  final m = d.inMinutes.abs();
  return '${d.isNegative ? '-' : '+'}${_two(m ~/ 60)}${_two(m % 60)}';
}

/// What follows the `@` in the UIDs of the feeds people subscribe to on their own calendars
/// (`<eventId>@den`). They keep it: a calendar app knows an event by its UID, so changing it
/// would make every subscribed calendar drop each event and add it again.
const String legacyUidDomain = 'den';

/// What follows the `@` in the UIDs of family [familyId]'s shared feed: `<eventId>@<familyId>.den`,
/// so a hub that subscribes to it can tell its own family's events from another family's.
String sharedUidDomain(String familyId) => '$familyId.den';

final RegExp _denUid = RegExp(r'@(den|[a-z2-7]+\.den)$');

/// Whether [uid] (an imported event's `source.ref`) came from a Den feed: a shared feed
/// (`@<familyId>.den`) or a calendar link of the older kind (`@den`). A family's shared feed leaves
/// such events out, so no family's events travel on to a third family or come back to their own.
bool isDenUid(String? uid) => uid != null && _denUid.hasMatch(uid);

/// Whether [uid] is one of family [familyId]'s own events, from its shared feed.
bool isOwnUid(String uid, String? familyId) => familyId != null && uid.endsWith('@${sharedUidDomain(familyId)}');

/// The family whose shared feed [uid] came from (`<eventId>@<familyId>.den`), else null.
String? sharedFamilyOf(String uid) {
  final m = _sharedUid.firstMatch(uid);
  return m?.group(1);
}

final RegExp _sharedUid = RegExp(r'@([a-z2-7]+)\.den$');

/// A weak ETag for an iCalendar file [text] that [writeIcs] wrote: a hash of every line but
/// `DTSTAMP`, which says when the file was written and so changes every time. The same events
/// give the same ETag, so a subscriber's conditional GET gets `304`.
String icsEtag(String text) {
  final lines = text.split('\r\n').where((l) => !l.startsWith('DTSTAMP:')).join('\r\n');
  return 'W/"${hashToken(lines).substring(0, 32)}"';
}

/// Whether an `If-None-Match` header [header] names [etag], compared weakly (RFC 9110, 13.1.2).
bool etagMatches(String? header, String etag) {
  if (header == null) return false;
  String bare(String tag) => tag.trim().startsWith('W/') ? tag.trim().substring(2) : tag.trim();
  final want = bare(etag);
  return header.split(',').any((t) => t.trim() == '*' || bare(t) == want);
}

/// Writes events as an iCalendar file (RFC 5545): a VEVENT per series with RRULE and EXDATE,
/// a RECURRENCE-ID VEVENT per changed occurrence, and VTIMEZONEs for the zones used. Each
/// event's UID is `<eventId>@<uidDomain>`.
String writeIcs({
  required String name,
  required String zone,
  required List<IcsExportEvent> events,
  required int now,
  String uidDomain = legacyUidDomain,
}) {
  final body = <String>[];
  final zones = <String>{};
  var earliest = now, latest = now;
  for (final x in events) {
    final e = x.event;
    final tz = x.zone;
    final allDay = e.allDay;
    if (!allDay && tz != 'UTC') zones.add(tz);
    if (e.start < earliest) earliest = e.start;
    if (e.end > latest) latest = e.end;
    final uid = '${e.id}@$uidDomain';
    final stamp = 'DTSTAMP:${_stamp(DateTime.fromMillisecondsSinceEpoch(now, isUtc: true))}Z';
    List<String> describe(String title, String location, String notes) => [
          'SUMMARY:${_escape(title)}',
          if (location.isNotEmpty) 'LOCATION:${_escape(location)}',
          if (notes.isNotEmpty) 'DESCRIPTION:${_escape(notes)}',
          if (x.category != null) 'CATEGORIES:${_escape(x.category!)}',
        ];
    body
      ..add('BEGIN:VEVENT')
      ..add('UID:$uid')
      ..add(stamp)
      ..add(_timeProp('DTSTART', e.start, tz, allDay: allDay))
      ..add(_timeProp('DTEND', e.end, tz, allDay: allDay));
    if (e.rrule != null) body.add('RRULE:${e.rrule}');
    for (final ex in x.exceptions.where((ex) => ex.cancelled)) {
      body.add(_timeProp('EXDATE', ex.occurrence, tz, allDay: allDay));
    }
    body
      ..addAll(describe(e.title, e.location, e.notes))
      ..add('END:VEVENT');
    for (final ex in x.exceptions.where((ex) => !ex.cancelled && ex.patch.values.any((v) => v != null))) {
      final p = ex.patch;
      final start = (p['start'] as num?)?.toInt() ?? ex.occurrence;
      final end = (p['end'] as num?)?.toInt() ?? start + (e.end - e.start);
      final exAllDay = p['allDay'] as bool? ?? allDay;
      body
        ..add('BEGIN:VEVENT')
        ..add('UID:$uid')
        ..add(stamp)
        ..add(_timeProp('RECURRENCE-ID', ex.occurrence, tz, allDay: allDay))
        ..add(_timeProp('DTSTART', start, tz, allDay: exAllDay))
        ..add(_timeProp('DTEND', end, tz, allDay: exAllDay))
        ..addAll(describe(p['title'] as String? ?? e.title, p['location'] as String? ?? e.location, p['notes'] as String? ?? e.notes))
        ..add('END:VEVENT');
    }
  }
  final lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Den//den_hub//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:${_escape(name)}',
    'X-WR-TIMEZONE:$zone',
    for (final z in zones.toList()..sort()) ..._vtimezone(z, earliest - 366 * 86400000, latest + 3 * 366 * 86400000),
    ...body,
    'END:VCALENDAR',
  ];
  return '${lines.map(_fold).join('\r\n')}\r\n';
}
