import 'package:flutter/material.dart';

import '../motion.dart';
import '../tokens.dart';

/// A round icon button: Add in ink (52), More on the card color (44). Its [label] is what
/// screen readers say and what a long press or hover shows.
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.fill,
    this.color,
    this.size = 52,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Ink ([DenColors.primary]) by default.
  final Color? fill;

  /// [DenColors.onPrimary] by default.
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onTap != null;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: DenPressable(
        onTap: onTap,
        color: enabled ? (fill ?? c.primary) : c.fill,
        shape: const CircleBorder(),
        semanticLabel: label,
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: size * 0.45, color: enabled ? (color ?? c.onPrimary) : c.ink3),
        ),
      ),
    );
  }
}

/// "Undo": underlined bold ink text, 44 tall, at the end of a row that just did something.
class UndoButton extends StatelessWidget {
  const UndoButton({super.key, required this.onTap, this.label = 'Undo'});

  final VoidCallback? onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Sp.xs)),
      child: Text(
        label,
        style: context.text.label(onTap == null ? c.ink3 : c.ink).copyWith(
              decoration: TextDecoration.underline,
              decorationColor: onTap == null ? c.ink3 : c.ink,
            ),
      ),
    );
  }
}
