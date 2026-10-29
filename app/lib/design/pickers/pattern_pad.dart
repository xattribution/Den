import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../pictograms.dart';
import '../motion.dart';
import '../tokens.dart';

/// The picture-pattern sign-in: the nine animals in a 3×3 grid, four taps, Undo. Animals are
/// the digits 0-8 in [Animal] order, so the pattern "cat, fish, dog, cow" is the secret "0517".
///
/// Tiles are ink on the well, never a marker color: on this pad an animal is a letter of the
/// secret, not a person. When [hidden], the slots fill with dots instead of the animals picked,
/// for signing in where others can see the screen. Not [enabled] (while a wrong try makes
/// someone wait), the animals stay in view but can't be tapped.
class PatternPad extends StatefulWidget {
  const PatternPad({
    super.key,
    required this.onComplete,
    this.length = 4,
    this.hidden = false,
    this.tile = 80,
    this.enabled = true,
  });

  final ValueChanged<String> onComplete;
  final int length;
  final bool hidden;
  final bool enabled;

  /// Edge of one animal tile; at least the 72-dp kids' target.
  final double tile;

  @override
  State<PatternPad> createState() => PatternPadState();
}

class PatternPadState extends State<PatternPad> {
  final List<Animal> _picked = [];

  /// Clears the taps, for another try after a wrong pattern.
  void clear() => setState(_picked.clear);

  void _tap(Animal a) {
    if (_picked.length >= widget.length) return;
    HapticFeedback.selectionClick();
    setState(() => _picked.add(a));
    if (_picked.length == widget.length) {
      widget.onComplete(_picked.map((a) => a.index).join());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tile = widget.tile < Targets.kid ? Targets.kid : widget.tile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${_picked.length} of ${widget.length} chosen',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                  child: _Slot(animal: i < _picked.length ? _picked[i] : null, hidden: widget.hidden, size: tile * 0.5),
                ),
            ],
          ),
        ),
        const SizedBox(height: Sp.l),
        for (var row = 0; row < 3; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.s),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var col = 0; col < 3; col++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                    child: _AnimalTile(
                      animal: Animal.values[row * 3 + col],
                      size: tile,
                      onTap: widget.enabled && _picked.length < widget.length ? () => _tap(Animal.values[row * 3 + col]) : null,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Sp.xs),
        SizedBox(
          height: Targets.kid,
          child: TextButton.icon(
            onPressed: _picked.isEmpty || !widget.enabled ? null : () => setState(_picked.removeLast),
            icon: const Icon(PhosphorIconsBold.arrowUUpLeft, size: 22),
            label: Text('Undo', style: context.type.title(_picked.isEmpty || !widget.enabled ? c.ink3 : c.ink)),
            style: TextButton.styleFrom(minimumSize: const Size(120, Targets.kid)),
          ),
        ),
      ],
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.animal, required this.hidden, required this.size});
  final Animal? animal;
  final bool hidden;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final filled = animal != null;
    // Fills on the UI spring as its picture is chosen.
    return SpringValue(
      value: filled ? 1 : 0,
      builder: (context, t, _) {
        final on = t.clamp(0.0, 1.0);
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.ink.withValues(alpha: on),
            border: Border.all(color: Color.lerp(c.ink2, c.ink, on)!, width: 2),
          ),
          alignment: Alignment.center,
          child: !filled
              ? null
              : Opacity(
                  opacity: on,
                  child: hidden
                      ? Container(width: size * 0.28, height: size * 0.28, decoration: BoxDecoration(color: c.onInk, shape: BoxShape.circle))
                      : Icon(Pictograms.animal(animal!), size: size * 0.6, color: c.onInk),
                ),
        );
      },
    );
  }
}

/// What a screen reader calls each symbol.
const Map<Animal, String> _names = {
  Animal.cat: 'Cat',
  Animal.dog: 'Dog',
  Animal.rabbit: 'Rabbit',
  Animal.bird: 'Bird',
  Animal.butterfly: 'Butterfly',
  Animal.fish: 'Fish',
  Animal.horse: 'Horse',
  Animal.cow: 'Cow',
  Animal.bug: 'Ladybug',
};

class _AnimalTile extends StatelessWidget {
  const _AnimalTile({required this.animal, required this.size, required this.onTap});
  final Animal animal;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: _names[animal],
      child: Material(
        color: c.well,
        borderRadius: BorderRadius.circular(Radii.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.card),
          splashColor: c.ink2,
          highlightColor: c.rule,
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Icon(Pictograms.animal(animal), size: size * 0.52, color: onTap == null ? c.ink3 : c.ink),
          ),
        ),
      ),
    );
  }
}
