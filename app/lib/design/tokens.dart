import 'dart:ui';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

/// Den's color tokens. Every chromatic color in the app comes from here; the night theme only
/// overrides values. See DESIGN.md for what each one encodes.
@immutable
class DenColors extends ThemeExtension<DenColors> {
  const DenColors({
    required this.paper,
    required this.well,
    required this.rule,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.onInk,
    required this.bad,
    required this.caution,
    required this.star,
    required this.starEdge,
    required this.markers,
  });

  final Color paper;
  final Color well;
  final Color rule;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color onInk;
  final Color bad;
  final Color caution;
  final Color star;
  final Color starEdge;
  final Map<Marker, Color> markers;

  /// The person's marker. A hue means a person, always and only.
  Color marker(Marker m) => markers[m]!;

  /// Pictograms and text drawn on top of a marker fill.
  Color get onMarker => paper;

  static const day = DenColors(
    paper: Color(0xFFFBFAF7),
    well: Color(0xFFF2F0EC),
    rule: Color(0xFFDCD9D3),
    ink: Color(0xFF231E19),
    ink2: Color(0xFF5F5A54),
    ink3: Color(0xFF847F7A),
    onInk: Color(0xFFFBFAF7),
    bad: Color(0xFFBE241F),
    caution: Color(0xFFA85F08),
    star: Color(0xFFE7B726),
    starEdge: Color(0xFF8A6200),
    markers: {
      Marker.blue: Color(0xFF2B7EC9),
      Marker.green: Color(0xFF348F4F),
      Marker.orange: Color(0xFFBF5914),
      Marker.pink: Color(0xFFBB4E7F),
      Marker.teal: Color(0xFF008E8E),
      Marker.plum: Color(0xFFA05DA4),
      Marker.brown: Color(0xFF9B6F52),
      Marker.olive: Color(0xFF78822B),
      Marker.sky: Color(0xFF2785A9),
      Marker.slate: Color(0xFF6C7B96),
    },
  );

  static const night = DenColors(
    paper: Color(0xFF15120F),
    well: Color(0xFF211D1A),
    rule: Color(0xFF393530),
    ink: Color(0xFFF0EEEA),
    ink2: Color(0xFFAFAAA4),
    ink3: Color(0xFF78746E),
    onInk: Color(0xFF15120F),
    bad: Color(0xFFF9786A),
    caution: Color(0xFFECA851),
    star: Color(0xFFF3C443),
    starEdge: Color(0xFFF3C443),
    markers: {
      Marker.blue: Color(0xFF59AAF8),
      Marker.green: Color(0xFF62BB78),
      Marker.orange: Color(0xFFEF8448),
      Marker.pink: Color(0xFFEC79A9),
      Marker.teal: Color(0xFF36BABA),
      Marker.plum: Color(0xFFCD87D1),
      Marker.brown: Color(0xFFC8997B),
      Marker.olive: Color(0xFFA2AD58),
      Marker.sky: Color(0xFF59B1D6),
      Marker.slate: Color(0xFF95A5C2),
    },
  );

  @override
  DenColors copyWith() => this;

  @override
  DenColors lerp(DenColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DenColors(
      paper: l(paper, other.paper),
      well: l(well, other.well),
      rule: l(rule, other.rule),
      ink: l(ink, other.ink),
      ink2: l(ink2, other.ink2),
      ink3: l(ink3, other.ink3),
      onInk: l(onInk, other.onInk),
      bad: l(bad, other.bad),
      caution: l(caution, other.caution),
      star: l(star, other.star),
      starEdge: l(starEdge, other.starEdge),
      markers: {for (final m in Marker.values) m: l(markers[m]!, other.markers[m]!)},
    );
  }
}

/// Spacing on a 4 px scale (`Sp.l` = 16).
abstract final class Sp {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Three radii: controls, kids' cards and sheet tops, and circles.
abstract final class Radii {
  static const double control = 6;
  static const double card = 16;
  static const double round = 999;
}

abstract final class Motion {
  /// A check landing, a toggle flipping.
  static const Duration state = Duration(milliseconds: 150);

  /// A sheet arriving.
  static const Duration sheet = Duration(milliseconds: 200);
  static const Curve curve = Curves.easeOut;

  /// Zero when the platform asks for reduced motion.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.of(context).disableAnimations ? Duration.zero : d;
}

/// Minimum touch targets.
abstract final class Targets {
  static const double adult = 48;
  static const double kid = 72;
}

/// Five type roles, two weights. Display mode scales everything by [DenType.wallScale].
@immutable
class DenType extends ThemeExtension<DenType> {
  const DenType(this.scale);

  final double scale;

  static const family = 'AtkinsonHyperlegibleNext';
  static const wallScale = 1.3;

  static const _tabular = [FontFeature.tabularFigures()];

  TextStyle _style(double size, FontWeight weight, Color color) => TextStyle(
        fontFamily: family,
        fontSize: size * scale,
        fontWeight: weight,
        fontVariations: [FontVariation.weight(weight.value.toDouble())],
        height: 1.3,
        color: color,
        fontFeatures: _tabular,
      );

  TextStyle meta(Color c) => _style(13, FontWeight.w400, c);
  TextStyle body(Color c) => _style(15, FontWeight.w400, c);
  TextStyle bodyStrong(Color c) => _style(15, FontWeight.w700, c);
  TextStyle title(Color c) => _style(18, FontWeight.w700, c);
  TextStyle heading(Color c) => _style(24, FontWeight.w700, c);
  TextStyle display(Color c) => _style(40, FontWeight.w700, c);

  @override
  DenType copyWith({double? scale}) => DenType(scale ?? this.scale);

  @override
  DenType lerp(DenType? other, double t) => other == null ? this : DenType(lerpDouble(scale, other.scale, t)!);
}

extension DenTheme on BuildContext {
  DenColors get colors => Theme.of(this).extension<DenColors>()!;
  DenType get type => Theme.of(this).extension<DenType>()!;
}
