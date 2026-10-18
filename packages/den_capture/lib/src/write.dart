import 'package:den_core/den_core.dart';

import 'check.dart';
import 'draft.dart';

/// One record a capture added.
class Added {
  const Added(this.type, this.id, this.title, {this.key});
  final String type;
  final String id;
  final String title;

  /// The draft entry it came from; null for a list made to hold items.
  final String? key;
}

/// What writing a draft did: what it added, in order, and what it couldn't add and why.
class CaptureReceipt {
  const CaptureReceipt({required this.added, required this.failed});
  final List<Added> added;

  /// Entry key to the reason, for people.
  final Map<String, String> failed;

  Set<String> get keys => {for (final a in added) ?a.key};
  bool get isEmpty => added.isEmpty;

  /// Removes everything this capture added, newest first. Each removal is an ordinary change in
  /// History, and can itself be restored.
  Future<void> undo(Den den) async {
    for (final a in added.reversed) {
      try {
        switch (a.type) {
          case RecordType.event:
            await den.deleteEvent(a.id);
          case RecordType.chore:
            await den.deleteChore(a.id);
          case RecordType.item:
            await den.removeItem(a.id);
          case RecordType.list:
            await den.deleteList(a.id);
        }
      } on InvalidInput {
        // Already removed by someone else.
      }
    }
  }
}

/// Adds the entries of [draft] named by [keys] (by default, those [DraftEntry.ready] to add
/// without a look) through [den], as its acting member, each change carrying the draft's
/// origin as `_from`. Entries are checked first; one that is blocked, or that the engine
/// refuses, is reported in [CaptureReceipt.failed] and the rest are still added.
Future<CaptureReceipt> writeDraft(Den den, CaptureDraft draft, {Iterable<String>? keys}) async {
  final wanted = keys?.toSet();
  final chosen = draft.withEntries([
    for (final e in draft.entries)
      if (wanted == null ? e.ready : wanted.contains(e.key)) e,
  ]);
  final checked = checkDraft(den, chosen);
  final origin = draft.origin;
  final added = <Added>[];
  final failed = <String, String>{};
  final lists = <NewList, String>{};

  for (final e in checked.entries) {
    final blocking = e.issues.where((i) => i.blocking).firstOrNull;
    if (blocking != null) {
      failed[e.key] = blocking.message;
      continue;
    }
    try {
      switch (e) {
        case DraftEvent():
          final zone = den.family?.timezone ?? 'UTC';
          final (start, end) = eventSpan(e, zone);
          final id = await den.addEvent(
            title: e.title,
            start: start,
            end: end,
            allDay: e.allDay,
            tz: zone,
            rrule: e.rrule,
            assignees: e.people,
            category: e.category,
            location: e.location,
            notes: e.notes,
            reminders: e.reminders,
            from: origin,
          );
          added.add(Added(RecordType.event, id, e.title, key: e.key));
        case DraftChore():
          added.add(Added(RecordType.chore, await _addChore(den, e, origin), e.title, key: e.key));
        case DraftReminder():
          added.add(Added(RecordType.chore, await _addChore(den, reminderChore(e), origin), e.text, key: e.key));
        case DraftItem():
          var listId = e.listId;
          final make = e.newList;
          if (listId == null && make != null) {
            listId = lists[make];
            if (listId == null) {
              listId = await den.addList(
                title: make.title,
                kind: make.kind,
                icon: make.kind.name,
                pinned: make.pinned,
                from: origin,
              );
              lists[make] = listId;
              added.add(Added(RecordType.list, listId, make.title));
            }
          }
          final id = await den.addItem(listId!, text: e.text, qty: e.qty, store: e.store, from: origin);
          added.add(Added(RecordType.item, id, e.text, key: e.key));
      }
    } on PermissionDenied catch (x) {
      failed[e.key] = x.message;
    } on InvalidInput catch (x) {
      failed[e.key] = x.message;
    }
  }
  return CaptureReceipt(added: added, failed: failed);
}

Future<String> _addChore(Den den, DraftChore e, CaptureOrigin origin) => den.addChore(
      title: e.title,
      owner: e.owner,
      schedule: e.schedule,
      icon: e.icon,
      dueTime: e.dueTime,
      points: e.points,
      reminders: e.reminders,
      from: origin,
    );
