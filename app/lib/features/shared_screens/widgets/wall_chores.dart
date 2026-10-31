import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/chunky.dart';
import '../../../design/glyphs.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../calendar/widgets/date_strip.dart' show SpringPagePhysics;
import '../../chores/chores.dart';
import '../screens/wall_screen.dart' show wallChoreAction, wallWrite;
import 'kid_parts.dart';
import 'kid_tiles.dart';

/// The wall's chores board (KIDS_MODE_AND_SOFT_THEME.md, "Layouts", `mocks/kid-chore-board-wall
/// .png`): one column per kid, each with their picture, name, "2 of 4 done" and star total,
/// then today's jobs as 156-tall chunky rows. Two to four kids share the width; five or more
/// page sideways, as many to a page as fit. Several kids share this screen, so a job's disc is
/// its kid's color, never a kid primary: a hue still means a person here.
///
/// One tap anywhere on a row checks it (asking "Who's doing this?" unless the person acting, or
/// open check-off, allows it); a long press reads it out. Wall screens rarely have haptics, so
/// there are none; a press sinks the row 8.
class WallChoresBoard extends StatelessWidget {
  const WallChoresBoard({super.key, required this.onAct});

  /// After a write, so the wall redraws its sign-in countdown.
  final VoidCallback onAct;

  /// A column is never narrower than this; past it, kids go to a second page.
  static const double minColumn = 340;

  /// The most kids side by side.
  static const int maxColumns = 4;

  /// How many kids' columns fit side by side in [width] with [margin] and [gap].
  static int columnsFor(double width, {required double margin, required double gap, required int kids}) {
    final fit = ((width - margin * 2 + gap) / (minColumn + gap)).floor();
    return math.max(1, math.min(math.min(fit, maxColumns), kids));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.chore, RecordType.completion, RecordType.adjustment, RecordType.redemption});
    final den = app.den;
    final kids = den.members.where((m) => m.isKid).toList();
    if (kids.isEmpty) return const EmptyLine(message: 'No kids in the family yet.');
    final chores = den.today().chores;

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1100;
        final margin = wide ? KidLayout.wallMargin : Sp.xl;
        final gap = wide ? KidLayout.wallColumnGap : Sp.xl;
        final perPage = columnsFor(box.maxWidth, margin: margin, gap: gap, kids: kids.length);
        final pages = (kids.length / perPage).ceil();

        Widget page(int index) {
          final shown = kids.skip(index * perPage).take(perPage).toList();
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: margin),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < perPage; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  Expanded(
                    child: i < shown.length
                        ? WallKidColumn(
                            key: ValueKey(shown[i].id),
                            kid: shown[i],
                            days: [for (final d in chores) if (d.owner == shown[i].id) d],
                            onAct: onAct,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          );
        }

        if (pages == 1) return page(0);
        return Semantics(
          hint: 'Swipe for more kids',
          container: true,
          child: PageView.builder(
            physics: const SpringPagePhysics(),
            itemCount: pages,
            itemBuilder: (context, i) => page(i),
          ),
        );
      },
    );
  }
}

/// One kid on the wall: picture, name, how many of today's jobs are done and their stars, then
/// their jobs.
class WallKidColumn extends StatelessWidget {
  const WallKidColumn({super.key, required this.kid, required this.days, required this.onAct});

  final Member kid;
  final List<ChoreDay> days;
  final VoidCallback onAct;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final den = app.den;
    final c = context.colors;
    final t = context.text;
    final person = c.marker(kid.marker);
    final pointsOn = den.family?.pointsEnabled ?? true;
    final done = days.where((d) => d.done).length;
    final stars = pointsOn ? den.points().available(kid.id) : null;
    final summary = days.isEmpty ? 'No jobs today' : '$done of ${days.length} done';

    final header = Semantics(
      header: true,
      label: [kid.name, summary, if (stars != null) '$stars ${stars == 1 ? 'star' : 'stars'}'].join(', '),
      child: ExcludeSemantics(
        child: Row(
          children: [
            KidAvatar(kid, size: KidLayout.wallAvatar),
            const SizedBox(width: Sp.xl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kid.name, style: t.kidWall(48, FontWeight.w800, c.ink, height: 1.1)),
                  Text(summary, style: t.kidWall(24, FontWeight.w400, c.ink2)),
                ],
              ),
            ),
            if (stars != null) ...[
              const SizedBox(width: Sp.m),
              Star(size: MediaQuery.textScalerOf(context).scale(52 / 1.3 * t.scale)),
              const SizedBox(width: Sp.s),
              Text('$stars', style: t.kidWall(44, FontWeight.w800, c.ink, height: 1)),
            ],
          ],
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.only(top: 40, bottom: KidLayout.wallMargin),
      children: [
        header,
        const SizedBox(height: 36),
        for (final (i, d) in days.indexed) ...[
          if (i > 0) const SizedBox(height: KidLayout.wallTileGap - Lip.wall),
          WallJobRow(day: d, person: person, pointsOn: pointsOn, onAct: onAct),
        ],
      ],
    );
  }
}

/// A job on the wall: a 156-tall chunky row with a 100 disc in the kid's color holding its
/// pictogram, its title and stars, and an empty 68 ring at the end; done, the row fills with the
/// kid's color and the disc turns white with a check.
class WallJobRow extends StatelessWidget {
  const WallJobRow({super.key, required this.day, required this.person, required this.pointsOn, required this.onAct});

  final ChoreDay day;
  final Color person;
  final bool pointsOn;
  final VoidCallback onAct;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final chore = day.chore;
    final done = day.done;
    final stepped = chore.steps.isNotEmpty;
    final points = pointsOn && day.pointsAvailable > 0;
    final meta = done
        ? 'Done'
        : stepped
            ? '${day.stepsDone} of ${day.stepCount}'
            : points
                ? '+${day.pointsAvailable} ${day.pointsAvailable == 1 ? 'star' : 'stars'}'
                : null;
    final ink = done ? c.onMarker : c.ink;

    Future<void> toggle() async {
      await wallWrite(
        context,
        (actor) => wallChoreAction(day, actor),
        () => context.choreActions.setDone(day, !done),
        likely: day.owner,
      );
      onAct();
    }

    Future<void> read() async {
      final problem = await speak(choreWords(chore));
      if (problem != null && context.mounted) showNote(context, problem);
    }

    // Four kids to a 1080p wall leaves a column about 410 wide: there the disc, ring and words
    // step down so a word like "Biscuit" still fits on its line.
    return LayoutBuilder(
      builder: (context, box) {
        final roomy = box.maxWidth >= 520;
        return ChunkyPressable(
          onTap: toggle,
          onLongPress: read,
          longPressHint: 'Read it to me',
          face: done ? person : c.card,
          lip: done ? KidColors.lipOf(person) : c.line,
          depth: Lip.wall,
          radius: Radii.kidTileWall,
          haptic: false,
          toggled: done,
          semanticLabel: [chore.title, ?meta].join(', '),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: roomy ? KidLayout.wallRowHeight : 120),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: roomy ? 36 : Sp.l + 4, vertical: Sp.l),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    KidDisc(
                      color: person,
                      glyph: choreGlyph(chore.icon, chore.title),
                      done: done ? 1 : 0,
                      size: roomy ? KidLayout.wallDisc : 72,
                      ink: c.onMarker,
                    ),
                    SizedBox(width: roomy ? 28 : Sp.l),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(chore.title, style: t.kidWall(roomy ? 40 : 32, FontWeight.w800, ink)),
                          if (meta != null)
                            Row(
                              children: [
                                if (points && !done && !stepped) ...[
                                  Star(size: MediaQuery.textScalerOf(context).scale((roomy ? 24 : 20) / 1.3 * t.scale)),
                                  const SizedBox(width: Sp.s),
                                ],
                                Flexible(
                                  child: Text(meta, style: t.kidWall(roomy ? 26 : 22, FontWeight.w700, done ? ink : c.ink2)),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    if (!done) ...[
                      SizedBox(width: roomy ? Sp.l : Sp.s),
                      TodoRing(size: roomy ? KidLayout.wallRing : 52),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
