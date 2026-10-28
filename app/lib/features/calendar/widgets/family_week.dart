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
/// with the family's dots. A cell grows to fit its titles, two lines each. Where the day
/// column would squeeze the people (six people on an iPad in portrait), each day's date sits
/// above its row instead and the people get the whole width.
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

  /// Share the height among the days, as on the wall. A day with more than its share takes the
  /// room it needs and the week scrolls: a block is never cut.
  final bool fillHeight;

  static const double dayColumn = 96;

  /// The widest word of [texts] in [style], as Text draws it: over the inherited style, whose
  /// letter spacing counts.
  static double _widestWord(BuildContext context, Iterable<String> texts, TextStyle style) {
    final drawn = DefaultTextStyle.of(context).style.merge(style);
    final painter = TextPainter(textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context));
    var widest = 0.0;
    for (final text in texts) {
      for (final word in text.split(' ')) {
        if (word.isEmpty) continue;
        painter.text = TextSpan(text: word, style: drawn);
        painter.layout();
        widest = math.max(widest, painter.width);
      }
    }
    painter.dispose();
    return widest;
  }

  static const double _minPersonColumn = 100;

  /// A column widens for the longest word in the week's titles up to this, so a word doesn't
  /// break or end in an ellipsis; a longer word ends in one.
  static const double _maxWordColumn = 220;

  /// A narrow cell's padding, both sides, and a hair for rounding.
  static const double _cellPadding = 17;
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
        // A column is never narrower than the longest word of anyone's name at this text size,
        // nor (up to a point) of the week's titles: words wrap whole. Past that the week scrolls
        // sideways.
        final t = context.text;
        final nameWord = _widestWord(context, [for (final m in people) m.name], t.rowTitle(c.ink));
        final titleWord = _widestWord(context, [
          for (final cell in grid.cells.values)
            for (final occ in cell.events) occ.title,
        ], t.meta(c.ink).bold);
        final minColumn = math.max(
          _minPersonColumn,
          math.max(nameWord + 4, math.min(titleWord + _cellPadding, _maxWordColumn)),
        );
        // The day column gives its room to the people when they'd be squeezed: the date goes
        // above each day's row.
        final stacked = _side * 2 + dayColumn + columns * (minColumn + _gap) > constraints.maxWidth;
        final lead = stacked ? -_gap : dayColumn;
        final natural = _side * 2 + lead + columns * (minColumn + _gap);
        final width = math.max(natural, constraints.maxWidth);
        final person = (width - _side * 2 - lead - columns * _gap) / columns;
        final fill = fillHeight && constraints.hasBoundedHeight;

        Widget row(int i) => _DayRow(
          date: grid.days[i],
          first: i == 0,
          grid: grid,
          personWidth: person,
          showChores: showChores,
          stacked: stacked,
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
                  _HeaderRow(
                    people: people,
                    personWidth: person,
                    beside: person - 44 >= minColumn && person >= 150,
                    stacked: stacked,
                  ),
                  if (fill)
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final share = box.maxHeight / grid.days.length;
                          return SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < grid.days.length; i++)
                                  ConstrainedBox(constraints: BoxConstraints(minHeight: share), child: row(i)),
                              ],
                            ),
                          );
                        },
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
  const _HeaderRow({required this.people, required this.personWidth, required this.beside, required this.stacked});

  final List<Member> people;
  final double personWidth;

  /// No day column: the dates sit above the rows.
  final bool stacked;

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
            if (!stacked) const SizedBox(width: FamilyWeek.dayColumn),
            for (final (i, m) in people.indexed) ...[
              if (i > 0 || !stacked) const SizedBox(width: FamilyWeek._gap),
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
    required this.stacked,
  });

  final String date;
  final bool first;
  final WeekGrid grid;
  final double personWidth;
  final bool showChores;

  /// The date above the row instead of beside it.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final today = date == app.today;
    final everyone = grid.everyone[date] ?? const <Occurrence>[];
    final label = today ? c.ink : c.ink2;
    final canAdd = app.allows(DenAction.editEvents);

    final day = Semantics(
      header: true,
      label: today ? 'Today, ${f.long(date)}' : f.long(date),
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.only(top: stacked ? 2 : 6),
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
    );

    final people = <Widget>[
      for (final (i, m) in grid.people.indexed) ...[
        if (i > 0 || !stacked) const SizedBox(width: FamilyWeek._gap),
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
    ];
    final Widget cells = stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              day,
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: people),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: FamilyWeek.dayColumn, child: day),
              ...people,
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
                padding: EdgeInsets.only(left: stacked ? 0 : FamilyWeek.dayColumn + FamilyWeek._gap),
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
