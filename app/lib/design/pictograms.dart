import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// One icon set (Phosphor). Fill weight for pictograms people recognize before they can read;
/// regular weight for interface glyphs. Records store a short key; Phosphor-style names
/// (`fork-knife`) are accepted too, so data from any client resolves. An unknown key draws
/// nothing rather than a check mark, which would read as "done".
abstract final class Pictograms {
  static IconData animal(Animal a) => switch (a) {
        Animal.cat => PhosphorIconsFill.cat,
        Animal.dog => PhosphorIconsFill.dog,
        Animal.rabbit => PhosphorIconsFill.rabbit,
        Animal.bird => PhosphorIconsFill.bird,
        Animal.butterfly => PhosphorIconsFill.butterfly,
        Animal.fish => PhosphorIconsFill.fish,
        Animal.horse => PhosphorIconsFill.horse,
        Animal.cow => PhosphorIconsFill.cow,
        Animal.bug => PhosphorIconsFill.bug,
      };

  /// Chore pictograms by canonical key, in the order the picker shows them.
  static const Map<String, IconData> chores = {
    'check': PhosphorIconsFill.checkSquareOffset,
    'bed': PhosphorIconsFill.bed,
    'tooth': PhosphorIconsFill.tooth,
    'broom': PhosphorIconsFill.broom,
    'trash': PhosphorIconsFill.trash,
    'recycle': PhosphorIconsFill.recycle,
    'dishes': PhosphorIconsFill.forkKnife,
    'cooking': PhosphorIconsFill.cookingPot,
    'laundry': PhosphorIconsFill.tShirt,
    'hanger': PhosphorIconsFill.coatHanger,
    'bath': PhosphorIconsFill.bathtub,
    'shower': PhosphorIconsFill.shower,
    'toilet': PhosphorIconsFill.toilet,
    'spray': PhosphorIconsFill.sprayBottle,
    'pet': PhosphorIconsFill.pawPrint,
    'plant': PhosphorIconsFill.pottedPlant,
    'leaf': PhosphorIconsFill.leaf,
    'book': PhosphorIconsFill.bookOpen,
    'homework': PhosphorIconsFill.pencilSimple,
    'science': PhosphorIconsFill.flask,
    'backpack': PhosphorIconsFill.backpack,
    'music': PhosphorIconsFill.musicNotes,
    'shoes': PhosphorIconsFill.sneaker,
    'car': PhosphorIconsFill.car,
    'mail': PhosphorIconsFill.envelopeSimple,
    'tools': PhosphorIconsFill.wrench,
    'pill': PhosphorIconsFill.pill,
  };

  /// Event category icons by canonical key.
  static const Map<String, IconData> categories = {
    'calendar': PhosphorIconsRegular.calendarBlank,
    'school': PhosphorIconsRegular.student,
    'sports': PhosphorIconsRegular.soccerBall,
    'work': PhosphorIconsRegular.briefcase,
    'health': PhosphorIconsRegular.firstAid,
    'birthday': PhosphorIconsRegular.cake,
    'holiday': PhosphorIconsRegular.tree,
    'family': PhosphorIconsRegular.house,
    'travel': PhosphorIconsRegular.airplane,
    'music': PhosphorIconsRegular.musicNotes,
    'party': PhosphorIconsRegular.balloon,
  };

  /// Event kinds by key: the ink line pictogram an event block carries on the person's color
  /// (ball, tooth, music, car). Bold line weight, so they hold up at 18 on a week cell and at 34
  /// on an event's page. Never on a tinted disc; never the picture pack, which is for people.
  static const Map<String, IconData> events = {
    'calendar': PhosphorIconsBold.calendarBlank,
    'ball': PhosphorIconsBold.soccerBall,
    'basketball': PhosphorIconsBold.basketball,
    'swim': PhosphorIconsBold.swimmingPool,
    'gym': PhosphorIconsBold.barbell,
    'tooth': PhosphorIconsBold.tooth,
    'doctor': PhosphorIconsBold.stethoscope,
    'music': PhosphorIconsBold.musicNotes,
    'church': PhosphorIconsBold.church,
    'food': PhosphorIconsBold.forkKnife,
    'heart': PhosphorIconsBold.heart,
    'car': PhosphorIconsBold.car,
    'bus': PhosphorIconsBold.bus,
    'people': PhosphorIconsBold.usersThree,
    'bag': PhosphorIconsBold.handbag,
    'vote': PhosphorIconsBold.checkSquare,
    'sitter': PhosphorIconsBold.user,
    'school': PhosphorIconsBold.backpack,
    'cake': PhosphorIconsBold.cake,
    'party': PhosphorIconsBold.balloon,
    'travel': PhosphorIconsBold.airplaneTilt,
    'beach': PhosphorIconsBold.umbrellaSimple,
    'work': PhosphorIconsBold.briefcase,
    'book': PhosphorIconsBold.books,
    'art': PhosphorIconsBold.paintBrush,
    'movie': PhosphorIconsBold.filmSlate,
    'pet': PhosphorIconsBold.pawPrint,
    'haircut': PhosphorIconsBold.scissors,
    'camp': PhosphorIconsBold.tent,
  };

  /// The pictogram for an event kind ([events]); the plain calendar page for anything else.
  static IconData event(String? kind) => events[kind] ?? PhosphorIconsBold.calendarBlank;

  static const Map<String, IconData> rewards = {
    'gift': PhosphorIconsFill.gift,
    'film': PhosphorIconsFill.filmSlate,
    'game': PhosphorIconsFill.gameController,
    'pizza': PhosphorIconsFill.pizza,
    'moon': PhosphorIconsFill.moonStars,
    'money': PhosphorIconsFill.coins,
    'ticket': PhosphorIconsFill.ticket,
    'treat': PhosphorIconsFill.iceCream,
  };

  /// Phosphor-style names written by earlier data, mapped to canonical keys.
  static const Map<String, String> _aliases = {
    'fork-knife': 'dishes',
    'bowl-food': 'dishes',
    'cooking-pot': 'cooking',
    't-shirt': 'laundry',
    'coat-hanger': 'hanger',
    'bathtub': 'bath',
    'spray-bottle': 'spray',
    'paw-print': 'pet',
    'cat': 'pet',
    'dog': 'pet',
    'potted-plant': 'plant',
    'books': 'book',
    'book-open': 'book',
    'pencil': 'homework',
    'pencil-simple': 'homework',
    'flask': 'science',
    'music-notes': 'music',
    'sneaker': 'shoes',
    'envelope': 'mail',
    'envelope-simple': 'mail',
    'wrench': 'tools',
    'check-circle': 'check',
    'graduation-cap': 'school',
    'student': 'school',
    'soccer-ball': 'sports',
    'basketball': 'sports',
    'briefcase': 'work',
    'first-aid': 'health',
    'first-aid-kit': 'health',
    'stethoscope': 'health',
    'cake': 'birthday',
    'tree': 'holiday',
    'house': 'family',
    'airplane': 'travel',
    'balloon': 'party',
    'film-slate': 'film',
    'game-controller': 'game',
    'moon-stars': 'moon',
    'coins': 'money',
    'ice-cream': 'treat',
    'cookie': 'treat',
  };

  static String canonical(String key) => _aliases[key] ?? key;

  static IconData? chore(String key) => chores[canonical(key)];

  static IconData listKind(ListKind kind) => switch (kind) {
        ListKind.shopping => PhosphorIconsRegular.shoppingCart,
        ListKind.checklist => PhosphorIconsRegular.listChecks,
        ListKind.packing => PhosphorIconsRegular.suitcase,
        ListKind.meal => PhosphorIconsRegular.cookingPot,
      };

  static IconData category(String? key) =>
      categories[canonical(key ?? '')] ?? PhosphorIconsRegular.calendarBlank;

  /// A device by its kind.
  static IconData device(DeviceKind k) => switch (k) {
        DeviceKind.phone => PhosphorIconsRegular.deviceMobile,
        DeviceKind.tablet => PhosphorIconsRegular.deviceTablet,
        DeviceKind.desktop => PhosphorIconsRegular.laptop,
        DeviceKind.browser => PhosphorIconsRegular.browser,
        DeviceKind.hub => PhosphorIconsRegular.hardDrives,
        DeviceKind.display => PhosphorIconsRegular.monitor,
      };

  static IconData reward(String key) => rewards[canonical(key)] ?? PhosphorIconsFill.gift;
}
