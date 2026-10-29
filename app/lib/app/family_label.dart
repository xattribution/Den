import 'package:flutter/material.dart';

import '../design/layout.dart';
import '../design/tokens.dart';
import '../design/widgets/source_tag.dart';
import 'app_state.dart';
import 'household.dart';

/// Which family a page that isn't merged is for (Chores, Family, Settings), on a device in
/// several families, wherever the switcher doesn't already say it: in "All my families" (these
/// tabs show the family last chosen), or on another family's page (`/l/<log>/...`). The family's
/// tag and name, and [note] after them. Nothing on a device in one family, or on a page of the
/// family the switcher shows.
class FamilyLabel extends StatelessWidget {
  const FamilyLabel({super.key, this.note, this.top = 0});

  /// What to add, after a middle dot: "Chores stay with each family".
  final String? note;

  /// Room above it, when it shows.
  final double top;

  @override
  Widget build(BuildContext context) {
    final home = Household.maybeOf(context);
    if (home == null || !home.several) return const SizedBox.shrink();
    final log = home.of(DenScope.read(context).den) ?? home.active;
    if (!home.showingAll && identical(log, home.active)) return const SizedBox.shrink();
    final c = context.colors;
    final t = context.text;
    return Semantics(
      container: true,
      label: 'In ${log.name}${note == null ? '' : '. $note'}',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(DenLayout.headingInset, top, DenLayout.headingInset, Sp.s),
        child: Row(
          children: [
            SourceTag(label: log.name, color: log.color, size: 20, semantics: false),
            const SizedBox(width: Sp.s),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: log.name, style: t.label(c.ink)),
                    if (note != null) TextSpan(text: ' · $note', style: t.meta(c.ink2)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
