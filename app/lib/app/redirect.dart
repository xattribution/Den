import 'package:go_router/go_router.dart';

import '../features/shared_screens/shared_screens.dart';
import 'app_state.dart';

/// The adult shell's four tabs.
bool _isShellTab(String loc) =>
    loc == '/today' || loc == '/chores' || loc == '/lists' || loc == '/calendar' || loc.startsWith('/calendar/');

/// Where the app sends someone before the main shell. Null means stay.
///
/// 0. An invite's link (`/join/<words>`): joining with its words, or Today for a device that is
///    already in a family. A recovery link from whoever runs the hub (`/recover/<words>`):
///    "I lost my phone" with its words, unless this device is already in.
/// 1. No family on this device: onboarding (`/welcome`).
/// 2. A join request sent but not approved yet: the waiting screen, whatever was asked for.
/// 3. Right after creating a family: the founder's recovery words, then the short "Add people"
///    step; any other onboarding route once the device is in the family goes to Today.
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

  if (path.startsWith('/recover/')) {
    if (den.isApproved) return '/today';
    final words = path.substring('/recover/'.length);
    return Uri(path: '/welcome/recover', queryParameters: {'code': words}).toString();
  }

  if (!den.hasFamily) return inWelcome ? null : '/welcome';
  // A device still waiting may get back in with recovery words instead.
  if (!den.isApproved) return loc == '/welcome/waiting' || loc == '/welcome/recover' ? null : '/welcome/waiting';
  // Right after starting a family: the founder's recovery words, then Add people.
  if (loc == '/welcome/start') return '/welcome/words';
  if (inWelcome && loc != '/welcome/people' && loc != '/welcome/words') return '/today';

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
