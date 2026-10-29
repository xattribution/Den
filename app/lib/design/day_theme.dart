import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.dart';

/// Draws [child] in the day tokens whatever the app's theme is, with the family's colors and the
/// type scale of the theme around it: the calendar a device keeps light while the rest of the app
/// is dark. It doesn't fork anything: the same widgets read `context.colors` and get the light
/// values. Sheets opened inside it are light too ([showDenSheet] carries the theme over).
///
/// The theme for each pack and scale is made once, so rebuilding never starts a theme animation,
/// and nothing below it moves when the app's own theme animates between day and night.
class DayTheme extends StatelessWidget {
  const DayTheme({super.key, required this.child});

  final Widget child;

  static final Map<(ColorPack, double), ThemeData> _themes = {};

  /// The day theme drawing people in [pack], at the type [scale] (1.3 on the wall).
  static ThemeData of(ColorPack pack, double scale) =>
      _themes[(pack, scale)] ??= denTheme(DenColors.day.withPack(pack), typeScale: scale);

  /// The day theme for what [context] draws now: its family's colors and its type scale.
  static ThemeData around(BuildContext context) => of(context.colors.pack, context.text.scale);

  @override
  Widget build(BuildContext context) => Theme(data: around(context), child: child);
}

/// Draws the people in [child] in [pack]'s colors, everything else as the theme around it: the
/// app under the family's pack, or a preview of another pack.
class PackTheme extends StatelessWidget {
  const PackTheme({super.key, required this.pack, required this.child});

  final ColorPack pack;
  final Widget child;

  static final Expando<Map<ColorPack, ThemeData>> _themes = Expando('PackTheme');

  /// [base] drawing people in [pack]; the same theme each time for the same two.
  static ThemeData of(ThemeData base, ColorPack pack) {
    final colors = base.extension<DenColors>();
    if (colors == null || colors.pack == pack) return base;
    final themes = _themes[base] ??= {};
    return themes[pack] ??= base.copyWith(
      extensions: [
        for (final e in base.extensions.values) e is DenColors ? e.withPack(pack) : e,
      ],
    );
  }

  // Always a Theme, so the tree under it keeps its state when the pack changes.
  @override
  Widget build(BuildContext context) => Theme(data: of(Theme.of(context), pack), child: child);
}
