import 'package:go_router/go_router.dart';

import 'screens/phone_calendars_screen.dart';
import 'screens/settings_screen.dart';

/// `/settings`, with `phone-calendars` and the [more] pages other features put under it.
GoRoute settingsRoute({List<RouteBase> more = const []}) => GoRoute(
      path: '/settings',
      builder: (_, _) => const SettingsScreen(),
      routes: [
        ...more,
        GoRoute(path: 'phone-calendars', builder: (_, _) => const PhoneCalendarsScreen()),
      ],
    );
