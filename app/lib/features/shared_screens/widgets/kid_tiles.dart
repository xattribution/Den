import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/chunky.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// Kids mode's parts (KIDS_MODE_AND_SOFT_THEME.md, "Components"): the kid's picture, a job's
/// disc, the empty ring of a job still to do, the star pips, the chunky job tile, "Read my jobs
/// to me" and the grid they sit in. Every state has a shape as well as a color: done is a check
/// in a white disc on a filled face, to do is a pictogram (or an empty ring on the wall), stars
/// owed are drawn as pips.

/// The kid's picture in a disc of their color with a 3 dp white ring inside it: 56 on a phone,
/// 88 on the wall.
class KidAvatar extends StatelessWidget {
  const KidAvatar(this.kid, {super.key, this.size = KidLayout.avatar});

  final Member kid;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = context.colors.marker(kid.marker);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
            child: Padding(padding: const EdgeInsets.all(3), child: DenAvatar(kid, size: size - 12)),
          ),
        ),
      ),
    );
  }
}

/// A fat colored disc holding a navy pictogram, or once [done] (0 to 1, so it can move between
/// them) a white disc with a navy check drawing its stroke.
class KidDisc extends StatelessWidget {
  const KidDisc({super.key, required this.color, required this.glyph, this.done = 0, this.size = KidLayout.disc});

  final Color color;
  final IconData? glyph;
  final double done;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = done.clamp(0.0, 1.0);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Color.lerp(color, Colors.white, t), shape: BoxShape.circle),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (glyph != null && t < 0.5)
              Opacity(
                opacity: 1 - t * 2,
                child: Icon(glyph, size: size * 0.55, color: KidColors.navy),
              ),
            if (t > 0)
              CustomPaint(size: Size.square(size * 0.6), painter: CheckPainter(progress: ((t - 0.2) / 0.8).clamp(0.0, 1.0))),
          ],
        ),
      ),
    );
  }
}

/// A check mark in navy, drawn from its short stroke to its long one as [progress] goes 0 to 1.
class CheckPainter extends CustomPainter {
  CheckPainter({required this.progress, this.color = KidColors.navy});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final s = size.width;
    final path = Path()
      ..moveTo(s * 0.12, s * 0.52)
      ..lineTo(s * 0.4, s * 0.78)
      ..lineTo(s * 0.92, s * 0.22);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.16
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(CheckPainter old) => old.progress != progress || old.color != color;
}

/// A job still to do on the wall: an empty ring, 3:1 or better on the card.
class TodoRing extends StatelessWidget {
  const TodoRing({super.key, this.size = KidLayout.wallRing});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: context.kid.todoRing, width: math.max(3, size / 14)),
          ),
        ),
      );
}

/// Stars owed toward a target, drawn so a kid who can't read "3 more" still sees them: one pip
/// per star needed, gold with an edge when earned and [DenColors.fill] when not. Past 12 they
/// would be too small to count, so it is a bar.
class StarPips extends StatelessWidget {
  const StarPips({super.key, required this.have, required this.need});

  final int have;
  final int need;

  /// The most pips drawn; more is a bar.
  static const int maxPips = 12;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final earned = have.clamp(0, need);
    const height = 14.0;
    final edge = c.starEdge == c.star ? null : Border.all(color: c.starEdge, width: 1.5);
    return Semantics(
      label: '$earned of $need ${need == 1 ? 'star' : 'stars'}',
      child: ExcludeSemantics(
        child: need > maxPips || need < 1
            ? ClipRRect(
                borderRadius: BorderRadius.circular(height / 2),
                child: SizedBox(
                  height: height,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: c.fill),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: need < 1 ? 1 : earned / need,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: c.star, borderRadius: BorderRadius.circular(height / 2), border: edge),
                      ),
                    ),
                  ),
                ),
              )
            : LayoutBuilder(
                builder: (context, box) {
                  const gap = 4.0;
                  final width = math.min(22.0, (box.maxWidth - gap * (need - 1)) / need);
                  return Row(
                    children: [
                      for (var i = 0; i < need; i++) ...[
                        if (i > 0) const SizedBox(width: gap),
                        Container(
                          width: width,
                          height: height,
                          decoration: BoxDecoration(
                            color: i < earned ? c.star : c.fill,
                            borderRadius: BorderRadius.circular(height / 2),
                            border: i < earned ? edge : null,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }
}

/// One job as a chunky tile (KIDS_MODE_AND_SOFT_THEME.md, component 1). To do: a white face on a
/// [DenColors.line] lip, a 60 disc in [disc] with the job's navy pictogram, its title, and "+2
/// stars" or "1 of 3". Done: the face and lip in the kid's own [person] color, a white disc with
/// a navy check, the title and "Done". The whole tile is the button; a long press reads it out.
///
/// The fill crossfades to the kid's color and the check draws its stroke on the check spring;
/// under Reduce Motion both are a 100 ms fade. Titles wrap and the tile grows; they never
/// truncate.
class KidJobTile extends StatelessWidget {
  const KidJobTile({
    super.key,
    required this.title,
    required this.glyph,
    required this.disc,
    required this.person,
    required this.done,
    required this.onTap,
    this.meta,
    this.metaStar = false,
    this.onLongPress,
    this.semanticLabel,
    this.toggled,
  });

  final String title;
  final IconData? glyph;

  /// The disc's color while it's to do: a kid primary on the kid's own board.
  final Color disc;

  /// The kid's color, which a done tile fills with.
  final Color person;
  final bool done;

  /// "+2 stars", "1 of 3"; "Done" when done.
  final String? meta;

  /// Draws a small star before [meta] (points, not steps).
  final bool metaStar;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  /// Whether a tap checks it (null for a job that opens its steps instead).
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reduced = DenMotion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: done ? 1 : 0),
      duration: reduced ? DenMotion.fade : DenMotion.checkSettle,
      curve: reduced ? Curves.linear : DenMotion.checkCurve,
      builder: (context, v, _) {
        final t = v.clamp(0.0, 1.0);
        final face = Color.lerp(c.card, person, t)!;
        final lip = Color.lerp(c.line, KidColors.lipOf(person), t)!;
        final ink = t < 0.5 ? c.ink : c.onMarker;
        final quiet = t < 0.5 ? c.ink2 : c.onMarker;
        final words = done ? 'Done' : meta;
        return ChunkyPressable(
          onTap: onTap,
          onLongPress: onLongPress,
          longPressHint: 'Read it to me',
          face: face,
          lip: lip,
          toggled: toggled,
          semanticLabel: semanticLabel,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: KidLayout.tileMinHeight, minWidth: KidLayout.minTarget),
            child: Padding(
              padding: const EdgeInsets.all(KidLayout.tilePadding),
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    KidDisc(color: disc, glyph: glyph, done: v),
                    const SizedBox(height: 10),
                    Text(title, textAlign: TextAlign.center, style: context.text.kidJob(ink)),
                    if (words != null) ...[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (metaStar && !done) ...[Star(size: MediaQuery.textScalerOf(context).scale(18)), const SizedBox(width: Sp.xs)],
                          Flexible(child: Text(words, textAlign: TextAlign.center, style: context.text.kidMeta(done ? ink : quiet))),
                        ],
                      ),
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

/// "Read my jobs to me": a full-width navy slab, 72 tall, with a speaker. Pinned to the bottom
/// of a phone for pre-readers; under the star card on a tablet.
class ReadToMeBar extends StatelessWidget {
  const ReadToMeBar({super.key, required this.onTap, this.label = 'Read my jobs to me'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ChunkyPressable(
      onTap: onTap,
      face: c.primary,
      lip: KidColors.lipOf(c.primary),
      depth: Lip.card,
      radius: Radii.kidButton,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: KidLayout.readBarHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.m),
          child: ExcludeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(PhosphorIconsBold.speakerHigh, size: 32, color: c.onPrimary),
                const SizedBox(width: Sp.m),
                Flexible(child: Text(label, style: context.text.kidJob(c.onPrimary))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiles [columns] across, [KidLayout.gridGap] apart, each row as tall as its tallest tile. When
/// a title would wrap to a third line at this width (large text), it drops a column, down to
/// one, so titles keep to two lines where they can and never truncate.
class KidGrid extends StatelessWidget {
  const KidGrid({super.key, required this.columns, required this.titles, required this.children});

  final int columns;

  /// Each tile's title, in order, to measure.
  final List<String> titles;
  final List<Widget> children;

  /// How many columns fit [titles] in [width] at [style] in two lines, from [columns] down.
  static int fit({
    required int columns,
    required double width,
    required List<String> titles,
    required TextStyle style,
    required TextScaler scaler,
  }) {
    for (var n = columns; n > 1; n--) {
      final inner = (width - KidLayout.gridGap * (n - 1)) / n - KidLayout.tilePadding * 2;
      final fits = titles.every((title) {
        final painter = TextPainter(
          text: TextSpan(text: title, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: inner);
        final lines = painter.computeLineMetrics().length;
        painter.dispose();
        return lines <= 2;
      });
      if (fits) return n;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final n = fit(
          columns: columns,
          width: box.maxWidth,
          titles: titles,
          style: context.text.kidJob(context.colors.ink),
          scaler: MediaQuery.textScalerOf(context),
        );
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += n) {
          rows.add(IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < n; j++) ...[
                  if (j > 0) const SizedBox(width: KidLayout.gridGap),
                  Expanded(child: i + j < children.length ? children[i + j] : const SizedBox.shrink()),
                ],
              ],
            ),
          ));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final (i, r) in rows.indexed) ...[if (i > 0) const SizedBox(height: KidLayout.gridGap), r]],
        );
      },
    );
  }
}
