import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/chore_actions.dart';
import '../state/chores_model.dart';
import '../words/chore_words.dart';

/// A chore on one day, as Chores.dc.html draws it: a 34 pt ring in its person's color, the
/// title and a quiet line (when, stars, steps, late). The ring checks it (a chore with steps
/// fills its ring as an arc and checks through its steps). Tapping the words opens it in place:
/// its steps to check, Give to… for someone who may hand it on, and Details. Nothing else sits
/// on the row, so a board of chores reads as names and rings. [date] is the day the board shows.
class ChoreRow extends StatelessWidget {
  const ChoreRow({
    super.key,
    required this.day,
    required this.date,
    required this.open,
    required this.onOpen,
    this.onGive,
  });

  final ChoreDay day;
  final String date;
  final bool open;
  final VoidCallback onOpen;

  /// Null when whoever is using the device may not hand this chore on.
  final VoidCallback? onGive;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final c = context.colors;
    final t = context.text;
    final chore = day.chore;
    final owner = app.memberById(day.owner);
    final color = owner == null ? c.ink2 : c.marker(owner.marker);
    final canCheck = canCheckChore(app, day.owner);
    final pointsOn = app.den.family?.pointsEnabled ?? true;
    final stepped = day.stepCount > 0;
    final meta = choreMeta(day, date: date, today: app.today, f: app.formats, stars: pointsOn ? day.pointsAvailable : null);

    void check() => attempt(context, () => context.choreActions.setDone(day, !day.done));
    final ringTap = stepped ? onOpen : (canCheck ? check : null);

    final words = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tidy(chore.title),
            style: t.rowTitle(day.done ? c.ink2 : c.ink).copyWith(
                  decoration: day.done ? TextDecoration.lineThrough : null,
                  decorationColor: c.ink2,
                ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(tidy(meta), style: day.late && !day.done ? t.meta(c.ink).bold : t.meta(c.ink2)),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Row(
            children: [
              DenPressable(
                onTap: ringTap,
                haptic: !stepped,
                toggled: stepped ? null : day.done,
                shape: const CircleBorder(),
                semanticLabel: stepped
                    ? '${chore.title}, ${day.stepsDone} of ${day.stepCount} steps done'
                    : '${chore.title}, ${day.done ? 'done' : 'not done'}',
                child: SizedBox.square(
                  dimension: 48,
                  child: Center(
                    child: CheckRing(
                      color: color,
                      done: day.done,
                      progress: stepped ? stepProgress((day.stepsDone, day.stepCount)) : null,
                      size: 34,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: DenPressable(
                  onTap: onOpen,
                  scale: false,
                  selected: open,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.input))),
                  semanticLabel: 'More about ${chore.title}',
                  child: ExcludeSemantics(child: Align(alignment: AlignmentDirectional.centerStart, child: words)),
                ),
              ),
            ],
          ),
        ),
        DenReveal(
          visible: open,
          child: open ? ChoreOpen(day: day, onGive: day.done ? null : onGive, color: color) : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// A chore opened in place: its notes and due time, its steps to check, Give to… for that day,
/// and Details.
class ChoreOpen extends StatelessWidget {
  const ChoreOpen({super.key, required this.day, required this.onGive, required this.color, this.indent = 52});

  final ChoreDay day;
  final VoidCallback? onGive;
  final Color color;

  /// Lines it up with the title beside the ring.
  final double indent;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final c = context.colors;
    final t = context.text;
    final chore = day.chore;
    final pointsOn = app.den.family?.pointsEnabled ?? true;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, bottom: Sp.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chore.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.s),
              child: Text(tidy(chore.notes), style: t.meta(c.ink2)),
            ),
          for (final step in chore.steps)
            Builder(
              builder: (context) {
                final checked = day.steps[step.id] != null;
                final can = canCheckChore(app, step.owner ?? day.owner);
                final who = app.memberById(step.owner);
                return DenPressable(
                  onTap: can ? () => attempt(context, () => context.choreActions.setStep(day, step.id, !checked)) : null,
                  scale: false,
                  haptic: true,
                  toggled: checked,
                  semanticLabel: step.text,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.input))),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: Targets.adult),
                    child: Row(
                      children: [
                        CheckRing(color: color, done: checked, size: 24),
                        const SizedBox(width: Sp.m),
                        Expanded(
                          child: ExcludeSemantics(
                            child: Text(
                              tidy(step.text),
                              style: t.body(checked ? c.ink2 : c.ink).copyWith(
                                    decoration: checked ? TextDecoration.lineThrough : null,
                                    decorationColor: c.ink2,
                                  ),
                            ),
                          ),
                        ),
                        if (who != null) ...[const SizedBox(width: Sp.s), DenAvatar(who, size: 24)],
                        if (pointsOn && step.points > 0) ...[
                          const SizedBox(width: Sp.s),
                          Text('${step.points}', style: t.meta(c.ink2)),
                          const SizedBox(width: 2),
                          const Star(size: 13),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: Sp.xs),
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
        ],
      ),
    );
  }
}
