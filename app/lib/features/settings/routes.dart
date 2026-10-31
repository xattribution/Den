import 'package:go_router/go_router.dart';

import 'screens/assistant_screen.dart';
import 'screens/calendars_screen.dart';
import 'screens/family_settings_screen.dart';
import 'screens/phone_calendars_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sign_in_account_screen.dart';

/// `/settings`, with `family`, `calendars`, `phone-calendars`, `assistant`, `sign-in` and the [more] pages
/// other features put under it (Advanced).
GoRoute settingsRoute({List<RouteBase> more = const []}) => GoRoute(
      path: '/settings',
      builder: (_, _) => const SettingsScreen(),
      routes: [
        ...more,
        GoRoute(path: 'family', builder: (_, _) => const FamilySettingsScreen()),
        GoRoute(path: 'calendars', builder: (_, _) => const CalendarsScreen()),
        GoRoute(path: 'phone-calendars', builder: (_, _) => const PhoneCalendarsScreen()),
        GoRoute(path: 'assistant', builder: (_, _) => const AssistantScreen()),
        GoRoute(path: 'sign-in', builder: (_, _) => const SignInAccountScreen()),
      ],
    );
