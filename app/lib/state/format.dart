import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

/// Dates and times as US families read them, in the family's time zone.
/// Local dates are `YYYY-MM-DD` strings, matching den_core.
class Formats {
  Formats(String timezone) : location = _location(timezone);

  final tz.Location location;

  static tz.Location _location(String name) {
    try {
      return tz.getLocation(name);
    } on Object {
      return tz.UTC;
    }
  }

  tz.TZDateTime at(int ms) => tz.TZDateTime.fromMillisecondsSinceEpoch(location, ms);

  /// "3:30 PM"
  String time(int ms) => DateFormat.jm().format(at(ms));

  /// "3:30 PM to 5:00 PM", or "All day".
  String span(int start, int end, {bool allDay = false}) =>
      allDay ? 'All day' : '${time(start)} to ${time(end)}';

  String localDate(int ms) => DateFormat('yyyy-MM-dd').format(at(ms));

  tz.TZDateTime dateTime(String date) {
    final p = date.split('-').map(int.parse).toList();
    return tz.TZDateTime(location, p[0], p[1], p[2]);
  }

  /// UTC ms of local midnight starting [date].
  int startOf(String date) => dateTime(date).millisecondsSinceEpoch;

  String addDays(String date, int days) {
    final d = dateTime(date);
    return DateFormat('yyyy-MM-dd').format(tz.TZDateTime(location, d.year, d.month, d.day + days));
  }

  /// "Fri, Oct 17"
  String short(String date) => DateFormat('EEE, MMM d').format(dateTime(date));

  /// "Friday, October 17"
  String long(String date) => DateFormat('EEEE, MMMM d').format(dateTime(date));

  /// "Wed"
  String weekday(String date) => DateFormat('EEE').format(dateTime(date));

  /// "Today", "Tomorrow", "Yesterday", else "Wed, Oct 22".
  String relative(String date, String today) {
    if (date == today) return 'Today';
    if (date == addDays(today, 1)) return 'Tomorrow';
    if (date == addDays(today, -1)) return 'Yesterday';
    return short(date);
  }

  /// "October 2026"
  String month(String date) => DateFormat('MMMM y').format(dateTime(date));
}
