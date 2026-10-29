import 'hlc.dart';
import 'model.dart';

/// How far an edit or delete of a repeating event reaches.
enum EditScope { one, following, all }

/// Thrown when the acting member may not make a change. [message] is written for people.
class PermissionDenied implements Exception {
  const PermissionDenied(this.message);
  final String message;
  @override
  String toString() => 'PermissionDenied: $message';
}

/// Thrown for input that fails a record type's schema. [message] is written for people.
class InvalidInput implements Exception {
  const InvalidInput(this.message);
  final String message;
  @override
  String toString() => 'InvalidInput: $message';
}

/// One occurrence of an event within a window, with exceptions applied.
class Occurrence {
  const Occurrence({
    required this.event,
    required this.start,
    required this.end,
    required this.title,
    required this.location,
    required this.notes,
    required this.assignees,
    required this.allDay,
    this.exceptionId,
    int? seriesStart,
    this.rides = const [],
    this.reminders = const [],
    this.category,
  }) : seriesStart = seriesStart ?? start;

  final Event event;

  /// UTC milliseconds of this occurrence (after any move).
  final int start;
  final int end;
  final String title;
  final String location;
  final String notes;
  final List<String> assignees;
  final bool allDay;

  /// Set when this occurrence was edited on its own.
  final String? exceptionId;

  /// The original start of the occurrence in the series, used to address it in edits.
  final int seriesStart;

  /// Ride legs for this occurrence, with any per-occurrence drivers applied.
  final List<Ride> rides;

  /// Minutes before the start to remind, for this occurrence.
  final List<int> reminders;

  /// The occurrence's category id, after any per-occurrence change.
  final String? category;

  bool get isRepeating => event.rrule != null;
  bool get forEveryone => assignees.isEmpty;
}

/// A chore as it stands on one local date.
class ChoreDay {
  const ChoreDay({
    required this.chore,
    required this.date,
    required this.owner,
    required this.done,
    required this.doneBy,
    required this.steps,
    required this.late,
    this.swapped = false,
  });

  final Chore chore;
  final String date;

  /// Who it belongs to on this date after rotations and swaps; null means anyone.
  final String? owner;
  final bool done;
  final String? doneBy;

  /// stepId -> member who checked it (null or absent when unchecked).
  final Map<String, String?> steps;

  /// Past its due time today, or from an earlier day, and not done.
  final bool late;

  /// The owner comes from a one-day swap rather than the chore's schedule.
  final bool swapped;

  int get stepsDone => steps.values.where((v) => v != null).length;
  int get stepCount => chore.steps.length;
  int get pointsAvailable => chore.points + chore.steps.fold(0, (sum, s) => sum + s.points);
}

/// A list with its live items, in display order.
class ListState {
  const ListState(this.list, this.items);
  final DenList list;
  final List<Item> items;
  int get open => items.where((i) => !i.checked).length;

  /// Open items per store; items with no store count under the empty string.
  Map<String, int> get openByStore {
    final counts = <String, int>{};
    for (final item in items.where((i) => !i.checked)) {
      counts.update(item.store ?? '', (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }
}

enum PointsSource { chore, step, adjustment, reward }

/// One line of the points history, derived or stored.
class PointsLine {
  const PointsLine({
    required this.member,
    required this.delta,
    required this.reason,
    required this.when,
    required this.source,
    this.ref,
  });
  final String member;
  final int delta;
  final String reason;

  /// UTC milliseconds.
  final int when;
  final PointsSource source;
  final String? ref;
}

class Standing {
  const Standing(this.member, this.earned, this.reachedAt);
  final String member;
  final int earned;

  /// When the running total first crossed the target and stayed there (UTC ms), else null.
  final int? reachedAt;
}

class GoalStanding {
  const GoalStanding(this.goal, this.windowStart, this.windowEnd, this.standings);
  final Goal goal;

  /// Local dates bounding the measured window (end exclusive, null when open-ended).
  final String windowStart;
  final String? windowEnd;
  final List<Standing> standings;

  /// For races: the earliest member to reach the target.
  String? get winner {
    final reached = standings.where((s) => s.reachedAt != null).toList()
      ..sort((a, b) => a.reachedAt!.compareTo(b.reachedAt!));
    return reached.isEmpty ? null : reached.first.member;
  }
}

class PointsSummary {
  const PointsSummary({
    required this.totals,
    required this.goals,
    required this.recent,
    required this.rewards,
    required this.pending,
  });

  /// memberId -> current balance (earned + adjustments - approved redemptions).
  final Map<String, int> totals;
  final List<GoalStanding> goals;

  /// Newest first.
  final List<PointsLine> recent;
  final List<Reward> rewards;
  final List<Redemption> pending;

  /// What [member] can still spend: their balance less what their requests waiting for a parent
  /// would cost.
  int available(String member) =>
      (totals[member] ?? 0) - pending.where((r) => r.member == member).fold(0, (n, r) => n + r.cost);
}

class FieldDiff {
  const FieldDiff(this.field, this.before, this.after);
  final String field;
  final Object? before;
  final Object? after;
}

/// One valid change rendered for people.
class HistoryEntry {
  const HistoryEntry({
    required this.when,
    required this.actor,
    required this.actorName,
    required this.device,
    required this.deviceName,
    required this.type,
    required this.rid,
    required this.title,
    required this.verb,
    required this.diffs,
    required this.space,
    this.via,
    this.from,
    this.change,
  });

  final Hlc when;
  final String? actor;

  /// The change's id (`"<deviceId>:<counter>"`), which [Den.undo] takes.
  final String? change;

  /// The member's name, or the device's name for open check-off and the hub.
  final String actorName;
  final String device;
  final String deviceName;
  final String type;
  final String rid;

  /// The record's title or text at the time of the change.
  final String title;

  /// Short past-tense verb: added, changed, removed, completed, reopened, checked, unchecked,
  /// approved, declined, swapped, requested, gave, took, restored.
  final String verb;
  final List<FieldDiff> diffs;
  final String space;

  /// Label of the API token or MCP connection that made the change through the hub.
  final String? via;

  /// What a capture read to make this change ("from a photo"), or null for a change made by hand.
  final CaptureOrigin? from;
}

/// What [Den.recording]'s body returned, with the ids of the changes this device committed
/// while it ran, oldest first.
class Recorded<T> {
  const Recorded(this.value, this.changes);
  final T value;
  final List<String> changes;
}

/// Part of an undo that wasn't done, and why, for people.
class UndoSkip {
  const UndoSkip({required this.type, required this.id, required this.title, required this.reason, this.field});

  /// The record's type and id.
  final String type;
  final String id;

  /// What people know the record by.
  final String title;

  /// The field left as it is, or null when the whole record was.
  final String? field;
  final String reason;
}

/// What [Den.undo] did: the changes it wrote, and what it left alone.
class UndoResult {
  const UndoResult({required this.changes, required this.skipped});

  /// Ids of the changes the undo wrote; empty when there was nothing it could take back.
  final List<String> changes;
  final List<UndoSkip> skipped;

  bool get isEmpty => changes.isEmpty;
}

enum GapKind {
  /// An event with a ride leg that has no driver.
  noDriver,

  /// Two timed events that name the same person overlap.
  overlap,

  /// A chore due today that nobody owns and nobody has done.
  unowned,

  /// One driver with two rides at once, from different places ([Den.rideGap]).
  driverBusy,
}

class Gap {
  const Gap({required this.kind, required this.message, required this.occurrences, this.members = const [], this.leg});
  final GapKind kind;

  /// Written for people: "Nobody is driving Leo to soccer".
  final String message;
  final List<Occurrence> occurrences;
  final List<String> members;

  /// For [GapKind.noDriver], the ride leg with no driver: `to` or `from`.
  final String? leg;
}

class TodayView {
  const TodayView({
    required this.date,
    required this.events,
    required this.chores,
    required this.lists,
    required this.gaps,
  });
  final String date;
  final List<Occurrence> events;
  final List<ChoreDay> chores;

  /// Pinned lists, dated lists due today, and lists linked to today's events.
  final List<ListState> lists;
  final List<Gap> gaps;
}

/// The family-columns week: a row per day, a column per person.
class WeekGrid {
  const WeekGrid({required this.days, required this.people, required this.cells, required this.everyone});

  /// Local dates, in order.
  final List<String> days;
  final List<Member> people;

  /// (date, memberId) -> that person's occurrences and chores that day.
  final Map<(String, String), WeekCell> cells;

  /// date -> occurrences for everyone (no assignees, or every member assigned).
  final Map<String, List<Occurrence>> everyone;
}

class WeekCell {
  const WeekCell(this.events, this.chores);
  final List<Occurrence> events;
  final List<ChoreDay> chores;
}

class SearchHit {
  const SearchHit({required this.type, required this.id, required this.title, this.detail, this.when});
  final String type;
  final String id;
  final String title;
  final String? detail;
  final int? when;
}

/// Result of [Den.ingest].
class IngestResult {
  const IngestResult({
    required this.added,
    required this.duplicate,
    required this.invalid,
    this.rejected = const {},
    this.pending = 0,
  });

  /// Changes newly stored, valid or not.
  final int added;
  final int duplicate;

  /// Changes kept in the log but not applied, with the reason.
  final Map<String, String> invalid;

  /// Changes refused outright and not stored, with the reason: a signature that doesn't verify.
  /// A forged copy is never stored, so it can't shadow the genuine change with the same id.
  final Map<String, String> rejected;

  /// Changes held back until the record of the device that signed them arrives.
  final int pending;
}
