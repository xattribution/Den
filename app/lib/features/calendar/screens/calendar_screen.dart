import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/calendar_models.dart';
import '../widgets/calendar_parts.dart';
import '../widgets/date_strip.dart';
import '../widgets/day_list.dart';
import '../widgets/family_week.dart';
import '../widgets/month_view.dart';
import '../words/block_words.dart';
import '../words/calendar_time.dart';
import 'agenda_view.dart';
import 'day_view.dart';

/// The calendar's views. `agenda` is the list (the phone's default), `family` the family week
/// (the default with room for it).
enum CalendarView { family, month, day, agenda }

/// The views a phone offers, and the ones an iPad does (DESIGN.md, "Calendar").
const List<(CalendarView, String)> phoneViews = [
  (CalendarView.agenda, 'List'),
  (CalendarView.day, 'Day'),
  (CalendarView.month, 'Month'),
];
const List<(CalendarView, String)> padViews = [
  (CalendarView.day, 'Day'),
  (CalendarView.family, 'Week'),
  (CalendarView.month, 'Month'),
];

/// The calendar. On a phone (under 700 pt of room) it's the list: the month as the title and a
/// Today button, the week as a strip of days with people's dots, who to show, and the chosen
/// day's events as solid blocks by time, then the days after. Day and Month are a tap away. With
/// room it's the iPad's family week, a column per person, with Day and Month beside it.
///
/// The view and the day live in the URL (`/calendar?view=month&date=2026-10-28`), so a link or
/// a rotation lands on the same thing.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, this.view, this.date, this.offline});

  /// Null: the default for the room there is.
  final CalendarView? view;

  /// Local date, `YYYY-MM-DD`; null for today.
  final String? date;

  /// For screenshots: draw the offline line whatever the network says.
  final bool? offline;

  /// The location for [view] on [date].
  static String location(CalendarView? view, String? date) =>
      Uri(path: '/calendar', queryParameters: {'view': ?view?.name, 'date': ?date}).toString();

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  CalendarView? _view;
  String? _date;
  String? _person;
  final Combined _combined = Combined();

  @override
  void initState() {
    super.initState();
    _view = widget.view;
    _date = widget.date;
  }

  @override
  void didUpdateWidget(CalendarScreen old) {
    super.didUpdateWidget(old);
    if (old.view != widget.view || old.date != widget.date) {
      _view = widget.view;
      _date = widget.date;
    }
  }

  @override
  void dispose() {
    _combined.dispose();
    super.dispose();
  }

  /// Shows [view] on [date] and keeps the URL in step, without a history entry per tap.
  void _show(CalendarView view, String date) {
    setState(() {
      _view = view;
      _date = date;
    });
    final router = GoRouter.maybeOf(context);
    if (router != null) Router.neglect(context, () => router.go(CalendarScreen.location(view, date)));
  }

  static CalendarView _fit(CalendarView? asked, bool pad) {
    if (pad) return asked == null || asked == CalendarView.agenda ? CalendarView.family : asked;
    return asked == null || asked == CalendarView.family ? CalendarView.agenda : asked;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final today = app.today;
    final date = _date ?? today;
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pad = constraints.maxWidth >= DenLayout.compactMax;
          final view = _fit(_view, pad);
          return pad ? _pad(context, view, date, today) : _phone(context, view, date, today);
        },
      ),
    );
  }

  /// The iPad's ‹ and ›: the shared round button on the card color.
  static Widget _arrow(BuildContext context, IconData icon, String label, VoidCallback onTap) => RoundButton(
    icon: icon,
    label: label,
    onTap: onTap,
    fill: context.colors.card,
    color: context.colors.ink,
    size: Targets.adult,
  );

  Widget _today(String date, CalendarView view, String today) => CalendarPill(
    label: 'Today',
    semanticLabel: date == today ? 'Today, showing' : 'Go to today',
    onTap: () => _show(view, today),
  );

  // ---------------------------------------------------------------- phone

  Widget _phone(BuildContext context, CalendarView view, String date, String today) {
    final f = DenScope.read(context).formats;
    Widget gutter(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: DenLayout.gutter),
      child: child,
    );
    final header = <Widget>[
      gutter(TitleRow(title: monthTitle(f, date, today), trailing: [_today(date, view, today)])),
      const SizedBox(height: Sp.m),
      gutter(
        Align(
          alignment: Alignment.centerLeft,
          child: ViewSwitch<CalendarView>(options: phoneViews, value: view, onChanged: (v) => _show(v, date)),
        ),
      ),
      gutter(OfflineNote(force: widget.offline)),
      const SizedBox(height: 20),
      gutter(
        view == CalendarView.month
            ? MonthCard(selected: date, person: _person, onPick: (d) => _show(view, d))
            : WeekStrip(selected: date, person: _person, onPick: (d) => _show(view, d)),
      ),
      const SizedBox(height: 18),
      PersonFilters(selected: _person, onChanged: (p) => setState(() => _person = p)),
      const SizedBox(height: 18),
    ];

    switch (view) {
      case CalendarView.day:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Sp.s),
            ...header,
            Expanded(
              child: DayView(date: date, person: _person),
            ),
          ],
        );
      case CalendarView.month:
        return ListView(
          padding: const EdgeInsets.only(top: Sp.s, bottom: Sp.l),
          children: [
            ...header,
            gutter(_MonthDay(date: date, person: _person, combined: _combined)),
          ],
        );
      case CalendarView.agenda:
      case CalendarView.family:
        return AgendaView(start: date, person: _person, combined: _combined, header: header);
    }
  }

  // ---------------------------------------------------------------- iPad

  Widget _pad(BuildContext context, CalendarView view, String date, String today) {
    final app = DenScope.read(context);
    final f = app.formats;
    final weekStart = f.weekStartOf(date, app.den.family?.weekStart ?? 0);
    final title = switch (view) {
      CalendarView.family || CalendarView.agenda => weekTitle(f, weekStart, today),
      CalendarView.month => monthTitle(f, date, today),
      CalendarView.day => dayHeading(f, date, today),
    };
    String step(int by) => switch (view) {
      CalendarView.family || CalendarView.agenda => f.addDays(date, 7 * by),
      CalendarView.month => f.addMonths(date, by),
      CalendarView.day => f.addDays(date, by),
    };
    final onToday = switch (view) {
      CalendarView.family || CalendarView.agenda => weekStart == f.weekStartOf(today, app.den.family?.weekStart ?? 0),
      CalendarView.month => date.substring(0, 7) == today.substring(0, 7),
      CalendarView.day => date == today,
    };
    final (back, forward) = switch (view) {
      CalendarView.month => ('Last month', 'Next month'),
      CalendarView.day => ('The day before', 'The day after'),
      _ => ('Last week', 'Next week'),
    };

    final content = switch (view) {
      // The card holds the week and the page scrolls, so there is no empty card below the last day.
      CalendarView.family ||
      CalendarView.agenda => SingleChildScrollView(child: FamilyWeek(startDate: weekStart, showChores: false)),
      CalendarView.month => MonthView(anchor: date, onDay: (d) => _show(CalendarView.day, d)),
      CalendarView.day => DecoratedBox(
        decoration: BoxDecoration(color: context.colors.card, borderRadius: BorderRadius.circular(Radii.section)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.section),
          child: Padding(
            padding: const EdgeInsets.only(top: Sp.s),
            child: DayView(date: date, perPerson: true),
          ),
        ),
      ),
    };

    return Padding(
      padding: EdgeInsets.fromLTRB(28, math.max(Sp.s, 32 - MediaQuery.paddingOf(context).top), 28, Sp.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TitleRow(
            title: title,
            large: true,
            trailing: [
              if (!onToday) _today(date, view, today),
              ViewSwitch<CalendarView>(
                options: padViews,
                value: view == CalendarView.agenda ? CalendarView.family : view,
                cardThumb: true,
                onChanged: (v) => _show(v, date),
              ),
              _arrow(context, PhosphorIconsBold.caretLeft, back, () => _show(view, step(-1))),
              _arrow(context, PhosphorIconsBold.caretRight, forward, () => _show(view, step(1))),
            ],
          ),
          OfflineNote(force: widget.offline),
          const SizedBox(height: 18),
          Expanded(child: content),
        ],
      ),
    );
  }
}

/// The chosen day under the phone's month.
class _MonthDay extends StatelessWidget {
  const _MonthDay({required this.date, required this.person, required this.combined});

  final String date;
  final String? person;
  final Combined combined;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final occurrences = context.view(OccurrencesModel(f.startOf(date), f.startOf(f.addDays(date, 1))));
    final day = occurrencesByDate(occurrences, f, from: date, to: date)[date] ?? const <Occurrence>[];
    return DaySection(
      date: date,
      occurrences: [
        for (final occ in day)
          if (showsFor(occ, person)) occ,
      ],
      combined: combined,
      person: person,
    );
  }
}
