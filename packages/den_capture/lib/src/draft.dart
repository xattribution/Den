import 'package:den_core/den_core.dart';

/// Something a person should look at before an entry is added.
enum IssueKind {
  /// No day could be read; someone has to choose one.
  needsDay,

  /// A name nobody in the family has.
  unknownPerson,

  /// Already on the calendar or the list.
  duplicate,

  /// It's in the past.
  past,

  /// The person sharing can't add this kind of thing.
  notAllowed,

  /// It fails the record's schema.
  invalid,

  /// A detail Den guessed, such as a time with no AM or PM.
  guessed,
}

class DraftIssue {
  const DraftIssue(this.kind, this.message);
  final IssueKind kind;

  /// Written for people: "No one in the family is called Coach Dan".
  final String message;

  /// Whether the entry can't be added until someone fixes it.
  bool get blocking => kind == IssueKind.needsDay || kind == IssueKind.notAllowed || kind == IssueKind.invalid;

  /// Whether the entry waits for a person instead of being added directly, and starts
  /// unchosen in review.
  bool get holds => blocking || kind == IssueKind.duplicate || kind == IssueKind.past || kind == IssueKind.unknownPerson;

  @override
  bool operator ==(Object other) => other is DraftIssue && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => '${kind.name}: $message';
}

const Object _keep = Object();

/// One proposed thing to add. Dates are local (`YYYY-MM-DD`) in the family's zone; times are
/// `HH:mm`.
sealed class DraftEntry {
  const DraftEntry({required this.key, this.issues = const []});

  /// Stable within its draft, for editing and choosing in review.
  final String key;
  final List<DraftIssue> issues;

  /// The title, item text or reminder, as review shows it.
  String get title;

  /// What the person sharing must be allowed to do to add it.
  DenAction get needs;

  bool get blocked => issues.any((i) => i.blocking);

  /// Whether it can be added without anyone looking first.
  bool get ready => !issues.any((i) => i.holds);

  DraftEntry withIssues(List<DraftIssue> issues);
}

class DraftEvent extends DraftEntry {
  const DraftEvent({
    required super.key,
    required this.title,
    required this.date,
    this.start,
    this.end,
    this.endDate,
    this.rrule,
    this.people = const [],
    this.location = '',
    this.notes = '',
    this.category,
    this.reminders = const [],
    super.issues,
  });

  @override
  final String title;
  final String date;

  /// Null for an all-day event.
  final String? start;
  final String? end;

  /// The last day of an event over several days (all day, or ending on a later day).
  final String? endDate;

  /// RFC 5545 RRULE without DTSTART, as den_core stores it.
  final String? rrule;

  /// Member ids; empty means everyone.
  final List<String> people;
  final String location;
  final String notes;

  /// The family's category id.
  final String? category;

  /// Minutes before the start.
  final List<int> reminders;

  bool get allDay => start == null;

  @override
  DenAction get needs => DenAction.editEvents;

  DraftEvent copyWith({
    String? title,
    String? date,
    Object? start = _keep,
    Object? end = _keep,
    Object? endDate = _keep,
    Object? rrule = _keep,
    List<String>? people,
    String? location,
    String? notes,
    Object? category = _keep,
    List<int>? reminders,
    List<DraftIssue>? issues,
  }) =>
      DraftEvent(
        key: key,
        title: title ?? this.title,
        date: date ?? this.date,
        start: start == _keep ? this.start : start as String?,
        end: end == _keep ? this.end : end as String?,
        endDate: endDate == _keep ? this.endDate : endDate as String?,
        rrule: rrule == _keep ? this.rrule : rrule as String?,
        people: people ?? this.people,
        location: location ?? this.location,
        notes: notes ?? this.notes,
        category: category == _keep ? this.category : category as String?,
        reminders: reminders ?? this.reminders,
        issues: issues ?? this.issues,
      );

  @override
  DraftEvent withIssues(List<DraftIssue> issues) => copyWith(issues: issues);
}

class DraftChore extends DraftEntry {
  const DraftChore({
    required super.key,
    required this.title,
    required this.owner,
    required this.date,
    this.rrule,
    this.dueTime,
    this.points = 0,
    this.icon = 'check',
    this.reminders = const [],
    super.issues,
  });

  @override
  final String title;
  final ChoreOwner owner;

  /// The day it's due, or the first day of a repeating chore.
  final String date;
  final String? rrule;
  final String? dueTime;
  final int points;

  /// A chore pictogram key.
  final String icon;
  final List<int> reminders;

  ChoreSchedule get schedule => rrule == null ? ChoreSchedule.once(date) : ChoreSchedule.repeating(rrule!, date);

  @override
  DenAction get needs => DenAction.editChores;

  DraftChore copyWith({
    String? title,
    ChoreOwner? owner,
    String? date,
    Object? rrule = _keep,
    Object? dueTime = _keep,
    int? points,
    String? icon,
    List<int>? reminders,
    List<DraftIssue>? issues,
  }) =>
      DraftChore(
        key: key,
        title: title ?? this.title,
        owner: owner ?? this.owner,
        date: date ?? this.date,
        rrule: rrule == _keep ? this.rrule : rrule as String?,
        dueTime: dueTime == _keep ? this.dueTime : dueTime as String?,
        points: points ?? this.points,
        icon: icon ?? this.icon,
        reminders: reminders ?? this.reminders,
        issues: issues ?? this.issues,
      );

  @override
  DraftChore withIssues(List<DraftIssue> issues) => copyWith(issues: issues);
}

/// A list to make because an item names one the family doesn't have yet.
class NewList {
  const NewList(this.title, this.kind, {this.pinned = false});
  final String title;
  final ListKind kind;
  final bool pinned;

  @override
  bool operator ==(Object other) => other is NewList && other.title.toLowerCase() == title.toLowerCase();

  @override
  int get hashCode => title.toLowerCase().hashCode;
}

class DraftItem extends DraftEntry {
  const DraftItem({
    required super.key,
    required this.text,
    this.qty,
    this.store,
    this.listId,
    this.newList,
    super.issues,
  }) : assert(listId != null || newList != null);

  final String text;
  final String? qty;
  final String? store;

  /// The list it goes on, or null when it goes on [newList].
  final String? listId;
  final NewList? newList;

  @override
  String get title => text;

  @override
  DenAction get needs => DenAction.editLists;

  DraftItem copyWith({
    String? text,
    Object? qty = _keep,
    Object? store = _keep,
    Object? listId = _keep,
    Object? newList = _keep,
    List<DraftIssue>? issues,
  }) =>
      DraftItem(
        key: key,
        text: text ?? this.text,
        qty: qty == _keep ? this.qty : qty as String?,
        store: store == _keep ? this.store : store as String?,
        listId: listId == _keep ? this.listId : listId as String?,
        newList: newList == _keep ? this.newList : newList as NewList?,
        issues: issues ?? this.issues,
      );

  @override
  DraftItem withIssues(List<DraftIssue> issues) => copyWith(issues: issues);
}

/// "Remind me to send the permission slip on Thursday": added as a one-day chore for the person,
/// with a reminder at its time.
class DraftReminder extends DraftEntry {
  const DraftReminder({
    required super.key,
    required this.text,
    required this.date,
    this.time,
    this.person,
    super.issues,
  });

  final String text;
  final String date;
  final String? time;

  /// Who to remind; null means whoever is sharing (or anyone, on a shared screen).
  final String? person;

  @override
  String get title => text;

  @override
  DenAction get needs => DenAction.editChores;

  DraftReminder copyWith({
    String? text,
    String? date,
    Object? time = _keep,
    Object? person = _keep,
    List<DraftIssue>? issues,
  }) =>
      DraftReminder(
        key: key,
        text: text ?? this.text,
        date: date ?? this.date,
        time: time == _keep ? this.time : time as String?,
        person: person == _keep ? this.person : person as String?,
        issues: issues ?? this.issues,
      );

  @override
  DraftReminder withIssues(List<DraftIssue> issues) => copyWith(issues: issues);
}

/// Everything a reader found in one capture, resolved to the family and checked.
class CaptureDraft {
  const CaptureDraft({required this.origin, required this.entries, this.unclear = const []});

  /// What was read and who read it; recorded as `_from` on every change it makes.
  final CaptureOrigin origin;
  final List<DraftEntry> entries;

  /// Things the reader saw but couldn't place, said for people.
  final List<String> unclear;

  bool get isEmpty => entries.isEmpty;
  Iterable<DraftEvent> get events => entries.whereType<DraftEvent>();
  Iterable<DraftChore> get chores => entries.whereType<DraftChore>();
  Iterable<DraftItem> get items => entries.whereType<DraftItem>();
  Iterable<DraftReminder> get reminders => entries.whereType<DraftReminder>();

  DraftEntry? entry(String key) {
    for (final e in entries) {
      if (e.key == key) return e;
    }
    return null;
  }

  /// This draft with [entry] in place of the one with its key.
  CaptureDraft replace(DraftEntry entry) => CaptureDraft(
        origin: origin,
        entries: [for (final e in entries) e.key == entry.key ? entry : e],
        unclear: unclear,
      );

  CaptureDraft remove(String key) =>
      CaptureDraft(origin: origin, entries: [for (final e in entries) if (e.key != key) e], unclear: unclear);

  CaptureDraft withEntries(List<DraftEntry> entries) => CaptureDraft(origin: origin, entries: entries, unclear: unclear);
}
