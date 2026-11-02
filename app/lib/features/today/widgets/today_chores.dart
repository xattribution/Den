import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/words.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../chores/chores.dart';
import '../state/today_model.dart';
import '../words/today_words.dart';

/// Today's chores (Main.dc.html "Chores"). On a phone, a row per person: their face and a pill
/// per chore. Wider (PadToday), a row per chore with whose it is at the end ([rows]).
///
/// The ring checks a chore off; the name opens it in place: its steps to check, "Give to…" for
/// today, and Details. Stars show only while points are on.
class TodayChores extends StatefulWidget {
  const TodayChores({super.key, required this.chores, this.rows = false});

  final List<ChoreDay> chores;
  final bool rows;

  @override
  State<TodayChores> createState() => _TodayChoresState();
}

class _TodayChoresState extends State<TodayChores> {
  /// The chore open in place, as `id@date`.
  String? _open;

  /// What the last Give to… did, with Undo, under the chores.
  Done? _note;

  static String _key(ChoreDay d) => '${d.chore.id}@${d.date}';

  void _toggle(ChoreDay d) => setState(() => _open = _open == _key(d) ? null : _key(d));

  Future<void> _check(ChoreDay d) => attempt(context, () => context.choreActions.setDone(d, !d.done));

  Future<void> _give(ChoreDay d) async {
    final given = await giveChore(context, d);
    if (given == null || !mounted) return;
    setState(() {
      _open = null;
      _note = given;
    });
  }

  Future<void> _undo(Receipt receipt) async {
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(() => _note = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(todayReads);
    final c = context.colors;
    final days = widget.chores;
    final pointsOn = app.den.family?.pointsEnabled ?? true;

    CheckPill pill(ChoreDay d) => CheckPill(
          label: d.chore.title,
          color: _colorOf(app, c, d.owner),
          done: d.done,
          late: d.late,
          stars: pointsOn ? d.pointsAvailable : null,
          steps: d.stepCount > 0 ? (d.stepsDone, d.stepCount) : null,
          open: _open == _key(d),
          onCheck: canCheckChore(app, d.owner) ? () => _check(d) : null,
          onOpen: () => _toggle(d),
        );

    Widget? more(Iterable<ChoreDay> group) {
      final open = group.where((d) => _key(d) == _open).firstOrNull;
      return open == null ? null : _ChoreMore(day: open, onGive: canSwap(app, open) ? () => _give(open) : null);
    }

    final Widget body;
    if (days.isEmpty) {
      final canAdd = app.allows(DenAction.editChores);
      body = EmptyState(
        compact: true,
        message: 'No chores today.',
        actionLabel: canAdd ? 'Add chore' : null,
        onAction: canAdd ? () => context.push('/chore/new') : null,
      );
    } else if (widget.rows) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: ruled([
          for (final d in days)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckRow(
                  label: d.chore.title,
                  detail: app.memberById(d.owner)?.name ?? 'Anyone',
                  color: _colorOf(app, c, d.owner),
                  done: d.done,
                  late: d.late,
                  stars: pointsOn ? d.pointsAvailable : null,
                  steps: d.stepCount > 0 ? (d.stepsDone, d.stepCount) : null,
                  open: _open == _key(d),
                  onCheck: canCheckChore(app, d.owner) ? () => _check(d) : null,
                  onOpen: () => _toggle(d),
                ),
                DenReveal(visible: _open == _key(d), child: more([d]) ?? const SizedBox.shrink()),
              ],
            ),
        ]),
      );
    } else {
      final groups = choreGroups(app.den.members, days, me: app.me?.id);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: ruled([
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.m),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: g.member == null
                        ? SizedBox.square(dimension: 40, child: Icon(PhosphorIconsRegular.usersThree, size: 26, color: c.ink))
                        : DenAvatar(g.member!, size: 40),
                  ),
                  const SizedBox(width: Sp.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Semantics(
                          header: true,
                          label: g.member?.name ?? 'Anyone',
                          child: Wrap(spacing: Sp.s, runSpacing: Sp.s, children: [for (final d in g.days) pill(d)]),
                        ),
                        DenReveal(visible: more(g.days) != null, child: more(g.days) ?? const SizedBox.shrink()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ]),
      );
    }

    final note = _note;
    return DenSection(
      title: 'Chores',
      trailing: days.isEmpty ? null : SectionCount(choresDone(days)),
      cardPadding: widget.rows ? const EdgeInsets.fromLTRB(10, 4, 18, 4) : const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          DenReveal(
            visible: note != null,
            child: note == null
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const RowRule(),
                      DoneRow(
                        message: note.message,
                        onUndo: note.receipt?.undoable == true ? () => _undo(note.receipt!) : null,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// A chore opened in place: its steps to check, Give to… for that day, and Details.
class _ChoreMore extends StatelessWidget {
  const _ChoreMore({required this.day, required this.onGive});

  final ChoreDay day;
  final VoidCallback? onGive;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(todayReads);
    final c = context.colors;
    final t = context.text;
    final chore = day.chore;
    final color = _colorOf(app, c, day.owner);
    final canCheck = canCheckChore(app, day.owner);
    final due = chore.dueTime;
    final about = [
      if (due != null) 'Due ${clockWords(due)}',
      if (chore.notes.isNotEmpty) chore.notes,
    ].join('. ');
    return Padding(
      padding: const EdgeInsets.only(top: Sp.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (about.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.s),
              child: Text(tidy(about), style: t.meta(c.ink2)),
            ),
          for (final step in chore.steps)
            DenPressable(
              onTap: canCheck
                  ? () => attempt(context, () => context.choreActions.setStep(day, step.id, day.steps[step.id] == null))
                  : null,
              scale: false,
              haptic: true,
              toggled: day.steps[step.id] != null,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.input))),
              semanticLabel: step.text,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Targets.adult),
                child: Row(
                  children: [
                    CheckRing(color: color, done: day.steps[step.id] != null, size: 22),
                    const SizedBox(width: Sp.m),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Text(
                          step.text,
                          style: t.body(day.steps[step.id] != null ? c.ink2 : c.ink).copyWith(
                                decoration: day.steps[step.id] != null ? TextDecoration.lineThrough : null,
                                decorationColor: c.ink2,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: Sp.s),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              if (onGive != null)
                OutlinedButton.icon(
                  onPressed: onGive,
                  icon: const Icon(PhosphorIconsRegular.arrowsLeftRight, size: 18),
                  label: const Text('Give to…'),
                ),
              TextButton(
                onPressed: () => context.push('/chore/${chore.id}?date=${day.date}'),
                child: const Text('Details'),
              ),
            ],
          ),
          const SizedBox(height: DenLayout.headingInset),
        ],
      ),
    );
  }
}

/// Whose color a chore's ring takes: its owner's, or quiet ink for anyone's.
Color _colorOf(AppState app, DenColors c, String? owner) {
  final m = app.memberById(owner);
  return m == null ? c.ink2 : c.marker(m.marker);
}
