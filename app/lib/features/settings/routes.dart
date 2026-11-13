import 'package:go_router/go_router.dart';

import '../linked/linked_families_screen.dart';
import '../linked/linked_family_screen.dart';
import 'screens/about_screen.dart';
import 'screens/age_groups_screen.dart';
import 'screens/appearance_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/backups_screen.dart';
import 'screens/calendars_screen.dart';
import 'screens/family_settings_screen.dart';
import 'screens/phone_calendars_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sign_in_account_screen.dart';

/// `/settings`, with `family` (and its `colors`), `appearance`, `about`, `calendars`, `phone-calendars`, `assistant`, `sign-in`, `backups`, `linked` (and each linked family) and the [more] pages
/// other features put under it (Advanced).
GoRoute settingsRoute({List<RouteBase> more = const []}) => GoRoute(
      path: '/settings',
      builder: (_, _) => const SettingsScreen(),
      routes: [
        ...more,
        GoRoute(
          path: 'family',
          builder: (_, _) => const FamilySettingsScreen(),
          routes: [
            GoRoute(path: 'colors', builder: (_, _) => const FamilyColorsScreen()),
            GoRoute(path: 'ages', builder: (_, _) => const AgeGroupsScreen()),
          ],
        ),
        GoRoute(path: 'appearance', builder: (_, _) => const AppearanceScreen()),
        GoRoute(path: 'about', builder: (_, _) => const AboutScreen()),
        GoRoute(path: 'calendars', builder: (_, _) => const CalendarsScreen()),
        GoRoute(path: 'phone-calendars', builder: (_, _) => const PhoneCalendarsScreen()),
        GoRoute(path: 'assistant', builder: (_, _) => const AssistantScreen()),
        GoRoute(path: 'sign-in', builder: (_, _) => const SignInAccountScreen()),
        GoRoute(path: 'backups', builder: (_, _) => const BackupsScreen()),
        GoRoute(
          path: 'linked',
          builder: (_, _) => const LinkedFamiliesScreen(),
          routes: [GoRoute(path: ':id', builder: (_, s) => LinkedFamilyScreen(id: s.pathParameters['id']!))],
        ),
      ],
    );
