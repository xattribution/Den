import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/event_row.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../words/calendar_time.dart';

/// The calendar as a list: days that have events, from [start], each under "Today",
/// "Tomorrow" or "Wed, Oct 22". Events only; chores live on Today and in Chores.
class AgendaView extends StatefulWidget {
  const AgendaView({super.key, required this.start, this.weeks = 4});

  final String start;

  /// How many weeks to show before "Show 4 more weeks".
  final int weeks;

  @override
  State<AgendaView> createState() => _AgendaViewState();
}

class _AgendaViewState extends State<AgendaView> {
  late int _weeks = widget.weeks;

  @override
  void didUpdateWidget(AgendaView old) {
    super.didUpdateWidget(old);
    if (old.start != widget.start) _weeks = widget.weeks;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final today = app.today;
    final from = widget.start;
    final to = f.addDays(from, _weeks * 7 - 1);
    final occurrences = app.den.occurrences(f.startOf(from), f.startOf(f.addDays(to, 1)));
    final byDate = occurrencesByDate(occurrences, f, from: from, to: to);
    final dates = byDate.keys.toList()..sort();
    final canAdd = app.allows(DenAction.editEvents);

    if (dates.isEmpty) {
      return ListView(
        children: [
          EmptyLine(
            message: 'Nothing on the calendar from ${f.monthDay(from)} to ${f.monthDay(to, relativeTo: from)}.',
            actionLabel: canAdd ? 'Add event' : null,
            onAction: () => context.push('/event/new?date=$from'),
          ),
          _more(context),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: Sp.xxxl),
      itemCount: dates.length + 1,
      itemBuilder: (context, i) {
        if (i == dates.length) return _more(context);
        final date = dates[i];
        final label = f.relative(date, today);
        final named = label != f.short(date);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              named ? label : f.shortWithYear(date, relativeTo: today),
              trailing: named ? f.short(date) : null,
            ),
            for (final occ in byDate[date]!) CalendarEventRow(occ: occ, date: date),
          ],
        );
      },
    );
  }

  Widget _more(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(onPressed: () => setState(() => _weeks += 4), child: const Text('Show 4 more weeks')),
    ),
  );
}
