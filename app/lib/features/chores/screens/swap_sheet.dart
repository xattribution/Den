import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../design/forms/fields.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';

/// Whether the actor may hand [day] to someone else: kids only their own chores.
bool canSwap(AppState app, ChoreDay day) {
  if (!app.allows(DenAction.swapChore)) return false;
  final me = app.me;
  if (me == null) return false;
  if (me.isKid || me.role == Role.guest) return day.owner == me.id;
  return true;
}

/// "Give Dishes to…": one tap hands the chore to a person, or to anyone, for that day only.
/// Undo gives it back.
Future<void> showSwapSheet(BuildContext context, ChoreDay day) {
  final app = context.app;
  final f = app.formats;
  final den = app.den;
  final people = den.members.where((m) => m.role != Role.guest).toList();
  final current = day.owner;
  final when = day.date == app.today ? 'today' : 'on ${f.short(day.date)}';
  final usual = switch (day.chore.owner) {
    OwnerMember(:final id) => den.member(id)?.name,
    OwnerRotation() => 'whoever is next in the rotation',
    OwnerAnyone() => 'anyone',
  };

  Future<void> give(BuildContext sheetContext, String? to) async {
    Navigator.of(sheetContext).pop();
    if (to == current) return;
    final ok = await attempt(context, () => den.swapForDay(day.chore.id, day.date, to));
    if (!ok || !context.mounted) return;
    final who = to == null
        ? 'Anyone can do ${day.chore.title} $when'
        : '${day.chore.title} is ${den.member(to)?.name ?? 'theirs'}\'s $when';
    showUndo(context, who, () => attempt(context, () => den.swapForDay(day.chore.id, day.date, current)));
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final c = sheetContext.colors;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Semantics(
                      header: true,
                      child: Text('Give ${day.chore.title} to…', style: sheetContext.type.title(c.ink)),
                    ),
                  ),
                  InfoTip(
                    day.date == app.today
                        ? 'Only for today. Tomorrow it goes back to ${usual ?? 'its usual owner'}.'
                        : 'Only for ${f.short(day.date)}. After that it goes back to ${usual ?? 'its usual owner'}.',
                  ),
                ],
              ),
              const SizedBox(height: Sp.m),
              Wrap(
                spacing: Sp.s,
                runSpacing: Sp.s,
                children: [
                  for (final m in people)
                    PersonChip(member: m, selected: m.id == current, onTap: () => give(sheetContext, m.id)),
                  AnyoneChip(selected: current == null, onTap: () => give(sheetContext, null)),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
