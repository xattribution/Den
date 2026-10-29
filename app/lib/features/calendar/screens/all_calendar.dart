import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/app_state.dart';
import '../../../app/household.dart';
import '../../../app/log_scope.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/calendar_models.dart';
import '../widgets/calendar_parts.dart';
import '../widgets/calendar_surface.dart';
import '../widgets/day_list.dart' show openEvent;
import '../widgets/event_block.dart';
import '../words/block_words.dart';
import '../words/calendar_time.dart';
import 'calendar_screen.dart';

/// The Calendar tab: the family the device shows, or "All my families" on a device in several.
class CalendarTab extends StatelessWidget {
  const CalendarTab({super.key, this.view, this.date});

  final CalendarView? view;
  final String? date;

  @override
  Widget build(BuildContext context) => (Household.maybeOf(context)?.showingAll ?? false)
      ? const AllCalendarScreen()
      : CalendarScreen(view: view, date: date);
}

/// The families "All my families" leaves off the calendar, kept on this device.
abstract final class HiddenFamilies {
  static const key = 'den.household.calendarHidden';

  static Future<Set<String>> load() async {
    try {
      return {...?(await SharedPreferences.getInstance()).getStringList(key)};
    } on Object {
      return {};
    }
  }

  static Future<void> save(Set<String> hidden) async {
    try {
      await (await SharedPreferences.getInstance()).setStringList(key, [...hidden]);
    } on Object {
      // Only which chips were off.
    }
  }
}

/// The calendar in "All my families" (FAMILY-LINKS-PLAN §4.2): every family's events for the
/// next two weeks in one list by day and time, each block with its family's tag (and outline, in
/// the family's color), and a chip per family at the top that turns it on and off. A block opens
/// its event in its own family (`/l/<log>/event/...`), where it is changed as always, so receipts
/// and Undo stay with that family.
class AllCalendarScreen extends StatefulWidget {
  const AllCalendarScreen({super.key, this.days = 14});

  /// How many days to list before "Show the next two weeks".
  final int days;

  @override
  State<AllCalendarScreen> createState() => _AllCalendarScreenState();
}

class _AllCalendarScreenState extends State<AllCalendarScreen> {
  late int _days = widget.days;
  Set<String> _hidden = {};

  @override
  void initState() {
    super.initState();
    HiddenFamilies.load().then((hidden) {
      if (mounted) setState(() => _hidden = hidden);
    });
  }

  void _toggle(FamilyLog log) {
    setState(() {
      if (!_hidden.remove(log.id)) _hidden.add(log.id);
    });
    HiddenFamilies.save(_hidden);
  }

  @override
  Widget build(BuildContext context) {
    final home = Household.maybeOf(context)!;
    final families = [for (final l in home.families) if (l.den.isApproved) l];
    return CalendarSurface(
      child: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: Listenable.merge([for (final l in families) l.state]),
          builder: (context, _) => _list(context, families),
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<FamilyLog> families) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final today = app.today;
    final from = today;
    final to = f.addDays(from, _days - 1);
    final pad = !DenLayout.of(context).isCompact;
    final shown = [for (final l in families) if (!_hidden.contains(l.id)) l];

    // Each family's events in its own time zone, then together by day (the zone of the family
    // the device shows) and time.
    final byDate = <String, List<(FamilyLog, Occurrence)>>{};
    for (final log in shown) {
      final lf = log.state.formats;
      final occurrences = log.state.view(OccurrencesModel(lf.startOf(from), lf.startOf(lf.addDays(to, 1))));
      for (final e in occurrencesByDate(occurrences, f, from: from, to: to).entries) {
        byDate.putIfAbsent(e.key, () => []).addAll([for (final occ in e.value) (log, occ)]);
      }
    }
    for (final day in byDate.values) {
      day.sort((a, b) {
        final allDay = (b.$2.allDay ? 1 : 0) - (a.$2.allDay ? 1 : 0);
        if (allDay != 0) return allDay;
        return a.$2.start != b.$2.start ? a.$2.start.compareTo(b.$2.start) : a.$1.name.compareTo(b.$1.name);
      });
    }
    final dates = {from, ...byDate.keys}.toList()..sort();
    final side = pad ? 28.0 : DenLayout.gutter;

    Widget gutter(Widget child) => Padding(padding: EdgeInsets.symmetric(horizontal: side), child: child);

    final chips = ChipRow(
      inset: side,
      children: [
        for (final log in families)
          PersonPill(
            face: SourceTag(label: log.name, color: log.color, size: 28, semantics: false),
            name: log.name,
            selected: !_hidden.contains(log.id),
            onTap: () => _toggle(log),
          ),
      ],
    );

    return ReadableWidth(
      child: ListView(
        padding: EdgeInsets.only(top: pad ? 32 : Sp.s, bottom: Sp.l),
        children: [
          gutter(TitleRow(title: 'All my families', overline: monthTitle(f, from, today), large: pad)),
          const SizedBox(height: Sp.m),
          chips,
          const SizedBox(height: 18),
          if (shown.isEmpty)
            gutter(const EmptyState(message: 'Every family is off. Turn one on above.'))
          else
            for (final (i, date) in dates.indexed) ...[
              if (i > 0) const SizedBox(height: DenLayout.sectionGap),
              gutter(_AllDay(date: date, today: today, events: byDate[date] ?? const [])),
            ],
          const SizedBox(height: DenLayout.sectionGap),
          gutter(
            Align(
              alignment: Alignment.centerLeft,
              child: CalendarPill(label: 'Show the next two weeks', onTap: () => setState(() => _days += 14)),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day of "All my families": its heading, then each family's events by time.
class _AllDay extends StatelessWidget {
  const _AllDay({required this.date, required this.today, required this.events});

  final String date;
  final String today;
  final List<(FamilyLog, Occurrence)> events;

  @override
  Widget build(BuildContext context) {
    final f = DenScope.read(context).formats;
    final c = context.colors;
    return DenSection(
      title: dayHeading(f, date, today),
      carded: false,
      child: events.isEmpty
          ? DecoratedBox(
              decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.block)),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: Sp.l),
                child: EmptyState(compact: true, message: 'Nothing on any calendar.'),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, (log, occ)) in events.indexed) ...[
                  if (i > 0) const SizedBox(height: 10),
                  _SourcedBlock(log: log, occ: occ, date: date),
                ],
              ],
            ),
    );
  }
}

/// An event in "All my families": its time and its family's tag, then its block as the family's
/// calendar draws it, outlined in the family's color when it has one; a tap opens it in its
/// family.
class _SourcedBlock extends StatelessWidget {
  const _SourcedBlock({required this.log, required this.occ, required this.date});

  final FamilyLog log;
  final Occurrence occ;
  final String date;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final f = log.state.formats;
    final color = log.color;
    final time = occ.allDay || f.localDate(occ.start) != date ? 'All day' : f.time(occ.start);
    Widget block = LogScope(
      log: log,
      child: Builder(builder: (inner) => EventBlock(occ: occ, date: date, onTap: () => openEvent(inner, occ))),
    );
    if (color != null) {
      // The family's color as a ring around the block, a gap of the page between them, the way
      // a face is ringed: never on the block itself, which stays its people's.
      block = DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: c.marker(color), width: 2.5),
          borderRadius: BorderRadius.circular(Radii.block + 4.5),
        ),
        child: Padding(padding: const EdgeInsets.all(2), child: block),
      );
    }
    final above = MediaQuery.textScalerOf(context).scale(1) > 1.35;
    final when = Text(keepUnits(time), style: t.meta(c.ink2), maxLines: 1, softWrap: false);
    final tag = SourceTag(label: log.name, color: color, size: 20);
    if (above) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Row(children: [tag, const SizedBox(width: Sp.s), when]),
          ),
          block,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: timeColumnWidth(context),
          child: Padding(
            padding: const EdgeInsets.only(top: 15),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [when, const SizedBox(height: 6), tag]),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: block),
      ],
    );
  }
}
