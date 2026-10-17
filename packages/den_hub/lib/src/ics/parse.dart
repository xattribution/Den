import '../times.dart';

/// A date or date-time from an iCalendar property.
class IcsTime {
  /// Creates a time.
  const IcsTime({required this.utc, required this.date, required this.zone, required this.wall});

  /// UTC milliseconds (local midnight in [zone] for dates).
  final int utc;

  /// A `VALUE=DATE` (all-day) value.
  final bool date;

  /// The IANA zone it was read in.
  final String zone;

  /// The wall-clock value as written (floating UTC fields).
  final DateTime wall;

  /// For dates, `YYYY-MM-DD`.
  String get dateText => dateOfWall(wall);
}

/// One VEVENT.
class IcsEvent {
  /// The event's UID.
  String uid = '';

  /// SUMMARY.
  String summary = '';

  /// LOCATION.
  String location = '';

  /// DESCRIPTION.
  String description = '';

  /// STATUS, uppercased.
  String status = '';

  /// DTSTART.
  IcsTime? start;

  /// DTEND.
  IcsTime? end;

  /// DURATION.
  Duration? duration;

  /// RRULE without the `RRULE:` prefix.
  String? rrule;

  /// EXDATE values.
  final List<IcsTime> exdates = [];

  /// RECURRENCE-ID, for an override of one occurrence.
  IcsTime? recurrenceId;

  /// Whether it is an all-day event.
  bool get allDay => start?.date ?? false;

  /// Whether the event (or this occurrence) is cancelled.
  bool get cancelled => status == 'CANCELLED';

  /// The end: DTEND, else DTSTART plus DURATION, else a day for all-day events and the start
  /// itself for timed ones.
  int get endUtc {
    final s = start!;
    if (end != null && end!.utc >= s.utc) return end!.utc;
    if (duration != null) {
      if (s.date) return midnightIn(s.zone, dateOfWall(s.wall.add(duration!)));
      return s.utc + duration!.inMilliseconds;
    }
    return s.date ? midnightIn(s.zone, addDays(s.dateText, 1)) : s.utc;
  }
}

/// A parsed calendar.
class IcsCalendar {
  /// Creates a calendar.
  IcsCalendar(this.name, this.events);

  /// X-WR-CALNAME.
  final String? name;

  /// Every VEVENT, masters and overrides, in file order.
  final List<IcsEvent> events;
}

/// The iCalendar file couldn't be read.
class IcsFormatException implements Exception {
  /// Creates the exception.
  IcsFormatException(this.message);

  /// What was wrong.
  final String message;

  @override
  String toString() => 'IcsFormatException: $message';
}

class _Line {
  _Line(this.name, this.params, this.value);
  final String name;
  final Map<String, String> params;
  final String value;
}

/// Unfolds lines (a line starting with a space or tab continues the previous one) and splits
/// each into name, parameters and value.
List<_Line> _lines(String text) {
  final out = <_Line>[];
  final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final unfolded = <String>[];
  for (final line in raw) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && unfolded.isNotEmpty) {
      unfolded[unfolded.length - 1] += line.substring(1);
    } else if (line.isNotEmpty) {
      unfolded.add(line);
    }
  }
  for (final line in unfolded) {
    var i = 0, quoted = false;
    while (i < line.length && (quoted || (line[i] != ':' && line[i] != ';'))) {
      if (line[i] == '"') quoted = !quoted;
      i++;
    }
    final name = line.substring(0, i).toUpperCase();
    final params = <String, String>{};
    while (i < line.length && line[i] == ';') {
      final start = ++i;
      quoted = false;
      while (i < line.length && (quoted || (line[i] != ':' && line[i] != ';'))) {
        if (line[i] == '"') quoted = !quoted;
        i++;
      }
      final part = line.substring(start, i);
      final eq = part.indexOf('=');
      if (eq > 0) params[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1).replaceAll('"', '');
    }
    if (i >= line.length) continue;
    out.add(_Line(name, params, line.substring(i + 1)));
  }
  return out;
}

String _unescape(String v) => v.replaceAllMapped(RegExp(r'\\([\\;,nN])'), (m) {
      final c = m[1]!;
      return c == 'n' || c == 'N' ? '\n' : c;
    });

const Map<String, String> _windowsZones = {
  'eastern standard time': 'America/New_York',
  'central standard time': 'America/Chicago',
  'mountain standard time': 'America/Denver',
  'us mountain standard time': 'America/Phoenix',
  'pacific standard time': 'America/Los_Angeles',
  'alaskan standard time': 'America/Anchorage',
  'hawaiian standard time': 'Pacific/Honolulu',
  'atlantic standard time': 'America/Halifax',
  'gmt standard time': 'Europe/London',
  'greenwich standard time': 'Atlantic/Reykjavik',
  'w. europe standard time': 'Europe/Berlin',
  'romance standard time': 'Europe/Paris',
  'central europe standard time': 'Europe/Budapest',
  'central european standard time': 'Europe/Warsaw',
  'e. europe standard time': 'Europe/Chisinau',
  'fle standard time': 'Europe/Kiev',
  'aus eastern standard time': 'Australia/Sydney',
  'tokyo standard time': 'Asia/Tokyo',
  'india standard time': 'Asia/Kolkata',
  'china standard time': 'Asia/Shanghai',
  'utc': 'UTC',
  'coordinated universal time': 'UTC',
};

/// The IANA zone for a TZID: IANA names, common Windows names, and vendor-prefixed names
/// (`/mozilla.org/20050126_1/America/New_York`). Null when unknown.
String? zoneForTzid(String tzid) {
  final t = tzid.trim();
  if (isZone(t)) return t;
  final windows = _windowsZones[t.toLowerCase()];
  if (windows != null) return windows;
  final parts = t.split('/');
  for (var i = 1; i < parts.length - 1; i++) {
    final candidate = parts.sublist(i).join('/');
    if (isZone(candidate)) return candidate;
  }
  return null;
}

final RegExp _dateValue = RegExp(r'^(\d{4})(\d{2})(\d{2})$');
final RegExp _dateTimeValue = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z)?$');

/// Reads one date or date-time value. [zone] applies to floating times and dates.
IcsTime _time(String value, Map<String, String> params, String zone) {
  final v = value.trim();
  final tzid = params['TZID'];
  final z = (tzid == null ? null : zoneForTzid(tzid)) ?? zone;
  final d = _dateValue.firstMatch(v);
  if (d != null || params['VALUE'] == 'DATE') {
    final m = d ?? _dateValue.firstMatch(v.substring(0, 8))!;
    final wall = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    return IcsTime(utc: utcOfWall(z, wall), date: true, zone: z, wall: wall);
  }
  final t = _dateTimeValue.firstMatch(v);
  if (t == null) throw IcsFormatException('Not a date or time: "$v"');
  final wall = DateTime.utc(int.parse(t[1]!), int.parse(t[2]!), int.parse(t[3]!), int.parse(t[4]!), int.parse(t[5]!),
      int.parse(t[6] ?? '0'));
  if (t[7] == 'Z') return IcsTime(utc: wall.millisecondsSinceEpoch, date: false, zone: z, wall: wallOf(z, wall.millisecondsSinceEpoch));
  return IcsTime(utc: utcOfWall(z, wall), date: false, zone: z, wall: wall);
}

final RegExp _durationRe = RegExp(r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$');

/// Reads an iCalendar DURATION (`PT1H30M`, `P1D`, `-PT15M`).
Duration? parseIcsDuration(String value) {
  final m = _durationRe.firstMatch(value.trim());
  if (m == null) return null;
  int n(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final d = Duration(days: n(2) * 7 + n(3), hours: n(4), minutes: n(5), seconds: n(6));
  return m[1] == '-' ? -d : d;
}

/// Parses an iCalendar file. Times without a zone are read in the calendar's X-WR-TIMEZONE,
/// else [defaultZone]. Throws [IcsFormatException] when it isn't a calendar.
IcsCalendar parseIcs(String text, {required String defaultZone}) {
  final lines = _lines(text);
  if (!lines.any((l) => l.name == 'BEGIN' && l.value.trim().toUpperCase() == 'VCALENDAR')) {
    throw IcsFormatException('That isn\'t an iCalendar file');
  }
  String? name;
  var zone = defaultZone;
  for (final l in lines) {
    if (l.name == 'BEGIN' && l.value.trim().toUpperCase() == 'VEVENT') break;
    if (l.name == 'X-WR-CALNAME') name = _unescape(l.value).trim();
    if (l.name == 'X-WR-TIMEZONE') zone = zoneForTzid(l.value) ?? zone;
  }
  final events = <IcsEvent>[];
  final stack = <String>[];
  IcsEvent? current;
  for (final l in lines) {
    if (l.name == 'BEGIN') {
      stack.add(l.value.trim().toUpperCase());
      if (stack.last == 'VEVENT') current = IcsEvent();
      continue;
    }
    if (l.name == 'END') {
      final ended = stack.isEmpty ? '' : stack.removeLast();
      if (ended == 'VEVENT' && current != null) {
        if (current.start != null && current.uid.isNotEmpty) events.add(current);
        current = null;
      }
      continue;
    }
    if (current == null || stack.isEmpty || stack.last != 'VEVENT') continue;
    try {
      switch (l.name) {
        case 'UID':
          current.uid = l.value.trim();
        case 'SUMMARY':
          current.summary = _unescape(l.value).trim();
        case 'LOCATION':
          current.location = _unescape(l.value).trim();
        case 'DESCRIPTION':
          current.description = _unescape(l.value).trim();
        case 'STATUS':
          current.status = l.value.trim().toUpperCase();
        case 'DTSTART':
          current.start = _time(l.value, l.params, zone);
        case 'DTEND':
          current.end = _time(l.value, l.params, zone);
        case 'DURATION':
          current.duration = parseIcsDuration(l.value);
        case 'RRULE':
          current.rrule = l.value.trim();
        case 'EXDATE':
          for (final v in l.value.split(',')) {
            if (v.trim().isNotEmpty) current.exdates.add(_time(v, l.params, zone));
          }
        case 'RECURRENCE-ID':
          current.recurrenceId = _time(l.value, l.params, zone);
      }
    } on IcsFormatException {
      continue;
    }
  }
  return IcsCalendar(name, events);
}
