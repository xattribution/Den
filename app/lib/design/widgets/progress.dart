import 'package:flutter/material.dart';

import '../motion.dart';
import '../tokens.dart';

/// Progress toward something (a star goal), as Chores.dc.html draws it: an 8 pt bar with round
/// ends, the person's [color] over a quiet track. It shows a measure and isn't a control; its
/// words go beside or under it ("8 more for movie night"), and [label] says them to screen
/// readers. The fill moves on the UI spring.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.fraction, required this.color, required this.label, this.height = 8});

  /// 0 to 1; values outside are held to it.
  final double fraction;
  final Color color;
  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final value = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0).toDouble();
    final radius = BorderRadius.circular(height / 2);
    return Semantics(
      label: label,
      value: '${(value * 100).round()} percent',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: radius,
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: ColoredBox(
              color: c.line,
              child: SpringValue(
                value: value,
                builder: (context, v, _) => FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: v.clamp(0.0, 1.0),
                  child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: radius)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
