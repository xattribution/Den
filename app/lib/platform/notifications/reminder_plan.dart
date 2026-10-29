import 'package:den_core/den_core.dart';

/// How far ahead a device keeps its reminders with the OS. Every change, every app start and a
/// timer while the app runs plan the window again, so it keeps rolling forward.
const Duration reminderWindow = Duration(hours: 48);

/// iOS keeps only 64 pending notifications per app; Den stays under that everywhere and keeps
/// the soonest.
const int maxScheduledReminders = 60;

/// What a shared device shows for an item outside the family space, so a parent's or a kid's
/// private event never appears on the kitchen tablet's lock screen.
const String privateReminderTitle = 'A reminder from Den';

/// One reminder as the OS should hold it: a notification id derived from the reminder's key,
/// the words to show, and the route a tap opens.
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.key,
    required this.at,
    required this.title,
    required this.body,
    required this.route,
  });

  /// The OS notification id. The same [key] maps to the same id on every plan, so scheduling it
  /// again replaces it instead of adding a second notification.
  final int id;

  /// [ReminderDue.key]: `"<type>:<id>:<when>:<offset>"`.
  final String key;

  /// UTC milliseconds it fires.
  final int at;
  final String title;
  final String body;

  /// The app route a tap opens: the event's occurrence or the chore's day.
  final String route;

  @override
  bool operator ==(Object other) =>
      other is PlannedReminder &&
      other.id == id &&
      other.key == key &&
      other.at == at &&
      other.title == title &&
      other.body == body &&
      other.route == route;

  @override
  int get hashCode => Object.hash(id, key, at, title, body, route);

  @override
  String toString() => 'PlannedReminder($key at $at: $title)';
}

/// The reminders this device should hold for [now] to [now] + [window]: the owner's on a personal
/// device, everyone's on a shared display or hub, one per [ReminderDue.key], soonest first, at
/// most [limit]. On a shared device an item outside the family space shows only
/// [privateReminderTitle].
List<PlannedReminder> planReminders(
  Den den, {
  required int now,
  Duration window = reminderWindow,
  int limit = maxScheduledReminders,
}) {
  if (!den.hasFamily || !den.isApproved) return const [];
  final shared = den.thisDevice?.isShared ?? false;
  final member = shared ? null : den.owner?.id;
  if (!shared && member == null) return const [];
  final keys = <String>{};
  final ids = <int>{};
  final out = <PlannedReminder>[];
  for (final r in den.remindersDue(now, now + window.inMilliseconds, memberId: member)) {
    if (out.length >= limit) break;
    if (!keys.add(r.key)) continue;
    var id = reminderId(r.key);
    while (!ids.add(id)) {
      id = (id + 1) & 0x7fffffff;
    }
    final private = shared && _spaceOf(den, r.key) != Space.family;
    out.add(PlannedReminder(
      id: id,
      key: r.key,
      at: r.at,
      title: private ? privateReminderTitle : r.title,
      body: private ? '' : r.body,
      route: reminderRoute(r.key),
    ));
  }
  return out;
}

/// One family's engine as the device's reminders see it: one budget across every family this
/// device holds.
class ReminderLog {
  const ReminderLog({required this.den, required this.id, this.label, this.first = true});

  final Den den;

  /// The family's id: it goes into the notification ids of every family but the first, and into
  /// the routes taps open once the device holds several (`/l/<id>/event/...`).
  final String id;

  /// The family's name, which starts each reminder's title while the device holds several
  /// families ("Kotvas: Soccer at 5").
  final String? label;

  /// The first family this device held keeps the ids Den always gave its reminders, so a device
  /// that had them scheduled replaces them rather than adding a second of each.
  final bool first;
}

/// The reminders the device should hold across every family in [logs]: each family's own
/// ([planReminders]), soonest first, at most [limit] in all. With one family it is exactly that
/// family's plan. With several, a family's reminders other than the first's have ids made with
/// its id, every title starts with the family's name, and a tap opens the family's own page.
List<PlannedReminder> planHouseholdReminders(
  List<ReminderLog> logs, {
  required int now,
  Duration window = reminderWindow,
  int limit = maxScheduledReminders,
}) {
  final families = [for (final l in logs) if (l.den.hasFamily && l.den.isApproved) l];
  if (families.isEmpty) return const [];
  if (families.length == 1 && families.single.first) {
    return planReminders(families.single.den, now: now, window: window, limit: limit);
  }
  final several = families.length > 1;
  final all = <PlannedReminder>[];
  for (final log in families) {
    for (final r in planReminders(log.den, now: now, window: window, limit: limit)) {
      final key = log.first ? r.key : '${log.id}|${r.key}';
      final label = log.label;
      all.add(PlannedReminder(
        id: reminderId(key),
        key: key,
        at: r.at,
        title: several && label != null && label.isNotEmpty ? '$label: ${r.title}' : r.title,
        body: r.body,
        route: several ? '/l/${Uri.encodeComponent(log.id)}${r.route}' : r.route,
      ));
    }
  }
  all.sort((a, b) => a.at != b.at ? a.at.compareTo(b.at) : a.key.compareTo(b.key));
  final ids = <int>{};
  final out = <PlannedReminder>[];
  for (final r in all) {
    if (out.length >= limit) break;
    var id = r.id;
    while (!ids.add(id)) {
      id = (id + 1) & 0x7fffffff;
    }
    out.add(id == r.id
        ? r
        : PlannedReminder(id: id, key: r.key, at: r.at, title: r.title, body: r.body, route: r.route));
  }
  return out;
}

/// A positive 31-bit notification id for a reminder key (FNV-1a), stable across runs and devices.
int reminderId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Where tapping a reminder goes: `/event/<id>?at=<occurrence>` or `/chore/<id>?date=<date>`.
String reminderRoute(String key) {
  final parts = key.split(':');
  if (parts.length < 3) return '/today';
  final id = Uri.encodeComponent(parts[1]);
  return switch (parts[0]) {
    'event' => '/event/$id?at=${parts[2]}',
    'chore' => '/chore/$id?date=${parts[2]}',
    _ => '/today',
  };
}

String? _spaceOf(Den den, String key) {
  final parts = key.split(':');
  if (parts.length < 2) return null;
  return switch (parts[0]) {
    'chore' => den.chore(parts[1])?.space,
    'event' => den.event(parts[1])?.space,
    _ => null,
  };
}
