import 'package:den_core/den_core.dart';

/// The layouts a parent can pick for a shared display: the family week, or today's board.
const List<DisplayLayout> wallLayouts = [DisplayLayout.week, DisplayLayout.today];

/// The layout a shared display shows: the week unless a parent picked Today. Month, Lists and
/// Photos were cut, so a display set to one shows the week.
DisplayLayout wallLayoutOf(Device? device) {
  if (device == null || device.rec.map('display')['layout'] == null) return DisplayLayout.week;
  return device.layout == DisplayLayout.today ? DisplayLayout.today : DisplayLayout.week;
}

/// What a wall shows now, one of the text tabs across its top (KIDS_MODE_AND_SOFT_THEME.md,
/// "Navigation"): the family week, today's board, or the kids' chores board, a column per kid.
///
/// The chores board is the spec's `DisplayLayout.chores`. It is a view of the wall rather than a
/// value of den_core's [DisplayLayout], which this change leaves alone: a parent still picks the
/// week or Today for a display ([wallLayoutOf]), and anyone at the wall can switch to Chores with
/// its tab, which the display keeps ([wallViewOf]). Adding `chores` to [DisplayLayout] later lets
/// a parent pick it from another device too. Lists joins the tabs if Lists comes back.
enum WallView {
  week('Week'),
  today('Today'),
  chores('Chores');

  const WallView(this.label);

  /// The tab's words.
  final String label;
}

/// The view a wall shows: the one chosen at the wall ([chosen], `DevicePrefs.wallView`), or the
/// layout a parent picked for [device].
WallView wallViewOf(Device? device, String? chosen) =>
    WallView.values.asNameMap()[chosen] ??
    (wallLayoutOf(device) == DisplayLayout.today ? WallView.today : WallView.week);
