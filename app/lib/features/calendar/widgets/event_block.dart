import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/avatar.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../state/calendar_models.dart';
import '../words/block_words.dart';
import 'event_look.dart';

/// Where a block sits in a stack of events at the same time: alone it has 18 corners; stacked,
/// the corners it shares with its neighbors are 6 (DESIGN.md, "Event blocks").
enum BlockPosition {
  alone,
  first,
  middle,
  last;

  static BlockPosition at(int index, int count) => count == 1
      ? alone
      : index == 0
          ? first
          : index == count - 1
              ? last
              : middle;

  BorderRadius get radius {
    const big = Radius.circular(Radii.block);
    const small = Radius.circular(6);
    return switch (this) {
      alone => const BorderRadius.all(big),
      first => const BorderRadius.vertical(top: big, bottom: small),
      middle => const BorderRadius.all(small),
      last => const BorderRadius.vertical(top: small, bottom: big),
    };
  }
}

/// The hero tag that carries an occurrence's block into its page.
String eventHeroTag(Occurrence occ) => 'event:${occ.event.id}:${occ.start}';

/// An event as a solid block in a day's list: its pictogram, the title (two lines at most), who
/// and until when, and the other people's faces (or, for everyone, the family's dots). Tap to
/// open it.
class EventBlock extends StatelessWidget {
  const EventBlock({
    super.key,
    required this.occ,
    required this.date,
    this.position = BlockPosition.alone,
    this.onTap,
    this.hero = false,
    this.person,
  });

  final Occurrence occ;

  /// The day the block sits under (a multi-day event says which day of it this is).
  final String date;
  final BlockPosition position;
  final VoidCallback? onTap;

  /// Carries the block into the event's page.
  final bool hero;

  /// The person the calendar is showing: their events take their color.
  final String? person;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final look = EventLook.of(app, occ, context.colors, column: app.memberById(person));
    final t = context.text;
    final alone = position == BlockPosition.alone;
    // The pictogram grows a little with the text, so it still reads beside a big title.
    final iconSize = MediaQuery.textScalerOf(context).scale(alone ? 26.0 : 22.0).clamp(alone ? 26.0 : 22.0, alone ? 34.0 : 30.0);
    final detail = blockDetail(f, occ, date, look.who);
    final time = blockTime(f, occ, date);

    final content = Padding(
      padding: alone ? const EdgeInsets.all(14) : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(look.icon, size: iconSize, color: look.ink),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tidyLine(occ.title),
                  style: t.rowTitle(look.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(tidyLine(detail), style: t.meta(look.ink)),
              ],
            ),
          ),
          if (look.everyone) ...[
            const SizedBox(width: Sp.s),
            FamilyDots(family: look.family),
          ] else if (look.others.isNotEmpty) ...[
            const SizedBox(width: Sp.s),
            BlockFaces(people: look.others, ring: look.fill),
          ],
        ],
      ),
    );

    final shape = RoundedRectangleBorder(borderRadius: position.radius);
    Widget block = DenPressable(
      onTap: onTap,
      color: look.fill,
      shape: shape,
      semanticLabel: [occ.title, ?time, detail].join(', '),
      child: ExcludeSemantics(child: content),
    );
    if (hero) {
      block = Hero(
        tag: eventHeroTag(occ),
        flightShuttleBuilder: (_, animation, _, _, _) => BlockFlight(animation: animation, color: look.fill),
        child: block,
      );
    }
    return block;
  }
}

/// What flies between a block and its page: the color, its corners growing from a block's 18
/// to the page's 24. The words appear where it lands.
class BlockFlight extends StatelessWidget {
  const BlockFlight({super.key, required this.animation, required this.color});

  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: animation,
        builder: (context, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(Radii.block + (heroRadius - Radii.block) * animation.value.clamp(0, 1)),
          ),
        ),
      );

  /// The corners of the block at the top of an event's page.
  static const double heroRadius = 24;
}

/// Events at the same time as one ink block: a disc in each event's color with its pictogram,
/// the titles together ("Soccer and Piano lesson") and who, from when. Tap to show them all.
class MergedBlock extends StatelessWidget {
  const MergedBlock({super.key, required this.items, required this.date, required this.onTap});

  final List<Occurrence> items;
  final String date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final looks = [for (final occ in items) EventLook.of(app, occ, c)];
    final title = combinedTitle([for (final occ in items) occ.title]);
    final whoNames = <String>[];
    for (final look in looks) {
      final names = look.everyone ? ['Everyone'] : [for (final m in look.people) m.name];
      for (final n in names) {
        if (!whoNames.contains(n)) whoNames.add(n);
      }
    }
    final start = blockTime(f, items.first, date);
    final detail = start == null ? joinNames(whoNames) : '${joinNames(whoNames)}, from $start';

    return DenPressable(
      onTap: onTap,
      color: c.primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.block)),
      semanticLabel: '$title, $detail. Show them one by one',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final look in looks.take(4))
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: look.everyone ? c.onPrimary : look.fill,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(look.icon, size: 18, color: look.everyone ? c.primary : look.ink),
                    ),
                ],
              ),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tidyLine(title), style: t.rowTitle(c.onPrimary), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(tidyLine(detail), style: t.meta(c.onPrimary)),
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

/// The other people in an event: faces overlapping a little, each in a ring of the block's
/// color so they read as separate.
class BlockFaces extends StatelessWidget {
  const BlockFaces({super.key, required this.people, required this.ring, this.size = 26, this.max = 3});

  final List<Member> people;
  final Color ring;
  final double size;
  final int max;

  static const double _overlap = 6;
  static const double _ring = 2;

  @override
  Widget build(BuildContext context) {
    final shown = people.take(max).toList();
    final step = size - _overlap;
    final width = size + step * (shown.length - 1);
    return SizedBox(
      width: width + _ring * 2,
      height: size + _ring * 2,
      child: Stack(
        children: [
          for (final (i, m) in shown.indexed)
            Positioned(
              left: i * step,
              top: 0,
              child: Container(
                padding: const EdgeInsets.all(_ring),
                decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
                child: DenAvatar(m, size: size),
              ),
            ),
        ],
      ),
    );
  }
}

/// The family's dots, one per person in their color, for an event for everyone.
class FamilyDots extends StatelessWidget {
  const FamilyDots({super.key, required this.family, this.size = 10, this.max = 6});

  final List<Member> family;
  final double size;
  final int max;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, m) in family.take(max).indexed) ...[
          if (i > 0) const SizedBox(width: 4),
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: c.marker(m.marker), shape: BoxShape.circle),
          ),
        ],
      ],
    );
  }
}

/// An event in a dense board cell (the iPad week, the month): one line, its pictogram, the
/// title with an ellipsis where the cell is narrow, and the time. The full words are on its
/// page, one tap away, and in what a screen reader says.
class EventCell extends StatelessWidget {
  const EventCell({
    super.key,
    required this.occ,
    required this.date,
    this.onTap,
    this.showTime = true,
    this.spanning = false,
    this.column,
  });

  final Occurrence occ;
  final String date;
  final VoidCallback? onTap;
  final bool showTime;

  /// The everyone row of the family week: says "everyone" and carries the family's dots.
  final bool spanning;

  /// The person whose column it sits in: it takes their color.
  final Member? column;

  static const double radius = 12;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final look = EventLook.of(app, occ, context.colors, column: column);
    final t = context.text;
    final firstDay = f.localDate(occ.start) == date;
    final spoken = [occ.title, if (!occ.allDay && firstDay) f.time(occ.start), look.who].join(', ');

    return LayoutBuilder(
      builder: (context, constraints) {
        // In a narrow cell the title keeps the room: the time goes first, then the pictogram.
        final narrow = constraints.maxWidth < 150 && !spanning;
        final tiny = constraints.maxWidth < 92 && !spanning;
        final time = !showTime || narrow || occ.allDay || !firstDay ? null : cellTime(f, occ.start);
        return DenPressable(
          onTap: onTap,
          color: look.fill,
          scale: false,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          semanticLabel: spoken,
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 10, vertical: 8),
                child: Row(
                  children: [
                    if (!tiny) ...[Icon(look.icon, size: 18, color: look.ink), SizedBox(width: narrow ? 6 : Sp.s)],
                    ..._words(t, look, time),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _words(DenText t, EventLook look, String? time) => [
                if (spanning) ...[
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            occ.title,
                            style: t.meta(look.ink).bold,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                          ),
                        ),
                        const SizedBox(width: Sp.s + 2),
                        Text(
                          time == null ? 'everyone' : '$time, everyone',
                          style: t.caption(look.ink).copyWith(fontSize: 14 * t.scale),
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Sp.s),
                  FamilyDots(family: look.family),
                ] else ...[
                  Expanded(
                    child: Text(
                      occ.title,
                      style: t.meta(look.ink).bold,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  if (time != null) ...[
                    const SizedBox(width: Sp.xs),
                    Text(time, style: t.caption(look.ink).copyWith(fontSize: 14 * t.scale), maxLines: 1, softWrap: false),
                  ],
                ],
              ];
}

/// The smallest a time column can be at the current text size: the longest time it shows.
double timeColumnWidth(BuildContext context) => math.max(66, MediaQuery.textScalerOf(context).scale(68));
