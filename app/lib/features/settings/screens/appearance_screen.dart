import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/widgets.dart';
import '../widgets/calendar_look_choice.dart';
import '../widgets/theme_choice.dart';

/// Settings → Appearance: Day, Night, Auto or Soft with a preview, then how the calendar looks
/// (matching the app or always light, and days as dots or colors). All kept on this device.
/// Text size is a row of its own on Settings, where it's looked for.
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  /// What the Settings row says the theme is now: "Auto".
  static String themeLabel(ThemeChoice choice) => ThemeChoiceSection.choices.firstWhere((c) => c.value == choice).label;

  @override
  Widget build(BuildContext context) => const DenPage(
        title: 'Appearance',
        children: [
          ThemeChoiceSection(),
          CalendarLookChoice(),
        ],
      );
}
