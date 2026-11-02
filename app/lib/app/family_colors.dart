import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../design/day_theme.dart';
import '../design/tokens.dart';
import 'den_scope.dart';

/// The family's color pack ([Family.colors]) over [child]: every `context.colors.marker(m)` below
/// draws the shades the family chose, the same on every device in it. Until a parent picks one,
/// and before there is a family, it is the theme's own ([DenPalette.defaultPack]): Bright, or the
/// Soft pack in the Soft theme.
///
/// It sits just under the app's theme, so pages and sheets get it too. Only the person colors
/// change, and the theme for a pack is made once per app theme ([PackTheme]), so a change to the
/// family that isn't its pack rebuilds nothing under it.
class FamilyColors extends StatelessWidget {
  const FamilyColors({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final family = DenScope.watch(context, const {RecordType.family}).den.family;
    final palette = Theme.of(context).extension<DenColors>()?.palette ?? DenPalette.neutral;
    return PackTheme(pack: familyPack(family, palette), child: child);
  }
}

/// The pack [family] draws people in on a device in [palette]: the one a parent picked, or before
/// anyone has, the palette's own (Bright; the Soft pack in the Soft theme). Family settings show
/// this one as chosen.
ColorPack familyPack(Family? family, DenPalette palette) {
  final picked = family?.rec.fields['colors'];
  return picked == null ? palette.defaultPack : ColorPack.parse(picked);
}
