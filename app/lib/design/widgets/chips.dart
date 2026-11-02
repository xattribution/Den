import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../motion.dart';
import '../tokens.dart';
import '../widgets.dart' show Star;

/// Something to check off, as a pill: a ring in the person's [color] that fills when [done],
/// the [label] (struck through when done), and its stars. 44 tall.
///
/// Tapping the ring checks it ([onCheck]); tapping the label opens more ([onOpen]: steps, Give
/// to…). A thing with steps fills its ring as an arc and checks through its steps, so its ring
/// opens too; once a step is done, "1 of 4" follows the label. [stars] null hides them (points
/// are off).
class CheckPill extends StatelessWidget {
  const CheckPill({
    super.key,
    required this.label,
    required this.color,
    required this.done,
    this.onCheck,
    this.onOpen,
    this.stars,
    this.steps,
    this.late = false,
    this.open = false,
  });

  final String label;
  final Color color;
  final bool done;

  /// Null when the person can't check it (shown, not tappable).
  final VoidCallback? onCheck;
  final VoidCallback? onOpen;
  final int? stars;

  /// (done, of) for a thing with steps.
  final (int, int)? steps;

  /// Past due: the label says so ("Late") after it.
  final bool late;

  /// Its details are showing below.
  final bool open;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final stepped = steps != null;
    final ring = CheckRing(color: color, done: done, progress: stepProgress(steps));
    final words = Text(
      label,
      style: t.control(done ? c.ink2 : c.ink).copyWith(
            decoration: done ? TextDecoration.lineThrough : null,
            decorationColor: c.ink2,
          ),
    );
    final checkTap = stepped ? onOpen : onCheck;
    final checkLabel = stepped
        ? '$label, ${steps!.$1} of ${steps!.$2} steps done'
        : '$label, ${done ? 'done' : 'not done'}';
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: c.card,
        shape: StadiumBorder(side: BorderSide(color: open ? c.ink : c.line, width: 1.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DenPressable(
            onTap: checkTap,
            haptic: !stepped,
            toggled: stepped ? null : done,
            semanticLabel: checkLabel,
            shape: const CircleBorder(),
            child: SizedBox(width: 42, height: Targets.adult, child: Center(child: ring)),
          ),
          Flexible(
            child: DenPressable(
              onTap: onOpen,
              scale: false,
              semanticLabel: onOpen == null ? null : 'More about $label',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Targets.adult),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(end: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: ExcludeSemantics(child: words)),
                      if (stepWords(steps, done: done) case final s?) ...[
                        const SizedBox(width: 6),
                        ExcludeSemantics(child: Text(s, style: t.meta(c.ink2))),
                      ],
                      if (late && !done) ...[
                        const SizedBox(width: 6),
                        Text('Late', style: t.meta(c.ink).bold),
                      ],
                      if (stars != null && stars! > 0) ...[
                        const SizedBox(width: 6),
                        Text('${stars!}', style: t.meta(c.ink2)),
                        const SizedBox(width: 2),
                        const Star(size: 13),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How far through its steps a thing is (0 to 1), or null for a thing without steps.
double? stepProgress((int, int)? steps) =>
    steps == null || steps.$2 <= 0 ? null : (steps.$1 / steps.$2).clamp(0.0, 1.0).toDouble();

/// "1 of 4" after a thing's name, once a step is done and until the last; null otherwise.
String? stepWords((int, int)? steps, {required bool done}) {
  if (steps == null || done) return null;
  final (n, of) = steps;
  return n > 0 && n < of ? '$n of $of' : null;
}

/// The ring a thing to check off shows, in the person's [color]: an empty ring, or filled with
/// an ink check when [done]. For a thing with steps, [progress] (0 to 1) lays a heavier arc of
/// the color over the ring: an empty ring at the start, closing as steps are checked. Never a
/// digit inside: at this size the font's slashed zero reads as a glitch. 26 across on a pill,
/// 32 to 34 on a row.
///
/// Checking it fills it on the check spring ([DenMotion.check], the one small settle allowed):
/// the color grows from the middle and the check lands with it. Steps close the arc on the UI
/// spring. A second tap mid-way turns it around; under Reduce Motion the two looks crossfade.
class CheckRing extends StatelessWidget {
  const CheckRing({super.key, required this.color, required this.done, this.progress, this.size = 26, this.checkColor});

  final Color color;
  final bool done;
  final double? progress;
  final double size;

  /// The check's color on the filled ring: dark ink on a person's color by default (lists, which
  /// are nobody's, fill with ink2 and a card-colored check).
  final Color? checkColor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stroke = size > 28 ? 2.5 : 2.0;
    final p = progress;
    final check = Icon(PhosphorIconsBold.check, size: (size * 0.62).roundToDouble(), color: checkColor ?? c.onMarker);
    Widget ring = SizedBox.square(
      dimension: size,
      child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: stroke))),
    );
    if (p != null) {
      ring = SpringValue(
        value: p,
        builder: (context, value, _) => CustomPaint(
          size: Size.square(size),
          painter: _ArcPainter(value.clamp(0.0, 1.0), color, stroke),
        ),
      );
    }
    return RepaintBoundary(
      child: SpringValue(
        value: done ? 1 : 0,
        spring: DenMotion.check,
        child: check,
        builder: (context, fill, check) {
          if (fill <= 0.001) return ring;
          if (fill >= 0.999 && fill <= 1.001) {
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color, border: Border.all(color: color, width: stroke)),
              alignment: Alignment.center,
              child: check,
            );
          }
          // Mid-way: the ring, the color growing inside it, the check scaling in with it.
          return SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ring,
                Transform.scale(
                  scale: fill.clamp(0.0, 1.1),
                  child: DecoratedBox(
                    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                    child: SizedBox.square(dimension: size),
                  ),
                ),
                Opacity(
                  opacity: fill.clamp(0.0, 1.0),
                  child: Transform.scale(scale: fill.clamp(0.0, 1.1), child: check),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.progress, this.color, this.stroke);

  final double progress;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    // The empty ring is the same ring an unstepped thing shows; the steps done lay a heavier
    // arc over it, from the top, clockwise.
    final band = stroke * 2;
    final rect = (Offset.zero & size).deflate(band / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..strokeWidth = stroke);
    if (progress > 0) {
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, paint..strokeWidth = band);
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.progress != progress || old.color != color || old.stroke != stroke;
}

/// Something to check off, as a full-width row (PadToday's chores): a 32 pt ring in the
/// person's [color], the [label] (struck through when done), and [detail] at the end (whose
/// it is). The ring checks ([onCheck]); the rest opens ([onOpen]), or checks too when there is
/// nothing more to open. 60 tall at least.
class CheckRow extends StatelessWidget {
  const CheckRow({
    super.key,
    required this.label,
    required this.color,
    required this.done,
    this.detail,
    this.onCheck,
    this.onOpen,
    this.stars,
    this.steps,
    this.late = false,
    this.open = false,
  });

  final String label;
  final Color color;
  final bool done;
  final String? detail;
  final VoidCallback? onCheck;
  final VoidCallback? onOpen;
  final int? stars;
  final (int, int)? steps;
  final bool late;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final stepped = steps != null;
    final checkTap = stepped ? onOpen : onCheck;
    final words = Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: t.body(done ? c.ink2 : c.ink).copyWith(
                  decoration: done ? TextDecoration.lineThrough : null,
                  decorationColor: c.ink2,
                ),
          ),
        ),
        if (stepWords(steps, done: done) case final s?) ...[const SizedBox(width: Sp.s), Text(s, style: t.meta(c.ink2))],
        if (late && !done) ...[const SizedBox(width: Sp.s), Text('Late', style: t.meta(c.ink).bold)],
        if (stars != null && stars! > 0) ...[
          const SizedBox(width: Sp.s),
          Text('${stars!}', style: t.meta(c.ink2)),
          const SizedBox(width: 2),
          const Star(size: 13),
        ],
        if (detail != null) ...[const SizedBox(width: Sp.m), Text(detail!, style: t.meta(c.ink2))],
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60),
      child: Row(
        children: [
          DenPressable(
            onTap: checkTap,
            haptic: !stepped,
            toggled: stepped ? null : done,
            semanticLabel: stepped ? '$label, ${steps!.$1} of ${steps!.$2} steps done' : '$label, ${done ? 'done' : 'not done'}',
            shape: const CircleBorder(),
            child: SizedBox.square(
              dimension: 48,
              child: Center(child: CheckRing(color: color, done: done, progress: stepProgress(steps), size: 32)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: DenPressable(
              onTap: onOpen ?? checkTap,
              scale: false,
              shape: const RoundedRectangleBorder(),
              selected: onOpen == null ? null : open,
              semanticLabel: onOpen == null ? null : 'More about $label',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Align(alignment: AlignmentDirectional.centerStart, child: ExcludeSemantics(child: words)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A choice among a few (a category, a kind): ink when chosen, the card color otherwise. 40
/// tall inside a 44 target.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, required this.selected, required this.onTap, this.icon});

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.onPrimary : (onTap == null ? c.ink3 : c.ink);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DenPressable(
        onTap: onTap,
        selected: selected,
        color: selected ? c.primary : c.card,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 6)],
                Flexible(child: Text(label, style: context.text.meta(fg).bold)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A person to filter by or choose: their face and name; chosen has an ink outline and a bold
/// name. 44 tall.
class PersonPill extends StatelessWidget {
  const PersonPill({super.key, required this.face, required this.name, required this.selected, required this.onTap});

  /// A 32 pt face.
  final Widget face;
  final String name;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPressable(
      onTap: onTap,
      selected: selected,
      color: c.card,
      semanticLabel: name,
      shape: StadiumBorder(side: BorderSide(color: selected ? c.ink : c.line, width: 1.5)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Targets.adult),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 16, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(dimension: 32, child: face),
              const SizedBox(width: Sp.s),
              Flexible(child: Text(name, style: selected ? t.control(c.ink).bold : t.control(c.ink))),
            ],
          ),
        ),
      ),
    );
  }
}

/// One thing Den understood, shown as a pill to adjust: an ink glyph and the value ("Wed,
/// 5:00 PM", "Leo", "Every week"). Outlined; tapping it opens its picker.
class ValueChip extends StatelessWidget {
  const ValueChip({super.key, required this.icon, required this.value, required this.label, this.onTap, this.missing = false});

  final IconData icon;
  final String value;

  /// What it is, for screen readers: "When", "Who", "Repeats".
  final String label;
  final VoidCallback? onTap;

  /// Den couldn't tell; the value asks ("Who?").
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenPressable(
      onTap: onTap,
      semanticLabel: '$label: $value',
      color: c.card,
      shape: StadiumBorder(side: BorderSide(color: missing ? c.ink : c.line, width: 1.5)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Targets.adult),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 16, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: c.ink),
              const SizedBox(width: 6),
              Flexible(child: Text(value, style: context.text.control(c.ink).bold)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A few mutually exclusive views ("Week", "Day"): a filled track with the chosen one in ink.
class DenSegmented<T> extends StatelessWidget {
  const DenSegmented({super.key, required this.options, required this.value, required this.onChanged});

  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final segments = [
      for (final MapEntry(:key, value: label) in options.entries)
        DenPressable(
          onTap: () {
            if (key != value) onChanged(key);
          },
          selected: key == value,
          color: key == value ? c.primary : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36, minWidth: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l),
              child: Center(
                widthFactor: 1,
                child: Text(label, style: key == value ? t.label(c.onPrimary) : t.control(c.ink2), maxLines: 1, softWrap: false),
              ),
            ),
          ),
        ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        // Labels never shrink or wrap; when large text makes them wider than the room, the
        // segments wrap onto a second line in a rounded track instead.
        final scaler = MediaQuery.textScalerOf(context);
        var needed = Sp.xs * 2;
        for (final label in options.values) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: t.label(c.ink)),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          needed += (painter.width + Sp.l * 2).clamp(72.0, double.infinity);
        }
        final fits = needed <= box.maxWidth;
        return DecoratedBox(
          decoration: ShapeDecoration(
            shape: fits
                ? const StadiumBorder()
                : const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.section))),
            color: c.fill,
          ),
          child: Padding(
            padding: const EdgeInsets.all(Sp.xs),
            child: fits
                ? Row(mainAxisSize: MainAxisSize.min, children: segments)
                : Wrap(spacing: Sp.xs, runSpacing: Sp.xs, children: segments),
          ),
        );
      },
    );
  }
}


/// A row of chips that scrolls sideways when they don't fit (the lists on Lists, people to
/// filter by), running to the screen's edges while its first chip lines up with the page.
/// [inset] is the page's side margin.
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.children, this.inset = 16, this.spacing = Sp.s});

  final List<Widget> children;
  final double inset;
  final double spacing;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.symmetric(horizontal: inset),
        child: Row(
          children: [
            for (final (i, child) in children.indexed) ...[if (i > 0) SizedBox(width: spacing), child],
          ],
        ),
      );
}
