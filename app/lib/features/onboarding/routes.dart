import 'package:go_router/go_router.dart';

import '../../app/household.dart';
import '../../platform/sync/pairing.dart';
import '../family/family.dart' show AnotherFamilyPairing, MissingFamilyScreen;
import '../kitchen_screen/kitchen_screen.dart' show AddScreenElsewhereScreen, ScreenCodeScreen;

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
/// phone"), `link`, `screen` (set up as a kitchen screen), `add-screen?code=` (a kitchen
/// screen's QR code opened where Den holds no family) and `waiting`, and the links `/join/:code`
/// (an invite), `/setup/:code/:hub` (a fresh hub's setup link), `/recover/:code` (from whoever
/// runs the hub) and `/add-screen/:code` (a kitchen screen's QR code), which the app's redirect
/// sends on.
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
      GoRoute(path: 'screen', builder: (_, _) => const ScreenCodeScreen()),
      GoRoute(path: 'add-screen', builder: (_, s) => AddScreenElsewhereScreen(code: s.uri.queryParameters['code'] ?? '')),
    ],
  ),
  GoRoute(path: '/join/:code', redirect: (_, _) => '/welcome/join'),
  GoRoute(path: '/recover/:code', redirect: (_, _) => '/welcome/recover'),
  GoRoute(path: '/setup/:code/:hub', redirect: (_, _) => '/welcome/start'),
  GoRoute(path: '/add-screen/:code', redirect: (_, _) => '/today'),
];

/// Joining another family on a device already in one (FAMILY-LINKS-PLAN §5.1):
/// `/families/join?code=&hub=`, from Paste an invite or an invite's link. The join screen, with
/// [AnotherFamilyPairing] starting the new family's own engine beside the others.
final List<RouteBase> familiesRoutes = [
  GoRoute(
    path: '/families/join',
    builder: (context, s) {
      final home = Household.maybeOf(context);
      final screen = JoinScreen(
        code: s.uri.queryParameters['code']?.replaceAll(RegExp(r'[-_]+'), ' '),
        hub: s.uri.queryParameters['hub'],
        another: true,
      );
      return home == null ? screen : PairingScope(service: AnotherFamilyPairing.of(home), child: screen);
    },
  ),
  // A link or reminder for a family this device doesn't hold, or that didn't open.
  GoRoute(
    path: '/families/missing',
    builder: (_, s) => MissingFamilyScreen(closed: s.uri.queryParameters['closed'] == '1'),
  ),
];
