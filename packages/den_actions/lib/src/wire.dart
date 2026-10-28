import 'package:den_core/den_core.dart';

import 'times.dart';

/// Turns den_core's views into the JSON every surface answers with (docs/hub-api.md, "Shared
/// objects"): snake_case keys, instants as ISO 8601 in the family's zone plus UTC milliseconds.
class Wire {
  /// Creates a serializer for [den]'s family.
  Wire(this.den) : zone = den.family?.timezone ?? 'UTC';

  /// The hub's engine.
  final Den den;

  /// The family's time zone.
  final String zone;

  /// `{<name>: ISO, <name>_ms: millis}`, both null for a null instant.
  Map<String, Object?> instant(String name, int? millis) => {
        name: millis == null ? null : isoIn(zone, millis),
        '${name}_ms': millis,
      };

  /// `everyone`, `parents` or `private`.
  static String audience(String space) => space == Space.family
      ? 'everyone'
      : space == Space.parents
          ? 'parents'
          : 'private';

  /// Space and audience fields.
  static Map<String, Object?> spaceFields(String space) => {'space': space, 'audience': audience(space)};

  /// The family object.
  Map<String, Object?>? family() {
    final f = den.family;
    if (f == null) return null;
    return {
      'id': f.id,
      'name': f.name,
      'timezone': f.timezone,
      'week_start': f.weekStart,
      'points_enabled': f.pointsEnabled,
    };
  }

  /// A member, without sign-in salts or hashes.
  static Map<String, Object?> member(Member m) => {
        'id': m.id,
        'name': m.name,
        'role': m.role.name,
        'tier': m.tier?.name,
        'marker': m.marker.name,
        'animal': m.animal.name,
        'birthday': m.birthday,
        'grants': [for (final g in Grant.values) if (m.grants.contains(g)) g.name],
        'order': m.order,
      };

  /// A category.
  static Map<String, Object?> category(EventCategory c) => {'id': c.id, 'name': c.name, 'icon': c.icon};

  /// The zone an event was written in (the family's when unset).
  String eventZone(Event e) {
    final tz = e.rec.fields['tz'];
    return tz is String && tz.isNotEmpty ? tz : zone;
  }

  Map<String, Object?> _rides(List<Ride> rides) => {
        'rides': [for (final r in rides) {'leg': r.leg, 'driver': r.driver}],
      };

  /// A series (or single event) as stored.
  Map<String, Object?> event(Event e) {
    final ez = eventZone(e);
    return {
      'id': e.id,
      'title': e.title,
      'notes': e.notes,
      'location': e.location,
      'category': e.category,
      'all_day': e.allDay,
      ...instant('start', e.start),
      ...instant('end', e.end),
      'start_date': e.allDay ? dateIn(ez, e.start) : null,
      'end_date': e.allDay ? dateIn(ez, e.end) : null,
      'tz': ez,
      'rrule': e.rrule,
      'assignees': e.assignees,
      'reminders': e.reminders,
      ..._rides(e.rides),
      'countdown': e.countdown,
      'source': {'kind': e.source.kind, 'label': e.source.label},
      'read_only': e.source.readOnly,
      ...spaceFields(e.space),
    };
  }

  /// The original start of an occurrence in its series, as edits address it.
  static int occurrenceKey(Occurrence o) {
    final x = o.exceptionId;
    if (x != null) {
      final at = int.tryParse(x.substring(x.lastIndexOf('@') + 1));
      if (at != null) return at;
    }
    return o.seriesStart;
  }

  /// `"<event_id>@<occurrence>"`.
  static String uidOf(Occurrence o) => '${o.event.id}@${occurrenceKey(o)}';

  /// One occurrence in a window, exceptions applied.
  Map<String, Object?> occurrence(Occurrence o) {
    final e = o.event;
    final ez = eventZone(e);
    final key = occurrenceKey(o);
    return {
      'uid': '${e.id}@$key',
      'event_id': e.id,
      'occurrence': key,
      'recurring': e.rrule != null,
      'edited': o.exceptionId != null,
      'title': o.title,
      'notes': o.notes,
      'location': o.location,
      'category': o.category ?? e.category,
      'all_day': o.allDay,
      ...instant('start', o.start),
      ...instant('end', o.end),
      'start_date': o.allDay ? dateIn(ez, o.start) : null,
      'end_date': o.allDay ? dateIn(ez, o.end) : null,
      'tz': ez,
      'rrule': e.rrule,
      'assignees': o.assignees,
      'reminders': o.reminders,
      ..._rides(o.rides),
      'countdown': e.countdown,
      'source': {'kind': e.source.kind, 'label': e.source.label},
      'read_only': e.source.readOnly,
      ...spaceFields(e.space),
    };
  }

  /// Sorts occurrences by start, then title, then id.
  static void sortOccurrences(List<Occurrence> list) => list.sort((a, b) {
        if (a.start != b.start) return a.start.compareTo(b.start);
        final t = a.title.compareTo(b.title);
        if (t != 0) return t;
        return uidOf(a).compareTo(uidOf(b));
      });

  /// A chore as it stands on one date.
  Map<String, Object?> choreDay(ChoreDay cd) {
    final c = cd.chore;
    final due = c.dueTime;
    final dueAt = due != null && isClockTime(due)
        ? utcOfWall(zone, wallOfDate(cd.date).add(Duration(hours: int.parse(due.substring(0, 2)), minutes: int.parse(due.substring(3)))))
        : null;
    final steps = [
      for (final s in c.steps)
        {
          'id': s.id,
          'text': s.text,
          'owner': s.owner,
          'points': s.points,
          'checked': cd.steps[s.id] != null,
          'checked_by': (cd.steps[s.id]?.isEmpty ?? true) ? null : cd.steps[s.id],
        },
    ];
    return {
      'id': c.id,
      'completion_id': '${c.id}@${cd.date}',
      'date': cd.date,
      'title': c.title,
      'notes': c.notes,
      'icon': c.icon,
      'owner': cd.owner,
      'owner_rule': c.owner.toJson(),
      'swapped': cd.swapped,
      'schedule': c.schedule.toJson(),
      'recurring': c.schedule.rrule != null,
      'due_time': due,
      ...instant('due', dueAt),
      'done': cd.done,
      'done_by': cd.doneBy,
      'late': cd.late,
      'points': c.points,
      'points_available': cd.pointsAvailable,
      'steps': steps,
      'steps_done': cd.stepsDone,
      'step_count': cd.stepCount,
      ...spaceFields(c.space),
    };
  }

  /// Sorts chore days by due time (chores without one last), then title, then id.
  static void sortChores(List<ChoreDay> list) => list.sort((a, b) {
        final da = a.chore.dueTime ?? '99:99', db = b.chore.dueTime ?? '99:99';
        if (da != db) return da.compareTo(db);
        final t = a.chore.title.compareTo(b.chore.title);
        if (t != 0) return t;
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : a.chore.id.compareTo(b.chore.id);
      });

  /// The `summary` of a chores response.
  static Map<String, Object?> choreSummary(List<ChoreDay> chores) {
    Map<String, int> count(Iterable<ChoreDay> list) {
      final total = list.length, done = list.where((c) => c.done).length;
      return {'total': total, 'done': done, 'left': total - done};
    }

    final byMember = <String, List<ChoreDay>>{};
    for (final c in chores) {
      if (c.owner != null) (byMember[c.owner!] ??= []).add(c);
    }
    return {
      ...count(chores),
      'anyone': count(chores.where((c) => c.owner == null)),
      'by_member': {for (final e in byMember.entries) e.key: count(e.value)},
    };
  }

  /// An item on a list.
  static Map<String, Object?> item(Item i) => {
        'id': i.id,
        'list': i.list,
        'text': i.text,
        'qty': i.qty,
        'store': i.store,
        'checked': i.checked,
        'checked_by': i.checkedBy,
        'order': i.order,
        'to_groceries': i.toGroceries,
      };

  /// A list with its items.
  static Map<String, Object?> list(ListState l) => {
        'id': l.list.id,
        'title': l.list.title,
        'icon': l.list.icon,
        'kind': l.list.kind.name,
        'lifecycle': l.list.lifecycle.name,
        'need_by': l.list.needBy,
        'event': l.list.event,
        'pinned': l.list.pinned,
        'order': l.list.order,
        ...spaceFields(l.list.space),
        'open': l.open,
        'open_by_store': l.openByStore,
        'items': [for (final i in l.items) item(i)],
      };

  /// A gap on the Today screen.
  Map<String, Object?> gap(Gap g) => {
        'kind': switch (g.kind) {
          GapKind.noDriver => 'no_driver',
          GapKind.overlap => 'overlap',
          GapKind.unowned => 'unowned',
        },
        'message': g.message,
        'occurrences': [for (final o in g.occurrences) uidOf(o)],
        'members': g.members,
      };

  /// A reward.
  static Map<String, Object?> reward(Reward r) => {
        'id': r.id,
        'title': r.title,
        'cost': r.cost,
        'icon': r.icon,
        'needs_approval': r.needsApproval,
        'active': r.active,
      };

  /// A redemption request.
  Map<String, Object?> redemption(Redemption r) => {
        'id': r.id,
        'reward': r.reward,
        'member': r.member,
        'cost': r.cost,
        'status': r.status.name,
        ...instant('requested', r.rec.created.millis),
      };

  /// A goal with its standings.
  Map<String, Object?> goal(GoalStanding g) => {
        'id': g.goal.id,
        'title': g.goal.title,
        'mode': g.goal.mode.name,
        'target': g.goal.target,
        'members': g.goal.members,
        'start': g.goal.start,
        'end': g.goal.end,
        'repeat': g.goal.repeat.name,
        'reward': g.goal.reward,
        'window_start': g.windowStart,
        'window_end': g.windowEnd,
        'winner': g.goal.mode == GoalMode.race ? g.winner : null,
        'standings': [
          for (final s in g.standings) {'member': s.member, 'earned': s.earned, ...instant('reached', s.reachedAt)},
        ],
      };

  /// The points summary.
  Map<String, Object?> points(PointsSummary p, {int recent = 50}) {
    final totals = {for (final m in den.members) m.id: p.totals[m.id] ?? 0};
    return {
      'enabled': den.family?.pointsEnabled ?? true,
      'totals': totals,
      'goals': [for (final g in p.goals) goal(g)],
      'recent': [
        for (final l in p.recent.take(recent))
          {
            'member': l.member,
            'delta': l.delta,
            'reason': l.reason,
            'source': l.source.name,
            'ref': l.ref,
            ...instant('when', l.when),
          },
      ],
      'rewards': [for (final r in p.rewards) reward(r)],
      'pending': [for (final r in p.pending) redemption(r)],
    };
  }

  /// One history entry.
  Map<String, Object?> history(HistoryEntry h) => {
        ...instant('when', h.when.millis),
        'hlc': h.when.toString(),
        'actor': h.actor,
        'actor_name': h.actorName,
        'device': h.device,
        'device_name': h.deviceName,
        'via': h.via,
        'type': h.type,
        'rid': h.rid,
        'title': h.title,
        'verb': h.verb,
        'space': h.space,
        'diffs': [for (final d in h.diffs) {'field': d.field, 'before': d.before, 'after': d.after}],
      };

  /// One search result.
  Map<String, Object?> searchHit(SearchHit s) => {
        'type': s.type,
        'id': s.id,
        'title': s.title,
        'detail': s.detail,
        ...instant('when', s.when),
      };

}
