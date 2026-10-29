import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/words.dart';
import '../../../design/chore_pictograms.dart';
import '../../../design/forms/forms.dart' show AnyoneMark, DestructiveButton, FormWidth;
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/chore_actions.dart';
import '../state/chores_model.dart';
import '../widgets/give.dart';
import '../words/chore_words.dart';

/// One chore on one day: whose it is and why, the check or its steps, Give to… for the day
/// (with Undo in place), how it repeats and the rest of its facts, and its recent days.
/// `/chore/:id?date=`.
class ChoreDetailScreen extends StatefulWidget {
  const ChoreDetailScreen({super.key, required this.id, this.date});

  final String id;
  final String? date;

  @override
  State<ChoreDetailScreen> createState() => _ChoreDetailScreenState();
}

class _ChoreDetailScreenState extends State<ChoreDetailScreen> {
  Done? _given;

  Future<void> _give(ChoreDay day) async {
    final given = await giveChore(context, day);
    if (given != null && mounted) setState(() => _given = given);
  }

  Future<void> _undoGive(Receipt receipt) async {
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(() => _given = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final den = app.den;
    final chore = den.chore(widget.id);
    if (chore == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          message: 'This chore was deleted, or it isn\'t shared with you.',
          actionLabel: 'Go to chores',
          onAction: () => context.go('/chores'),
        ),
      );
    }

    final f = app.formats;
    final c = context.colors;
    final today = app.today;
    final day = widget.date ?? today;
    final cd = den.choresOn(day).where((d) => d.chore.id == widget.id).firstOrNull;
    final spec = ScheduleSpec.fromSchedule(chore.schedule, today: today);
    final pointsOn = den.family?.pointsEnabled ?? true;
    final canEdit = app.allows(DenAction.editChores);
    final given = _given;
    final owner = app.memberById(cd?.owner);
    final color = owner == null ? c.ink2 : c.marker(owner.marker);

    final stepPoints = chore.steps.fold(0, (n, s) => n + s.points);
    final pointsWords = chore.points == 0 && stepPoints == 0
        ? 'None'
        : [
            if (chore.points > 0) '${chore.points} ${chore.points == 1 ? 'star' : 'stars'}',
            if (stepPoints > 0) '$stepPoints for steps',
          ].join(', plus ');

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (canEdit)
            BarAction(
              quiet: true,
              child: TextButton.icon(
                onPressed: () => context.push('/chore/${widget.id}/edit'),
                icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 18),
                label: const Text('Edit'),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xxl),
        children: [
          FormWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(chore: chore, day: cd, date: day),
                const SizedBox(height: DenLayout.sectionGap),
                if (cd == null)
                  _NotScheduled(choreId: widget.id, date: day)
                else ...[
                  if (cd.late && !cd.done)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Sp.m),
                      child: NoticeLine(
                        icon: PhosphorIconsBold.clockCountdown,
                        message: cd.date != day
                            ? 'Late. It was due ${f.short(cd.date)}.'
                            : chore.dueTime != null
                                ? 'Late. It was due by ${clockWords(chore.dueTime!)}.'
                                : 'Late.',
                      ),
                    ),
                  if (chore.steps.isEmpty)
                    GroupCard(
                      padding: const EdgeInsets.fromLTRB(4, 0, 16, 0),
                      child: CheckRow(
                        label: cd.done
                            ? (app.memberById(cd.doneBy) == null ? 'Done' : 'Done by ${app.memberById(cd.doneBy)!.name}')
                            : canCheckChore(app, cd.owner)
                                ? 'Mark done'
                                : 'Not done yet',
                        color: color,
                        done: cd.done,
                        onCheck: canCheckChore(app, cd.owner)
                            ? () => attempt(context, () => context.choreActions.setDone(cd, !cd.done))
                            : null,
                      ),
                    )
                  else
                    _Steps(day: cd, color: color, pointsOn: pointsOn),
                  if (given != null || (canSwap(app, cd) && !cd.done)) ...[
                    const SizedBox(height: Sp.m),
                    DoneSwap(
                      done: given == null
                          ? null
                          : DoneRow(
                              message: given.message,
                              onUndo: given.receipt?.undoable == true ? () => _undoGive(given.receipt!) : null,
                            ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton.icon(
                          onPressed: () => _give(cd),
                          icon: const Icon(PhosphorIconsRegular.arrowsLeftRight, size: 18),
                          label: Text(day == today ? 'Give to… for today' : 'Give to… for ${f.short(day)}'),
                        ),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: DenLayout.sectionGap),
                DenSection(
                  title: 'About',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: ruled([
                      InfoRow.text(label: 'Repeats', value: spec.words(f)),
                      InfoRow.text(
                        label: 'Due',
                        value: chore.dueTime == null ? 'Any time that day' : 'By ${clockWords(chore.dueTime!)}',
                      ),
                      if (pointsOn) InfoRow.text(label: 'Stars', value: pointsWords),
                      if (chore.reminders.isNotEmpty && chore.dueTime != null)
                        InfoRow.text(label: 'Reminders', value: chore.reminders.map((m) => reminderWords(m, due: true)).join(', ')),
                      InfoRow.text(label: 'Who sees it', value: app.seenBy(chore.space)),
                      if (chore.notes.isNotEmpty) InfoRow.text(label: 'Notes', value: chore.notes),
                    ]),
                  ),
                ),
                _Recent(choreId: widget.id, before: day),
                if (canEdit) ...[
                  const SizedBox(height: DenLayout.sectionGap),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: DestructiveButton(label: 'Delete chore', onPressed: () => _delete(context, chore)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, Chore chore) async {
    final actions = context.actions;
    final keep = Navigator.of(context, rootNavigator: true).context;
    final result = await perform(context, () => context.choreActions.delete(chore));
    if (result == null || !context.mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/chores');
    }
    if (!keep.mounted) return;
    // The same chore comes back, with the days it was done and the stars they earned.
    offerUndo(keep, actions, '${chore.title} deleted', result);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.chore, required this.day, required this.date});
  final Chore chore;
  final ChoreDay? day;
  final String date;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final den = app.den;
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final today = app.today;
    final when = date == today ? 'today' : 'on ${f.short(date)}';
    final weekStart = den.family?.weekStart ?? 0;
    final onDate = day?.date ?? date;

    final usualId = switch (chore.owner) {
      OwnerMember(:final id) => id,
      OwnerRotation r when r.ids.isNotEmpty => r.ids[rotationIndex(r, onDate, weekStart)],
      _ => null,
    };
    // Not on the chart that day: say whose it usually is.
    final ownerId = day == null ? usualId : day!.owner;
    final owner = app.memberById(ownerId);
    final swapped = day != null && ownerId != usualId;
    final usualName = usualId == null ? 'anyone' : den.member(usualId)?.name ?? 'someone';

    String? note;
    if (swapped) {
      note = 'Done from $usualName for ${date == today ? 'today' : f.short(date)}';
    } else if (chore.owner case final OwnerRotation r) {
      note = rotationWords(r, date, today, f, (id) => den.member(id)?.name ?? 'someone', weekStart: weekStart);
    }
    final who = day == null
        ? (owner == null ? 'Anyone can do it' : 'Usually ${owner.name}\'s')
        : (owner == null ? 'Anyone can do it $when' : '${owner.name}\'s $when');

    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, DenLayout.headingInset, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: ChoreGlyph(chore.icon, size: 40, color: c.ink)),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(header: true, child: Text(tidy(chore.title), style: t.screenTitle(c.ink))),
                const SizedBox(height: Sp.s),
                Row(
                  children: [
                    if (owner != null) DenAvatar(owner, size: 26) else const AnyoneMark(size: 26),
                    const SizedBox(width: Sp.s),
                    Flexible(child: Text(who, style: t.body(c.ink))),
                  ],
                ),
                if (note != null) ...[
                  const SizedBox(height: Sp.xs),
                  Text(tidy(note), style: t.meta(c.ink2)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A chore's steps, each checked on its own; the last one completes the chore.
class _Steps extends StatelessWidget {
  const _Steps({required this.day, required this.color, required this.pointsOn});
  final ChoreDay day;
  final Color color;
  final bool pointsOn;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final by = app.memberById(day.doneBy);
    return DenSection(
      title: 'Steps',
      trailing: SectionCount(
        day.done ? (by == null ? 'All done' : 'Done by ${by.name}') : '${day.stepsDone} of ${day.stepCount} done',
      ),
      cardPadding: const EdgeInsets.fromLTRB(4, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: ruled([
          for (final step in day.chore.steps)
            CheckRow(
              label: step.text,
              color: color,
              done: day.steps[step.id] != null,
              detail: app.memberById(step.owner)?.name,
              stars: pointsOn && step.points > 0 ? step.points : null,
              onCheck: canCheckChore(app, step.owner ?? day.owner)
                  ? () => attempt(context, () => context.choreActions.setStep(day, step.id, day.steps[step.id] == null))
                  : null,
            ),
        ], indent: 54),
      ),
    );
  }
}

class _NotScheduled extends StatelessWidget {
  const _NotScheduled({required this.choreId, required this.date});
  final String choreId;
  final String date;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final f = app.formats;
    String? next;
    for (var i = 1; i <= 62; i++) {
      final d = f.addDays(date, i);
      if (app.den.choresOn(d).any((x) => x.chore.id == choreId && x.date == d)) {
        next = d;
        break;
      }
    }
    return GroupCard(
      child: EmptyState(
        compact: true,
        message: date == app.today ? 'Not on today\'s chart.' : 'Not on the chart for ${f.short(date)}.',
        actionLabel: next == null ? null : 'Show ${f.relative(next, app.today)}',
        onAction: next == null ? null : () => context.replace('/chore/$choreId?date=$next'),
      ),
    );
  }
}

/// The last few days the chore was on the chart, done or not, and by whom.
class _Recent extends StatelessWidget {
  const _Recent({required this.choreId, required this.before});
  final String choreId;
  final String before;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final recent = <ChoreDay>[];
    for (var i = 1; i <= 28 && recent.length < 5; i++) {
      final d = f.addDays(before, -i);
      final x = app.den.choresOn(d).where((e) => e.chore.id == choreId && e.date == d).firstOrNull;
      if (x != null) recent.add(x);
    }
    if (recent.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: DenLayout.sectionGap),
      child: DenSection(
        title: 'Recent days',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: ruled([
            for (final d in recent)
              InfoRow(
                label: f.relative(d.date, app.today),
                child: Row(
                  children: [
                    if (d.done) ...[
                      Icon(PhosphorIconsBold.check, size: 18, color: c.ink),
                      const SizedBox(width: Sp.s),
                    ],
                    Expanded(
                      child: Text(
                        d.done
                            ? (app.memberById(d.doneBy) == null ? 'Done' : 'Done by ${app.memberById(d.doneBy)!.name}')
                            : (app.memberById(d.owner) == null ? 'Not done' : 'Not done by ${app.memberById(d.owner)!.name}'),
                        style: t.body(d.done ? c.ink : c.ink2),
                      ),
                    ),
                  ],
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
