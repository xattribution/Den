/// Words more than one part of the app says the same way. Pure Dart, so the hub and an assistant
/// can say them the way the screens do.
library;

import 'package:den_core/den_core.dart';
import 'package:intl/intl.dart';

/// "3:30 PM": every clock time the app shows.
String clockAt(int hour, int minute) => DateFormat.jm().format(DateTime(2000, 1, 1, hour, minute));

/// "3:30 PM" from a stored "15:30", such as a chore's due time.
String clockWords(String hhmm) {
  final p = hhmm.split(':');
  final h = int.tryParse(p.first) ?? 0;
  final m = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
  return clockAt(h, m);
}

/// A reminder [minutes] ahead, said the same way for events and chores: "15 minutes before",
/// "1 hour 30 minutes before", "2 days before". At 0 it is "At the start" for an event and
/// "When it's due" for a chore ([due]).
String reminderWords(int minutes, {bool due = false}) {
  if (minutes <= 0) return due ? "When it's due" : 'At the start';
  String unit(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';
  if (minutes % 10080 == 0) return '${unit(minutes ~/ 10080, 'week')} before';
  if (minutes % 1440 == 0) return '${unit(minutes ~/ 1440, 'day')} before';
  if (minutes >= 60) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${unit(h, 'hour')} before' : '${unit(h, 'hour')} ${unit(m, 'minute')} before';
  }
  return '${unit(minutes, 'minute')} before';
}

/// Who sees something kept in [space]: "Everyone", "Parents", "Just you" (when it's [me]'s) or
/// "Just Maya". [nameOf] finds a member's name.
String audienceWords(String space, {required String? me, required String? Function(String id) nameOf}) {
  if (space == Space.family) return 'Everyone';
  if (space == Space.parents) return 'Parents';
  final owner = Space.memberOf(space);
  if (owner == null) return 'Everyone';
  if (owner == me) return 'Just you';
  final name = nameOf(owner);
  return name == null ? 'Just one person' : 'Just $name';
}
