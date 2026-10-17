import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Den's mark: a den doorway with the family standing in it, each person in their marker. It
/// restates the app's two rules, people are the color and the family sits side by side in
/// columns, and works from a 16 px favicon up to the 1024 px app icon.
class DenMark extends StatelessWidget {
  const DenMark({super.key, this.size = 48, this.background = false});

  final double size;

  /// Paints the paper square behind the mark, as app icons need.
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

  static const _people = [
    (Marker.blue, 0.86),
    (Marker.orange, 0.52),
    (Marker.green, 0.64),
    (Marker.plum, 0.94),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    if (background) canvas.drawRect(Offset.zero & size, Paint()..color = colors.paper);

    final doorLeft = s * 0.17;
    final doorWidth = s * 0.66;
    final doorTop = s * 0.18;
    final doorBottom = s * 0.86;
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
      final (marker, height) = _people[i];
      final paint = Paint()..color = DenColors.night.marker(marker);
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
