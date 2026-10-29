import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../design/day_theme.dart';
import 'den_scope.dart';

/// The family's color pack ([Family.colors]) over [child]: every `context.colors.marker(m)` below
/// draws the shades the family chose, the same on every device in it. Bright until a parent picks
/// another, and before there is a family.
///
/// It sits just under the app's theme, so pages and sheets get it too. Only the person colors
/// change, and the theme for a pack is made once per app theme ([PackTheme]), so a change to the
/// family that isn't its pack rebuilds nothing under it.
class FamilyColors extends StatelessWidget {
  const FamilyColors({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pack = DenScope.watch(context, const {RecordType.family}).den.family?.colors ?? ColorPack.bright;
    return PackTheme(pack: pack, child: child);
  }
}
