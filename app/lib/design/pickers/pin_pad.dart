import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../motion.dart';
import '../tokens.dart';

/// A 4-digit PIN pad for shared screens: four dots and a phone-style keypad with 72-dp keys, so
/// kids and grandparents can use it on the wall. Calls [onComplete] on the last digit.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onComplete, this.length = 4, this.keySize = 76});

  final ValueChanged<String> onComplete;
  final int length;
  final double keySize;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _digits = '';

  /// Clears the digits, for another try after a wrong PIN.
  void clear() => setState(() => _digits = '');

  void _press(String d) {
    if (_digits.length >= widget.length) return;
    HapticFeedback.selectionClick();
    setState(() => _digits += d);
    if (_digits.length == widget.length) widget.onComplete(_digits);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = widget.keySize < Targets.kid ? Targets.kid : widget.keySize;
    Widget key(String d) => _Key(
          size: size,
          label: d,
          onTap: () => _press(d),
          child: Text(d, style: context.type.heading(c.ink)),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${_digits.length} of ${widget.length} digits',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                  // Each dot fills on the UI spring as its digit is typed.
                  child: SpringValue(
                    value: i < _digits.length ? 1 : 0,
                    builder: (context, t, _) {
                      final on = t.clamp(0.0, 1.0);
                      return Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c.ink.withValues(alpha: on),
                          border: Border.all(color: Color.lerp(c.ink2, c.ink, on)!, width: 2),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Sp.xl),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.s),
            child: Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d)]),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: size + Sp.s * 2),
            key('0'),
            _Key(
              size: size,
              label: 'Delete',
              filled: false,
              onTap: _digits.isEmpty
                  ? null
                  : () => setState(() => _digits = _digits.substring(0, _digits.length - 1)),
              child: Icon(PhosphorIconsRegular.backspace, size: 28, color: _digits.isEmpty ? c.ink3 : c.ink),
            ),
          ],
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.size, required this.label, required this.onTap, required this.child, this.filled = true});
  final double size;
  final String label;
  final VoidCallback? onTap;
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.s),
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: filled ? c.well : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            splashColor: c.ink2,
            highlightColor: c.rule,
            onTap: onTap,
            child: SizedBox.square(dimension: size, child: Center(child: child)),
          ),
        ),
      ),
    );
  }
}
