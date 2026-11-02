import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../layout.dart';
import '../motion.dart';
import '../tokens.dart';
import '../words.dart';

/// A field with its label above it, never floating inside: the label in meta ink2 lined up with
/// the card's text, the field (52 tall, 17 pt) under it, and an [error] under that in red text
/// with its icon, naming what to do.
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child, this.error});

  final String label;
  final Widget child;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Text(label, style: t.meta(c.ink2)),
        ),
        const SizedBox(height: 6),
        child,
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, 0),
            child: Semantics(
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(PhosphorIconsFill.warningOctagon, size: 18, color: c.destructive),
                  ),
                  const SizedBox(width: Sp.s),
                  Expanded(child: Text(tidy(error!), style: t.meta(c.destructive))),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One of the [ChoiceRows]: what it's called and, if it needs one, a line about it.
class Choice<T> {
  const Choice(this.value, this.label, {this.detail});

  final T value;
  final String label;
  final String? detail;
}

/// A setting with a few answers (Day, Night, Auto; Sunday or Monday), as rows inside a section's
/// card: the chosen one has an ink check before it. One tap chooses. For views of the same
/// thing use [DenSegmented]; for on and off, a [SwitchLine].
class ChoiceRows<T> extends StatelessWidget {
  const ChoiceRows({super.key, required this.choices, required this.value, required this.onChanged});

  final List<Choice<T>> choices;
  final T value;

  /// Null shows the choice without letting it change.
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final rows = <Widget>[];
    for (final choice in choices) {
      final chosen = choice.value == value;
      if (rows.isNotEmpty) rows.add(const _Rule(indent: 34));
      rows.add(
        Semantics(
          inMutuallyExclusiveGroup: true,
          checked: chosen,
          child: DenPressable(
            onTap: onChanged == null || chosen ? null : () => onChanged!(choice.value),
            scale: false,
            shape: const RoundedRectangleBorder(),
            semanticLabel: choice.detail == null ? choice.label : '${choice.label}, ${choice.detail}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.s + 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: chosen ? Icon(PhosphorIconsBold.check, size: 22, color: c.ink) : null,
                    ),
                    const SizedBox(width: Sp.m),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(choice.label, style: chosen ? t.body(c.ink).bold : t.body(c.ink)),
                            if (choice.detail != null) Text(tidy(choice.detail!), style: t.meta(c.ink2)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

class _Rule extends StatelessWidget {
  const _Rule({required this.indent});

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsetsDirectional.only(start: indent),
        child: SizedBox(height: 1, width: double.infinity, child: ColoredBox(color: context.colors.line)),
      );
}

/// Short steps to follow somewhere else (another app's settings, a Shortcut): each number in
/// bold ink in its own column and the step as reading text beside it. No circles, no icons.
class NumberedSteps extends StatelessWidget {
  const NumberedSteps({super.key, required this.steps});

  /// Each step's words; a [Widget] for a step that holds more than words (an address to copy).
  final List<Object> steps;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? Sp.m : Sp.s, bottom: i == steps.length - 1 ? Sp.m : 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 24 * scale.clamp(1, 1.6), child: Text('${i + 1}', style: t.body(c.ink).bold)),
                const SizedBox(width: Sp.s),
                Expanded(child: step is Widget ? step : Text(tidy('$step'), style: t.body(c.ink))),
              ],
            ),
          ),
      ],
    );
  }
}
