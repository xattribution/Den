import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Kids mode's tokens (KIDS_MODE_AND_SOFT_THEME.md, "Kids mode tokens"): the toy-box layer on
/// top of Den. Chunky tiles stand on a solid colored lip instead of a shadow, each job gets a fat
/// colored disc holding a navy pictogram, and color is loud only where a kid acts.
///
/// The six primaries are a scoped exception to "no brand accent" (ANTI-SLOP.md): they color job
/// discs on a kid's own board and nowhere else. On the wall, where kids share a screen, discs are
/// the person's color, so a hue still means a person there.

/// One of the six kid primaries: the face a disc is drawn in, and the darker lip under it.
@immutable
class KidPrimary {
  const KidPrimary(this.name, this.face, this.lip);

  final String name;

  /// The disc. Navy text and pictograms on it ([KidColors.onFace]), 5.94:1 or better.
  final Color face;

  /// The solid base under a chunky shape. Decorative: it never carries text.
  final Color lip;

  @override
  bool operator ==(Object other) => other is KidPrimary && other.face == face && other.lip == lip;

  @override
  int get hashCode => Object.hash(face, lip);

  @override
  String toString() => 'KidPrimary($name)';
}

/// Kids mode's colors, per theme: the six primaries (the same in every theme), navy for text on
/// them, and the empty ring of a job still to do.
@immutable
class KidColors extends ThemeExtension<KidColors> {
  const KidColors({required this.todoRing, this.onFace = navy, this.primaries = all});

  /// Navy: text and pictograms on every kid face.
  static const navy = Color(0xFF0F2338);

  static const sky = KidPrimary('sky', Color(0xFF4FB4F7), Color(0xFF2C8FD6));
  static const leaf = KidPrimary('leaf', Color(0xFF4CC968), Color(0xFF2FA34C));
  static const sun = KidPrimary('sun', Color(0xFFFFD23F), Color(0xFFE8B400));
  static const tangerine = KidPrimary('tangerine', Color(0xFFFF9B3F), Color(0xFFE87A1C));
  static const berry = KidPrimary('berry', Color(0xFFFF6F7D), Color(0xFFE04A5C));
  static const bubble = KidPrimary('bubble', Color(0xFFF58BC0), Color(0xFFD9619E));

  static const List<KidPrimary> all = [sky, leaf, sun, tangerine, berry, bubble];

  /// Day: a neutral gray ring, 3.36:1 on a white card.
  static const day = KidColors(todoRing: Color(0xFF8C8C8C));

  /// Night: 3.46:1 on the #141414 card.
  static const night = KidColors(todoRing: Color(0xFF6B6B6B));

  /// Soft by day: 3.05:1 on white, at the floor (don't lighten it).
  static const softDay = KidColors(todoRing: Color(0xFF7F96AE));

  /// Soft at night: 3.64:1 on the #111F30 card.
  static const softNight = KidColors(todoRing: Color(0xFF5F7894));

  /// The kid tokens that go with [c].
  static KidColors of(DenColors c) => switch ((c.palette, c.isDark)) {
        (DenPalette.neutral, false) => day,
        (DenPalette.neutral, true) => night,
        (DenPalette.soft, false) => softDay,
        (DenPalette.soft, true) => softNight,
      };

  final Color onFace;

  /// The unchecked circle at the end of a wall row: 3:1 or better on the card (non-text).
  final Color todoRing;

  final List<KidPrimary> primaries;

  /// The primary for a job: chosen from a stable key for it (the board uses its title), so the
  /// same job is the same color on every device and every day. Two jobs can share one; the
  /// pictogram tells them apart.
  KidPrimary forJob(String key) => primaries[stableIndex(key, primaries.length)];

  /// The primaries for a board's jobs in order: each job's own ([forJob]), except that a job
  /// whose color matches one of the [apart] jobs before it takes the next free one, so no tile
  /// matches the one beside it or above it (2 or 3 across). The same jobs in the same order get
  /// the same colors every time.
  List<KidPrimary> forJobs(List<String> keys, {int apart = 3}) {
    final picked = <KidPrimary>[];
    for (final id in keys) {
      final recent = picked.skip(math.max(0, picked.length - apart)).toSet();
      var i = stableIndex(id, primaries.length);
      for (var tries = 0; tries < primaries.length && recent.contains(primaries[i]); tries++) {
        i = (i + 1) % primaries.length;
      }
      picked.add(primaries[i]);
    }
    return picked;
  }

  /// A hash of [id] into `0 ≤ i < n` that is the same on every platform (the VM and the web
  /// differ in `String.hashCode`), and stays within doubles' exact integers on the web.
  static int stableIndex(String id, int n) {
    var h = 7;
    for (final unit in id.codeUnits) {
      h = (h * 31 + unit) & 0x7FFFFFFF;
    }
    return h % n;
  }

  /// The lip under a face with no hand-picked one (a person's color on a done tile): the same
  /// hue, 0.13 darker and a little less saturated, which is how the six primaries' lips sit
  /// under their faces.
  static Color lipOf(Color face) {
    final hsl = HSLColor.fromColor(face);
    return hsl
        .withLightness((hsl.lightness - 0.13).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0))
        .toColor();
  }

  @override
  KidColors copyWith({Color? onFace, Color? todoRing, List<KidPrimary>? primaries}) => KidColors(
        onFace: onFace ?? this.onFace,
        todoRing: todoRing ?? this.todoRing,
        primaries: primaries ?? this.primaries,
      );

  @override
  KidColors lerp(KidColors? other, double t) {
    if (other == null) return this;
    return KidColors(
      onFace: Color.lerp(onFace, other.onFace, t)!,
      todoRing: Color.lerp(todoRing, other.todoRing, t)!,
      primaries: t < 0.5 ? primaries : other.primaries,
    );
  }
}

/// How far a chunky shape's solid lip sits below its face (KIDS_MODE_AND_SOFT_THEME.md,
/// "Elevation"). No blur shadows anywhere: the shape is drawn twice, the lip offset down, and a
/// press sinks the face onto it.
abstract final class Lip {
  /// A job tile on a phone or tablet.
  static const double tile = 6;

  /// The star card and "Read my jobs to me".
  static const double card = 4;

  /// A job row on the wall: deeper, read from across the kitchen.
  static const double wall = 8;
}

/// Kids mode's geometry. Targets are 64 or more everywhere and job tiles keep [Targets.kid] (72)
/// as their floor.
abstract final class KidLayout {
  /// Between tiles in the grid.
  static const double gridGap = 16;

  /// Inside a tile.
  static const double tilePadding = 16;

  /// Between the header, the star card, the grid and the sections under it.
  static const double sectionGap = 20;

  /// The smallest a kid can press.
  static const double minTarget = 64;

  /// A job tile's height: 136 to 168, growing when its title wraps.
  static const double tileMinHeight = 136;

  /// The colored disc on a job tile.
  static const double disc = 60;

  /// The kid's picture in their header.
  static const double avatar = 56;

  /// "Read my jobs to me".
  static const double readBarHeight = 72;

  /// The wall: outer margin, the gap between kids' columns, between job rows.
  static const double wallMargin = 64;
  static const double wallColumnGap = 48;
  static const double wallTileGap = 22;

  /// A job on the wall: a 156-tall row with a 100 disc at the start and a 68 ring at the end.
  static const double wallRowHeight = 156;
  static const double wallDisc = 100;
  static const double wallRing = 68;

  /// A kid's picture at the top of their wall column.
  static const double wallAvatar = 88;
}

/// Kids mode's four type roles (KIDS_MODE_AND_SOFT_THEME.md, "Type"), on top of [DenText] so
/// the wall's 1.3 scale and the person's text size apply as everywhere else.
extension KidText on DenText {
  TextStyle _kid(double size, FontWeight weight, Color c, double height) =>
      meta(c).copyWith(fontSize: size * scale, height: height).withWeight(weight);

  /// "Hi, Leo": 30 / 800.
  TextStyle kidHello(Color c) => _kid(30, FontWeight.w800, c, 1.15);

  /// A job's title on a tile: 20 / 800 (the wall's rows set 40).
  TextStyle kidJob(Color c) => _kid(20, FontWeight.w800, c, 1.2);

  /// "+2 stars", "1 of 3", "Done": 15 / 700.
  TextStyle kidMeta(Color c) => _kid(15, FontWeight.w700, c, 1.2);

  /// The star total: 46 / 800.
  TextStyle kidCount(Color c) => _kid(46, FontWeight.w800, c, 1.0);
}

extension KidTheme on BuildContext {
  /// Kids mode's colors for the theme here.
  KidColors get kid => Theme.of(this).extension<KidColors>() ?? KidColors.of(colors);
}
