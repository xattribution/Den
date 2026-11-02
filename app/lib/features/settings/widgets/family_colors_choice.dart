import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/day_theme.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// Settings, Family: "Family colors", the shades everyone in the family sees. Each pack is a row
/// with the family's own people in it, as solid tags in their color with their face and name, so
/// a parent sees the family's week in it before choosing; the chosen one has an ink check. One
/// tap chooses, for every device in the family. Everyone keeps their color's place: Mia's
/// Bubblegum becomes Mia's Raspberry in Deep.
class FamilyColorsChoice extends StatelessWidget {
  const FamilyColorsChoice({super.key, required this.people, required this.value, required this.onChanged});

  /// The family, in its order.
  final List<Member> people;
  final ColorPack value;

  /// Null shows the packs without letting them change.
  final ValueChanged<ColorPack>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final rows = <Widget>[];
    for (final pack in ColorPack.values) {
      final chosen = pack == value;
      if (rows.isNotEmpty) rows.add(const RowRule(indent: 34));
      final who = [for (final m in people) '${m.name}, ${pack.of(m.marker).label}'].join('; ');
      rows.add(
        Semantics(
          inMutuallyExclusiveGroup: true,
          checked: chosen,
          child: DenPressable(
            onTap: onChanged == null || chosen ? null : () => onChanged!(pack),
            scale: false,
            shape: const RoundedRectangleBorder(),
            semanticLabel: people.isEmpty ? pack.label : '${pack.label}: $who',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.m),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                          Text(pack.label, style: chosen ? t.body(c.ink).bold : t.body(c.ink)),
                          const SizedBox(height: Sp.s),
                          PackTheme(pack: pack, child: _Preview(people: people, pack: pack)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// The family in one pack: a tag per person in their color, at full strength, with dark ink on
/// it; a family with nobody in it yet shows the pack's eight colors.
class _Preview extends StatelessWidget {
  const _Preview({required this.people, required this.pack});

  final List<Member> people;
  final ColorPack pack;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (people.isEmpty) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final color in pack.colors)
            DecoratedBox(
              decoration: BoxDecoration(color: color.color, shape: BoxShape.circle),
              child: const SizedBox.square(dimension: 24),
            ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final m in people)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: DecoratedBox(
                decoration: BoxDecoration(color: c.marker(m.marker), borderRadius: BorderRadius.circular(10)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DenAvatar(m, size: 24),
                      const SizedBox(width: 6),
                      Flexible(child: Text(m.name, style: context.text.caption(c.onMarker).bold)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
