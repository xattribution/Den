import 'dart:ui';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

/// Den's color tokens. Neutral grays (equal R, G and B), ink for every action, and color only
/// for people, the star and destructive red. Light and dark set the same names; dark is true
/// black for OLED with cards a step up in gray. See DESIGN.md, "Color".
///
/// The old names (`paper`, `well`, `rule`, `onInk`, `bad`, `caution`) still work as deprecated
/// aliases so screens can move to the new names one at a time.
@immutable
class DenColors extends ThemeExtension<DenColors> {
  const DenColors({
    required this.brightness,
    required this.bg,
    required this.card,
    required this.raised,
    required this.fill,
    required this.line,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.onPrimary,
    required this.onMarker,
    required this.destructive,
    required this.star,
    required this.starEdge,
    required this.scrim,
    required this.handle,
    required this.track,
    required this.switchOff,
    required this.knob,
    required this.pictureBg,
    required this.photoBg,
    required this.photoFg,
    required this.bar,
  });

  final Brightness brightness;

  /// The page behind grouped sections, and the surface of sheets.
  final Color bg;

  /// Grouped sections, inputs, unselected chips and secondary buttons. Elevation is this step
  /// in gray, never a shadow.
  final Color card;

  /// True overlays: menus and popovers (with a shadow by day, a [line] edge at night).
  final Color raised;

  /// The track of a segmented control.
  final Color fill;

  /// Dividers inside a section, the tab bar's top edge, outlines of chips on a card. Decorative.
  final Color line;

  /// Text, icons, primary buttons, selected states, the focus ring.
  final Color ink;

  /// Secondary text: times, places, counts. 4.5:1 or better on [bg] and [card].
  final Color ink2;

  /// Unselected tab labels and other quiet text. Still 4.5:1 or better on [bg] and [card].
  final Color ink3;

  /// Text and icons on a primary (ink) fill.
  final Color onPrimary;

  /// Text and icons on a person's color: dark ink in both themes.
  final Color onMarker;

  /// Destructive and failed, as text plus an icon. Never a background.
  final Color destructive;

  /// The star's fill, and nothing else.
  final Color star;

  /// The star's outline, for contrast with the page.
  final Color starEdge;

  /// Behind sheets.
  final Color scrim;

  /// A sheet's grab handle.
  final Color handle;

  /// The unfilled part of a progress bar toward a goal.
  final Color track;

  /// A switch's track when off.
  final Color switchOff;

  /// A switch's thumb.
  final Color knob;

  /// Behind a picture from the pack, inside the person's ring.
  final Color pictureBg;

  /// The placeholder for a photo that hasn't loaded: background and silhouette.
  final Color photoBg;
  final Color photoFg;

  /// The tab bar and the iPad sidebar.
  final Color bar;

  /// The primary action's fill: ink.
  Color get primary => ink;

  /// The iPad sidebar sits on the same surface as the tab bar.
  Color get sidebar => bar;

  bool get isDark => brightness == Brightness.dark;

  /// A person's color. The same hex in light and dark, always with [onMarker] on it.
  Color marker(Marker m) => PersonColor.forMarker(m).color;

  @Deprecated('Use bg: the page behind sections (sheets sit on bg too).')
  Color get paper => bg;

  @Deprecated('Use card for inputs, chips and secondary buttons, or fill for a segmented track.')
  Color get well => card;

  @Deprecated('Use line.')
  Color get rule => line;

  @Deprecated('Use onPrimary: text and icons on a primary (ink) fill.')
  Color get onInk => onPrimary;

  @Deprecated('Use destructive, as text plus an icon, never as a background.')
  Color get bad => destructive;

  @Deprecated('Den has no caution color: attention is position, a plain word and an ink icon. Use ink.')
  Color get caution => ink;

  static const day = DenColors(
    brightness: Brightness.light,
    bg: Color(0xFFF2F2F2),
    card: Color(0xFFFFFFFF),
    raised: Color(0xFFFFFFFF),
    fill: Color(0xFFE6E6E6),
    line: Color(0xFFE0E0E0),
    ink: Color(0xFF141414),
    ink2: Color(0xFF595959),
    ink3: Color(0xFF6B6B6B),
    onPrimary: Color(0xFFFFFFFF),
    onMarker: Color(0xFF141414),
    destructive: Color(0xFFBE241F),
    star: Color(0xFFF2B705),
    starEdge: Color(0xFF8A6200),
    scrim: Color(0x7A000000),
    handle: Color(0xFFC4C4C4),
    track: Color(0xFFE0E0E0),
    switchOff: Color(0xFFD4D4D4),
    knob: Color(0xFFFFFFFF),
    pictureBg: Color(0xFFF0F0F0),
    photoBg: Color(0xFFD9D9D9),
    photoFg: Color(0xFFA6A6A6),
    bar: Color(0xFFFFFFFF),
  );

  static const night = DenColors(
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    card: Color(0xFF141414),
    raised: Color(0xFF1F1F1F),
    fill: Color(0xFF242424),
    line: Color(0xFF262626),
    ink: Color(0xFFF2F2F2),
    ink2: Color(0xFFA6A6A6),
    ink3: Color(0xFF8C8C8C),
    onPrimary: Color(0xFF000000),
    onMarker: Color(0xFF141414),
    destructive: Color(0xFFF9786A),
    star: Color(0xFFFFC83D),
    starEdge: Color(0xFFFFC83D),
    // A black page can't be dimmed, so at night the page behind a sheet goes to a flat dark gray
    // and the black sheet stands out against it.
    scrim: Color(0xD91A1A1A),
    handle: Color(0xFF4A4A4A),
    track: Color(0xFF2A2A2A),
    switchOff: Color(0xFF3A3A3A),
    knob: Color(0xFFF2F2F2),
    pictureBg: Color(0xFF262626),
    photoBg: Color(0xFF3A3A3A),
    photoFg: Color(0xFF8C8C8C),
    bar: Color(0xFF000000),
  );

  @override
  DenColors copyWith() => this;

  @override
  DenColors lerp(DenColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DenColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: l(bg, other.bg),
      card: l(card, other.card),
      raised: l(raised, other.raised),
      fill: l(fill, other.fill),
      line: l(line, other.line),
      ink: l(ink, other.ink),
      ink2: l(ink2, other.ink2),
      ink3: l(ink3, other.ink3),
      onPrimary: l(onPrimary, other.onPrimary),
      onMarker: l(onMarker, other.onMarker),
      destructive: l(destructive, other.destructive),
      star: l(star, other.star),
      starEdge: l(starEdge, other.starEdge),
      scrim: l(scrim, other.scrim),
      handle: l(handle, other.handle),
      track: l(track, other.track),
      switchOff: l(switchOff, other.switchOff),
      knob: l(knob, other.knob),
      pictureBg: l(pictureBg, other.pictureBg),
      photoBg: l(photoBg, other.photoBg),
      photoFg: l(photoFg, other.photoFg),
      bar: l(bar, other.bar),
    );
  }
}

/// The family colors: eight bright colors, one per person, the same hex in light and dark and
/// always with dark ink text ([DenColors.onMarker], 5.4:1 or better on every one). Declared in
/// assignment order; every neighbor in this order passes the color-blind (deltaE 15.9 worst)
/// and normal-vision (deltaE 25.8 worst) separation checks. Never add or tweak one by eye: run
/// the validator.
enum PersonColor {
  sky('Sky', Color(0xFF339FEE)),
  grass('Grass', Color(0xFF4CC157)),
  lavender('Lavender', Color(0xFFAD87ED)),
  tangerine('Tangerine', Color(0xFFF88B1C)),
  aqua('Aqua', Color(0xFF10CACA)),
  coral('Coral', Color(0xFFF05653)),
  sunshine('Sunshine', Color(0xFFF4CE23)),
  bubblegum('Bubblegum', Color(0xFFF075AA));

  const PersonColor(this.label, this.color);

  /// The color's name as people see it in pickers.
  final String label;
  final Color color;

  /// The colors in the order new people get them, for pickers.
  static const List<PersonColor> assignmentOrder = values;

  /// The color the next person gets: the first in assignment order nobody has yet, or, once all
  /// eight are taken, the one the fewest people share ([Marker.next]).
  static PersonColor next(Iterable<PersonColor> taken) =>
      forMarker(Marker.next(taken.map((p) => p.marker)));

  /// The engine's name for this color.
  Marker get marker => Marker.values.byName(name);

  /// The color for a person's [Marker]; the engine names the same eight colors in the same order.
  static PersonColor forMarker(Marker m) => values.byName(m.name);
}

/// Spacing on a 4 px scale (`Sp.l` = 16). Page-level spacing lives in DenLayout.
abstract final class Sp {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Radius follows the object: pills for buttons and chips, 14 for inputs, 20 for grouped
/// sections, circles for avatars. Never one radius for everything, never a card in a card.
abstract final class Radii {
  /// Text fields, search, the add-item bar.
  static const double input = 14;

  /// Tiles inside a section: day buttons in the week strip, the picker's photo buttons.
  static const double tile = 16;

  /// A solid event block in the calendar (6 where blocks stack).
  static const double block = 18;

  /// Grouped sections (iOS inset lists).
  static const double section = 20;

  /// The top corners of a sheet, all four corners of an iPad form sheet.
  static const double sheet = 28;

  /// Buttons and chips. Prefer a [StadiumBorder]; this is the same as a radius.
  static const double pill = 999;

  @Deprecated('Use input (14) for fields, a StadiumBorder for buttons and chips, or tile (16).')
  static const double control = input;

  @Deprecated('Use section (20) for grouped sections, or sheet (28) for sheet tops.')
  static const double card = section;

  @Deprecated('Use pill, or a circle for avatars.')
  static const double round = pill;
}

@Deprecated('Use DenMotion (design/motion.dart): springs for movement, a 100 ms fade under Reduce Motion.')
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

/// Minimum touch targets. The visible part can be smaller inside the target.
abstract final class Targets {
  static const double adult = 44;
  static const double kid = 72;
}

/// The old type roles (13, 15, 18, 24, 40). Kept so screens render as before while they move to
/// [DenText]; [family] and [wallScale] stay.
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

  @Deprecated('Use context.text.meta (15) or caption (13).')
  TextStyle meta(Color c) => _style(13, FontWeight.w400, c);

  @Deprecated('Use context.text.body (17) or meta (15).')
  TextStyle body(Color c) => _style(15, FontWeight.w400, c);

  @Deprecated('Use context.text.rowTitle (17, bold) or label (16, bold) for buttons.')
  TextStyle bodyStrong(Color c) => _style(15, FontWeight.w700, c);

  @Deprecated('Use context.text.section (20).')
  TextStyle title(Color c) => _style(18, FontWeight.w700, c);

  @Deprecated('Use context.text.screenTitle (30) or sheetTitle (26).')
  TextStyle heading(Color c) => _style(24, FontWeight.w700, c);

  @Deprecated('Use context.text.display (44).')
  TextStyle display(Color c) => _style(40, FontWeight.w700, c);

  @override
  DenType copyWith({double? scale}) => DenType(scale ?? this.scale);

  @override
  DenType lerp(DenType? other, double t) => other == null ? this : DenType(lerpDouble(scale, other.scale, t)!);
}

/// Den's type: Atkinson Hyperlegible Next at 400 and 700, with 800 only for the one heading on
/// a screen or sheet. Body is 17. Every size follows the platform's text size (through
/// MediaQuery.textScaler, which Text applies) and the wall display's [scale]. Line height is
/// 1.25 for titles and 1.35 for reading text.
@immutable
class DenText extends ThemeExtension<DenText> {
  const DenText([this.scale = 1]);

  /// 1.3 on the wall display, 1 elsewhere.
  final double scale;

  static const _tabular = [FontFeature.tabularFigures()];

  TextStyle _style(double size, FontWeight weight, Color color, double height, {double tracking = 0}) => TextStyle(
        fontFamily: DenType.family,
        fontSize: size * scale,
        fontWeight: weight,
        fontVariations: [FontVariation.weight(weight.value.toDouble())],
        height: height,
        letterSpacing: tracking == 0 ? null : tracking * scale,
        leadingDistribution: TextLeadingDistribution.even,
        color: color,
        fontFeatures: _tabular,
      );

  /// The one heading on a screen ("Good morning", "October"): 30, or 34 on iPad ([large]).
  TextStyle screenTitle(Color c, {bool large = false}) =>
      _style(large ? 34 : 30, FontWeight.w800, c, 1.15, tracking: large ? -0.5 : -0.4);

  /// A sheet's one heading ("Add", "Mia's picture").
  TextStyle sheetTitle(Color c) => _style(26, FontWeight.w800, c, 1.2);

  /// A section's heading ("Needs you", "Today").
  TextStyle section(Color c) => _style(20, FontWeight.w700, c, 1.25);

  /// The first line of a row: an event, a request, a person.
  TextStyle rowTitle(Color c) => _style(17, FontWeight.w700, c, 1.25);

  /// Reading text and what people type.
  TextStyle body(Color c) => _style(17, FontWeight.w400, c, 1.35);

  /// Buttons and selected chips.
  TextStyle label(Color c) => _style(16, FontWeight.w700, c, 1.25);

  /// Chips that aren't selected, and other 16 px controls.
  TextStyle control(Color c) => _style(16, FontWeight.w400, c, 1.25);

  /// A row's second line ("Soccer, 3:30 PM at Field 4"), counts beside a section heading.
  TextStyle meta(Color c) => _style(15, FontWeight.w400, c, 1.35);

  /// Names under pictures, day letters in the week strip.
  TextStyle caption(Color c) => _style(13, FontWeight.w400, c, 1.3);

  /// Tab bar labels; the selected tab is bold.
  TextStyle tab(Color c, {bool selected = false}) =>
      _style(11, selected ? FontWeight.w700 : FontWeight.w400, c, 1.2);

  /// Numbers read across a room: a kid's star total.
  TextStyle display(Color c) => _style(44, FontWeight.w700, c, 1.05);

  @override
  DenText copyWith({double? scale}) => DenText(scale ?? this.scale);

  @override
  DenText lerp(DenText? other, double t) => other == null ? this : DenText(lerpDouble(scale, other.scale, t)!);
}

/// Weight changes for Den's text styles. The bundled font is variable, so a weight has to move
/// its weight axis too; `copyWith(fontWeight: ...)` alone would draw the old weight.
extension DenTextWeight on TextStyle {
  /// The same style at 700.
  TextStyle get bold => withWeight(FontWeight.w700);

  /// The same style at 400.
  TextStyle get regular => withWeight(FontWeight.w400);

  TextStyle withWeight(FontWeight weight) =>
      copyWith(fontWeight: weight, fontVariations: [FontVariation.weight(weight.value.toDouble())]);
}

extension DenTheme on BuildContext {
  DenColors get colors => Theme.of(this).extension<DenColors>()!;
  DenType get type => Theme.of(this).extension<DenType>()!;
  DenText get text => Theme.of(this).extension<DenText>() ?? const DenText();
}
