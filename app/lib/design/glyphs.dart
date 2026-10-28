import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pictograms.dart';

/// Phosphor names some records store (`fork-knife`, `paw-print`) mapped to the pictogram keys
/// in [Pictograms.chores], so a chore always shows its picture, never the generic check.
const Map<String, String> _aliases = {
  'fork-knife': 'dishes',
  'bowl-food': 'dishes',
  'sink': 'dishes',
  'cat': 'pet',
  'dog': 'pet',
  'paw-print': 'pet',
  'fish': 'pet',
  'envelope': 'mail',
  'envelope-simple': 'mail',
  'books': 'book',
  'book-open': 'book',
  'book': 'book',
  'pencil': 'homework',
  'pencil-simple': 'homework',
  'student': 'homework',
  't-shirt': 'laundry',
  'coat-hanger': 'hanger',
  'cooking-pot': 'cooking',
  'potted-plant': 'plant',
  'spray-bottle': 'spray',
  'bathtub': 'bath',
  'sneaker': 'shoes',
  'music-notes': 'music',
  'wrench': 'tools',
  'trash-simple': 'trash',
  'recycle': 'recycle',
  'tooth': 'tooth',
  'bed': 'bed',
  'broom': 'broom',
  'leaf': 'leaf',
  'backpack': 'backpack',
  'car': 'car',
  'pill': 'pill',
  'shower': 'shower',
  'toilet': 'toilet',
};

/// Words in a chore or step that name a picture, for records whose icon isn't one Den knows and
/// for steps, which have no icon of their own.
const Map<String, String> _words = {
  'teeth': 'tooth', 'tooth': 'tooth', 'brush': 'tooth', 'floss': 'tooth',
  'bed': 'bed', 'pillow': 'bed', 'blanket': 'bed',
  'dish': 'dishes', 'plate': 'dishes', 'bowl': 'dishes', 'cup': 'dishes', 'table': 'dishes', 'dishwasher': 'dishes',
  'trash': 'trash', 'garbage': 'trash', 'bin': 'trash',
  'recycl': 'recycle',
  'laundry': 'laundry', 'clothes': 'laundry', 'shirt': 'laundry', 'sock': 'laundry', 'pajama': 'laundry',
  'hang': 'hanger', 'coat': 'hanger', 'jacket': 'hanger',
  'bath': 'bath', 'shower': 'shower', 'toilet': 'toilet', 'potty': 'toilet',
  'wipe': 'spray', 'spray': 'spray', 'counter': 'spray',
  'sweep': 'broom', 'broom': 'broom', 'floor': 'broom', 'vacuum': 'broom', 'tidy': 'broom', 'toys': 'broom',
  'kitchen': 'broom', 'clean': 'broom',
  'dog': 'pet', 'cat': 'pet', 'pet': 'pet', 'feed': 'pet', 'fish': 'pet',
  'water': 'plant', 'plant': 'plant', 'flower': 'plant',
  'leaves': 'leaf', 'yard': 'leaf', 'rake': 'leaf',
  'book': 'book', 'library': 'book', 'read': 'book',
  'homework': 'homework', 'write': 'homework', 'draw': 'homework', 'science': 'homework',
  'backpack': 'backpack', 'lunch': 'backpack',
  'piano': 'music', 'music': 'music', 'practice': 'music', 'violin': 'music',
  'shoe': 'shoes', 'boots': 'shoes',
  'car': 'car', 'mail': 'mail', 'medicine': 'pill', 'vitamin': 'pill',
  'cook': 'cooking', 'dinner': 'cooking', 'breakfast': 'cooking',
};

/// A picture named by [text]'s words, or null.
IconData? pictureForWords(String text) {
  final t = text.toLowerCase();
  for (final e in _words.entries) {
    if (t.contains(e.key)) return Pictograms.chore(e.value);
  }
  return null;
}

/// The chore's pictogram: its icon when Den knows it (directly or by its Phosphor name), else a
/// picture its title names, else the plain check.
IconData choreGlyph(String icon, String title) {
  final key = Pictograms.canonical(_aliases[icon] ?? icon);
  if (key != 'check') {
    final known = Pictograms.chore(key);
    if (known != null) return known;
  }
  return pictureForWords(title) ?? PhosphorIconsFill.checkCircle;
}
