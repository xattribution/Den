import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _zonesLoaded = false;
final Map<String, tz.Location> _zones = {};

/// The named IANA zone, or UTC when the name is unknown to the bundled database.
tz.Location zone(String name) {
  if (!_zonesLoaded) {
    tzdata.initializeTimeZones();
    _zonesLoaded = true;
  }
  return _zones.putIfAbsent(name, () {
    try {
      return tz.getLocation(name);
    } on Object {
      return tz.UTC;
    }
  });
}

/// Whether [name] is a zone the bundled database knows.
bool isKnownZone(String name) => name == 'UTC' || zone(name) != tz.UTC;

/// Wall-clock times are carried as UTC [DateTime]s whose fields read as local time ("floating").
DateTime wallTime(String zoneName, int utcMillis) {
  final t = tz.TZDateTime.fromMillisecondsSinceEpoch(zone(zoneName), utcMillis);
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second, t.millisecond);
}

/// UTC milliseconds of a wall-clock time in a zone.
int wallToUtc(String zoneName, DateTime wall) => tz.TZDateTime(
      zone(zoneName),
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
    ).millisecondsSinceEpoch;

/// Moves [utcMillis] by a wall-clock amount, so 7:00 plus a day is 7:00 the next day across DST.
int shiftWall(String zoneName, int utcMillis, Duration wallDelta) =>
    wallToUtc(zoneName, wallTime(zoneName, utcMillis).add(wallDelta));

/// The wall-clock difference between two instants as seen in a zone.
Duration wallDelta(String zoneName, int fromUtc, int toUtc) =>
    wallTime(zoneName, toUtc).difference(wallTime(zoneName, fromUtc));

final RegExp _dateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final RegExp _timeRe = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

/// Whether [value] is a real `YYYY-MM-DD` date.
bool isLocalDate(Object? value) {
  if (value is! String) return false;
  final m = _dateRe.firstMatch(value);
  if (m == null) return false;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final dt = DateTime.utc(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

/// Whether [value] is an `HH:mm` time.
bool isLocalTime(Object? value) => value is String && _timeRe.hasMatch(value);

/// Midnight of a local date as a floating [DateTime].
DateTime dateToWall(String date) {
  final m = _dateRe.firstMatch(date);
  if (m == null) throw FormatException('Not a date', date);
  return DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String wallToDate(DateTime wall) =>
    '${wall.year.toString().padLeft(4, '0')}-${wall.month.toString().padLeft(2, '0')}-'
    '${wall.day.toString().padLeft(2, '0')}';

/// Minutes after midnight of an `HH:mm` time.
int minutesOf(String time) {
  final m = _timeRe.firstMatch(time);
  if (m == null) throw FormatException('Not a time', time);
  return int.parse(m[1]!) * 60 + int.parse(m[2]!);
}

String addDays(String date, int days) {
  final d = dateToWall(date);
  return wallToDate(DateTime.utc(d.year, d.month, d.day + days));
}

int daysBetween(String from, String to) =>
    (dateToWall(to).millisecondsSinceEpoch - dateToWall(from).millisecondsSinceEpoch) ~/
    Duration.millisecondsPerDay;

/// ISO weekday of a local date: 1 Monday to 7 Sunday.
int weekdayOf(String date) => dateToWall(date).weekday;

/// The first day of the week holding [date], where [weekStart] is 0 for Sunday, 1 for Monday.
String startOfWeek(String date, int weekStart) {
  final dayIndex = weekdayOf(date) % 7;
  return addDays(date, -((dayIndex - weekStart) % 7));
}

String startOfMonth(String date) => '${date.substring(0, 7)}-01';

String addMonths(String date, int months) {
  final d = dateToWall(date);
  return wallToDate(DateTime.utc(d.year, d.month + months, 1));
}

/// The local date of an instant in a zone.
String dateIn(String zoneName, int utcMillis) => wallToDate(wallTime(zoneName, utcMillis));

/// UTC milliseconds of local midnight starting [date] in a zone.
int dayStartIn(String zoneName, String date) => wallToUtc(zoneName, dateToWall(date));

/// UTC milliseconds of a local date and `HH:mm` time in a zone.
int dateTimeIn(String zoneName, String date, String time) =>
    wallToUtc(zoneName, dateToWall(date).add(Duration(minutes: minutesOf(time))));

/// "3:30 PM", the US clock format Den shows by default.
String clockText(DateTime wall) {
  final h = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
  final suffix = wall.hour < 12 ? 'AM' : 'PM';
  return '$h:${wall.minute.toString().padLeft(2, '0')} $suffix';
}

/// "Leo", "Leo and Mia", "Ava, Leo and Mia".
String joinNames(List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) return names.first;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}
