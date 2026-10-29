import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'avatar.dart';
import 'motion.dart';
import 'tokens.dart';

export 'avatar.dart';
export 'feedback.dart';
export 'pickers/people_picker.dart';
export 'pickers/sheet_pickers.dart';
export 'widgets/buttons.dart';
export 'widgets/chips.dart';
export 'widgets/choices.dart';
export 'widgets/disclosure.dart';
export 'widgets/inputs.dart';
export 'widgets/navigation.dart';
export 'widgets/page.dart';
export 'widgets/progress.dart';
export 'widgets/rows.dart';
export 'widgets/section.dart';
export 'widgets/sheet_header.dart';
export 'widgets/states.dart';
export 'widgets/switch_line.dart';

/// The vertical marker bar beside an event or chore: one segment per person it belongs to.
/// Items for everyone show every member's segment.
class PersonBar extends StatelessWidget {
  const PersonBar({super.key, required this.markers, this.width = 4, this.minHeight = 32});

  final List<Marker> markers;
  final double width;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final segments = markers.isEmpty ? [c.line] : markers.map(c.marker).toList();
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: SizedBox(
        width: width,
        child: Column(
          children: [
            for (final color in segments)
              Expanded(child: Container(width: width, color: color)),
          ],
        ),
      ),
    );
  }
}

/// The round check box of the fridge chart: an empty ring, or solid ink with a check.
/// Done is readable without color: the check mark and the strike-through on the label.
class CheckDot extends StatelessWidget {
  const CheckDot({
    super.key,
    required this.done,
    required this.onChanged,
    this.size = 26,
    this.label,
  });

  final bool done;
  final ValueChanged<bool>? onChanged;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onChanged != null;
    final target = math.max(size + 16, Targets.adult);
    return Semantics(
      checked: done,
      enabled: enabled,
      label: label,
      button: true,
      child: InkResponse(
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onChanged!(!done);
              }
            : null,
        radius: target / 2,
        child: SizedBox(
          width: target,
          height: target,
          child: Center(
            // Fills on the check spring, like every check (CheckRing).
            child: SpringValue(
              value: done ? 1 : 0,
              spring: DenMotion.check,
              builder: (context, fill, _) {
                final on = fill.clamp(0.0, 1.0);
                return SizedBox.square(
                  dimension: size,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Color.lerp(enabled ? c.ink2 : c.ink3, c.ink, on)!, width: 2),
                        ),
                        child: SizedBox.square(dimension: size),
                      ),
                      if (fill > 0.001)
                        Transform.scale(
                          scale: fill.clamp(0.0, 1.1),
                          child: DecoratedBox(
                            decoration: BoxDecoration(shape: BoxShape.circle, color: c.ink),
                            child: SizedBox.square(
                              dimension: size,
                              child: Icon(PhosphorIconsBold.check, size: size * 0.62, color: c.onPrimary),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Points: the star sticker shape in star gold with an edge for contrast, and the number.
class StarCount extends StatelessWidget {
  const StarCount(this.points, {super.key, this.size = 16, this.style});

  final int points;
  final double size;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: '$points ${points == 1 ? 'star' : 'stars'}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$points', style: style ?? context.type.meta(c.ink2)),
          const SizedBox(width: 2),
          Star(size: size),
        ],
      ),
    );
  }
}

class Star extends StatelessWidget {
  const Star({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(PhosphorIconsFill.star, size: size, color: c.starEdge),
          Icon(PhosphorIconsFill.star, size: size * 0.78, color: c.star),
        ],
      ),
    );
  }
}

/// A person choice: avatar and name. Selected is a solid ink fill (owner rule O1).
class PersonChip extends StatelessWidget {
  const PersonChip({super.key, required this.member, required this.selected, required this.onTap});

  final Member member;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.ink : c.card,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DenAvatar(member, size: 30),
                  const SizedBox(width: Sp.s),
                  Text(member.name, style: context.type.body(selected ? c.onPrimary : c.ink)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of mutually exclusive choices with a solid selected segment.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.value, required this.onChanged});

  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in options.entries)
            Semantics(
              selected: entry.key == value,
              button: true,
              child: Material(
                color: entry.key == value ? c.ink : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.pill),
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  onTap: () => onChanged(entry.key),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 38, minWidth: 48),
                    padding: const EdgeInsets.symmetric(horizontal: Sp.m),
                    alignment: Alignment.center,
                    child: Text(
                      entry.value,
                      style: entry.key == value ? context.type.bodyStrong(c.onPrimary) : context.type.body(c.ink2),
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

/// A group heading with an optional count or summary on the right. No subtitle (rule O3).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.action});

  final String title;
  final String? trailing;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.s, Sp.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Semantics(header: true, child: Text(title, style: context.type.title(c.ink)))),
          if (trailing != null) Text(trailing!, style: context.type.meta(c.ink2)),
          ?action,
        ],
      ),
    );
  }
}

/// The (i) next to a label: help on hover, focus or tap, never printed on the page.
class InfoTip extends StatelessWidget {
  const InfoTip(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      child: Focus(
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.symmetric(horizontal: Sp.xs),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: focused ? c.ink : c.ink2, width: focused ? 2 : 1),
              ),
              child: Text('i', style: context.type.meta(c.ink2).copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
            );
          },
        ),
      ),
    );
  }
}

/// A state that needs a person (a gap, a conflict, an approval) in ink, or one that went wrong
/// (late, failed) in destructive red. Always icon plus words; there is no caution color.
class AttentionLine extends StatelessWidget {
  const AttentionLine({super.key, required this.message, this.bad = false, this.action});

  final String message;
  final bool bad;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = bad ? c.destructive : c.ink;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.xs),
      child: Row(
        children: [
          Icon(bad ? PhosphorIconsFill.warningOctagon : PhosphorIconsFill.warning, size: 18, color: color),
          const SizedBox(width: Sp.s),
          Expanded(child: Text(message, style: context.type.body(color))),
          ?action,
        ],
      ),
    );
  }
}

/// An empty state: why it's empty and one thing to do about it.
class EmptyLine extends StatelessWidget {
  const EmptyLine({super.key, required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.l),
      child: Row(
        children: [
          Expanded(child: Text(message, style: context.type.body(c.ink2))),
          if (actionLabel != null) OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// A fact on a detail page: its label in a column on the left, the value beside it.
///
/// [FactRow] is the event page's: inside the page gutters, with a label column that grows with
/// the text. [center] is for a value that holds a button: the label centers on it, and the
/// button's own 48 px height stands in for the row's padding. [FactRow.compact] is the chore
/// page's: inside the page's own padding, read by screen readers as one phrase.
class FactRow extends StatelessWidget {
  const FactRow({super.key, required this.label, required this.child, this.center = false}) : _compact = false;

  const FactRow.compact({super.key, required this.label, required this.child})
      : center = false,
        _compact = true;

  final String label;
  final Widget child;
  final bool center;
  final bool _compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_compact) {
      return MergeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.s - 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 108,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(label, style: context.type.meta(c.ink2)),
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(Sp.l, center ? 0 : Sp.s, Sp.l, center ? 0 : Sp.s),
      child: Row(
        crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96 * context.type.scale,
            child: Padding(
              padding: EdgeInsets.only(top: center ? 0 : 2),
              child: Text(label, style: context.type.meta(c.ink2)),
            ),
          ),
          const SizedBox(width: Sp.s),
          Expanded(child: child),
        ],
      ),
    );
  }
}
