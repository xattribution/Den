import 'dart:async';

import 'package:go_router/go_router.dart';

import '../features/family/family.dart' show accessEndedHere;
import '../features/shared_screens/shared_screens.dart';
import '../platform/capabilities.dart';
import '../platform/web/handoff.dart';
import '../platform/web/web_app.dart';
import 'app_state.dart';
import 'household.dart';
import 'log_scope.dart';

/// The adult shell's four tabs.
bool _isShellTab(String loc) =>
    loc == '/today' || loc == '/chores' || loc == '/lists' || loc == '/calendar' || loc.startsWith('/calendar/');

/// Where the app sends someone, on a device that may hold several families ([home]):
///
/// - `/l/<log>/<page>` is that family's page, in its scope; `/l/<log>` alone, or with one of the
///   app's places (`/l/<log>/today`), shows that family and goes to the place. That family's own
///   gates come first, as [familyRedirect] applies them to the family the device shows: still
///   waiting for a parent, or a sitter's access ended, shows that family on its own screen; a
///   little kid's family or a wall display goes to the kids' app or the wall instead of a tab.
/// - A family this device doesn't hold, or whose engine didn't open, gets a page that says so
///   (`/families/missing`), never another family's page.
/// - `/families/...` (joining another family) is for a device already in one.
/// - Everything else is [familyRedirect] for the family the device shows.
String? householdRedirect(Household home, GoRouterState route) {
  final split = splitLog(route.uri.toString());
  if (split != null) {
    final log = home.byId(split.log);
    if (log == null) {
      final closed = home.unopened.any((m) => m.id == split.log.toLowerCase());
      return closed ? '/families/missing?closed=1' : '/families/missing';
    }
    final place = isPlaceRoute(split.rest);
    final gate = !log.den.isApproved
        ? '/welcome/waiting'
        : accessEndedHere(log.state)
            ? '/ended'
            : place
                ? _shellGate(log.state, split.rest.split('?').first)
                : null;
    if (gate != null || place) {
      if (!identical(log, home.active) || home.showingAll) scheduleMicrotask(() => home.choose(log));
      return gate ?? split.rest;
    }
    return null;
  }
  final state = home.active.state;
  if (route.uri.path.startsWith('/families/') && !state.den.isApproved) return '/welcome';
  return familyRedirect(state, route);
}

/// Where the app sends someone before the main shell. Null means stay.
///
/// 0. An invite's link (`/join/<words>`): joining with its words, or, on a device already in a
///    family, joining that family beside it (`/families/join`). A fresh hub's setup link
///    (`/setup/<code>/<hub>`): starting the family with that hub. A recovery link from whoever
///    runs the hub (`/recover/<words>`): "I lost my phone" with its words, unless this device is
///    already in. A Home Screen app with no family yet first takes the link Safari kept for it
///    ([Handoff]).
/// 1. No family on this device: onboarding (`/welcome`). A sitter's device past their last day:
///    that their access ended (`/ended`).
/// 2. A join request sent but not approved yet: the waiting screen, whatever was asked for.
/// 3. Right after creating a family: the short "Add people" step (recovery words wait in Needs
///    you); any other onboarding route once the device is in the family goes to Today.
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

  var path = route.uri.path;
  // The invite or setup link Safari kept for the Home Screen app, on its first start.
  if (!den.hasFamily && Capabilities.web) {
    final kept = Handoff.take(standalone: WebApp.info.standalone);
    if (kept != null) path = kept;
  }
  if (path.startsWith('/join/')) {
    final words = path.substring('/join/'.length);
    // A device in a family already joins another one beside it.
    if (den.isApproved) return Uri(path: '/families/join', queryParameters: {'code': words}).toString();
    if (den.hasFamily) return '/today';
    return Uri(path: '/welcome/join', queryParameters: {'code': words}).toString();
  }

  if (path.startsWith('/setup/')) {
    if (den.hasFamily) return '/today';
    final parts = path.substring('/setup/'.length).split('/');
    return Uri(path: '/welcome/start', queryParameters: {'setup': parts.first, if (parts.length > 1) 'hub': parts[1]}).toString();
  }

  if (path.startsWith('/recover/')) {
    if (den.isApproved) return '/today';
    final words = path.substring('/recover/'.length);
    return Uri(path: '/welcome/recover', queryParameters: {'code': words}).toString();
  }

  if (!den.hasFamily) return inWelcome ? null : '/welcome';
  // A sitter past their last day, removed or not yet: their access ended.
  if (accessEndedHere(state)) return loc == '/ended' ? null : '/ended';
  if (loc == '/ended') return '/today';
  // A device still waiting may get back in with recovery words instead.
  if (!den.isApproved) return loc == '/welcome/waiting' || loc == '/welcome/recover' ? null : '/welcome/waiting';
  // Right after starting a family: Add people. The recovery words wait in Needs you.
  if (loc == '/welcome/start') return '/welcome/people';
  if (inWelcome && loc != '/welcome/people' && loc != '/welcome/words') return '/today';

  final gate = _shellGate(state, loc);
  if (gate != null) return gate;
  if (loc == '/kid' && !isLittleKid(state.me) && !_display(state)) return '/today';
  return null;
}

/// Whether this device is a display in [state]'s family: set to "Use as wall display", or a
/// shared one.
bool _display(AppState state) => state.wall || (state.den.thisDevice?.isShared ?? false);

/// Where a tab at [loc] goes instead in [state]'s family: the kids' app for a pre-reader or
/// little kid acting on this device; the wall for Today on a display, unless someone signed in
/// on a shared one to use the full app. Null: the tab itself.
String? _shellGate(AppState state, String loc) {
  final den = state.den;
  final device = den.thisDevice;
  if (isLittleKid(state.me) && _isShellTab(loc)) return '/kid';
  // A personal device set to "Use as wall display" always shows the wall for Today; a shared
  // display does too, unless someone signed in to use the full app.
  if (_display(state) && loc == '/today' && (den.actor == null || !(device?.isShared ?? false))) return '/wall';
  return null;
}

/// Whether [state]'s family shows the app's tabs on this device now, by the same rules as
/// [familyRedirect]: in it and let in, the person's access not ended, not a little kid's, and
/// not a wall display. "All my families" merges only these ([mergedFamilies]).
bool showsTabs(AppState state) =>
    state.den.isApproved && !accessEndedHere(state) && _shellGate(state, '/today') == null && _shellGate(state, '/lists') == null;

/// The families "All my families" merges: each one [showsTabs] for on this device now.
List<FamilyLog> mergedFamilies(Household home) => [for (final l in home.families) if (showsTabs(l.state)) l];
