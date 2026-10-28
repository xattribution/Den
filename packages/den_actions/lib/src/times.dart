import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _loaded = false;
final Map<String, tz.Location?> _zones = {};

/// The IANA zone [name], or null when the bundled database doesn't know it.
tz.Location? findZone(String name) {
  if (!_loaded) {
    tzdata.initializeTimeZones();
    _loaded = true;
  }
  return _zones.putIfAbsent(name, () {
    if (name == 'UTC' || name == 'Etc/UTC' || name == 'Z') return tz.UTC;
    try {
      return tz.getLocation(name);
    } on Object {
      return null;
    }
  });
}

/// The IANA zone [name], or UTC when unknown.
tz.Location zoneOf(String name) => findZone(name) ?? tz.UTC;

/// Whether [name] is an IANA zone the hub knows.
bool isZone(String name) => findZone(name) != null;

/// Wall-clock fields of an instant in a zone, as a floating UTC [DateTime].
DateTime wallOf(String zone, int utcMillis) {
  final t = tz.TZDateTime.fromMillisecondsSinceEpoch(zoneOf(zone), utcMillis);
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second, t.millisecond);
}

/// UTC milliseconds of a wall-clock time in a zone. Times skipped by a DST change move forward.
int utcOfWall(String zone, DateTime wall) => tz.TZDateTime(
      zoneOf(zone),
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
    ).millisecondsSinceEpoch;

/// The zone's offset from UTC at an instant.
Duration offsetAt(String zone, int utcMillis) =>
    tz.TZDateTime.fromMillisecondsSinceEpoch(zoneOf(zone), utcMillis).timeZoneOffset;

String _two(int n) => n.toString().padLeft(2, '0');

/// ISO 8601 with the zone's offset at that instant and whole seconds: `2026-10-20T17:30:00-05:00`.
String isoIn(String zone, int utcMillis) {
  final w = wallOf(zone, utcMillis);
  final offset = offsetAt(zone, utcMillis);
  final minutes = offset.inMinutes.abs();
  final sign = offset.isNegative ? '-' : '+';
  return '${w.year.toString().padLeft(4, '0')}-${_two(w.month)}-${_two(w.day)}T'
      '${_two(w.hour)}:${_two(w.minute)}:${_two(w.second)}$sign${_two(minutes ~/ 60)}:${_two(minutes % 60)}';
}

final RegExp _dateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final RegExp _timeRe = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

/// Whether [value] is a real `YYYY-MM-DD` date.
bool isDate(Object? value) {
  if (value is! String) return false;
  final m = _dateRe.firstMatch(value);
  if (m == null) return false;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final dt = DateTime.utc(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

/// Whether [value] is an `HH:mm` time.
bool isClockTime(Object? value) => value is String && _timeRe.hasMatch(value);

/// Midnight of a local date as a floating [DateTime].
DateTime wallOfDate(String date) {
  final m = _dateRe.firstMatch(date);
  if (m == null) throw FormatException('Not a date', date);
  return DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// `YYYY-MM-DD` of a floating [DateTime].
String dateOfWall(DateTime wall) =>
    '${wall.year.toString().padLeft(4, '0')}-${_two(wall.month)}-${_two(wall.day)}';

/// The local date of an instant in a zone.
String dateIn(String zone, int utcMillis) => dateOfWall(wallOf(zone, utcMillis));

/// UTC milliseconds of local midnight starting [date] in a zone.
int midnightIn(String zone, String date) => utcOfWall(zone, wallOfDate(date));

/// [date] moved by [days].
String addDays(String date, int days) {
  final d = wallOfDate(date);
  return dateOfWall(DateTime.utc(d.year, d.month, d.day + days));
}

/// Whole days from [from] to [to].
int daysBetween(String from, String to) =>
    (wallOfDate(to).millisecondsSinceEpoch - wallOfDate(from).millisecondsSinceEpoch) ~/ Duration.millisecondsPerDay;

/// ISO weekday of a local date: 1 Monday to 7 Sunday.
int weekdayOfDate(String date) => wallOfDate(date).weekday;

/// "3:42 PM".
String clockText(DateTime wall) {
  final h = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
  return '$h:${_two(wall.minute)} ${wall.hour < 12 ? 'AM' : 'PM'}';
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November',
  'December',
];

/// "Friday, October 17".
String longDate(String date) {
  final d = wallOfDate(date);
  return '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';
}

/// "Fri, Oct 17".
String shortDate(String date) {
  final d = wallOfDate(date);
  return '${_weekdays[d.weekday - 1].substring(0, 3)}, ${_months[d.month - 1].substring(0, 3)} ${d.day}';
}

/// "Leo", "Leo and Mia", "Ava, Leo and Mia".
String joinNames(List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) return names.first;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

final RegExp _instantRe = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?\s*(Z|z|[+\- ]\d{2}(?::?\d{2})?)?$',
);

/// Reads an instant as a request may give it: integer UTC milliseconds (or their digits),
/// ISO 8601 with an offset or `Z`, or ISO 8601 without one, read in [zone]. A space where the
/// offset's sign belongs is a `+` that a query string decoded. With [allowDate], a local date
/// is midnight starting that day in [zone]. Throws [FormatException].
int parseInstant(Object? value, String zone, {bool allowDate = false}) {
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  if (value is! String) throw const FormatException('not a time');
  final text = value.trim();
  if (RegExp(r'^-?\d{1,16}$').hasMatch(text)) return int.parse(text);
  if (isDate(text)) {
    if (!allowDate) throw const FormatException('a date where a time is needed');
    return midnightIn(zone, text);
  }
  final m = _instantRe.firstMatch(text);
  if (m == null) throw const FormatException('not a time');
  final fraction = m[7] ?? '';
  final millis = fraction.isEmpty ? 0 : int.parse(fraction.padRight(3, '0').substring(0, 3));
  final wall = DateTime.utc(
    int.parse(m[1]!),
    int.parse(m[2]!),
    int.parse(m[3]!),
    int.parse(m[4]!),
    int.parse(m[5]!),
    int.parse(m[6] ?? '0'),
    millis,
  );
  if (wall.month != int.parse(m[2]!) || wall.day != int.parse(m[3]!) || int.parse(m[4]!) > 23) {
    throw const FormatException('not a time');
  }
  final offset = m[8];
  if (offset == null) return utcOfWall(zone, wall);
  if (offset == 'Z' || offset == 'z') return wall.millisecondsSinceEpoch;
  final sign = offset[0] == '-' ? -1 : 1;
  final digits = offset.substring(1).replaceAll(':', '');
  final hours = int.parse(digits.substring(0, 2));
  final minutes = digits.length >= 4 ? int.parse(digits.substring(2, 4)) : 0;
  if (hours > 18 || minutes > 59) throw const FormatException('not a time');
  return wall.millisecondsSinceEpoch - sign * (hours * 60 + minutes) * 60000;
}

/// Reads a local date, or the local date of an instant in [zone]. Throws [FormatException].
String parseDateLike(Object? value, String zone) {
  if (value is String && isDate(value.trim())) return value.trim();
  return dateIn(zone, parseInstant(value, zone));
}
