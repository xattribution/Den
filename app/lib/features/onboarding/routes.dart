import 'package:go_router/go_router.dart';

import 'screens/add_people_screen.dart';
import 'screens/join_screen.dart';
import 'screens/link_this_browser_screen.dart';
import 'screens/recover_screen.dart';
import 'screens/recovery_words_screen.dart';
import 'screens/start_family_screen.dart';
import 'screens/waiting_screen.dart';
import 'screens/welcome_screen.dart';

/// Getting a device into a family: `/welcome` with `start?setup=&hub=`, `words` (recovery
/// words, offered later from Needs you), `people`, `join?code=`, `recover?code=` ("I lost my
/// phone"), `link` and `waiting`, and the links `/join/:code` (an invite), `/setup/:code/:hub`
/// (a fresh hub's setup link) and `/recover/:code` (from whoever runs the hub), which the app's
/// redirect sends on.
final List<RouteBase> onboardingRoutes = [
  GoRoute(
    path: '/welcome',
    builder: (_, _) => const WelcomeScreen(),
    routes: [
      GoRoute(
        path: 'start',
        builder: (_, s) => StartFamilyScreen(setupCode: s.uri.queryParameters['setup'], hubDevice: s.uri.queryParameters['hub']),
      ),
      GoRoute(path: 'words', builder: (_, _) => const RecoveryWordsScreen()),
      GoRoute(path: 'people', builder: (_, _) => const AddPeopleScreen()),
      GoRoute(
        path: 'join',
        builder: (_, s) => JoinScreen(code: s.uri.queryParameters['code']?.replaceAll(RegExp(r'[-_]+'), ' ')),
      ),
      GoRoute(
        path: 'recover',
        builder: (_, s) => RecoverScreen(code: s.uri.queryParameters['code']?.replaceAll(RegExp(r'[-_]+'), ' ')),
      ),
      GoRoute(path: 'link', builder: (_, _) => const LinkThisBrowserScreen()),
      GoRoute(path: 'waiting', builder: (_, _) => const WaitingScreen()),
    ],
  ),
  GoRoute(path: '/join/:code', redirect: (_, _) => '/welcome/join'),
  GoRoute(path: '/recover/:code', redirect: (_, _) => '/welcome/recover'),
  GoRoute(path: '/setup/:code/:hub', redirect: (_, _) => '/welcome/start'),
];
