import 'package:flutter/material.dart';

import '../motion.dart';
import '../tokens.dart';
import '../words.dart';

/// A setting as a sentence and a switch (Family.dc.html's parent controls): what on means
/// ("Can add to lists"), a quieter line under it ("Groceries and packing lists"), and the switch
/// at the end. The whole row flips it. 64 tall at least, inside a section's card.
///
/// [onChanged] null keeps it visible and unchangeable, with [reason] saying why in place of the
/// detail ("Change this on your own phone").
class SwitchLine extends StatelessWidget {
  const SwitchLine({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.detail,
    this.reason,
    this.leading,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? detail;

  /// Why it can't be changed now, shown when [onChanged] is null.
  final String? reason;

  /// A face (32 or 40) before the words, for a switch about a person.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final enabled = onChanged != null;
    final under = !enabled && reason != null ? reason : detail;
    return MergeSemantics(
      child: DenPressable(
        onTap: enabled ? () => onChanged!(!value) : null,
        scale: false,
        shape: const RoundedRectangleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s + 2),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: Sp.m)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tidy(label), style: t.body(enabled ? c.ink : c.ink2)),
                      if (under != null && under.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(tidy(under), style: t.meta(c.ink2)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Sp.m),
                DenSwitch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// On or off (DESIGN.md, "Switches"): on is an ink track with a light knob, off is the switch-off
/// gray with a white knob. 52 by 32 with nothing around it, so its edge lines up with the text
/// and cards around it; a tap anywhere 44 tall on it flips it. The knob moves on the UI spring
/// from wherever it is, so a quick second tap turns it around mid-way; under Reduce Motion the
/// two looks crossfade. Screen readers hear a switch, on or off.
class DenSwitch extends StatelessWidget {
  const DenSwitch({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;

  /// Null shows it without letting it change.
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  static const Size size = Size(52, 32);
  static const double _knob = 26;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onChanged != null;
    final track = SpringValue(
      value: value ? 1 : 0,
      builder: (context, t, _) {
        final on = t.clamp(0.0, 1.0);
        final travel = size.width - _knob - (size.height - _knob);
        return CustomPaint(
          size: size,
          painter: _SwitchPainter(
            track: Color.lerp(c.switchOff, c.primary, on)!,
            knob: Color.lerp(c.knob, c.onPrimary, on)!,
            knobLeft: (size.height - _knob) / 2 + travel * t.clamp(-0.05, 1.05),
            knobSize: _knob,
          ),
        );
      },
    );
    void flip() => onChanged!(!value);
    // The press shade lies on the track itself; the target reaches 44 tall around it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: enabled ? flip : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: (Targets.adult - 32) / 2),
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: DenPressable(
            onTap: enabled ? flip : null,
            haptic: true,
            scale: false,
            toggled: value,
            semanticLabel: semanticLabel,
            child: RepaintBoundary(child: track),
          ),
        ),
      ),
    );
  }
}

class _SwitchPainter extends CustomPainter {
  _SwitchPainter({required this.track, required this.knob, required this.knobLeft, required this.knobSize});

  final Color track;
  final Color knob;
  final double knobLeft;
  final double knobSize;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(size.height / 2)), Paint()..color = track);
    canvas.drawCircle(Offset(knobLeft + knobSize / 2, size.height / 2), knobSize / 2, Paint()..color = knob);
  }

  @override
  bool shouldRepaint(_SwitchPainter old) =>
      old.track != track || old.knob != knob || old.knobLeft != knobLeft || old.knobSize != knobSize;
}
