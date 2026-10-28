import 'package:go_router/go_router.dart';

import 'screens/add_people_screen.dart';
import 'screens/join_screen.dart';
import 'screens/link_this_browser_screen.dart';
import 'screens/start_family_screen.dart';
import 'screens/waiting_screen.dart';
import 'screens/welcome_screen.dart';

/// Getting a device into a family: `/welcome` with `start`, `people`, `join?code=`, `link` and
/// `waiting`, and an invite's link `/join/:code` (the app's redirect sends it on).
final List<RouteBase> onboardingRoutes = [
  GoRoute(
    path: '/welcome',
    builder: (_, _) => const WelcomeScreen(),
    routes: [
      GoRoute(path: 'start', builder: (_, _) => const StartFamilyScreen()),
      GoRoute(path: 'people', builder: (_, _) => const AddPeopleScreen()),
      GoRoute(
        path: 'join',
        builder: (_, s) => JoinScreen(code: s.uri.queryParameters['code']?.replaceAll(RegExp(r'[-_]+'), ' ')),
      ),
      GoRoute(path: 'link', builder: (_, _) => const LinkThisBrowserScreen()),
      GoRoute(path: 'waiting', builder: (_, _) => const WaitingScreen()),
    ],
  ),
  GoRoute(path: '/join/:code', redirect: (_, _) => '/welcome/join'),
];
