import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../tokens.dart';

/// One choice among several, laid out in a Wrap: solid ink when chosen (owner rule O1), the
/// well otherwise. Radius 6, like every control.
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.semanticsLabel,
    this.padding = Sp.m,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? semanticsLabel;

  /// Space on each side of the label; [ChoiceRow] narrows it to fit equal tiles.
  final double padding;

  @override
  Widget build(BuildContext context) {
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

/// A form label with an optional (i) beside it. Never a subtitle.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.info});
  final String text;
  final Widget? info;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.s),
      child: Row(
        children: [
          Text(text, style: context.type.meta(c.ink2)),
          ?info,
        ],
      ),
    );
  }
}

/// A well-filled control that shows a value and opens a picker: a date, a time, a driver.
class PickerButton extends StatelessWidget {
  const PickerButton({super.key, required this.label, required this.onTap, this.icon, this.semanticsLabel, this.error = false});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? semanticsLabel;
  final bool error;

  @override
  Widget build(BuildContext context) {
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
