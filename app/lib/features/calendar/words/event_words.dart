import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';

/// Reminder offsets offered first, in minutes before the start. Their words are
/// `reminderWords` (app/words.dart), which chores say too.
const List<int> reminderPresets = [5, 15, 30, 60, 120, 1440];

/// A ride leg as parents say it: driving there is drop-off, coming back is pick-up.
String legWords(String leg) => leg == 'from' ? 'Pick-up' : 'Drop-off';

/// "Everyone", or the people's names.
String whoWords(FamilyReads app, List<String> assignees) {
  if (assignees.isEmpty) return 'Everyone';
  final names = assignees.map(app.memberById).whereType<Member>().map((m) => m.name).toList();
  return names.isEmpty ? 'Everyone' : names.join(', ');
}

/// Days until a countdown event: "Today", "Tomorrow", "In 12 days"; null once it's past.
String? countdownWords(int days) {
  if (days < 0) return null;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  return 'In $days days';
}

/// Members who might drive: adults, and teens.
List<Member> possibleDrivers(FamilyReads app) =>
    app.den.members.where((m) => m.role == Role.parent || m.role == Role.adult || m.tier == Tier.teen).toList();

/// Whether this person could take a ride leg.
bool canDrive(Member? me) => me != null && (me.role == Role.parent || me.role == Role.adult || me.tier == Tier.teen);

/// Whether whoever is acting may take a ride leg themselves: someone who could drive, and whom
/// the engine lets set a driver (that changes the event, so it needs [DenAction.editEvents]).
bool canTakeRide(FamilyReads app) => canDrive(app.me) && app.allows(DenAction.editEvents);
