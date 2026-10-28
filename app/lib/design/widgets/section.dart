import 'package:flutter/material.dart';

import '../layout.dart';
import '../tokens.dart';

/// A page section: its heading (20/700), with a count or a quiet link on the right, over one
/// grouped card. Sections sit [DenLayout.sectionGap] apart; the heading lines up with the rows'
/// text, [DenLayout.headingInset] in from the card's edge.
///
/// [carded] false puts [child] straight on the page (a row of fields, a wrap of chips): not
/// every section gets a container (ANTI-SLOP 11).
class DenSection extends StatelessWidget {
  const DenSection({super.key, required this.title, this.trailing, required this.child, this.carded = true, this.cardPadding});

  final String title;

  /// A count ("2 of 5 done", meta in ink2) or a link ([SectionLink]).
  final Widget? trailing;
  final Widget child;
  final bool carded;

  /// The card's padding; [GroupCard]'s default otherwise.
  final EdgeInsets? cardPadding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Semantics(header: true, child: Text(title, style: context.text.section(c.ink)))),
              if (trailing != null) ...[const SizedBox(width: Sp.m), trailing!],
            ],
          ),
        ),
        const SizedBox(height: DenLayout.headingGap),
        if (carded) GroupCard(padding: cardPadding ?? GroupCard.defaultPadding, child: child) else child,
      ],
    );
  }
}

/// A section heading's count, in meta ink2: "2 things", "14 items".
class SectionCount extends StatelessWidget {
  const SectionCount(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: context.text.meta(context.colors.ink2));
}

/// A section heading's link: bold meta in ink2 ("Week", "14 items"), 44 tall to tap.
class SectionLink extends StatelessWidget {
  const SectionLink(this.text, {super.key, required this.onTap, this.semanticLabel});

  final String text;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        link: true,
        label: semanticLabel,
        excludeSemantics: semanticLabel != null,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Targets.adult),
            child: Center(
              widthFactor: 1,
              child: Text(text, style: context.text.meta(context.colors.ink2).bold),
            ),
          ),
        ),
      );
}

/// One grouped section's card: the card color, 20 corners, no border, no shadow. Never put a
/// card inside a card.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.child, this.padding = GroupCard.defaultPadding});

  static const EdgeInsets defaultPadding = EdgeInsets.symmetric(horizontal: DenLayout.cardPadding);

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: context.colors.card, borderRadius: BorderRadius.circular(Radii.section)),
        child: Padding(padding: padding, child: child),
      );
}

/// A hairline between rows inside a card, [indent] in from the start (52 lines it up with text
/// after a 40 pt face).
class RowRule extends StatelessWidget {
  const RowRule({super.key, this.indent = 0});

  /// The indent that lines a rule up with the text beside a 40 pt face.
  static const double afterFace = 52;

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsetsDirectional.only(start: indent),
        child: SizedBox(height: 1, child: ColoredBox(color: context.colors.line)),
      );
}

/// [children] with a [RowRule] between each two.
List<Widget> ruled(Iterable<Widget> children, {double indent = 0}) {
  final out = <Widget>[];
  for (final child in children) {
    if (out.isNotEmpty) out.add(RowRule(indent: indent));
    out.add(child);
  }
  return out;
}
