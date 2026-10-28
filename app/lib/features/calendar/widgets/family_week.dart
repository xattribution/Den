import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../state/calendar_models.dart';

/// Den's signature view, taken from the paper family organizer: a column per person, a row per
/// day. Each cell holds that person's events and chores in their marker; events for everyone
/// span the row.
class FamilyWeek extends StatelessWidget {
  const FamilyWeek({
    super.key,
    required this.startDate,
    this.days = 7,
    this.showChores = true,
    this.fillHeight = false,
  });

  final String startDate;
  final int days;
  final bool showChores;

  /// Stretch the day rows to fill the height instead of scrolling, as on the wall.
  final bool fillHeight;

  static const double _dayColumn = 92;
  static const double _minPersonColumn = 150;

  /// Below this row height the grid scrolls instead of stretching to fill.
  static const double _minFilledRow = 96;

  @override
  Widget build(BuildContext context) {
    final grid = context.view(WeekModel(startDate, days: days));
    final c = context.colors;

    return LayoutBuilder(
      builder: (context, constraints) {
        final people = grid.people;
        final natural = _dayColumn + people.length * _minPersonColumn;
        final width = natural > constraints.maxWidth ? natural : constraints.maxWidth;
        final personWidth = (width - _dayColumn) / (people.isEmpty ? 1 : people.length);
        final fill = fillHeight &&
            constraints.hasBoundedHeight &&
            (constraints.maxHeight - 56) / grid.days.length >= _minFilledRow;

        final table = SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeaderRow(people: people, dayWidth: _dayColumn, personWidth: personWidth),
              Divider(height: 1, color: c.rule),
              if (fill)
                for (final (i, date) in grid.days.indexed) ...[
                  if (i > 0) Divider(height: 1, color: c.rule),
                  Expanded(
                    child: ClipRect(
                      child: _DayRow(
                        date: date,
                        people: people,
                        grid: grid,
                        dayWidth: _dayColumn,
                        personWidth: personWidth,
                        showChores: showChores,
                        fill: true,
                      ),
                    ),
                  ),
                ]
              else
                Expanded(
                  child: ListView.separated(
                    itemCount: grid.days.length,
                    separatorBuilder: (_, _) => Divider(height: 1, color: c.rule),
                    itemBuilder: (context, i) => _DayRow(
                      date: grid.days[i],
                      people: people,
                      grid: grid,
                      dayWidth: _dayColumn,
                      personWidth: personWidth,
                      showChores: showChores,
                    ),
                  ),
                ),
            ],
          ),
        );

        return natural > constraints.maxWidth
            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: table)
            : table;
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.people, required this.dayWidth, required this.personWidth});
  final List<Member> people;
  final double dayWidth;
  final double personWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(width: dayWidth),
        for (final m in people)
          Container(
            width: personWidth,
            padding: const EdgeInsets.fromLTRB(Sp.s, Sp.s, Sp.s, Sp.s),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: c.rule),
                bottom: BorderSide(color: c.marker(m.marker), width: 3),
              ),
            ),
            child: Row(
              children: [
                DenAvatar(m, size: 26),
                const SizedBox(width: Sp.s),
                Flexible(child: Text(m.name, style: context.type.bodyStrong(c.ink), overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.date,
    required this.people,
    required this.grid,
    required this.dayWidth,
    required this.personWidth,
    required this.showChores,
    this.fill = false,
  });

  final String date;
  final List<Member> people;
  final WeekGrid grid;
  final double dayWidth;
  final double personWidth;
  final bool showChores;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final isToday = date == app.today;
    final everyone = grid.everyone[date] ?? const <Occurrence>[];

    final cells = Row(
      crossAxisAlignment: fill ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
      children: [
        for (final m in people)
          Container(
            width: personWidth,
            constraints: const BoxConstraints(minHeight: 72),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: c.rule))),
            padding: const EdgeInsets.all(Sp.xs),
            child: fill
                ? SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: _Cell(cell: grid.cells[(date, m.id)], showChores: showChores),
                  )
                : _Cell(cell: grid.cells[(date, m.id)], showChores: showChores),
          ),
      ],
    );

    return Container(
      color: isToday ? c.well : null,
      child: Row(
        crossAxisAlignment: fill ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: dayWidth,
            child: Padding(
              padding: const EdgeInsets.all(Sp.s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isToday ? 'Today' : f.weekday(date), style: context.type.bodyStrong(c.ink)),
                  Text(f.dateTime(date).day.toString(), style: context.type.heading(isToday ? c.ink : c.ink2)),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final occ in everyone)
                  Container(
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: c.rule))),
                    padding: const EdgeInsets.fromLTRB(Sp.s, Sp.xs, Sp.s, 0),
                    child: _EventChip(occ, spanning: true),
                  ),
                if (fill) Expanded(child: cells) else cells,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.cell, required this.showChores});
  final WeekCell? cell;
  final bool showChores;

  @override
  Widget build(BuildContext context) {
    if (cell == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final occ in cell!.events) _EventChip(occ),
        if (showChores)
          for (final day in cell!.chores) _ChoreLine(day),
      ],
    );
  }
}

class _EventChip extends StatelessWidget {
  const _EventChip(this.occ, {this.spanning = false});
  final Occurrence occ;
  final bool spanning;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final c = context.colors;
    final time = occ.allDay ? null : app.formats.time(occ.start);
    return InkWell(
      onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PersonBar(markers: app.markersFor(occ.assignees), width: 3, minHeight: 18),
              const SizedBox(width: Sp.s - 2),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    if (time != null) TextSpan(text: '$time  ', style: context.type.meta(c.ink2)),
                    TextSpan(text: occ.title, style: context.type.meta(c.ink).copyWith(fontWeight: spanning ? FontWeight.w700 : null)),
                  ]),
                  maxLines: spanning ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoreLine extends StatelessWidget {
  const _ChoreLine(this.day);
  final ChoreDay day;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: () => context.push('/chore/${day.chore.id}?date=${day.date}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(
              day.done ? PhosphorIconsFill.checkCircle : Pictograms.chore(day.chore.icon),
              size: 15,
              color: day.done ? c.ink : c.ink2,
            ),
            const SizedBox(width: Sp.xs + 2),
            Expanded(
              child: Text(
                day.chore.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.meta(day.done ? c.ink2 : c.ink).copyWith(
                      decoration: day.done ? TextDecoration.lineThrough : null,
                      decorationColor: c.ink2,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
