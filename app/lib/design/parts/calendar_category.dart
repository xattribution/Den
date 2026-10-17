import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../pictograms.dart';

/// Phosphor icon names as categories may store them (the demo family and imports use these),
/// beside the short keys in [Pictograms.categories].
const Map<String, IconData> _byPhosphorName = {
  'calendar-blank': PhosphorIconsRegular.calendarBlank,
  'graduation-cap': PhosphorIconsRegular.graduationCap,
  'student': PhosphorIconsRegular.student,
  'soccer-ball': PhosphorIconsRegular.soccerBall,
  'basketball': PhosphorIconsRegular.basketball,
  'first-aid-kit': PhosphorIconsRegular.firstAidKit,
  'first-aid': PhosphorIconsRegular.firstAid,
  'cake': PhosphorIconsRegular.cake,
  'house': PhosphorIconsRegular.house,
  'airplane': PhosphorIconsRegular.airplane,
  'briefcase': PhosphorIconsRegular.briefcase,
  'music-notes': PhosphorIconsRegular.musicNotes,
  'balloon': PhosphorIconsRegular.balloon,
  'tree': PhosphorIconsRegular.tree,
};

/// The icon for a category's stored key, whichever naming it uses.
IconData categoryIcon(String? key) =>
    Pictograms.categories[key] ?? _byPhosphorName[key] ?? Pictograms.category(key);
