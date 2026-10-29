import 'package:den_core/den_core.dart';

/// The layouts a parent can pick for a shared display: the family week, or today's board.
const List<DisplayLayout> wallLayouts = [DisplayLayout.week, DisplayLayout.today];

/// The layout a shared display shows: the week unless a parent picked Today. Month, Lists and
/// Photos were cut, so a display set to one shows the week.
DisplayLayout wallLayoutOf(Device? device) {
  if (device == null || device.rec.map('display')['layout'] == null) return DisplayLayout.week;
  return device.layout == DisplayLayout.today ? DisplayLayout.today : DisplayLayout.week;
}
