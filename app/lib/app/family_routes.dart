import 'package:den_core/den_core.dart';
import 'package:go_router/go_router.dart';

import '../features/advanced/screens/add_hub_screen.dart';
import '../features/family/screens/device_screen.dart';
import '../features/family/screens/link_browser_screen.dart';
import '../features/family/screens/family_screen.dart';
import '../features/family/screens/member_editor.dart';
import '../features/shared_screens/screens/kid_screen.dart';
import '../features/onboarding/screens/add_people_screen.dart';
import '../features/onboarding/screens/join_screen.dart';
import '../features/onboarding/screens/link_this_browser_screen.dart';
import '../features/onboarding/screens/start_family_screen.dart';
import '../features/onboarding/screens/waiting_screen.dart';
import '../features/onboarding/screens/welcome_screen.dart';
import '../features/advanced/screens/connections_screen.dart';
import '../features/advanced/screens/create_token_screen.dart';
import '../features/advanced/screens/home_assistant_screen.dart';
import '../features/settings/screens/phone_calendars_screen.dart';
import '../features/settings/screens/settings_screen.dart';
import '../features/shared_screens/screens/wall_screen.dart';
import 'app_state.dart';

/// The adult shell's four tabs.
bool _isShellTab(String loc) =>
    loc == '/today' || loc == '/chores' || loc == '/lists' || loc == '/calendar' || loc.startsWith('/calendar/');

/// Kids who get the picture-first kids' app instead of the adult shell.
bool isLittleKid(Member? m) => m != null && m.isKid && (m.tier == Tier.preReader || m.tier == Tier.little);

/// Where the app sends someone before the main shell. Null means stay.
///
/// 0. An invite's link (`/join/<words>`): joining with its words, or Today for a device that is
///    already in a family.
/// 1. No family on this device: onboarding (`/welcome`).
/// 2. A join request sent but not approved yet: the waiting screen, whatever was asked for.
/// 3. Right after creating a family: the short "Add people" step; any other onboarding route
///    once the device is in the family goes to Today.
/// 4. A pre-reader or little kid acting on this device (its owner, or verified on a shared
///    screen): the kids' app instead of the shell's tabs.
/// 5. A shared display, a hub with no owner, or this device set to "Use as wall display": the
///    wall instead of Today, unless someone has signed in to use the full app. A parent's device
///    running as the hub acts for that parent (see DenNetwork) and keeps the full app.
/// 6. Leaving the kids' app when the person acting is no longer a younger kid.
String? familyRedirect(AppState state, GoRouterState route) {
  final den = state.den;
  final loc = route.matchedLocation;
  final inWelcome = loc == '/welcome' || loc.startsWith('/welcome/');

  final path = route.uri.path;
  if (path.startsWith('/join/')) {
    if (den.hasFamily) return '/today';
    final words = path.substring('/join/'.length);
    return Uri(path: '/welcome/join', queryParameters: {'code': words}).toString();
  }

  if (!den.hasFamily) return inWelcome ? null : '/welcome';
  if (!den.isApproved) return loc == '/welcome/waiting' ? null : '/welcome/waiting';
  if (loc == '/welcome/start') return '/welcome/people';
  if (inWelcome && loc != '/welcome/people') return '/today';

  final me = state.me;
  final device = den.thisDevice;
  final display = state.wall || (device?.isShared ?? false);

  if (isLittleKid(me) && _isShellTab(loc)) return '/kid';
  // A personal device set to "Use as wall display" always shows the wall for Today; a shared
  // display does too, unless someone signed in to use the full app.
  if (display && loc == '/today' && (den.actor == null || !(device?.isShared ?? false))) return '/wall';
  if (loc == '/kid' && !isLittleKid(me) && !display) return '/today';
  return null;
}

/// Routes owned by family, devices, settings, onboarding, the wall display and the kids' apps.
final List<RouteBase> familyRoutes = [
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
  GoRoute(
    path: '/family',
    builder: (_, _) => const FamilyScreen(),
    routes: [
      GoRoute(
        path: 'devices/add',
        builder: (_, _) => const AddDeviceScreen(),
        routes: [
          GoRoute(path: 'hub', builder: (_, _) => const AddHubScreen()),
          GoRoute(path: 'browser', builder: (_, _) => const LinkBrowserScreen()),
        ],
      ),
      GoRoute(path: 'member/new', builder: (_, s) => MemberEditor(role: s.uri.queryParameters['role'])),
      GoRoute(path: 'member/:id', builder: (_, s) => MemberEditor(memberId: s.pathParameters['id'])),
      GoRoute(path: 'device/:id', builder: (_, s) => DeviceScreen(deviceId: s.pathParameters['id']!)),
    ],
  ),
  GoRoute(
    path: '/settings',
    builder: (_, _) => const SettingsScreen(),
    routes: [
      GoRoute(
        path: 'connections',
        builder: (_, _) => const ConnectionsScreen(),
        routes: [GoRoute(path: 'new', builder: (_, s) => CreateTokenScreen(label: s.uri.queryParameters['label']))],
      ),
      GoRoute(path: 'home-assistant', builder: (_, _) => const HomeAssistantScreen()),
      GoRoute(path: 'phone-calendars', builder: (_, _) => const PhoneCalendarsScreen()),
    ],
  ),
  // An invite's link; familyRedirect sends it on.
  GoRoute(path: '/join/:code', redirect: (_, _) => '/welcome/join'),
  GoRoute(path: '/wall', builder: (_, _) => const WallScreen()),
  GoRoute(path: '/kid', builder: (_, _) => const KidScreen()),
];
