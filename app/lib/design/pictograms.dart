import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// One icon set (Phosphor). Fill weight for pictograms people recognize before they can read;
/// regular weight for interface glyphs. Chore, list and category records store the key.
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

  /// Chore pictograms, keyed by the value stored in `chore.icon`.
  static const Map<String, IconData> chores = {
    'check': PhosphorIconsFill.checkCircle,
    'bed': PhosphorIconsFill.bed,
    'tooth': PhosphorIconsFill.tooth,
    'broom': PhosphorIconsFill.broom,
    'trash': PhosphorIconsFill.trash,
    'recycle': PhosphorIconsFill.recycle,
    'dishes': PhosphorIconsFill.bowlFood,
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
    'backpack': PhosphorIconsFill.backpack,
    'music': PhosphorIconsFill.musicNotes,
    'shoes': PhosphorIconsFill.sneaker,
    'car': PhosphorIconsFill.car,
    'mail': PhosphorIconsFill.envelopeSimple,
    'tools': PhosphorIconsFill.wrench,
    'pill': PhosphorIconsFill.pill,
  };

  static IconData chore(String key) => chores[key] ?? PhosphorIconsFill.checkCircle;

  static IconData listKind(ListKind kind) => switch (kind) {
        ListKind.shopping => PhosphorIconsRegular.shoppingCart,
        ListKind.checklist => PhosphorIconsRegular.listChecks,
        ListKind.packing => PhosphorIconsRegular.suitcase,
        ListKind.meal => PhosphorIconsRegular.cookingPot,
      };

  /// Event category icons, keyed by `category.icon`.
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

  static IconData category(String? key) => categories[key] ?? PhosphorIconsRegular.calendarBlank;

  static const Map<String, IconData> rewards = {
    'gift': PhosphorIconsFill.gift,
    'film': PhosphorIconsFill.filmSlate,
    'game': PhosphorIconsFill.gameController,
    'pizza': PhosphorIconsFill.pizza,
    'moon': PhosphorIconsFill.moonStars,
    'money': PhosphorIconsFill.coins,
    'ticket': PhosphorIconsFill.ticket,
    'ice': PhosphorIconsFill.cookie,
  };

  static IconData reward(String key) => rewards[key] ?? PhosphorIconsFill.gift;
}
