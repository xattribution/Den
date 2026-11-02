import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/today_model.dart';
import '../words/today_words.dart';

/// The day's events in one card (Main.dc.html "Today"): the time, the title, who it's for (and
/// whether anyone is driving), and their faces. Two of one person's events at once say so under
/// the second. Nothing on: one line, and Add event for someone who may.
class TodayEvents extends StatelessWidget {
  const TodayEvents({super.key, required this.title, required this.date, required this.events, this.gaps = const [], this.link});

  final String title;
  final String date;
  final List<Occurrence> events;
  final List<Gap> gaps;

  /// "Week" on Today, "Calendar" on Tomorrow.
  final Widget? link;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(todayReads);
    final overlaps = <String, List<Gap>>{};
    for (final gap in gaps) {
      if (gap.kind != GapKind.overlap) continue;
      final occ = gap.occurrences.last;
      overlaps.putIfAbsent('${occ.event.id}@${occ.start}', () => []).add(gap);
    }
    final Widget body;
    if (events.isEmpty) {
      final canAdd = app.allows(DenAction.editEvents);
      body = EmptyState(
        compact: true,
        message: date == app.today ? 'Nothing on the calendar today.' : 'Nothing on the calendar ${app.formats.relative(date, app.today).toLowerCase()}.',
        actionLabel: canAdd ? 'Add event' : null,
        onAction: canAdd ? () => context.push('/event/new?date=$date') : null,
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: ruled([
          for (final occ in events)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EventLine(occ),
                for (final gap in overlaps['${occ.event.id}@${occ.start}'] ?? const <Gap>[])
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.m),
                    child: NoticeLine(message: gap.message, icon: PhosphorIconsBold.warning),
                  ),
              ],
            ),
        ]),
      );
    }
    return DenSection(title: title, trailing: link, child: body);
  }
}

/// One event on Today: time, title, who, faces. Tapping opens it. With large text the time
/// goes over the title instead of beside it.
class EventLine extends StatelessWidget {
  const EventLine(this.occ, {super.key});

  final Occurrence occ;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(todayReads);
    final c = context.colors;
    final t = context.text;
    final f = app.formats;
    final people = occ.forEveryone ? app.den.members : [for (final id in occ.assignees) ?app.memberById(id)];
    final time = Text(occ.allDay ? 'All day' : f.time(occ.start), style: t.meta(c.ink2), maxLines: 1, softWrap: false);
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tidy(occ.title), style: t.rowTitle(c.ink)),
        const SizedBox(height: 2),
        Text(tidy(eventWho(app, occ)), style: t.meta(c.ink2)),
      ],
    );
    final faces = FaceStack(faces: [for (final m in people) DenAvatar(m, size: 26)]);
    return DenPressable(
      onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}'),
      scale: false,
      shape: const RoundedRectangleBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked = MediaQuery.textScalerOf(context).scale(1) > 1.35 || constraints.maxWidth < 280;
            if (stacked) {
              return Row(
                children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [time, const SizedBox(height: 2), words]),
                  ),
                  const SizedBox(width: Sp.s),
                  faces,
                ],
              );
            }
            return Row(
              children: [
                SizedBox(width: 68, child: time),
                const SizedBox(width: Sp.m),
                Expanded(child: words),
                const SizedBox(width: Sp.s),
                faces,
              ],
            );
          },
        ),
      ),
    );
  }
}
