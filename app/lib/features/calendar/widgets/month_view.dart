import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'event_line.dart';
import '../../../design/tokens.dart';
import '../../../app/app_state.dart';
import '../words/calendar_time.dart';

/// The month as a grid of day squares that fills the height it's given (the wall uses it whole).
/// Weeks start on the family's week start; today is a solid well square with a bold date.
/// Events are ink text behind the person's 3 px marker; multi-day events appear on every day
/// they cover. Tap a square for that day; tap an event (on wider screens) for its detail.
class MonthView extends StatelessWidget {
  const MonthView({super.key, required this.anchor, this.maxEvents});

  /// Any date in the month to show.
  final String anchor;

  /// Caps the events listed per square; by default as many as fit.
  final int? maxEvents;

  static const double _minRow = 64;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final weekStart = app.den.family?.weekStart ?? 0;
    final first = f.firstOfMonth(anchor);
    final gridStart = f.weekStartOf(first, weekStart);
    final lead = f.daysFrom(gridStart, first);
    final weeks = ((lead + f.daysInMonth(first)) / 7).ceil();
    final gridEnd = f.addDays(gridStart, weeks * 7 - 1);
    final occurrences = app.den.occurrences(f.startOf(gridStart), f.startOf(f.addDays(gridEnd, 1)));
    final byDate = occurrencesByDate(occurrences, f, from: gridStart, to: gridEnd);
    final month = first.substring(0, 7);
    final today = app.today;

    return LayoutBuilder(
      builder: (context, constraints) {
        final headerHeight = (context.type.meta(c.ink2).fontSize! * 1.3).ceilToDouble() + Sp.s * 2;
        final available = constraints.hasBoundedHeight ? constraints.maxHeight - headerHeight - weeks : weeks * 110.0;
        final rowHeight = math.max(_minRow, (available / weeks).floorToDouble());
        final columnWidth = constraints.maxWidth / 7;
        final scrolls =
            constraints.hasBoundedHeight && rowHeight * weeks + headerHeight + weeks > constraints.maxHeight + 0.5;

        final grid = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: headerHeight,
              child: Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    SizedBox(
                      width: columnWidth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            f.weekdayName((weekStart + i) % 7, long: columnWidth >= 160),
                            style: context.type.meta(c.ink2),
                            overflow: TextOverflow.clip,
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            for (var w = 0; w < weeks; w++) ...[
              Divider(height: 1, thickness: 1, color: c.rule),
              SizedBox(
                height: rowHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var d = 0; d < 7; d++)
                      () {
                        final date = f.addDays(gridStart, w * 7 + d);
                        return _DaySquare(
                          date: date,
                          inMonth: date.startsWith(month),
                          isToday: date == today,
                          occurrences: byDate[date] ?? const [],
                          width: columnWidth,
                          height: rowHeight,
                          maxEvents: maxEvents,
                          leftRule: d > 0,
                        );
                      }(),
                  ],
                ),
              ),
            ],
          ],
        );
        return scrolls ? SingleChildScrollView(child: grid) : grid;
      },
    );
  }
}

class _DaySquare extends StatelessWidget {
  const _DaySquare({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.occurrences,
    required this.width,
    required this.height,
    required this.maxEvents,
    required this.leftRule,
  });

  final String date;
  final bool inMonth;
  final bool isToday;
  final List<Occurrence> occurrences;
  final double width;
  final double height;
  final int? maxEvents;
  final bool leftRule;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final day = f.dateTime(date).day;
    final dateStyle = isToday ? context.type.bodyStrong(c.ink) : context.type.body(inMonth ? c.ink : c.ink2);
    final dateText = day == 1 ? f.monthDay(date) : '$day';

    const pad = Sp.xs;
    final dateRow = (dateStyle.fontSize! * 1.3).ceilToDouble() + 2;
    final lineHeight = CalendarEventLine.lineHeight(context);
    var fit = ((height - pad * 2 - dateRow) / lineHeight).floor();
    if (maxEvents != null) fit = math.min(fit, maxEvents!);
    fit = math.max(fit, 0);
    final overflow = occurrences.length > fit;
    final shown = overflow ? math.max(fit - 1, 0) : occurrences.length;
    final more = occurrences.length - shown;

    final wideEnough = width >= 100;
    // Times only where the title still fits beside them (the wall); titles matter more.
    final showTimes = width >= 200;

    void openDay() => context.go('/calendar/day/$date');

    final count = occurrences.length;
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label:
            '${f.long(date)}${isToday ? ', today' : ''}, ${count == 0 ? 'nothing planned' : '$count ${count == 1 ? 'event' : 'events'}'}',
        child: Material(
          color: isToday ? c.well : Colors.transparent,
          child: InkWell(
            onTap: openDay,
            child: Container(
              decoration: leftRule
                  ? BoxDecoration(
                      border: Border(left: BorderSide(color: c.rule)),
                    )
                  : null,
              padding: const EdgeInsets.all(pad),
              child: ClipRect(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: dateRow,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                        child: Text(
                          dateText,
                          style: dateStyle,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                        ),
                      ),
                    ),
                    for (final occ in occurrences.take(shown))
                      ExcludeSemantics(
                        excluding: !wideEnough,
                        child: CalendarEventLine(
                          occ: occ,
                          height: lineHeight,
                          fade: !wideEnough,
                          time: showTimes && !occ.allDay && f.localDate(occ.start) == date ? f.time(occ.start) : null,
                          onTap: wideEnough ? () => context.push('/event/${occ.event.id}?at=${occ.start}') : null,
                        ),
                      ),
                    if (overflow && more > 0)
                      SizedBox(
                        height: lineHeight,
                        child: Padding(
                          padding: const EdgeInsets.only(left: Sp.xs + 3),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              width < 72 ? '+$more' : '+$more more',
                              style: context.type.meta(c.ink2),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
