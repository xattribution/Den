import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/chore_pictograms.dart';
import '../../../app/words.dart';
import '../state/chore_actions.dart';
import '../state/chores_model.dart';

/// A chore on a day: the check (or, for a chore with steps, the ring of steps it completes
/// through), its pictogram, title, due time and stars. Tapping opens the chore; [onSwap] adds
/// the swap gesture (long-press on touch, right-click with a mouse, or the screen reader's "Swap"
/// action). Done is a check plus strike-through; late is the bad color with its icon and the word.
class ChoreRow extends StatelessWidget {
  const ChoreRow({super.key, required this.day, this.onSwap, this.compact = false, this.showDue = true, this.vertical = 0});

  final ChoreDay day;

  /// Whether "by 5:00 PM" shows; Today leaves it out.
  final bool showDue;

  /// Space above and below the row.
  final double vertical;

  /// Null when the actor may not swap this chore.
  final VoidCallback? onSwap;

  /// Narrow columns: the due time drops under the title.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final c = context.colors;
    final chore = day.chore;
    final mine = day.owner == null || day.owner == app.me?.id;
    final canCheck = app.allows(mine ? DenAction.completeOwnChore : DenAction.completeAnyChore);
    final pointsOn = app.den.family?.pointsEnabled ?? true;
    final late = day.late && !day.done;
    final scale = context.type.scale;
    final due = chore.dueTime == null ? null : clockWords(chore.dueTime!);
    final titleStyle = context.type
        .body(day.done ? c.ink2 : c.ink)
        .copyWith(decoration: day.done ? TextDecoration.lineThrough : null, decorationColor: c.ink2);

    Widget lateMark() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(PhosphorIconsFill.clockCountdown, size: 16 * scale, color: c.bad),
        const SizedBox(width: 2),
        Text('Late', style: context.type.meta(c.bad)),
      ],
    );

    final dueText = due == null || day.done || !showDue ? null : Text('by $due', style: context.type.meta(c.ink2));

    final swapLabel = day.date == app.today ? 'Swap for today' : 'Swap for ${app.formats.short(day.date)}';
    return Semantics(
      customSemanticsActions: onSwap == null ? null : {CustomSemanticsAction(label: swapLabel): onSwap!},
      child: InkWell(
        onTap: () => context.push('/chore/${chore.id}?date=${day.date}'),
        onLongPress: onSwap,
        onSecondaryTap: onSwap,
        child: Padding(
          padding: EdgeInsets.only(left: Sp.xs, right: Sp.l, top: vertical, bottom: vertical),
          child: Row(
            children: [
              if (chore.steps.isEmpty)
                CheckDot(
                  done: day.done,
                  size: 26 * scale,
                  label: chore.title,
                  onChanged: canCheck
                      ? (v) => attempt(context, () => context.choreActions.setDone(day, v))
                      : null,
                )
              else
                StepRing(done: day.stepsDone, total: day.stepCount, size: 26 * scale),
              ChoreGlyph(chore.icon, size: 20 * scale, color: c.ink2),
              const SizedBox(width: Sp.s),
              Expanded(
                child: compact && (late || dueText != null)
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: Sp.xs),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(chore.title, style: titleStyle),
                            if (late) lateMark() else ?dueText,
                          ],
                        ),
                      )
                    : Text(chore.title, style: titleStyle),
              ),
              if (!compact) ...[
                if (late) ...[const SizedBox(width: Sp.s), lateMark()],
                if (!late && dueText != null) ...[const SizedBox(width: Sp.s), dueText],
              ],
              if (pointsOn && day.pointsAvailable > 0) ...[
                const SizedBox(width: Sp.s),
                StarCount(day.pointsAvailable, size: 16 * scale),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
