import 'package:flutter/widgets.dart';

import '../design/mark.dart';
import '../design/tokens.dart';

/// Shown in a browser tab while Den is open in another tab of the same browser: the family's
/// log is shared between them, and only one may write it. This tab carries on by itself once
/// the other one closes.
class OtherTabScreen extends StatelessWidget {
  const OtherTabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final night = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final colors = night ? DenColors.night : DenColors.day;
    return ColoredBox(
      color: colors.paper,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Sp.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CustomPaint(size: const Size.square(56), painter: DenMarkPainter(colors)),
                const SizedBox(height: Sp.l),
                Text(
                  'Den is open in another tab. Close that tab to use Den here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: DenType.family,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: colors.ink,
                    decoration: TextDecoration.none,
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
