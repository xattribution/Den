import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../state/calendar_models.dart';
import '../words/calendar_time.dart';
import 'day_colors.dart';

/// Pages that settle on Den's UI spring, carrying the fling.
class SpringPagePhysics extends PageScrollPhysics {
  const SpringPagePhysics({super.parent});

  @override
  SpringPagePhysics applyTo(ScrollPhysics? ancestor) => SpringPagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => DenMotion.ui;
}

/// Who has something on [date] among [occurrences], as their colors, at most four: the dots
/// under a day. [person] narrows it to one person's events.
List<Color> dayDots(AppState app, DenColors c, List<Occurrence> occurrences, String date, {String? person}) {
  final f = app.formats;
  final ids = <String>[];
  final family = app.den.members;
  for (final occ in occurrences) {
    if (f.localDate(occ.start).compareTo(date) > 0 || f.lastDate(occ.start, occ.end).compareTo(date) < 0) continue;
    final everyone = occ.assignees.isEmpty;
    if (person != null && !everyone && !occ.assignees.contains(person)) continue;
    for (final id in everyone ? family.map((m) => m.id) : occ.assignees) {
      if (!ids.contains(id)) ids.add(id);
    }
  }
  return [
    for (final id in ids.take(4))
      if (app.memberById(id) case final m?) c.marker(m.marker),
  ];
}

/// The week as seven day tiles in a card: the chosen day in ink, people's dots under each day.
/// Swipe it for the next or the last week; it settles on the UI spring. Tap a day to choose it.
class WeekStrip extends StatefulWidget {
  const WeekStrip({super.key, required this.selected, required this.onPick, this.person});

  final String selected;
  final ValueChanged<String> onPick;
  final String? person;

  @override
  State<WeekStrip> createState() => _WeekStripState();
}

class _WeekStripState extends State<WeekStrip> {
  PageController? _pages;

  /// The first day of the week every page index counts from.
  late String _epoch;
  int _weekStart = 0;

  int _indexOf(String date, AppState app) {
    final f = app.formats;
    return f.daysFrom(_epoch, f.weekStartOf(date, _weekStart)) ~/ 7;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = DenScope.read(context);
    final weekStart = app.den.family?.weekStart ?? 0;
    if (_pages == null || weekStart != _weekStart) {
      _weekStart = weekStart;
      _epoch = app.formats.weekStartOf('2000-01-05', weekStart);
      _pages?.dispose();
      _pages = PageController(initialPage: _indexOf(widget.selected, app));
    }
  }

  @override
  void didUpdateWidget(WeekStrip old) {
    super.didUpdateWidget(old);
    final pages = _pages;
    if (old.selected == widget.selected || pages == null || !pages.hasClients) return;
    final target = _indexOf(widget.selected, DenScope.read(context));
    final current = pages.page?.round() ?? target;
    if (target == current) return;
    if ((target - current).abs() == 1 && !DenMotion.reduced(context)) {
      pages.animateToPage(target, duration: DenMotion.uiSettle, curve: DenMotion.uiCurve);
    } else {
      pages.jumpToPage(target);
    }
  }

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  void _settled(int index) {
    final app = DenScope.read(context);
    if (index == _indexOf(widget.selected, app)) return;
    final f = app.formats;
    final shift = (index - _indexOf(widget.selected, app)) * 7;
    widget.onPick(f.addDays(widget.selected, shift));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MediaQuery.withClampedTextScaling(
      // Seven days across a phone: past 150 % the date numbers would collide.
      maxScaleFactor: 1.5,
      child: Builder(
        builder: (context) {
          final height = _DayTile.heightFor(context) + Sp.s * 2;
          return Semantics(
            label: 'Week',
            hint: 'Swipe for the next week or the last',
            container: true,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.section),
              child: ColoredBox(
                color: c.card,
                child: SizedBox(
                  height: height,
                  child: PageView.builder(
                    controller: _pages,
                    physics: const SpringPagePhysics(),
                    onPageChanged: _settled,
                    itemBuilder: (context, index) {
                      final f = DenScope.read(context).formats;
                      final start = f.addDays(_epoch, index * 7);
                      return _WeekPage(
                        start: start,
                        selected: widget.selected,
                        person: widget.person,
                        onPick: widget.onPick,
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WeekPage extends StatelessWidget {
  const _WeekPage({required this.start, required this.selected, required this.person, required this.onPick});

  final String start;
  final String selected;
  final String? person;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final end = f.addDays(start, 7);
    final occurrences = context.view(OccurrencesModel(f.startOf(start), f.startOf(end)));
    return Padding(
      padding: const EdgeInsets.all(Sp.s),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++) ...[
            if (i > 0) const SizedBox(width: Sp.xs),
            Expanded(
              child: () {
                final date = f.addDays(start, i);
                return _DayTile(
                  date: date,
                  label: DateFormat('EEE').format(f.dateTime(date)),
                  selected: date == selected,
                  today: date == app.today,
                  dots: dayDots(app, c, occurrences, date, person: person),
                  onTap: () => onPick(date),
                );
              }(),
            ),
          ],
        ],
      ),
    );
  }
}

/// One day of the strip: its short name, its number and who has something that day.
class _DayTile extends StatelessWidget {
  const _DayTile({
    required this.date,
    required this.label,
    required this.selected,
    required this.today,
    required this.dots,
    required this.onTap,
  });

  final String date;
  final String label;
  final bool selected;
  final bool today;
  final List<Color> dots;
  final VoidCallback onTap;

  static double heightFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final content = scaler.scale(13) * 1.3 + 5 + scaler.scale(20) * 1.25 + 5 + 7;
    return math.max(76, (content + 16).ceilToDouble());
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final f = app.formats;
    final c = context.colors;
    final fill = selected ? c.primary : c.card;
    final ink = selected ? c.onPrimary : c.ink;
    final day = f.dateTime(date).day;
    return DenPressable(
      onTap: onTap,
      color: fill,
      selected: selected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.tile)),
      semanticLabel:
          '${f.long(date)}${today ? ', today' : ''}${dots.isEmpty ? '' : ', ${dots.length} ${dots.length == 1 ? 'person' : 'people'} busy'}',
      child: ExcludeSemantics(
        child: SizedBox(
          height: heightFor(context),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: context.text.caption(ink), maxLines: 1, softWrap: false, overflow: TextOverflow.clip),
              const SizedBox(height: 5),
              Text('$day', style: context.text.section(ink), maxLines: 1, softWrap: false),
              const SizedBox(height: 5),
              SizedBox(
                height: 7,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, color) in dots.indexed) ...[
                      if (i > 0) const SizedBox(width: 3),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The month on a phone: the weekday letters and six weeks of day tiles in a card. The strip's
/// month form: swipe for the next or the last month, tap a day to see it below.
///
/// With days shown as dots (the default), the chosen day is ink, today ringed, and people's dots
/// sit under each day. With days shown as colors ([CalendarDays.colors]), each day is its
/// people's colors at full strength ([DaySegments]); the chosen day has an ink ring, today's
/// number sits in an ink disc, and days of the months around keep their dots.
class MonthCard extends StatefulWidget {
  const MonthCard({super.key, required this.selected, required this.onPick, this.person});

  final String selected;
  final ValueChanged<String> onPick;
  final String? person;

  @override
  State<MonthCard> createState() => _MonthCardState();
}

class _MonthCardState extends State<MonthCard> {
  PageController? _pages;

  static int _indexOf(String date) => int.parse(date.substring(0, 4)) * 12 + int.parse(date.substring(5, 7)) - 1;

  static String _monthAt(int index) =>
      '${(index ~/ 12).toString().padLeft(4, '0')}-${(index % 12 + 1).toString().padLeft(2, '0')}-01';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pages ??= PageController(initialPage: _indexOf(widget.selected));
  }

  @override
  void didUpdateWidget(MonthCard old) {
    super.didUpdateWidget(old);
    final pages = _pages;
    if (old.selected == widget.selected || pages == null || !pages.hasClients) return;
    final target = _indexOf(widget.selected);
    final current = pages.page?.round() ?? target;
    if (target == current) return;
    if ((target - current).abs() == 1 && !DenMotion.reduced(context)) {
      pages.animateToPage(target, duration: DenMotion.uiSettle, curve: DenMotion.uiCurve);
    } else {
      pages.jumpToPage(target);
    }
  }

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  void _settled(int index) {
    if (index == _indexOf(widget.selected)) return;
    final f = DenScope.read(context).formats;
    widget.onPick(f.addMonths(widget.selected, index - _indexOf(widget.selected)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final colors = context.watch(const {Changes.prefs}).calendarDays == CalendarDays.colors;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Builder(
        builder: (context) {
          final scaler = MediaQuery.textScalerOf(context);
          final letters = (scaler.scale(13) * 1.3).ceilToDouble() + Sp.s;
          final height = Sp.s * 2 + letters + 6 * _MonthDay.heightFor(context, colors: colors) + 5 * Sp.xs;
          return Semantics(
            label: 'Month',
            hint: 'Swipe for the next month or the last',
            container: true,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.section),
              child: ColoredBox(
                color: c.card,
                child: SizedBox(
                  height: height,
                  child: PageView.builder(
                    controller: _pages,
                    physics: const SpringPagePhysics(),
                    onPageChanged: _settled,
                    itemBuilder: (context, index) => _MonthPage(
                      first: _monthAt(index),
                      selected: widget.selected,
                      person: widget.person,
                      colors: colors,
                      onPick: widget.onPick,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MonthPage extends StatelessWidget {
  const _MonthPage({
    required this.first,
    required this.selected,
    required this.person,
    required this.colors,
    required this.onPick,
  });

  final String first;
  final String selected;
  final String? person;

  /// Days in their people's colors rather than dots.
  final bool colors;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final weekStart = app.den.family?.weekStart ?? 0;
    final gridStart = f.weekStartOf(first, weekStart);
    final gridEnd = f.addDays(gridStart, 42);
    final occurrences = context.view(OccurrencesModel(f.startOf(gridStart), f.startOf(gridEnd)));
    final month = first.substring(0, 7);
    return Padding(
      padding: const EdgeInsets.all(Sp.s),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.s),
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Text(
                      f.weekdayName((weekStart + i) % 7).substring(0, 1),
                      textAlign: TextAlign.center,
                      style: context.text.caption(c.ink2),
                      semanticsLabel: f.weekdayName((weekStart + i) % 7, long: true),
                    ),
                  ),
              ],
            ),
          ),
          for (var w = 0; w < 6; w++) ...[
            if (w > 0) const SizedBox(height: Sp.xs),
            Row(
              children: [
                for (var d = 0; d < 7; d++) ...[
                  if (d > 0) const SizedBox(width: Sp.xs),
                  Expanded(
                    child: () {
                      final date = f.addDays(gridStart, w * 7 + d);
                      final inMonth = date.startsWith(month);
                      return _MonthDay(
                        date: date,
                        inMonth: inMonth,
                        selected: date == selected,
                        today: date == app.today,
                        dots: dayDots(app, c, occurrences, date, person: person),
                        colors: colors,
                        people: colors && inMonth ? dayPeople(app, occurrences, date, person: person) : null,
                        onTap: () => onPick(date),
                      );
                    }(),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MonthDay extends StatelessWidget {
  const _MonthDay({
    required this.date,
    required this.inMonth,
    required this.selected,
    required this.today,
    required this.dots,
    required this.onTap,
    this.colors = false,
    this.people,
  });

  final String date;
  final bool inMonth;
  final bool selected;
  final bool today;
  final List<Color> dots;
  final VoidCallback onTap;

  /// The month shows days in their people's colors (their tiles are a little taller).
  final bool colors;

  /// Who has something this day, to draw in their colors; null draws dots (a day of the months
  /// around, or the dots look).
  final DayPeople? people;

  static const double _corner = 14;

  /// The selected day's ring and the gap inside it.
  static const double _ring = 2.5;
  static const double _gap = 2;

  static double heightFor(BuildContext context, {bool colors = false}) {
    final scaler = MediaQuery.textScalerOf(context);
    if (!colors) return math.max(Targets.adult + 4, (scaler.scale(17) * 1.25 + 4 + 5 + 12).ceilToDouble());
    // Today's disc, then a line for "+2" or the dots, with room for the selected ring.
    final disc = scaler.scale(17) * 1.25 + 4;
    return math.max(Targets.adult + 4, (disc + 2 + scaler.scale(13) * 1.3 + 8).ceilToDouble());
  }

  @override
  Widget build(BuildContext context) {
    if (colors) return _inColors(context);
    final app = context.watch(const {});
    final f = app.formats;
    final c = context.colors;
    final fill = selected ? c.primary : c.card;
    final ink = selected ? c.onPrimary : (inMonth ? c.ink : c.ink3);
    final number = Text(
      '${f.dateTime(date).day}',
      style: today || selected ? context.text.rowTitle(ink) : context.text.body(ink),
      maxLines: 1,
      softWrap: false,
    );
    return DenPressable(
      onTap: onTap,
      color: fill,
      selected: selected,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: today && !selected ? BorderSide(color: c.ink, width: 2) : BorderSide.none,
      ),
      semanticLabel: '${f.long(date)}${today ? ', today' : ''}${dots.isEmpty ? '' : ', something planned'}',
      child: ExcludeSemantics(
        child: SizedBox(
          height: heightFor(context),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              number,
              const SizedBox(height: 4),
              _dotRow(dots),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _dotRow(List<Color> dots) => SizedBox(
        height: 5,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, color) in dots.take(3).indexed) ...[
              if (i > 0) const SizedBox(width: 2),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ],
          ],
        ),
      );

  /// The day in its people's colors: the whole tile theirs, split into equal parts for two or
  /// three, the first two and "+N" for more, ink with the family's dots for everyone. The chosen
  /// day has an ink ring with a gap of the card's color; today's number sits in a disc.
  Widget _inColors(BuildContext context) {
    final app = context.watch(const {});
    final f = app.formats;
    final c = context.colors;
    final day = people ?? DayPeople.none;
    final filled = !day.isEmpty;
    final onFill = filled ? dayInk(c, day) : (inMonth ? c.ink : c.ink3);
    // Today's disc is the opposite of what's behind it, so it shows on ink as well as on color.
    final disc = day.everyone ? c.onPrimary : c.ink;
    final numberColor = today ? (day.everyone ? c.ink : c.onPrimary) : onFill;
    final number = Text(
      '${f.dateTime(date).day}',
      style: filled || today || selected ? context.text.rowTitle(numberColor) : context.text.body(numberColor),
      maxLines: 1,
      softWrap: false,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final discSize = (scaler.scale(17) * 1.25 + 4).ceilToDouble();
    final Widget lower;
    if (!day.everyone && day.more > 0) {
      lower = Text('+${day.more}', style: context.text.caption(onFill).bold, maxLines: 1, softWrap: false);
    } else if (day.everyone || people == null) {
      lower = _dotRow(dots);
    } else {
      lower = const SizedBox.shrink();
    }
    const outer = BorderRadius.all(Radius.circular(_corner));
    final inset = selected ? _ring + _gap : 0.0;
    final what = people == null
        ? (dots.isEmpty ? '' : ', something planned')
        : day.isEmpty
            ? ''
            : ', ${day.words}';
    return DenPressable(
      onTap: onTap,
      color: c.card,
      selected: selected,
      shape: const RoundedRectangleBorder(borderRadius: outer),
      semanticLabel: '${f.long(date)}${today ? ', today' : ''}$what',
      child: ExcludeSemantics(
        child: SizedBox(
          height: heightFor(context, colors: true),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (filled)
                Padding(
                  padding: EdgeInsets.all(inset),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_corner - inset),
                    child: DaySegments(day: day),
                  ),
                ),
              if (selected)
                DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: RoundedRectangleBorder(
                      borderRadius: outer,
                      side: BorderSide(color: c.ink, width: _ring),
                    ),
                  ),
                ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  DecoratedBox(
                    decoration: today ? ShapeDecoration(color: disc, shape: const StadiumBorder()) : const BoxDecoration(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: discSize, minHeight: discSize),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Center(widthFactor: 1, child: number),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  lower,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
