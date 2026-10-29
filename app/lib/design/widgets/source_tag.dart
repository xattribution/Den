import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../tokens.dart';

/// Where something comes from, when it could come from more than one place (a family, later a
/// group or a shared calendar): the source's initial in a rounded square, in the source's color
/// ([color], one of the eight places) or in ink when it has none (DESIGN.md, "What may carry
/// color"). It never stands for a person: faces do. Screen readers hear [label].
class SourceTag extends StatelessWidget {
  const SourceTag({super.key, required this.label, this.color, this.size = 22, this.semantics = true});

  /// The source's name: "Kotvas", "Smith family".
  final String label;

  /// The source's color; null draws the tag in ink.
  final Marker? color;

  final double size;

  /// Whether the tag says [label] to screen readers; off where the row already says it.
  final bool semantics;

  /// The letter on the tag: the first letter of the name's first word that isn't "the".
  static String initialOf(String label) {
    final words = label.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final word = words.length > 1 && words.first.toLowerCase() == 'the' ? words[1] : words.firstOrNull;
    if (word == null) return '';
    return String.fromCharCode(word.runes.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fill = color == null ? c.ink : c.marker(color!);
    final ink = color == null ? c.onPrimary : c.onMarker;
    final tag = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(size * 0.28)),
        child: Center(
          child: Text(
            initialOf(label),
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontFamily: context.text.body(ink).fontFamily,
              fontSize: size * 0.58,
              height: 1,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
        ),
      ),
    );
    return semantics ? Semantics(label: label, image: true, child: ExcludeSemantics(child: tag)) : ExcludeSemantics(child: tag);
  }
}
