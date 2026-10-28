import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/avatar.dart';
import '../../../design/glyphs.dart';
import '../../../design/tokens.dart';
import '../state/calendar_models.dart';
import 'event_block.dart';

/// Den's signature view, the paper family organizer on the iPad: one card, a column per person
/// under their face and name, a row per day. Each person's events are solid blocks in their
/// color with the kind's pictogram; events for everyone run across the row as an ink block
/// with the family's dots. Dense cells keep one line per event and show the rest on tap.
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

  static const double dayColumn = 96;

  static double _widestWord(BuildContext context, List<Member> people) {
    final style = context.text.rowTitle(context.colors.ink);
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    for (final m in people) {
      for (final word in m.name.split(' ')) {
        final painter = TextPainter(
          text: TextSpan(text: word, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        widest = math.max(widest, painter.width);
        painter.dispose();
      }
    }
    return widest;
  }

  static const double _minPersonColumn = 100;

  /// Below this row height the wall's week scrolls instead of stretching to fill.
  static const double _minFilledRow = 96;
  static const double _gap = 8;
  static const double _side = 14;

  @override
  Widget build(BuildContext context) {
    final grid = context.view(WeekModel(startDate, days: days));
    final c = context.colors;

    return LayoutBuilder(
      builder: (context, constraints) {
        final people = grid.people;
        final columns = math.max(1, people.length);
        // A column is never narrower than the longest word of anyone's name at this text size:
        // names wrap between words, never inside one. Past that the week scrolls sideways.
        final minColumn = math.max(_minPersonColumn, _widestWord(context, people) + 4);
        final natural = _side * 2 + dayColumn + columns * (minColumn + _gap);
        final width = math.max(natural, constraints.maxWidth);
        final person = (width - _side * 2 - dayColumn - columns * _gap) / columns;
        // Rows share the height only while each gets room for a block or two; on a short wall the
        // week scrolls instead of cutting its blocks.
        final fill = fillHeight && constraints.hasBoundedHeight && (constraints.maxHeight - 80) / grid.days.length >= _minFilledRow;

        Widget row(int i) => _DayRow(
          date: grid.days[i],
          first: i == 0,
          grid: grid,
          personWidth: person,
          showChores: showChores,
          fill: fill,
        );

        final card = DecoratedBox(
          decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.section)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.section),
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: fill || constraints.hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HeaderRow(people: people, personWidth: person, beside: person - 44 >= minColumn && person >= 150),
                  if (fill)
                    // On the wall each day gets an equal share of the height; a day with more than fits
                    // shows what fits, as the old wall did.
                    for (var i = 0; i < grid.days.length; i++)
                      Expanded(
                        child: ClipRect(
                          child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: row(i)),
                        ),
                      )
                  else if (constraints.hasBoundedHeight)
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: Sp.s),
                        itemCount: grid.days.length,
                        itemBuilder: (context, i) => row(i),
                      ),
                    )
                  else ...[for (var i = 0; i < grid.days.length; i++) row(i), const SizedBox(height: Sp.s)],
                ],
              ),
            ),
          ),
        );

        return natural > constraints.maxWidth
            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: card)
            : card;
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.people, required this.personWidth, required this.beside});

  final List<Member> people;
  final double personWidth;

  /// The name beside the face; otherwise under it.
  final bool beside;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(FamilyWeek._side, 14, FamilyWeek._side, 10),
        child: Row(
          children: [
            const SizedBox(width: FamilyWeek.dayColumn),
            for (final m in people) ...[
              const SizedBox(width: FamilyWeek._gap),
              SizedBox(
                width: personWidth,
                // Names never truncate: with many people the name goes under the face, where it
                // has the column's whole width to wrap in.
                child: beside
                    ? Row(
                        children: [
                          DenAvatar(m, size: 34),
                          const SizedBox(width: 10),
                          Expanded(child: Text(m.name, style: context.text.rowTitle(c.ink))),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DenAvatar(m, size: 34),
                          const SizedBox(height: 6),
                          Text(m.name, style: context.text.rowTitle(c.ink)),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.date,
    required this.first,
    required this.grid,
    required this.personWidth,
    required this.showChores,
    required this.fill,
  });

  final String date;
  final bool first;
  final WeekGrid grid;
  final double personWidth;
  final bool showChores;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final today = date == app.today;
    final everyone = grid.everyone[date] ?? const <Occurrence>[];
    final label = today ? c.ink : c.ink2;
    final canAdd = app.allows(DenAction.editEvents);

    final cells = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: FamilyWeek.dayColumn,
          child: Semantics(
            header: true,
            label: today ? 'Today, ${f.long(date)}' : f.long(date),
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: Sp.s,
                children: [
                  Text(
                    '${f.dateTime(date).day}',
                    style: context.text.section(label).copyWith(fontSize: 22 * context.text.scale),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      today ? 'Today' : f.weekday(date),
                      style: today ? context.text.meta(label).bold : context.text.meta(label),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        for (final m in grid.people) ...[
          const SizedBox(width: FamilyWeek._gap),
          SizedBox(
            width: personWidth,
            child: _Cell(
              date: date,
              cell: grid.cells[(date, m.id)],
              showChores: showChores,
              onAdd: canAdd ? () => context.push('/event/new?date=$date&who=${m.id}') : null,
              who: m,
            ),
          ),
        ],
      ],
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: c.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FamilyWeek._side, vertical: Sp.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 40), child: cells),
            for (final occ in everyone) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: FamilyWeek.dayColumn + FamilyWeek._gap),
                child: EventCell(
                  occ: occ,
                  date: date,
                  spanning: true,
                  onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}&from=calendar'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.date,
    required this.cell,
    required this.showChores,
    required this.onAdd,
    required this.who,
  });

  final String date;
  final WeekCell? cell;
  final bool showChores;
  final VoidCallback? onAdd;
  final Member who;

  @override
  Widget build(BuildContext context) {
    final events = cell?.events ?? const <Occurrence>[];
    final chores = showChores ? (cell?.chores ?? const <ChoreDay>[]) : const <ChoreDay>[];
    final children = <Widget>[
      for (final occ in events)
        EventCell(
          column: who,
          occ: occ,
          date: date,
          onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}&from=calendar'),
        ),
      for (final day in chores) _ChoreLine(day),
    ];
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 6), child],
      ],
    );
    if (onAdd == null) return column;
    // The empty part of a cell adds an event for that person on that day.
    return Semantics(
      onTapHint: 'Add an event for ${who.name}',
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onAdd,
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 40), child: column),
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
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          children: [
            Icon(
              day.done ? PhosphorIconsFill.checkCircle : choreGlyph(day.chore.icon, day.chore.title),
              size: 15,
              color: day.done ? c.ink : c.ink2,
            ),
            const SizedBox(width: Sp.xs + 2),
            Expanded(
              child: Text(
                day.chore.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text
                    .meta(day.done ? c.ink2 : c.ink)
                    .copyWith(decoration: day.done ? TextDecoration.lineThrough : null, decorationColor: c.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
