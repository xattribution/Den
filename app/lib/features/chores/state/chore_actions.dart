import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/actions.dart';
import '../../../app/den_scope.dart';
import '../../../app/family_reads.dart';

/// Whether whoever is acting may check off a chore that is [owner]'s that day (null: anyone's).
bool canCheckChore(FamilyReads app, String? owner) {
  final mine = owner == null || owner == app.me?.id;
  return app.allows(mine ? DenAction.completeOwnChore : DenAction.completeAnyChore);
}

/// Whether whoever is acting may hand [day] to someone else: kids only their own chores.
bool canSwap(FamilyReads app, ChoreDay day) {
  if (!app.allows(DenAction.swapChore)) return false;
  final me = app.me;
  if (me == null) return false;
  if (me.isKid || me.role == Role.guest) return day.owner == me.id;
  return true;
}

/// Every change the chores screens make (and Today, the wall and the kids' screens make to
/// chores), each one a den_actions action: the hub's API, MCP and the assistant offer the very
/// same verbs.
class ChoreActions {
  const ChoreActions(this._actions);

  final AppActions _actions;

  /// Marks [day]'s chore done or not, as whoever is using the device.
  Future<ActionResult> setDone(ChoreDay day, bool done) =>
      _actions.run('complete_chore', {'chore': day.chore.id, 'date': day.date, 'done': done});

  /// Checks or unchecks one of [day]'s steps; the last one completes the chore.
  Future<ActionResult> setStep(ChoreDay day, String stepId, bool done) =>
      _actions.run('complete_chore', {'chore': day.chore.id, 'date': day.date, 'step': stepId, 'done': done});

  /// Hands [day]'s chore to [to] (null: anyone) for that day only.
  Future<ActionResult> swap(ChoreDay day, String? to) =>
      _actions.run('swap_chore', {'chore': day.chore.id, 'date': day.date, 'to': to ?? 'anyone'});

  /// Removes [chore]; its receipt brings it back exactly, done days and all.
  Future<ActionResult> delete(Chore chore) => _actions.run('delete_chore', {'chore': chore.id});

  /// Adds a chore, or changes [existing]. [audience] is null when who sees it stays as it is.
  Future<ActionResult> save(
    Chore? existing, {
    required String title,
    required ChoreOwner owner,
    required ChoreSchedule schedule,
    required String icon,
    required String notes,
    required String? dueTime,
    required int points,
    required List<ChoreStep> steps,
    required List<int> reminders,
    Audience? audience,
  }) {
    final args = <String, Object?>{
      if (existing != null) 'chore': existing.id,
      'title': title,
      ...switch (owner) {
        OwnerMember(:final id) => {'owner': id},
        OwnerAnyone() => {'owner': 'anyone'},
        OwnerRotation(:final ids, :final every, :final anchor) => {
            'rotation': ids,
            'rotate_every': every,
            'rotation_start': anchor,
          },
      },
      if (schedule.once != null) 'once': schedule.once else ...{'repeat': schedule.rrule, 'start': schedule.start},
      // A pictogram another app stored stays as it is unless someone picks a new one.
      if (existing == null || icon != existing.icon) 'icon': icon,
      'notes': notes,
      'due_time': dueTime ?? '',
      'points': points,
      'steps': [
        for (final s in steps)
          {
            if (s.id.isNotEmpty) 'id': s.id,
            'text': s.text,
            'owner': s.owner,
            'points': s.points,
          },
      ],
      'reminders': reminders,
      if (audience != null) 'who_can_see': whoCanSee(audience),
    };
    return _actions.run(existing == null ? 'create_chore' : 'update_chore', args);
  }
}

extension ChoreActionsOf on BuildContext {
  /// The chores' actions. Reading them never rebuilds.
  ChoreActions get choreActions => ChoreActions(actions);
}
