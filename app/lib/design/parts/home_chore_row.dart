import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../state/app_state.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'home_pictograms.dart';

/// The chores board's row: Today's `ChoreRow` plus the due time and a swap gesture
/// (long-press on touch, right-click with a mouse, or the screen reader's "Swap" action).
/// Done is a check plus strike-through; late is the bad color with its icon and the word.
class BoardChoreRow extends StatelessWidget {
  const BoardChoreRow({super.key, required this.day, this.onSwap, this.compact = false});

  final ChoreDay day;

  /// Null when the actor may not swap this chore.
  final VoidCallback? onSwap;

  /// Narrow columns: the due time drops under the title.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final chore = day.chore;
    final mine = day.owner == null || day.owner == app.me?.id;
    final canCheck = app.allows(mine ? DenAction.completeOwnChore : DenAction.completeAnyChore);
    final pointsOn = app.den.family?.pointsEnabled ?? true;
    final late = day.late && !day.done;
    final scale = context.type.scale;
    final due = chore.dueTime == null ? null : _clock(chore.dueTime!);
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

    final dueText = due == null || day.done ? null : Text('by $due', style: context.type.meta(c.ink2));

    return Semantics(
      customSemanticsActions: onSwap == null ? null : {const CustomSemanticsAction(label: 'Swap for today'): onSwap!},
      child: InkWell(
        onTap: () => context.push('/chore/${chore.id}?date=${day.date}'),
        onLongPress: onSwap,
        onSecondaryTap: onSwap,
        child: Padding(
          padding: const EdgeInsets.only(left: Sp.xs, right: Sp.l),
          child: Row(
            children: [
              if (chore.steps.isEmpty)
                CheckDot(
                  done: day.done,
                  size: 26 * scale,
                  label: chore.title,
                  onChanged: canCheck
                      ? (v) => attempt(context, () => app.den.setChoreDone(chore.id, day.date, v))
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

  static String _clock(String hhmm) {
    final p = hhmm.split(':');
    var h = int.tryParse(p.first) ?? 0;
    final m = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
    final pm = h >= 12;
    h = h % 12 == 0 ? 12 : h % 12;
    return '$h:${m.toString().padLeft(2, '0')} ${pm ? 'PM' : 'AM'}';
  }
}
