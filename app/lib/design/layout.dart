import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// How much room a screen has, by available width rather than device type.
enum DenWidth {
  /// Under 700 pt (iPhone, iPad Slide Over): a bottom tab bar with Add in the middle, one column.
  compact,

  /// 700 to 1100 pt (iPad portrait, split view): a 248 pt sidebar, up to two content columns.
  regular,

  /// 1100 pt and wider (iPad landscape, Mac, the wall): sidebar plus two columns; the calendar
  /// opens on the family week.
  wide;

  bool get isCompact => this == compact;

  /// A sidebar instead of a tab bar.
  bool get hasSidebar => this != compact;

  /// Sheets become centered form sheets.
  bool get centersSheets => this != compact;

  /// Content columns beside the sidebar.
  int get columns => this == compact ? 1 : 2;

  /// Tile columns in kid mode (72 pt targets either way).
  int get kidColumns => switch (this) {
        compact => 2,
        regular => 3,
        wide => 4,
      };
}

/// Den's page geometry and breakpoints. See DESIGN.md, "Layout".
abstract final class DenLayout {
  /// Below this width a screen is [DenWidth.compact].
  static const double compactMax = 700;

  /// From this width on a screen is [DenWidth.wide].
  static const double wideMin = 1100;

  /// The iPad sidebar.
  static const double sidebarWidth = 248;

  /// Text columns never grow past this; grids reflow instead.
  static const double readableWidth = 680;

  /// iPad form sheets are at most this wide.
  static const double sheetMaxWidth = 560;

  /// Phone side padding.
  static const double gutter = 16;

  /// Between sections on a page.
  static const double sectionGap = 24;

  /// Between a section's heading and its card.
  static const double headingGap = 10;

  /// A grouped section's side padding, and its rows' vertical padding.
  static const double cardPadding = 16;

  /// Section headings sit this far in from the card's edge, so their text lines up with the rows.
  static const double headingInset = 4;

  /// System text size is followed up to here (200 %), never clamped below.
  static const double maxTextScale = 2;

  static DenWidth forWidth(double width) => width < compactMax
      ? DenWidth.compact
      : width < wideMin
          ? DenWidth.regular
          : DenWidth.wide;

  /// The width class of the whole window. Prefer [DenLayoutBuilder] inside split layouts, where
  /// the available width is what counts.
  static DenWidth of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);
}

/// Builds for the width class of the space it is given (not the device), so a screen in split
/// view or a sidebar column lays itself out for the room it actually has.
class DenLayoutBuilder extends StatelessWidget {
  const DenLayoutBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, DenWidth width) builder;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) => builder(context, DenLayout.forWidth(constraints.maxWidth)));
}

/// Keeps text columns at a readable width on wide screens, centered, without stretching.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({super.key, required this.child, this.maxWidth = DenLayout.readableWidth});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      );
}

/// The text size a person picks in Settings, on top of the system's own (which a Home Screen web
/// app never hears about: Dynamic Type doesn't reach Safari's pages).
enum TextSize {
  /// The system's size as it is.
  standard(1),

  /// 20 pt body text where the system says 17.
  larger(20 / 17),

  /// 23 pt body text where the system says 17: iOS's largest size before the accessibility sizes.
  largest(23 / 17);

  const TextSize(this.factor);

  /// What it multiplies the system's text size by.
  final double factor;
}

/// Follows the platform's text size times the person's [TextSize] up to 200 %, never past it.
/// Put it once above the app's routes.
class DenTextScale extends StatelessWidget {
  const DenTextScale({super.key, required this.child, this.size = TextSize.standard});

  final Widget child;
  final TextSize size;

  /// The text scale for a system [scale] and the person's [size]: their product, held to
  /// [DenLayout.maxTextScale].
  static double combined(double scale, TextSize size) => math.min(scale * size.factor, DenLayout.maxTextScale);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final system = media.textScaler.scale(1);
    final scale = combined(system, size);
    if (scale == system) return child;
    return MediaQuery(data: media.copyWith(textScaler: TextScaler.linear(scale)), child: child);
  }
}
