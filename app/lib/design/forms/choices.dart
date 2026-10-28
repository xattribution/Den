import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../tokens.dart';

/// One choice among several, in a Wrap or a [ChoiceRow]: solid ink when chosen (owner rule O1),
/// the well otherwise. Radius 6, like every control.
///
/// [ChoiceTile] is 44 tall with an ink ripple (calendar and family forms). [ChoiceTile.chip] is
/// a 40 tall chip inside a 48 tall target, with a selection click and an optional [count] (the
/// chores, lists and points editors, and [DayToggles]).
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.semanticsLabel,
    this.padding = Sp.m,
  })  : count = null,
        _chip = false;

  const ChoiceTile.chip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.count,
    this.semanticsLabel,
    this.padding = Sp.m,
  }) : _chip = true;

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? semanticsLabel;

  /// A number after the label (a chip only), such as how many items a store has.
  final int? count;

  /// Space on each side of the label; [ChoiceRow] narrows it to fit equal tiles, and day
  /// toggles use none to fit seven across a phone.
  final double padding;

  final bool _chip;

  @override
  Widget build(BuildContext context) => _chip ? _buildChip(context) : _buildTile(context);

  Widget _buildChip(BuildContext context) {
    final c = context.colors;
    final enabled = onTap != null;
    final fg = selected ? c.onInk : (enabled ? c.ink : c.ink3);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onTap!();
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.xs),
          child: AnimatedContainer(
            duration: Motion.of(context, Motion.state),
            curve: Motion.curve,
            constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
            padding: EdgeInsets.symmetric(horizontal: padding),
            decoration: BoxDecoration(
              color: selected ? c.ink : c.well,
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: Sp.s - 2)],
                Text(label, style: selected ? context.type.bodyStrong(fg) : context.type.body(fg)),
                if (count != null) ...[
                  const SizedBox(width: Sp.s - 2),
                  Text('$count', style: context.type.meta(selected ? c.onInk : c.ink2)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTile(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.onInk : (onTap == null ? c.ink3 : c.ink);
    return Semantics(
      selected: selected,
      button: true,
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: Material(
        color: selected ? c.ink : c.well,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: Targets.adult, minWidth: Targets.adult),
            padding: EdgeInsets.fromLTRB(icon == null ? padding : Sp.s + 2, 0, padding, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: selected ? c.onInk : c.ink2),
                  const SizedBox(width: Sp.s - 2),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: selected ? context.type.bodyStrong(fg) : context.type.body(fg),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mutually exclusive choices as equal tiles across the width when every label fits, else
/// wrapped like chips. Equal tiles keep a short set from leaving one option alone on a line.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({super.key, required this.options, required this.value, required this.onChanged});

  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = context.type.bodyStrong(c.ink);
    final scaler = MediaQuery.textScalerOf(context);
    final widths = <double>[];
    for (final label in options.values) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widths.add(painter.width.ceilToDouble() + Sp.s * 2 + 2);
      painter.dispose();
    }
    final widest = widths.fold<double>(0, (a, b) => a > b ? a : b);
    final natural = widths.fold<double>(0, (a, b) => a + b) + _gap * (widths.length - 1);
    Widget tile(MapEntry<T, String> e, {double padding = Sp.m}) => ChoiceTile(
          label: e.value,
          selected: e.key == value,
          padding: padding,
          onTap: () {
            if (e.key != value) onChanged(e.key);
          },
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        final n = options.length;
        final each = (constraints.maxWidth - _gap * (n - 1)) / n;
        final equal = widest <= each;
        if (equal || natural <= constraints.maxWidth) {
          // Equal tiles when every label fits one; otherwise each takes room in proportion to
          // its label, so the row still spans the width on one line.
          return Row(
            children: [
              for (final (i, e) in options.entries.indexed) ...[
                if (i > 0) const SizedBox(width: _gap),
                Expanded(flex: equal ? 1 : widths[i].round(), child: tile(e, padding: Sp.s)),
              ],
            ],
          );
        }
        return Wrap(spacing: Sp.s, runSpacing: Sp.s, children: [for (final e in options.entries) tile(e)]);
      },
    );
  }
}

/// A removable value: label and an x. Used for reminders and similar short lists.
class RemovableTile extends StatelessWidget {
  const RemovableTile({super.key, required this.label, required this.onRemove, required this.removeLabel});
  final String label;
  final VoidCallback? onRemove;
  final String removeLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: Targets.adult),
      padding: const EdgeInsets.only(left: Sp.m),
      decoration: BoxDecoration(color: c.well, borderRadius: BorderRadius.circular(Radii.control)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: context.type.body(c.ink)),
          if (onRemove != null)
            IconButton(
              tooltip: removeLabel,
              onPressed: onRemove,
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(minimumSize: const Size(40, 40)),
              icon: Icon(PhosphorIconsRegular.x, size: 16, color: c.ink2),
            )
          else
            const SizedBox(width: Sp.m),
        ],
      ),
    );
  }
}

/// A control that shows a chosen value (a date, a time, a driver, an event) and opens a picker;
/// [onClear] adds an x that clears it. [PickerButton] is filled with the well (calendar forms);
/// [PickerButton.outlined] is an outlined button (the chores, lists and points editors).
class PickerButton extends StatelessWidget {
  const PickerButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.semanticsLabel,
    this.error = false,
    this.onClear,
  }) : _outlined = false;

  const PickerButton.outlined({super.key, required this.label, required this.onTap, required IconData this.icon, this.onClear})
      : semanticsLabel = null,
        error = false,
        _outlined = true;

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? semanticsLabel;
  final bool error;
  final VoidCallback? onClear;
  final bool _outlined;

  @override
  Widget build(BuildContext context) {
    final button = _outlined
        ? OutlinedButton.icon(onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label))
        : _filled(context);
    if (!_outlined && onClear == null) return button;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_outlined) button else Flexible(child: button),
        if (onClear != null)
          IconButton(tooltip: 'Clear', onPressed: onClear, icon: const Icon(PhosphorIconsRegular.x, size: 18)),
      ],
    );
  }

  Widget _filled(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: Material(
        color: c.well,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          side: error ? BorderSide(color: c.bad, width: 2) : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: Targets.adult),
            padding: const EdgeInsets.symmetric(horizontal: Sp.m),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 18, color: c.ink2), const SizedBox(width: Sp.s)],
                Flexible(
                  child: Text(label, style: context.type.body(onTap == null ? c.ink3 : c.ink), overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
