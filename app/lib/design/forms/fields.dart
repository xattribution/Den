import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../tokens.dart';
import '../widgets.dart';
import 'choices.dart';

/// Labels, steppers, pictogram grids, day toggles, switch rows and errors for every form.

/// The label above a field or a group of controls. Help goes in [info] (an (i) beside it), never
/// under it.
///
/// [FieldLabel] heads a group in an editor (chores, lists, points), with room above it.
/// [FieldLabel.quiet] is the calendar and family forms' label: meta type in ink2, nothing above.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.info, this.trailing, this.top = Sp.xl}) : quiet = false;

  const FieldLabel.quiet(this.text, {super.key, this.info, this.trailing})
      : quiet = true,
        top = 0;

  final String text;
  final String? info;
  final Widget? trailing;
  final double top;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: Sp.s),
      child: Row(
        children: [
          Semantics(
            header: true,
            child: Text(text, style: quiet ? context.type.meta(c.ink2) : context.type.bodyStrong(c.ink)),
          ),
          if (info != null) InfoTip(info!),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// "Anyone" as a person choice, shaped like [PersonChip] with a group glyph for the avatar.
class AnyoneChip extends StatelessWidget {
  const AnyoneChip({super.key, required this.selected, required this.onTap, this.label = 'Anyone'});

  final bool selected;
  final VoidCallback? onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.ink : c.well,
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
                  AnyoneMark(size: 30, onInk: selected),
                  const SizedBox(width: Sp.s),
                  Text(label, style: context.type.body(selected ? c.onInk : c.ink)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The stand-in avatar for "Anyone": a ring with a group glyph, in ink (it is nobody's color).
class AnyoneMark extends StatelessWidget {
  const AnyoneMark({super.key, this.size = 28, this.onInk = false});

  final double size;
  final bool onInk;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = onInk ? c.onInk : c.ink2;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: fg, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Icon(PhosphorIconsRegular.usersThree, size: size * 0.58, color: fg),
    );
  }
}

/// A whole number with minus and plus buttons; 48 dp targets, tabular figures.
class NumberStepper extends StatelessWidget {
  const NumberStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 999,
    this.step = 1,
    this.suffix,
    this.label,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final int step;
  final Widget? suffix;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: label,
      value: '$value',
      increasedValue: '${(value + step).clamp(min, max)}',
      decreasedValue: '${(value - step).clamp(min, max)}',
      onIncrease: value < max ? () => onChanged((value + step).clamp(min, max)) : null,
      onDecrease: value > min ? () => onChanged((value - step).clamp(min, max)) : null,
      child: Container(
        decoration: BoxDecoration(color: c.well, borderRadius: BorderRadius.circular(Radii.control)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Fewer',
              onPressed: value > min ? () => onChanged((value - step).clamp(min, max)) : null,
              icon: const Icon(PhosphorIconsBold.minus, size: 18),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 36),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ExcludeSemantics(child: Text('$value', style: context.type.title(c.ink))),
                  if (suffix != null) ...[const SizedBox(width: Sp.xs), suffix!],
                ],
              ),
            ),
            IconButton(
              tooltip: 'More',
              onPressed: value < max ? () => onChanged((value + step).clamp(min, max)) : null,
              icon: const Icon(PhosphorIconsBold.plus, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// A grid of pictograms to choose one from. The chosen one is a solid ink tile.
class PictogramGrid extends StatelessWidget {
  const PictogramGrid({super.key, required this.icons, required this.value, required this.onChanged});

  final Map<String, IconData> icons;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        // As many 48 dp cells as fit, then stretched so the grid fills the row edge to edge.
        const gap = Sp.xs;
        final columns = ((constraints.maxWidth + gap) / (Targets.adult + gap)).floor().clamp(1, 12);
        final cell = (constraints.maxWidth - (columns - 1) * gap) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final entry in icons.entries)
              Semantics(
                button: true,
                selected: entry.key == value,
                label: pictogramName(entry.key),
                child: Material(
                  color: entry.key == value ? c.ink : Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.control),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.control),
                    onTap: () => onChanged(entry.key),
                    child: SizedBox(
                      width: cell,
                      height: Targets.adult,
                      child: Icon(entry.value, size: 26, color: entry.key == value ? c.onInk : c.ink2),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A readable name for a pictogram key, for screen readers.
String pictogramName(String key) => switch (key) {
  'check' => 'Check mark',
  'tooth' => 'Teeth',
  'dishes' => 'Dishes',
  'pet' => 'Pet',
  'homework' => 'Homework',
  'hanger' => 'Clothes',
  'spray' => 'Cleaning',
  'tools' => 'Tools',
  'ice' => 'Treat',
  _ => key.isEmpty ? key : '${key[0].toUpperCase()}${key.substring(1)}',
};

/// Seven day toggles in the family's week order. [days] holds `DateTime.weekday` values
/// (1 Monday to 7 Sunday).
class DayToggles extends StatelessWidget {
  const DayToggles({super.key, required this.days, required this.onChanged, this.weekStart = 0});

  final Set<int> days;
  final ValueChanged<Set<int>> onChanged;

  /// 0 Sunday, 1 Monday, as stored on the family.
  final int weekStart;

  static const _short = {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun'};
  static const _long = {
    1: 'Monday',
    2: 'Tuesday',
    3: 'Wednesday',
    4: 'Thursday',
    5: 'Friday',
    6: 'Saturday',
    7: 'Sunday',
  };

  @override
  Widget build(BuildContext context) {
    final first = weekStart == 0 ? 7 : 1;
    final order = [for (var i = 0; i < 7; i++) ((first - 1 + i) % 7) + 1];
    return Row(
      children: [
        for (final d in order) ...[
          Expanded(
            child: ChoiceTile.chip(
              label: _short[d]!,
              padding: 0,
              semanticsLabel: _long[d],
              selected: days.contains(d),
              onTap: () {
                final next = {...days};
                if (!next.remove(d)) next.add(d);
                onChanged(next);
              },
            ),
          ),
          if (d != order.last) const SizedBox(width: 2),
        ],
      ],
    );
  }
}

/// A switch row with a label and optional help.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.label, required this.value, required this.onChanged, this.info});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? info;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Targets.adult),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(child: Text(label, style: context.type.body(c.ink))),
                    if (info != null) InfoTip(info!),
                  ],
                ),
              ),
              const SizedBox(width: Sp.s),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// Error text under a field, in the bad color with its icon; nothing when [message] is null.
/// [body] sets it in body type, as the calendar's forms do.
class FieldError extends StatelessWidget {
  const FieldError(this.message, {super.key, this.body = false});
  final String? message;
  final bool body;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    final c = context.colors;
    if (body) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(PhosphorIconsFill.warningOctagon, size: 18, color: c.bad),
          ),
          const SizedBox(width: Sp.s),
          Expanded(child: Text(message!, style: context.type.body(c.bad))),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Sp.xs),
      child: Row(
        children: [
          Icon(PhosphorIconsFill.warningOctagon, size: 16, color: c.bad),
          const SizedBox(width: Sp.xs),
          Expanded(child: Text(message!, style: context.type.meta(c.bad))),
        ],
      ),
    );
  }
}

/// Caps editor and detail content at a readable width on tablets and desktops, starting at the
/// same left edge as the page title.
class FormWidth extends StatelessWidget {
  const FormWidth({super.key, required this.child, this.max = 640});
  final Widget child;
  final double max;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: max),
      child: child,
    ),
  );
}

/// Pulls a control left by the empty margin inside its touch target, so its visible edge (a
/// check circle, a text button's icon) lines up with the text edge above it.
class Hang extends StatelessWidget {
  const Hang({super.key, required this.by, required this.child});
  final double by;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // A row that fills its parent also grows by [by], so its right edge stays put.
      final fills = constraints.hasTightWidth;
      return Transform.translate(
        offset: Offset(-by, 0),
        child: fills
            ? OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: constraints.maxWidth + by,
                maxWidth: constraints.maxWidth + by,
                fit: OverflowBoxFit.deferToChild,
                child: child,
              )
            : child,
      );
    },
  );
}

/// The destructive action at the end of an editor or detail page: icon and word in `bad`.
class DestructiveButton extends StatelessWidget {
  const DestructiveButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: Hang(
        by: Sp.s,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: c.bad,
            padding: const EdgeInsets.symmetric(horizontal: Sp.s),
          ),
          onPressed: onPressed,
          icon: Icon(PhosphorIconsRegular.trash, size: 18, color: c.bad),
          label: Text(label, style: context.type.bodyStrong(c.bad)),
        ),
      ),
    );
  }
}
