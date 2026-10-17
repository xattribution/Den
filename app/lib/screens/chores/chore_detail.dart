import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/home_form.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'chore_words.dart';
import 'swap_sheet.dart';
import '../../design/parts/home_pictograms.dart';

/// One chore on one day: who has it and why, its steps to check, how it repeats, and what
/// happened on recent days. `/chore/:id?date=`.
class ChoreDetailScreen extends StatelessWidget {
  const ChoreDetailScreen({super.key, required this.id, this.date});

  final String id;
  final String? date;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final chore = den.chore(id);
    if (chore == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyLine(
          message: 'This chore was deleted, or it isn\'t shared with you.',
          actionLabel: 'Go to chores',
          onAction: () => context.go('/chores'),
        ),
      );
    }

    final f = app.formats;
    final c = context.colors;
    final today = app.today;
    final day = date ?? today;
    final cd = den.choresOn(day).where((d) => d.chore.id == id).firstOrNull;
    final spec = ScheduleSpec.fromSchedule(chore.schedule, today: today);
    final pointsOn = den.family?.pointsEnabled ?? true;
    final canEdit = app.allows(DenAction.editChores);

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (canEdit)
            Padding(
              padding: const EdgeInsets.only(right: Sp.s),
              child: TextButton.icon(
                onPressed: () => context.push('/chore/$id/edit'),
                icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 18),
                label: const Text('Edit chore'),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xxxl),
        children: [
          FormWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(chore: chore, day: cd, date: day),
                if (cd == null)
                  _NotScheduled(choreId: id, date: day)
                else ...[
                  if (cd.late && !cd.done)
                    Padding(
                      padding: const EdgeInsets.only(top: Sp.m),
                      child: AttentionLine(
                        bad: true,
                        message: cd.date != day
                            ? 'Late. It was due ${f.short(cd.date)}.'
                            : chore.dueTime != null
                            ? 'Late. It was due by ${clockWords(chore.dueTime!)}.'
                            : 'Late.',
                      ),
                    ),
                  if (chore.steps.isEmpty) _MainCheck(day: cd) else _Steps(day: cd),
                ],
                const SizedBox(height: Sp.l),
                Divider(color: c.rule),
                const SizedBox(height: Sp.s),
                _Fact('Repeats', Text(spec.words(f), style: context.type.body(c.ink))),
                _Fact(
                  'Due',
                  Text(
                    chore.dueTime == null ? 'Any time that day' : 'By ${clockWords(chore.dueTime!)}',
                    style: context.type.body(c.ink),
                  ),
                ),
                if (pointsOn) _Fact('Points', _PointsWords(chore)),
                if (chore.reminders.isNotEmpty && chore.dueTime != null)
                  _Fact(
                    'Reminders',
                    Text(chore.reminders.map(reminderWords).join(', '), style: context.type.body(c.ink)),
                  ),
                _Fact('Who sees it', Text(_audienceWords(app, chore), style: context.type.body(c.ink))),
                if (chore.notes.isNotEmpty) _Fact('Notes', Text(chore.notes, style: context.type.body(c.ink))),
                if (cd != null && canSwap(app, cd)) ...[
                  const SizedBox(height: Sp.l),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () => showSwapSheet(context, cd),
                      icon: const Icon(PhosphorIconsRegular.arrowsLeftRight, size: 18),
                      label: Text(day == today ? 'Swap for today' : 'Swap for ${f.short(day)}'),
                    ),
                  ),
                ],
                _Recent(choreId: id, before: day),
                if (canEdit) ...[
                  const SizedBox(height: Sp.xl),
                  DestructiveButton(label: 'Delete chore', onPressed: () => _delete(context, chore)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _audienceWords(AppState app, Chore chore) {
    final owner = Space.memberOf(chore.space);
    if (owner == null) return chore.audience == Audience.parents ? 'Parents' : 'Everyone';
    if (owner == app.me?.id) return 'Just me';
    return 'Only ${app.den.member(owner)?.name ?? 'one person'}';
  }

  Future<void> _delete(BuildContext context, Chore chore) async {
    final den = context.den;
    final keep = Navigator.of(context, rootNavigator: true).context;
    final ok = await attempt(context, () => den.deleteChore(chore.id));
    if (!ok || !context.mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/chores');
    }
    if (!keep.mounted) return;
    showUndo(
      keep,
      '${chore.title} deleted',
      () => attempt(
        keep,
        () => den.addChore(
          title: chore.title,
          owner: chore.owner,
          schedule: chore.schedule,
          icon: chore.icon,
          notes: chore.notes,
          dueTime: chore.dueTime,
          points: chore.points,
          steps: chore.steps,
          reminders: chore.reminders,
          audience: chore.audience,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.chore, required this.day, required this.date});
  final Chore chore;
  final ChoreDay? day;
  final String date;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final f = app.formats;
    final c = context.colors;
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
      note = 'Swapped from $usualName for ${date == today ? 'today' : f.short(date)}';
    } else if (chore.owner case final OwnerRotation r) {
      note = rotationWords(r, date, today, f, (id) => den.member(id)?.name ?? 'someone', weekStart: weekStart);
    }

    return Padding(
      padding: const EdgeInsets.only(top: Sp.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ChoreGlyph(chore.icon, size: 40, color: c.ink),
          ),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(header: true, child: Text(chore.title, style: context.type.heading(c.ink))),
                const SizedBox(height: Sp.s),
                Row(
                  children: [
                    if (owner != null) DenAvatar(owner, size: 24) else const AnyoneMark(size: 24),
                    const SizedBox(width: Sp.s),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: owner?.name ?? 'Anyone', style: context.type.bodyStrong(c.ink)),
                            TextSpan(
                              text: day == null
                                  ? (owner == null ? ' can do it' : '')
                                  : (owner == null ? ' can do it $when' : ' $when'),
                              style: context.type.body(c.ink),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Sp.xs),
                    child: Text(note, style: context.type.meta(c.ink2)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

bool _canCheckFor(AppState app, String? owner) {
  final mine = owner == null || owner == app.me?.id;
  return app.allows(mine ? DenAction.completeOwnChore : DenAction.completeAnyChore);
}

/// The fridge chart's box for a chore without steps, large, with who did it.
class _MainCheck extends StatelessWidget {
  const _MainCheck({required this.day});
  final ChoreDay day;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final can = _canCheckFor(app, day.owner);
    final by = app.memberById(day.doneBy);
    void toggle() => attempt(context, () => app.den.setChoreDone(day.chore.id, day.date, !day.done));
    return Padding(
      padding: const EdgeInsets.only(top: Sp.m),
      child: Hang(
        by: (Targets.adult - 32) / 2,
        child: InkWell(
          onTap: can ? toggle : null,
          borderRadius: BorderRadius.circular(Radii.control),
          child: Row(
            children: [
              CheckDot(done: day.done, size: 32, label: day.chore.title, onChanged: can ? (_) => toggle() : null),
              const SizedBox(width: Sp.xs),
              Expanded(
                child: Text(
                  day.done ? (by == null ? 'Done' : 'Done by ${by.name}') : (can ? 'Mark done' : 'Not done yet'),
                  style: day.done ? context.type.bodyStrong(c.ink) : context.type.body(can ? c.ink : c.ink2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.day});
  final ChoreDay day;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final steps = day.chore.steps;
    final pointsOn = app.den.family?.pointsEnabled ?? true;
    final by = app.memberById(day.doneBy);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(
          'Steps',
          top: Sp.l,
          trailing: Text(
            day.done ? (by == null ? 'All done' : 'Done by ${by.name}') : '${day.stepsDone} of ${day.stepCount} done',
            style: context.type.meta(c.ink2),
          ),
        ),
        for (final step in steps)
          Builder(
            builder: (context) {
              final checkedBy = day.steps[step.id];
              final checked = checkedBy != null;
              final owner = app.memberById(step.owner);
              final can = _canCheckFor(app, step.owner ?? day.owner);
              void toggle() => attempt(context, () => app.den.setStep(day.chore.id, day.date, step.id, !checked));
              return Hang(
                by: (Targets.adult - 26) / 2,
                child: InkWell(
                  onTap: can ? toggle : null,
                  child: Row(
                    children: [
                      CheckDot(done: checked, label: step.text, onChanged: can ? (_) => toggle() : null),
                      Expanded(
                        child: Text(
                          step.text,
                          style: context.type
                              .body(checked ? c.ink2 : c.ink)
                              .copyWith(
                                decoration: checked ? TextDecoration.lineThrough : null,
                                decorationColor: c.ink2,
                              ),
                        ),
                      ),
                      if (owner != null) ...[const SizedBox(width: Sp.s), DenAvatar(owner, size: 24)],
                      if (pointsOn && step.points > 0) ...[const SizedBox(width: Sp.s), StarCount(step.points)],
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _NotScheduled extends StatelessWidget {
  const _NotScheduled({required this.choreId, required this.date});
  final String choreId;
  final String date;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    String? next;
    for (var i = 1; i <= 62; i++) {
      final d = f.addDays(date, i);
      if (app.den.choresOn(d).any((x) => x.chore.id == choreId && x.date == d)) {
        next = d;
        break;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            date == app.today ? 'Not on today\'s chart.' : 'Not on the chart for ${f.short(date)}.',
            style: context.type.body(c.ink2),
          ),
          if (next != null) ...[
            const SizedBox(height: Sp.s),
            OutlinedButton(
              onPressed: () => context.replace('/chore/$choreId?date=$next'),
              child: Text('Show ${f.relative(next, app.today)}'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.s - 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(label, style: context.type.meta(c.ink2)),
              ),
            ),
            Expanded(child: value),
          ],
        ),
      ),
    );
  }
}

class _PointsWords extends StatelessWidget {
  const _PointsWords(this.chore);
  final Chore chore;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stepPoints = chore.steps.fold(0, (n, s) => n + s.points);
    final style = context.type.body(c.ink);
    if (chore.points == 0 && stepPoints == 0) return Text('None', style: style);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Sp.xs,
      children: [
        if (chore.points > 0) StarCount(chore.points, style: style),
        if (chore.points > 0 && stepPoints > 0) Text('for the chore, plus', style: style),
        if (stepPoints > 0) ...[StarCount(stepPoints, style: style), Text('for steps', style: style)],
      ],
    );
  }
}

class _Recent extends StatelessWidget {
  const _Recent({required this.choreId, required this.before});
  final String choreId;
  final String before;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final recent = <ChoreDay>[];
    for (var i = 1; i <= 28 && recent.length < 5; i++) {
      final d = f.addDays(before, -i);
      final x = app.den.choresOn(d).where((e) => e.chore.id == choreId && e.date == d).firstOrNull;
      if (x != null) recent.add(x);
    }
    if (recent.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Recent days'),
        for (final d in recent)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s - 2),
            child: Row(
              children: [
                SizedBox(width: 108, child: Text(f.relative(d.date, app.today), style: context.type.meta(c.ink2))),
                if (d.done) ...[
                  Icon(PhosphorIconsBold.check, size: 16, color: c.ink),
                  const SizedBox(width: Sp.xs),
                  Expanded(
                    child: Text(
                      app.memberById(d.doneBy) == null ? 'Done' : 'Done by ${app.memberById(d.doneBy)!.name}',
                      style: context.type.body(c.ink),
                    ),
                  ),
                ] else
                  Expanded(
                    child: Text(
                      app.memberById(d.owner) == null ? 'Not done' : 'Not done (${app.memberById(d.owner)!.name})',
                      style: context.type.body(c.ink2),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
