import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pictograms.dart';

/// Chore and reward pictograms as the chores, lists and points screens draw them.
///
/// Records may store either the short keys of [Pictograms] ('dishes', 'pet') or Phosphor's own
/// kebab-case names ('fork-knife', 'cat'), which the hub, MCP clients and the demo write. Both
/// resolve here. An unknown key draws nothing rather than a check mark, which beside a chore's
/// check box would read as "done".
abstract final class HomePictograms {
  static const Map<String, IconData> _phosphor = {
    'fork-knife': PhosphorIconsFill.forkKnife,
    'bowl-food': PhosphorIconsFill.bowlFood,
    'cooking-pot': PhosphorIconsFill.cookingPot,
    'cat': PhosphorIconsFill.cat,
    'dog': PhosphorIconsFill.dog,
    'paw-print': PhosphorIconsFill.pawPrint,
    'fish': PhosphorIconsFill.fish,
    'envelope': PhosphorIconsFill.envelopeSimple,
    'envelope-simple': PhosphorIconsFill.envelopeSimple,
    'books': PhosphorIconsFill.books,
    'book-open': PhosphorIconsFill.bookOpen,
    'book': PhosphorIconsFill.bookOpen,
    'trash': PhosphorIconsFill.trash,
    'recycle': PhosphorIconsFill.recycle,
    'broom': PhosphorIconsFill.broom,
    'bed': PhosphorIconsFill.bed,
    'tooth': PhosphorIconsFill.tooth,
    't-shirt': PhosphorIconsFill.tShirt,
    'coat-hanger': PhosphorIconsFill.coatHanger,
    'bathtub': PhosphorIconsFill.bathtub,
    'shower': PhosphorIconsFill.shower,
    'toilet': PhosphorIconsFill.toilet,
    'spray-bottle': PhosphorIconsFill.sprayBottle,
    'potted-plant': PhosphorIconsFill.pottedPlant,
    'plant': PhosphorIconsFill.plant,
    'leaf': PhosphorIconsFill.leaf,
    'pencil-simple': PhosphorIconsFill.pencilSimple,
    'backpack': PhosphorIconsFill.backpack,
    'music-notes': PhosphorIconsFill.musicNotes,
    'sneaker': PhosphorIconsFill.sneaker,
    'car': PhosphorIconsFill.car,
    'wrench': PhosphorIconsFill.wrench,
    'pill': PhosphorIconsFill.pill,
    'washing-machine': PhosphorIconsFill.washingMachine,
    'drop': PhosphorIconsFill.drop,
    'gift': PhosphorIconsFill.gift,
    'film-slate': PhosphorIconsFill.filmSlate,
    'game-controller': PhosphorIconsFill.gameController,
    'pizza': PhosphorIconsFill.pizza,
    'moon': PhosphorIconsFill.moonStars,
    'moon-stars': PhosphorIconsFill.moonStars,
    'coins': PhosphorIconsFill.coins,
    'money': PhosphorIconsFill.coins,
    'ticket': PhosphorIconsFill.ticket,
    'cookie': PhosphorIconsFill.cookie,
    'ice-cream': PhosphorIconsFill.iceCream,
    'television': PhosphorIconsFill.television,
  };

  /// The chore's pictogram, or null when the key is unknown.
  static IconData? chore(String key) => Pictograms.chores[key] ?? _phosphor[key];

  /// The reward's pictogram; unknown keys show the gift.
  static IconData reward(String key) => Pictograms.rewards[key] ?? _phosphor[key] ?? PhosphorIconsFill.gift;

  /// [base] with [key] added at the front when it isn't one of them, so an editor can show a
  /// record's current pictogram as chosen.
  static Map<String, IconData> withCurrent(Map<String, IconData> base, String key, IconData? icon) =>
      base.containsKey(key) || icon == null ? base : {key: icon, ...base};
}

/// A chore's pictogram at [size] in [color], or the same empty space when it has none.
class ChoreGlyph extends StatelessWidget {
  const ChoreGlyph(this.icon, {super.key, required this.size, required this.color});

  final String icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final data = HomePictograms.chore(icon);
    return data == null ? SizedBox.square(dimension: size) : Icon(data, size: size, color: color);
  }
}
