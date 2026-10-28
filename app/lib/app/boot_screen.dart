import 'package:flutter/widgets.dart';

import '../design/mark.dart';
import '../design/tokens.dart';

/// The first frame, drawn before the engine has opened: the mark on the page color, matching
/// the platform's light or dark setting so there's no flash.
class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final night = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final colors = night ? DenColors.night : DenColors.day;
    return ColoredBox(
      color: colors.paper,
      child: Center(
        child: CustomPaint(size: const Size.square(72), painter: DenMarkPainter(colors)),
      ),
    );
  }
}
