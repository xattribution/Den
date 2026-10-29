import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../state/calendar_models.dart';
import '../words/calendar_time.dart';
import 'day_colors.dart';
import 'event_look.dart';

/// The month as a board of day squares in one card, filling the height it's given (the iPad and
/// the wall use it whole). Weeks start on the family's week start; today's number sits in an
/// ink circle. Each day lists its events as small solid blocks, one line each, with the kind's
/// pictogram, as many as fit and then "+2 more". Tap a day for that day; tap an event for it.
///
/// With days shown as colors ([CalendarDays.colors]), each day of the month is its people's
/// colors at full strength ([DaySegments]) and its events are lines of dark ink on them (light on
/// a day for everyone, which is ink); days of the months around keep the blocks.
class MonthView extends StatelessWidget {
  const MonthView({super.key, required this.anchor, this.maxEvents, this.onDay});

  /// Any date in the month to show.
  final String anchor;

  /// Caps the events listed per square; by default as many as fit.
  final int? maxEvents;

  /// What tapping a day does; by default the calendar's day view.
  final ValueChanged<String>? onDay;

  static const double _minRow = 72;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {...calendarReads, Changes.prefs});
    final f = app.formats;
    final c = context.colors;
    final colors = app.calendarDays == CalendarDays.colors;
    final weekStart = app.den.family?.weekStart ?? 0;
    final first = f.firstOfMonth(anchor);
    final gridStart = f.weekStartOf(first, weekStart);
    final lead = f.daysFrom(gridStart, first);
    final weeks = ((lead + f.daysInMonth(first)) / 7).ceil();
    final gridEnd = f.addDays(gridStart, weeks * 7 - 1);
    final occurrences = context.view(OccurrencesModel(f.startOf(gridStart), f.startOf(f.addDays(gridEnd, 1))));
    final byDate = occurrencesByDate(occurrences, f, from: gridStart, to: gridEnd);
    final month = first.substring(0, 7);
    final today = app.today;

    return LayoutBuilder(
      builder: (context, constraints) {
        final headerHeight =
            (MediaQuery.textScalerOf(context).scale(context.text.caption(c.ink2).fontSize!) * 1.3).ceilToDouble() + 20;
        final available = constraints.hasBoundedHeight ? constraints.maxHeight - headerHeight - weeks : weeks * 120.0;
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
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            f.weekdayName((weekStart + i) % 7, long: columnWidth >= 160),
                            style: context.text.caption(c.ink2).bold,
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
              Container(height: 1, color: c.line),
              SizedBox(
                height: rowHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var d = 0; d < 7; d++)
                      () {
                        final date = f.addDays(gridStart, w * 7 + d);
                        final inMonth = date.startsWith(month);
                        final dayOccurrences = byDate[date] ?? const <Occurrence>[];
                        return _DaySquare(
                          date: date,
                          inMonth: inMonth,
                          isToday: date == today,
                          occurrences: dayOccurrences,
                          people: colors && inMonth ? dayPeople(app, dayOccurrences, date) : null,
                          width: columnWidth,
                          height: rowHeight,
                          maxEvents: maxEvents,
                          leftRule: d > 0,
                          onDay:
                              onDay ??
                              (date) => context.go(
                                Uri(path: '/calendar', queryParameters: {'view': 'day', 'date': date}).toString(),
                              ),
                        );
                      }(),
                  ],
                ),
              ),
            ],
          ],
        );
        return DecoratedBox(
          decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.section)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.section),
            child: scrolls ? SingleChildScrollView(child: grid) : grid,
          ),
        );
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
    required this.onDay,
    this.people,
  });

  final String date;
  final bool inMonth;
  final bool isToday;
  final List<Occurrence> occurrences;
  final double width;
  final double height;
  final int? maxEvents;
  final bool leftRule;
  final ValueChanged<String> onDay;

  /// Who has something this day, when the month shows days in their colors; null for blocks.
  final DayPeople? people;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final day = f.dateTime(date).day;
    final colored = people != null && !people!.isEmpty;
    // On a day in its people's colors, words are dark ink (light on a day for everyone, which is
    // ink), and today's disc is the opposite of what's behind it.
    final words = colored ? dayInk(c, people!) : null;
    final disc = colored && people!.everyone ? c.onPrimary : c.primary;
    final numberStyle = isToday
        ? context.text.rowTitle(colored && people!.everyone ? c.ink : c.onPrimary)
        : colored
            ? context.text.rowTitle(words!)
            : context.text.body(inMonth ? c.ink : c.ink3);
    final scaler = MediaQuery.textScalerOf(context);
    final numberSize = (scaler.scale(numberStyle.fontSize!) * 1.25).ceilToDouble() + 6;

    const pad = 6.0;
    final chipHeight = _MonthChip.heightFor(context);
    var fit = ((height - pad * 2 - numberSize - 4) / (chipHeight + 3)).floor();
    if (maxEvents != null) fit = math.min(fit, maxEvents!);
    fit = math.max(fit, 0);
    final overflow = occurrences.length > fit;
    final shown = overflow ? math.max(fit - 1, 0) : occurrences.length;
    final more = occurrences.length - shown;
    final roomy = width >= 96;
    final count = occurrences.length;
    // People past the three a day shows as colors.
    final morePeople = colored && !people!.everyone ? people!.more : 0;

    final content = Padding(
      padding: const EdgeInsets.all(pad),
      child: ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: isToday ? ShapeDecoration(color: disc, shape: const StadiumBorder()) : const BoxDecoration(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: numberSize, minHeight: numberSize, maxHeight: numberSize),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        widthFactor: 1,
                        child: ExcludeSemantics(
                          child: Text(
                            day == 1 && !isToday && roomy ? f.monthDay(date) : '$day',
                            style: numberStyle,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (morePeople > 0) ...[
                  const Spacer(),
                  ExcludeSemantics(
                    child: Text('+$morePeople', style: context.text.caption(words!).bold, maxLines: 1, softWrap: false),
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
            const SizedBox(height: 4),
            for (final occ in occurrences.take(shown)) ...[
              ExcludeSemantics(
                excluding: !roomy,
                child: _MonthChip(
                  occ: occ,
                  on: words,
                  onTap: roomy ? () => context.push('/event/${occ.event.id}?at=${occ.start}&from=calendar') : null,
                ),
              ),
              const SizedBox(height: 3),
            ],
            if (overflow && more > 0)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  width < 72 ? '+$more' : '+$more more',
                  style: context.text.caption(words ?? c.ink2).bold,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                ),
              ),
          ],
        ),
      ),
    );

    final who = colored ? ', ${people!.words}' : '';
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label:
            '${f.long(date)}${isToday ? ', today' : ''}, ${count == 0 ? 'nothing planned' : '$count ${count == 1 ? 'event' : 'events'}'}$who',
        child: DenPressable(
          onTap: () => onDay(date),
          scale: false,
          shape: const RoundedRectangleBorder(),
          child: Container(
            decoration: leftRule ? BoxDecoration(border: Border(left: BorderSide(color: c.line))) : null,
            child: colored ? Stack(fit: StackFit.expand, children: [DaySegments(day: people!), content]) : content,
          ),
        ),
      ),
    );
  }
}

/// An event in a month square: a small solid block, one line, the pictogram and the title. On a
/// day already in its people's colors it's the line alone, in that day's ink ([on]).
class _MonthChip extends StatelessWidget {
  const _MonthChip({required this.occ, this.onTap, this.on});

  final Occurrence occ;
  final VoidCallback? onTap;

  /// The words' color on a day in its people's colors; null draws the block.
  final Color? on;

  static double heightFor(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(13 * context.text.scale) * 1.3).ceilToDouble() + 6;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final look = EventLook.of(app, occ, context.colors);
    final ink = on ?? look.ink;
    final chip = Container(
      height: heightFor(context),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: on == null ? BoxDecoration(color: look.fill, borderRadius: BorderRadius.circular(6)) : null,
      child: Row(
        children: [
          Icon(look.icon, size: 13 * context.text.scale, color: ink),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              occ.title,
              style: context.text.caption(ink).bold,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
      button: true,
      label: occ.title,
      excludeSemantics: true,
      child: GestureDetector(onTap: onTap, child: chip),
    );
  }
}
