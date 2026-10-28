import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// One picture from the family's picture pack: original, full-color illustrations a person picks
/// as their own picture, always shown inside a ring of their color (DenAvatar). They are
/// identity, never icons on buttons or headings.
@immutable
class DenPicture {
  const DenPicture(this.id, this.label, this.name);

  /// The stored key and the file name.
  final String id;

  /// The short name under the picture in the picker ("Melon").
  final String label;

  /// The full name, for screen readers and the pack overview ("Watermelon").
  final String name;

  String get asset => 'assets/pictures/$id.svg';

  @override
  String toString() => 'DenPicture($id)';
}

/// A group of pictures, as the picker's category chips show them.
@immutable
class DenPictureGroup {
  const DenPictureGroup(this.name, this.pictures);

  final String name;
  final List<DenPicture> pictures;
}

/// The 64 pictures, in the canvas's categories and order. Each is a 64 x 64 SVG in
/// `assets/pictures/` using only circle, ellipse, rect, path and g with fills, strokes and
/// rotations, all of which flutter_svg draws.
abstract final class DenPictures {
  static const List<DenPictureGroup> groups = [
    DenPictureGroup('Animals', [
      DenPicture('fox', 'Fox', 'Fox'),
      DenPicture('bear', 'Bear', 'Bear'),
      DenPicture('cat', 'Cat', 'Cat'),
      DenPicture('dog', 'Dog', 'Dog'),
      DenPicture('bunny', 'Bunny', 'Bunny'),
      DenPicture('owl', 'Owl', 'Owl'),
      DenPicture('panda', 'Panda', 'Panda'),
      DenPicture('frog', 'Frog', 'Frog'),
    ]),
    DenPictureGroup('Critters', [
      DenPicture('whale', 'Whale', 'Whale'),
      DenPicture('octopus', 'Octopus', 'Octopus'),
      DenPicture('turtle', 'Turtle', 'Turtle'),
      DenPicture('ladybug', 'Ladybug', 'Ladybug'),
      DenPicture('bee', 'Bee', 'Bee'),
      DenPicture('butterfly', 'Butterfly', 'Butterfly'),
      DenPicture('snail', 'Snail', 'Snail'),
      DenPicture('chick', 'Chick', 'Chick'),
    ]),
    DenPictureGroup('Snacks', [
      DenPicture('strawberry', 'Strawberry', 'Strawberry'),
      DenPicture('avocado', 'Avocado', 'Avocado'),
      DenPicture('pizza', 'Pizza', 'Pizza'),
      DenPicture('cupcake', 'Cupcake', 'Cupcake'),
      DenPicture('watermelon', 'Melon', 'Watermelon'),
      DenPicture('banana', 'Banana', 'Banana'),
      DenPicture('icecream', 'Ice cream', 'Ice cream'),
      DenPicture('pancakes', 'Pancakes', 'Pancakes'),
    ]),
    DenPictureGroup('Outdoors', [
      DenPicture('sunflower', 'Sunflower', 'Sunflower'),
      DenPicture('cactus', 'Cactus', 'Cactus'),
      DenPicture('mushroom', 'Mushroom', 'Mushroom'),
      DenPicture('tree', 'Tree', 'Apple tree'),
      DenPicture('rainbow', 'Rainbow', 'Rainbow'),
      DenPicture('sun', 'Sun', 'Sun'),
      DenPicture('moon', 'Moon', 'Moon'),
      DenPicture('cloud', 'Cloud', 'Rain cloud'),
    ]),
    DenPictureGroup('Play', [
      DenPicture('soccer', 'Soccer', 'Soccer'),
      DenPicture('basketball', 'Hoops', 'Basketball'),
      DenPicture('rocket', 'Rocket', 'Rocket'),
      DenPicture('guitar', 'Guitar', 'Guitar'),
      DenPicture('palette', 'Paints', 'Paints'),
      DenPicture('kite', 'Kite', 'Kite'),
      DenPicture('dinosaur', 'Dino', 'Dinosaur'),
      DenPicture('robot', 'Robot', 'Robot'),
    ]),
    DenPictureGroup('Home and adventure', [
      DenPicture('house', 'Home', 'Home'),
      DenPicture('sailboat', 'Sailboat', 'Sailboat'),
      DenPicture('balloon', 'Balloon', 'Balloon'),
      DenPicture('teacup', 'Teacup', 'Teacup'),
      DenPicture('tent', 'Camping', 'Camping'),
      DenPicture('star', 'Star', 'Star'),
      DenPicture('crown', 'Crown', 'Crown'),
      DenPicture('camera', 'Camera', 'Camera'),
    ]),
    DenPictureGroup('Heroes and jobs', [
      DenPicture('firefighter', 'Firefighter', 'Firefighter'),
      DenPicture('police', 'Police', 'Police'),
      DenPicture('doctor', 'Doctor', 'Doctor'),
      DenPicture('spy', 'Agent', 'Secret agent'),
      DenPicture('ninja', 'Ninja', 'Ninja'),
      DenPicture('armyman', 'Army man', 'Army man'),
      DenPicture('astronaut', 'Astronaut', 'Astronaut'),
      DenPicture('pirate', 'Pirate', 'Pirate'),
    ]),
    DenPictureGroup('Action and wheels', [
      DenPicture('tank', 'Tank', 'Tank'),
      DenPicture('jet', 'Jet', 'Jet'),
      DenPicture('racecar', 'Race car', 'Race car'),
      DenPicture('firetruck', 'Fire truck', 'Fire truck'),
      DenPicture('helicopter', 'Chopper', 'Helicopter'),
      DenPicture('train', 'Train', 'Train'),
      DenPicture('sheriff', 'Sheriff', 'Sheriff'),
      DenPicture('revolver', 'Six-shooter', 'Six-shooter'),
    ]),
  ];

  /// Every picture, in pack order.
  static final List<DenPicture> all = [for (final g in groups) ...g.pictures];

  static final Map<String, DenPicture> _byId = {for (final p in all) p.id: p};

  /// The picture stored under [id], or null for an id this version doesn't know.
  static DenPicture? find(String? id) => id == null ? null : _byId[id];

  static final Map<String, ({ui.Picture picture, ui.Size size})> _drawn = {};
  static Future<void>? _loading;

  /// Parses every picture once, so avatars draw in their first frame instead of popping in.
  /// Safe to call more than once; avatars fall back to loading one picture at a time until it
  /// has finished.
  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      for (final p in all) {
        if (_drawn.containsKey(p.id)) continue;
        final info = await vg.loadPicture(SvgAssetLoader(p.asset), null);
        _drawn[p.id] = (picture: info.picture, size: info.size);
      }
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  /// The parsed picture for [id], once [load] has finished.
  static ({ui.Picture picture, ui.Size size})? drawn(String id) => _drawn[id];
}
