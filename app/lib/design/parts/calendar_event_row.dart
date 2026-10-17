import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../screens/calendar/calendar_time.dart';
import '../../state/app_state.dart';
import '../tokens.dart';
import '../widgets.dart';

/// An event as a row of a day's list, matching Today: a time column, the person bar, the title
/// and place, and who it's for on the right. [date] is the day the row sits under, so a
/// multi-day event reads "Until 11:00 AM" on its last day.
class CalendarEventRow extends StatelessWidget {
  const CalendarEventRow({super.key, required this.occ, required this.date});

  final Occurrence occ;
  final String date;

  static const double timeColumn = 76;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final people = occ.assignees.map(app.memberById).whereType<Member>().toList();
    final who = occ.forEveryone ? 'Everyone' : people.map((m) => m.name).join(', ');

    final first = f.localDate(occ.start);
    final last = f.lastDate(occ.start, occ.end);
    final multiDay = first != last;
    final List<String> times;
    if (occ.allDay || (multiDay && date != first && date != last)) {
      times = ['All day'];
    } else if (multiDay && date == last && date != first) {
      times = ['Until', f.time(occ.end)];
    } else if (multiDay || occ.end <= occ.start) {
      times = [f.time(occ.start)];
    } else {
      times = [f.time(occ.start), f.time(occ.end)];
    }
    final dayOf = multiDay ? 'Day ${f.daysFrom(first, date) + 1} of ${f.daysFrom(first, last) + 1}' : null;
    final detail = [if (occ.location.isNotEmpty) occ.location, ?dayOf].join(' · ');

    return Semantics(
      button: true,
      child: InkWell(
        onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: timeColumn,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [for (final t in times) Text(t, style: context.type.meta(c.ink2))],
                    ),
                  ),
                ),
                const SizedBox(width: Sp.m),
                PersonBar(markers: app.markersFor(occ.assignees)),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(occ.title, style: context.type.body(c.ink)),
                      if (detail.isNotEmpty) Text(detail, style: context.type.meta(c.ink2)),
                    ],
                  ),
                ),
                const SizedBox(width: Sp.s),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(who, style: context.type.meta(c.ink2), textAlign: TextAlign.right),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
