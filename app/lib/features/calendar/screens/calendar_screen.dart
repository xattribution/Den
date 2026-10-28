import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import 'agenda_view.dart';
import 'day_view.dart';
import '../widgets/family_week.dart';
import '../widgets/month_view.dart';

enum CalendarView { family, month, day, agenda }

/// The calendar. The Family view (the paper organizer's columns) is the default; month, day and
/// agenda read the same data. The view and date live in the URL.
class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key, this.view = CalendarView.family, this.date});

  final CalendarView view;
  final String? date;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final anchor = date ?? app.today;
    final weekStart = _weekStart(app, anchor);

    void goTo(CalendarView v, String d) => context.go('/calendar/${v.name}/$d');
    // The month steps by calendar month (Oct 31 back to Sep 30, Jan 31 on to Feb 28); the others
    // by a week or a day.
    String step(int by) => switch (view) {
      CalendarView.family || CalendarView.agenda => f.addDays(anchor, 7 * by),
      CalendarView.month => f.addMonths(anchor, by),
      CalendarView.day => f.addDays(anchor, by),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.s, Sp.s),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              Semantics(
                header: true,
                child: Text(
                  view == CalendarView.day ? f.long(anchor) : f.month(anchor),
                  style: context.type.heading(c.ink),
                ),
              ),
              IconButton(
                tooltip: 'Earlier',
                onPressed: () => goTo(view, step(-1)),
                icon: const Icon(PhosphorIconsRegular.caretLeft),
              ),
              OutlinedButton(onPressed: () => goTo(view, app.today), child: const Text('Today')),
              IconButton(
                tooltip: 'Later',
                onPressed: () => goTo(view, step(1)),
                icon: const Icon(PhosphorIconsRegular.caretRight),
              ),
              Segmented<CalendarView>(
                options: const {
                  CalendarView.family: 'Family',
                  CalendarView.month: 'Month',
                  CalendarView.day: 'Day',
                  CalendarView.agenda: 'Agenda',
                },
                value: view,
                onChanged: (v) => goTo(v, anchor),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: c.rule),
        Expanded(
          child: switch (view) {
            CalendarView.family => FamilyWeek(startDate: weekStart),
            CalendarView.month => MonthView(anchor: anchor),
            CalendarView.day => DayView(date: anchor),
            CalendarView.agenda => AgendaView(start: anchor),
          },
        ),
      ],
    );
  }

  static String _weekStart(AppState app, String date) {
    final f = app.formats;
    final weekday = f.dateTime(date).weekday % 7; // 0 = Sunday
    final start = app.den.family?.weekStart ?? 0;
    return f.addDays(date, -((weekday - start + 7) % 7));
  }
}
