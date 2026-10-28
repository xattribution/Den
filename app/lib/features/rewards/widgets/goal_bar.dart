import 'package:flutter/material.dart';

import '../../../design/tokens.dart';

/// One person's progress toward a points goal, in their marker color (their own progress, so
/// their hue), with ticks at each quarter. Square ends: it shows a measure, it isn't a control.
class GoalBar extends StatelessWidget {
  const GoalBar({super.key, required this.fraction, required this.color, this.height = 12, this.semanticLabel});

  final double fraction;
  final Color color;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: semanticLabel,
      value: '${(fraction.clamp(0, 1) * 100).round()} percent',
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _GoalBarPainter(fraction.clamp(0, 1).toDouble(), color, c.well, c.paper)),
      ),
    );
  }
}

class _GoalBarPainter extends CustomPainter {
  _GoalBarPainter(this.fraction, this.fill, this.track, this.tick);
  final double fraction;
  final Color fill;
  final Color track;
  final Color tick;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = track);
    if (fraction > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width * fraction, size.height), Paint()..color = fill);
    }
    final tickPaint = Paint()..color = tick;
    for (final q in const [0.25, 0.5, 0.75]) {
      final x = (size.width * q).roundToDouble();
      canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, size.height), tickPaint);
    }
  }

  @override
  bool shouldRepaint(_GoalBarPainter old) =>
      old.fraction != fraction || old.fill != fill || old.track != track || old.tick != tick;
}
