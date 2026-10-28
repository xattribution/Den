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
