import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';
import 'package:den_core/time.dart';

import 'draft.dart';
import 'lexicon.dart';

/// Issues that come from the family as it is now, recomputed on every check; resolution's own
/// (a missing day, an unknown name, a guess) stay until someone edits that part.
const Set<IssueKind> _checked = {IssueKind.notAllowed, IssueKind.invalid, IssueKind.duplicate, IssueKind.past};

/// Checks each entry of [draft] the way the engine will when it's written: whether the acting
/// member may add it, whether its fields pass den_core's schema, whether it's over, and
/// whether the calendar or list already has it. Nothing is written.
CaptureDraft checkDraft(Den den, CaptureDraft draft) {
  final zone = den.family?.timezone ?? 'UTC';
  final today = den.todayDate();
  final seen = <String>{};
  return draft.withEntries([
    for (final e in draft.entries)
      e.withIssues([
        ...e.issues.where((i) => !_checked.contains(i.kind)),
        ..._issues(den, e, draft.origin, zone, today, seen),
      ]),
  ]);
}

/// UTC start and end of an event draft in [zone].
(int, int) eventSpan(DraftEvent e, String zone) {
  if (e.allDay) return (dayStartIn(zone, e.date), dayStartIn(zone, addDays(e.endDate ?? e.date, 1)));
  final start = dateTimeIn(zone, e.date, e.start!);
  final endTime = e.end ?? e.start!;
  var end = dateTimeIn(zone, e.endDate ?? e.date, endTime);
  if (end <= start) end = start + const Duration(hours: 1).inMilliseconds;
  return (start, end);
}

/// The fields the engine writes for [e], for checking against den_core's schema.
Map<String, Object?> eventFields(DraftEvent e, String zone, CaptureOrigin origin) {
  final (start, end) = eventSpan(e, zone);
  return {
    'title': e.title,
    'notes': e.notes,
    'location': e.location,
    'category': e.category,
    'start': start,
    'end': end,
    'allDay': e.allDay,
    'tz': zone,
    'rrule': e.rrule,
    'assignees': e.people,
    'reminders': e.reminders,
    'source': {'kind': 'manual'},
    'rides': const <Object>[],
    'countdown': false,
    '_from': origin.toJson(),
  };
}

/// A reminder is written as a one-day chore with a reminder at its time.
DraftChore reminderChore(DraftReminder r) => DraftChore(
      key: r.key,
      title: r.text,
      owner: r.person == null ? const OwnerAnyone() : OwnerMember(r.person!),
      date: r.date,
      dueTime: r.time,
      icon: choreIcon(r.text),
      reminders: r.time == null ? const [] : const [0],
    );

Map<String, Object?> choreFields(DraftChore e, CaptureOrigin origin) => {
      'title': e.title,
      'notes': '',
      'icon': e.icon,
      'owner': e.owner.toJson(),
      'schedule': e.schedule.toJson(),
      'dueTime': e.dueTime,
      'points': e.points,
      'steps': const <Object>[],
      'reminders': e.reminders,
      'active': true,
      '_from': origin.toJson(),
    };

Map<String, Object?> itemFields(DraftItem e, CaptureOrigin origin) => {
      'list': e.listId ?? 'new',
      'text': e.text,
      'qty': e.qty,
      'store': e.store,
      'checked': false,
      'checkedBy': null,
      'order': 'm',
      'toGroceries': false,
      '_from': origin.toJson(),
    };

Map<String, Object?> listFields(NewList l, CaptureOrigin origin) => {
      'title': l.title,
      'icon': l.kind.name,
      'kind': l.kind.name,
      'lifecycle': ListLifecycle.running.name,
      'needBy': null,
      'event': null,
      'pinned': l.pinned,
      'order': 'm',
      '_from': origin.toJson(),
    };

List<DraftIssue> _issues(Den den, DraftEntry e, CaptureOrigin origin, String zone, String today, Set<String> seen) {
  final out = <DraftIssue>[];
  final actor = den.actor;
  if (actor == null) {
    // Nobody acting: a shared screen nobody signed in on, or a hub with no person to act for
    // (an API or MCP connection acts as its person, so this is one that acts for nobody).
    out.add(DraftIssue(
      IssueKind.notAllowed,
      den.thisDevice?.mode == DeviceMode.hub
          ? 'Nobody is acting through the hub, so nothing can be added; a parent chooses who a connection acts as'
          : 'Sign in on this screen to add things',
    ));
  } else if (!can(actor, e.needs)) {
    final what = switch (e) {
      DraftEvent() => 'events',
      DraftChore() => 'chores',
      DraftItem() => 'to lists',
      DraftReminder() => 'reminders',
    };
    out.add(DraftIssue(IssueKind.notAllowed, '${actor.name} can\'t add $what'));
  }

  String? schema;
  switch (e) {
    case DraftEvent():
      schema = checkFields(RecordType.event, eventFields(e, zone, origin), creating: true);
      if (schema == null) {
        final missing = e.people.where((id) => den.member(id) == null);
        if (missing.isNotEmpty) schema = 'Someone it\'s for isn\'t in the family any more';
      }
      final over = e.rrule == null
          ? (e.endDate ?? e.date).compareTo(today) < 0
          : _ruleOver(e.rrule!, today);
      if (over && !e.issues.any((i) => i.kind == IssueKind.needsDay)) {
        out.add(const DraftIssue(IssueKind.past, 'This is already over'));
      }
      if (schema == null) {
        final (start, end) = eventSpan(e, zone);
        final title = e.title.toLowerCase();
        final there = den.occurrences(start, end).any((o) => o.start == start && o.title.toLowerCase() == title);
        if (there) out.add(const DraftIssue(IssueKind.duplicate, 'Already on the calendar'));
        if (!seen.add('event|$title|$start')) out.add(const DraftIssue(IssueKind.duplicate, 'Listed twice'));
      }
    case DraftChore():
      schema = _choreIssues(den, e, origin, today, seen, out);
    case DraftReminder():
      schema = _choreIssues(den, reminderChore(e), origin, today, seen, out);
    case DraftItem():
      if (e.newList != null) schema = checkFields(RecordType.list, listFields(e.newList!, origin), creating: true);
      schema ??= checkFields(RecordType.item, itemFields(e, origin), creating: true);
      if (schema == null && e.listId != null) {
        final list = den.list(e.listId!);
        if (list == null) {
          schema = 'That list was removed';
        } else {
          final text = e.text.toLowerCase();
          if (list.items.any((i) => !i.checked && i.text.toLowerCase() == text)) {
            out.add(DraftIssue(IssueKind.duplicate, 'Already on ${list.list.title}'));
          }
        }
      }
      final where = e.listId ?? 'new:${e.newList?.title.toLowerCase()}';
      if (!seen.add('item|$where|${e.text.toLowerCase()}')) out.add(const DraftIssue(IssueKind.duplicate, 'Listed twice'));
  }
  if (schema != null) out.add(DraftIssue(IssueKind.invalid, schema));
  return out;
}

String? _choreIssues(Den den, DraftChore e, CaptureOrigin origin, String today, Set<String> seen, List<DraftIssue> out) {
  var schema = checkFields(RecordType.chore, choreFields(e, origin), creating: true);
  final owner = e.owner;
  final ids = switch (owner) {
    OwnerMember(:final id) => [id],
    OwnerRotation(:final ids) => ids,
    OwnerAnyone() => const <String>[],
  };
  if (schema == null && ids.any((id) => den.member(id) == null)) schema = 'Someone it\'s for isn\'t in the family any more';
  if (e.rrule == null ? e.date.compareTo(today) < 0 : _ruleOver(e.rrule!, today)) {
    out.add(const DraftIssue(IssueKind.past, 'This was due already'));
  }
  final title = e.title.toLowerCase();
  final ownerKey = owner.toJson().toString();
  final there = den.chores.firstWhereOrNull(
    (c) =>
        c.active &&
        c.title.toLowerCase() == title &&
        c.owner.toJson().toString() == ownerKey &&
        (e.rrule != null || c.schedule.once == e.date),
  );
  if (there != null) out.add(const DraftIssue(IssueKind.duplicate, 'Already a chore'));
  if (!seen.add('chore|$title|$ownerKey|${e.date}')) out.add(const DraftIssue(IssueKind.duplicate, 'Listed twice'));
  return schema;
}

bool _ruleOver(String rrule, String today) {
  if (!RecurrenceRule.isValid(rrule)) return false;
  final until = RecurrenceRule.parse(rrule).until;
  return until != null && until.isBefore(DateTime.parse('${today}T00:00:00Z'));
}
