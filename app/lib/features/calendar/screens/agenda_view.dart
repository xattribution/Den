import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../state/calendar_models.dart';
import '../widgets/calendar_parts.dart';
import '../widgets/day_list.dart';
import '../words/calendar_time.dart';

/// The calendar as a list: [start]'s events as solid blocks by time (or a line saying it's
/// free), then each later day that has something, for two weeks, and the way to see more.
/// Events only; chores live on Today and in Chores. [header] scrolls with it (the phone's title,
/// week strip and who to show).
class AgendaView extends StatefulWidget {
  const AgendaView({super.key, required this.start, this.person, this.combined, this.header = const [], this.days = 14});

  final String start;

  /// One person's events (and everyone's); null for all.
  final String? person;

  /// Which groups are combined; one of its own when not given.
  final Combined? combined;
  final List<Widget> header;

  /// How many days to list before "Show the next two weeks".
  final int days;

  @override
  State<AgendaView> createState() => _AgendaViewState();
}

class _AgendaViewState extends State<AgendaView> {
  late int _days = widget.days;
  Combined? _own;

  Combined get _combined => widget.combined ?? (_own ??= Combined());

  @override
  void didUpdateWidget(AgendaView old) {
    super.didUpdateWidget(old);
    if (old.start != widget.start) _days = widget.days;
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final from = widget.start;
    final to = f.addDays(from, _days - 1);
    final occurrences = context.view(OccurrencesModel(f.startOf(from), f.startOf(f.addDays(to, 1))));
    final byDate = occurrencesByDate(occurrences, f, from: from, to: to);
    List<Occurrence> on(String date) => [
          for (final occ in byDate[date] ?? const <Occurrence>[])
            if (showsFor(occ, widget.person)) occ,
        ];
    final later = [
      for (final date in byDate.keys.toList()..sort())
        if (date != from && on(date).isNotEmpty) date,
    ];

    Widget section(String date) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.gutter),
          child: DaySection(date: date, occurrences: on(date), combined: _combined, person: widget.person),
        );

    final children = <Widget>[
      ...widget.header,
      section(from),
      for (final date in later) ...[const SizedBox(height: DenLayout.sectionGap), section(date)],
      const SizedBox(height: DenLayout.sectionGap),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: DenLayout.gutter),
        child: Align(
          alignment: Alignment.centerLeft,
          child: CalendarPill(
            label: 'Show the next two weeks',
            onTap: () => setState(() => _days += 14),
          ),
        ),
      ),
    ];

    return ListView(
      padding: EdgeInsets.only(top: widget.header.isEmpty ? Sp.s : Sp.s, bottom: Sp.l),
      children: children,
    );
  }
}
