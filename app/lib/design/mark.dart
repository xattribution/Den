import 'package:flutter/material.dart';

import 'tokens.dart';

/// Den's mark: a den doorway with the family standing in it, each person in their color. It
/// restates the app's two rules, people are the color and the family sits side by side in
/// columns, and works from a 16 px favicon up to the 1024 px app icon.
class DenMark extends StatelessWidget {
  const DenMark({super.key, this.size = 48, this.background = false});

  final double size;

  /// Paints the page-colored square behind the mark, as app icons need.
  final bool background;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<DenColors>() ?? DenColors.day;
    return CustomPaint(size: Size.square(size), painter: DenMarkPainter(colors, background: background));
  }
}

class DenMarkPainter extends CustomPainter {
  DenMarkPainter(this.colors, {this.background = false});

  final DenColors colors;
  final bool background;

  /// The doorway's place in the mark's square, as fractions of its side. Apart from the
  /// background, everything the mark paints is inside it.
  static const doorway = Rect.fromLTRB(0.17, 0.18, 0.83, 0.86);

  static const _people = [
    (PersonColor.sky, 0.86),
    (PersonColor.tangerine, 0.52),
    (PersonColor.grass, 0.64),
    (PersonColor.lavender, 0.94),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    if (background) canvas.drawRect(Offset.zero & size, Paint()..color = colors.bg);

    final doorLeft = s * doorway.left;
    final doorWidth = s * doorway.width;
    final doorTop = s * doorway.top;
    final doorBottom = s * doorway.bottom;
    final radius = doorWidth / 2;
    final door = Path()
      ..moveTo(doorLeft, doorBottom)
      ..lineTo(doorLeft, doorTop + radius)
      ..arcToPoint(Offset(doorLeft + doorWidth, doorTop + radius), radius: Radius.circular(radius))
      ..lineTo(doorLeft + doorWidth, doorBottom)
      ..close();
    canvas.drawPath(door, Paint()..color = colors.ink);

    final inset = s * 0.09;
    final innerLeft = doorLeft + inset;
    final innerWidth = doorWidth - inset * 2;
    final gap = s * 0.025;
    final barWidth = (innerWidth - gap * (_people.length - 1)) / _people.length;
    final floor = doorBottom;
    final maxHeight = floor - doorTop - radius * 0.42;
    final head = barWidth * 0.86;
    final neck = barWidth * 0.14;
    for (var i = 0; i < _people.length; i++) {
      final (person, height) = _people[i];
      final paint = Paint()..color = person.color;
      final left = innerLeft + i * (barWidth + gap);
      final top = floor - maxHeight * height;
      final bodyTop = top + head + neck;
      canvas.drawCircle(Offset(left + barWidth / 2, top + head / 2), head / 2, paint);
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          left,
          bodyTop,
          left + barWidth,
          floor,
          topLeft: Radius.circular(barWidth / 2),
          topRight: Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(DenMarkPainter old) => old.colors != colors || old.background != background;
}
