import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'family_week.dart';

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
    final step = switch (view) {
      CalendarView.family || CalendarView.agenda => 7,
      CalendarView.month => 30,
      CalendarView.day => 1,
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
                onPressed: () => goTo(view, f.addDays(anchor, -step)),
                icon: const Icon(PhosphorIconsRegular.caretLeft),
              ),
              OutlinedButton(onPressed: () => goTo(view, app.today), child: const Text('Today')),
              IconButton(
                tooltip: 'Later',
                onPressed: () => goTo(view, f.addDays(anchor, step)),
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
            CalendarView.month => MonthViewSlot(anchor: anchor),
            CalendarView.day => DayViewSlot(date: anchor),
            CalendarView.agenda => AgendaViewSlot(start: anchor),
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

/// Month grid. Replaced by the full implementation in month_view.dart.
class MonthViewSlot extends StatelessWidget {
  const MonthViewSlot({super.key, required this.anchor});
  final String anchor;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Single day timeline. Replaced by the full implementation in day_view.dart.
class DayViewSlot extends StatelessWidget {
  const DayViewSlot({super.key, required this.date});
  final String date;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Agenda list. Replaced by the full implementation in agenda_view.dart.
class AgendaViewSlot extends StatelessWidget {
  const AgendaViewSlot({super.key, required this.start});
  final String start;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
