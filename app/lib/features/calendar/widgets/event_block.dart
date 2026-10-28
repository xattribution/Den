import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/avatar.dart';
import '../../../design/motion.dart';
import '../../../design/pictograms.dart';
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
    final iconSize = MediaQuery.textScalerOf(
      context,
    ).scale(alone ? 26.0 : 22.0).clamp(alone ? 26.0 : 22.0, alone ? 34.0 : 30.0);
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
                Text(tidyLine(occ.title), style: t.rowTitle(look.ink), maxLines: 2, overflow: TextOverflow.ellipsis),
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

/// Events at the same time as one ink block, laid out like a single block: one neutral
/// pictogram, the titles together ("Soccer and Piano lesson") and who, from when, and the
/// faces of everyone in them (the family's dots when one is for everyone). Tap to show them
/// all.
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
    final people = <Member>[];
    for (final look in looks) {
      final names = look.everyone ? ['Everyone'] : [for (final m in look.people) m.name];
      for (final n in names) {
        if (!whoNames.contains(n)) whoNames.add(n);
      }
      for (final m in look.people) {
        if (!people.any((p) => p.id == m.id)) people.add(m);
      }
    }
    final everyone = looks.any((look) => look.everyone);
    final start = blockTime(f, items.first, date);
    final detail = start == null ? joinNames(whoNames) : '${joinNames(whoNames)}, from $start';
    final iconSize = MediaQuery.textScalerOf(context).scale(26.0).clamp(26.0, 34.0);

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
              Icon(Pictograms.event(null), size: iconSize, color: c.onPrimary),
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
              if (everyone) ...[
                const SizedBox(width: Sp.s),
                FamilyDots(family: looks.first.family),
              ] else if (people.isNotEmpty) ...[
                const SizedBox(width: Sp.s),
                BlockFaces(people: people, ring: c.primary),
              ],
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

/// How an event's title sits in a board cell of a given width. The title wraps to two lines
/// before anything gives way; then the time goes, then the pictogram; only a title that still
/// doesn't fit (a very long one, or a word wider than the cell) ends in an ellipsis. Words never
/// break in the middle.
@immutable
class CellFit {
  const CellFit({
    required this.text,
    required this.icon,
    required this.time,
    required this.maxLines,
    required this.lines,
    required this.lineHeight,
  });

  /// The title as drawn (with its last two words kept together when that still fits).
  final String text;
  final bool icon;
  final bool time;
  final int maxLines;

  /// How many lines the title takes.
  final int lines;

  /// The height of one line of the title, to set the pictogram against the first.
  final double lineHeight;

  /// The pictogram's size in a board cell.
  static const double cellIcon = 18;

  /// Lays [title] out in [width] (the room inside the block's padding) on at most [lines]
  /// lines. [iconSize] and [iconGap] are the pictogram's; [timeWidth] is the time's width with
  /// its gap, or null for no time. The time goes before the pictogram, and shows only beside
  /// it. [style] is the title's style as drawn, over the inherited one.
  static CellFit of(
    String title, {
    required TextStyle style,
    required TextScaler scaler,
    required double width,
    required double iconGap,
    double iconSize = cellIcon,
    double? timeWidth,
    bool icon = true,
    int lines = 2,
  }) {
    final most = lines;
    final tidy = tidyLine(title);
    final texts = {tidy, title}.toList();
    final painter = TextPainter(textDirection: TextDirection.ltr, textScaler: scaler, maxLines: most);
    try {
      painter.text = TextSpan(text: 'Ag', style: style);
      painter.layout();
      final lineHeight = painter.preferredLineHeight;

      double widestWord(String text) {
        var widest = 0.0;
        for (final word in text.split(RegExp(r'[ \n]+'))) {
          if (word.isEmpty) continue;
          painter.text = TextSpan(text: word, style: style);
          painter.layout();
          widest = math.max(widest, painter.width);
        }
        return widest;
      }

      // The lines the text takes in [room], or null when it needs more than [most] or a word
      // would break.
      int? linesIn(String text, double room) {
        if (room <= 0 || widestWord(text) > room) return null;
        painter.text = TextSpan(text: text, style: style);
        painter.layout(maxWidth: room);
        if (painter.didExceedMaxLines) return null;
        return painter.computeLineMetrics().length;
      }

      final options = [
        if (icon && timeWidth != null) (true, true),
        if (icon) (true, false),
        (false, false),
      ];
      for (final (withIcon, withTime) in options) {
        final room = width - (withIcon ? iconSize + iconGap : 0) - (withTime ? timeWidth! : 0);
        for (final text in texts) {
          final lines = linesIn(text, room);
          if (lines != null) {
            return CellFit(
              text: text,
              icon: withIcon,
              time: withTime,
              maxLines: most,
              lines: lines,
              lineHeight: lineHeight,
            );
          }
        }
      }
      // The last resort. Whole words ending in an ellipsis ("Sophie's birthday…"); a word wider
      // than the cell keeps to one line rather than breaking in the middle.
      final wordsFit = widestWord(title) <= width;
      if (wordsFit) {
        final words = title.split(' ');
        for (var n = words.length - 1; n > 0; n--) {
          final text = '${words.take(n).join(' ').replaceAll(RegExp(r'[\s,;:.\-–—]+$'), '')}…';
          final lines = linesIn(text, width);
          if (lines != null) {
            return CellFit(text: text, icon: false, time: false, maxLines: most, lines: lines, lineHeight: lineHeight);
          }
        }
      }
      return CellFit(
        text: title,
        icon: false,
        time: false,
        maxLines: wordsFit ? most : 1,
        lines: wordsFit ? most : 1,
        lineHeight: lineHeight,
      );
    } finally {
      painter.dispose();
    }
  }
}

/// An event in a board cell (the iPad week, the day's all-day row): a block in the person's
/// color with its pictogram, the title on up to two lines and, where there's room, the time.
/// The block grows to fit its title ([CellFit] says what gives way first). The full words are
/// on its page, one tap away, and in what a screen reader says.
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

  /// Narrower than this, a cell has no room for the pictogram beside a word.
  static const double dense = 92;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final look = EventLook.of(app, occ, context.colors, column: column);
    final t = context.text;
    final firstDay = f.localDate(occ.start) == date;
    final spoken = [occ.title, if (!occ.allDay && firstDay) f.time(occ.start), look.who].join(', ');
    final time = !showTime || occ.allDay || !firstDay ? null : cellTime(f, occ.start);
    final scaler = MediaQuery.textScalerOf(context);
    // Measured as Text will draw it: over the inherited style (its letter spacing counts).
    final base = DefaultTextStyle.of(context).style;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 150 && !spanning;
        final padding = narrow ? 8.0 : 10.0;
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
                padding: EdgeInsets.symmetric(horizontal: padding, vertical: 8),
                child: spanning
                    ? _spanning(t, look, time)
                    : _cell(t, look, time, scaler, base, constraints.maxWidth, padding, narrow),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _cell(
    DenText t,
    EventLook look,
    String? time,
    TextScaler scaler,
    TextStyle base,
    double cell,
    double padding,
    bool narrow,
  ) {
    final titleStyle = base.merge(t.meta(look.ink).bold);
    final timeStyle = base.merge(t.caption(look.ink).copyWith(fontSize: 14 * t.scale));
    final iconGap = narrow ? 6.0 : Sp.s;
    double? timeWidth;
    // A narrow cell gives its room to the title: no time there.
    if (time != null && !narrow) {
      final painter = TextPainter(
        text: TextSpan(text: time, style: timeStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      timeWidth = painter.width + Sp.xs;
      painter.dispose();
    }
    final fit = CellFit.of(
      occ.title,
      style: titleStyle,
      scaler: scaler,
      width: cell - padding * 2,
      iconGap: iconGap,
      timeWidth: timeWidth,
      icon: cell >= dense,
    );
    final wrapped = fit.lines > 1;
    return Row(
      crossAxisAlignment: wrapped ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        if (fit.icon) ...[
          Padding(
            // Beside the first line of a wrapped title.
            padding: EdgeInsets.only(top: wrapped ? math.max(0, (fit.lineHeight - CellFit.cellIcon) / 2) : 0),
            child: Icon(look.icon, size: CellFit.cellIcon, color: look.ink),
          ),
          SizedBox(width: iconGap),
        ],
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  fit.text,
                  style: titleStyle,
                  maxLines: fit.maxLines,
                  overflow: TextOverflow.ellipsis,
                  softWrap: fit.maxLines > 1,
                ),
              ),
              if (fit.time && time != null) ...[
                const SizedBox(width: Sp.xs),
                Text(time, style: timeStyle, maxLines: 1, softWrap: false),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _spanning(DenText t, EventLook look, String? time) => Row(
    children: [
      Icon(look.icon, size: CellFit.cellIcon, color: look.ink),
      const SizedBox(width: Sp.s),
      Expanded(
        child: Wrap(
          spacing: Sp.s + 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(tidyLine(occ.title), style: t.meta(look.ink).bold),
            Text(
              time == null ? 'everyone' : '$time, everyone',
              style: t.caption(look.ink).copyWith(fontSize: 14 * t.scale),
            ),
          ],
        ),
      ),
      const SizedBox(width: Sp.s),
      FamilyDots(family: look.family),
    ],
  );
}

/// The smallest a time column can be at the current text size: the longest time it shows.
double timeColumnWidth(BuildContext context) => math.max(66, MediaQuery.textScalerOf(context).scale(68));
