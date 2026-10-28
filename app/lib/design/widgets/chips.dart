import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../motion.dart';
import '../tokens.dart';
import '../widgets.dart' show Star;

/// Something to check off, as a pill: a ring in the person's [color] that fills when [done],
/// the [label] (struck through when done), and its stars. 44 tall.
///
/// Tapping the ring checks it ([onCheck]); tapping the label opens more ([onOpen]: steps, Give
/// to…). A thing with steps shows how many are done in the ring and checks through its steps,
/// so its ring opens too. [stars] null hides them (points are off).
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
    final ring = CheckRing(color: color, done: done, stepsDone: steps?.$1);
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

/// The ring a thing to check off shows: the person's [color], filled with an ink check when
/// [done], or how many steps are done. 26 across on a pill, 32 on a row.
class CheckRing extends StatelessWidget {
  const CheckRing({super.key, required this.color, required this.done, this.stepsDone, this.size = 26});

  final Color color;
  final bool done;
  final int? stepsDone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? color : null,
        border: Border.all(color: color, width: size > 28 ? 2.5 : 2),
      ),
      alignment: Alignment.center,
      child: done
          ? Icon(PhosphorIconsBold.check, size: (size * 0.62).roundToDouble(), color: c.onMarker)
          : stepsDone != null
              ? Text('$stepsDone', style: t.caption(c.ink).bold, textScaler: TextScaler.noScaling)
              : null,
    );
  }
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
              child: Center(child: CheckRing(color: color, done: done, stepsDone: steps?.$1, size: 32)),
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
    return DecoratedBox(
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: c.fill),
      child: Padding(
        padding: const EdgeInsets.all(Sp.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                      child: Text(label, style: key == value ? t.label(c.onPrimary) : t.control(c.ink2)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
