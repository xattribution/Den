import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/app_state.dart';
import '../../../design/widgets.dart';
import '../state/chore_actions.dart';

/// "Give Dishes to…": the people picker, then the chore is that person's (or anyone's) for
/// that day only. Completes with what it did ("Dishes is Leo's today"), or null when nothing
/// changed.
Future<Done?> giveChore(BuildContext context, ChoreDay day) async {
  final app = DenScope.read(context);
  final people = app.den.members.where((m) => m.role != Role.guest).toList();
  final pick = await showPeoplePicker(
    context,
    title: 'Give ${day.chore.title} to',
    people: people,
    current: day.owner,
    anyoneLabel: 'Anyone',
    anyoneCurrent: day.owner == null,
  );
  if (pick == null || !context.mounted) return null;
  final to = pick.anyone ? null : pick.member;
  if (to == day.owner) return null;
  final result = await perform(context, () => context.choreActions.swap(day, to));
  if (result == null) return null;
  final when = day.date == app.today ? 'today' : 'on ${app.formats.short(day.date)}';
  final title = day.chore.title;
  return (
    message: to == null ? 'Anyone can do $title $when' : '$title is ${app.memberById(to)?.name ?? 'theirs'}\'s $when',
    receipt: result.receipt,
  );
}
