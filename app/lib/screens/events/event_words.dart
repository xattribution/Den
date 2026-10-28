import 'package:den_core/den_core.dart';

import '../../state/app_state.dart';

/// Reminder offsets offered first, in minutes before the start.
const List<int> reminderPresets = [5, 15, 30, 60, 120, 1440];

/// "At the start", "15 minutes before", "1 hour 30 minutes before", "2 days before".
String reminderWords(int minutes) {
  if (minutes <= 0) return 'At the start';
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

/// A ride leg as parents say it: driving there is drop-off, coming back is pick-up.
String legWords(String leg) => leg == 'from' ? 'Pick-up' : 'Drop-off';

/// "Everyone", or the people's names.
String whoWords(AppState app, List<String> assignees) {
  if (assignees.isEmpty) return 'Everyone';
  final names = assignees.map(app.memberById).whereType<Member>().map((m) => m.name).toList();
  return names.isEmpty ? 'Everyone' : names.join(', ');
}

/// Who can see an item in [space]: "Everyone", "Parents", "Just you", "Just Mia".
String audienceWords(AppState app, String space) {
  final owner = Space.memberOf(space);
  if (space == Space.family) return 'Everyone';
  if (space == Space.parents) return 'Parents';
  if (owner == null) return 'Everyone';
  if (owner == app.me?.id) return 'Just you';
  final name = app.memberById(owner)?.name;
  return name == null ? 'Just one person' : 'Just $name';
}

/// Days until a countdown event: "Today", "Tomorrow", "In 12 days"; null once it's past.
String? countdownWords(int days) {
  if (days < 0) return null;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  return 'In $days days';
}

/// Members who might drive: adults, and teens.
List<Member> possibleDrivers(AppState app) =>
    app.den.members.where((m) => m.role == Role.parent || m.role == Role.adult || m.tier == Tier.teen).toList();

/// Whether this person could take a ride leg.
bool canDrive(Member? me) => me != null && (me.role == Role.parent || me.role == Role.adult || me.tier == Tier.teen);

/// Whether whoever is acting may take a ride leg themselves: someone who could drive, and whom
/// the engine lets set a driver (that changes the event, so it needs [DenAction.editEvents]).
bool canTakeRide(AppState app) => canDrive(app.me) && app.allows(DenAction.editEvents);
