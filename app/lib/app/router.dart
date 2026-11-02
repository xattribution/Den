import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design/sheet_page.dart';
import '../features/add/routes.dart';
import '../features/advanced/routes.dart';
import '../features/assistant/routes.dart';
import '../features/calendar/routes.dart';
import '../features/chores/routes.dart';
import '../features/family/routes.dart';
import '../features/lists/routes.dart';
import '../features/onboarding/routes.dart';
import '../features/rewards/routes.dart';
import '../features/settings/routes.dart';
import '../features/shared_screens/routes.dart';
import '../features/today/routes.dart';
import 'app_state.dart';
import 'household.dart';
import 'log_scope.dart';
import 'redirect.dart';
import 'shell.dart';

/// The app's routes, composed from each feature's `routes.dart`: the four tabs in the shell,
/// and every other page over it. The redirect runs again only when who's who, this device, the
/// wall setting or the family it shows changes, never for an event or a chore.
///
/// On a device in several families, `/l/<log>/<page>` is any page below in that family
/// ([LogScope]): an event from "All my families", a reminder from the family the device isn't
/// showing. A page without the prefix is the family the device shows ([Household.active]).
GoRouter buildRouter(AppState state, {Household? household}) {
  final home = household ?? Household.single(state);
  // The pages a family's own: the same under `/l/<log>`.
  final pages = <RouteBase>[
    ...calendarRoutes,
    ...advancedRoutes,
    ...choreRoutes,
    ...listRoutes,
    ...rewardRoutes,
    familyRoute(addDevice: advancedAddDeviceRoutes),
    settingsRoute(more: advancedSettingsRoutes),
    // Add's review page, for Add in "All my families" adding to a family it doesn't show.
    ...addRoutes,
  ];
  return GoRouter(
    initialLocation: '/today',
    refreshListenable: _Routing(home),
    redirect: (context, route) => householdRedirect(home, route),
    routes: [
      GoRoute(path: '/', redirect: (_, _) => '/today'),
      StatefulShellRoute.indexedStack(
        builder: (context, routeState, shell) => AppShell(navigationShell: shell),
        branches: [todayBranch(), calendarBranch(), choresBranch(), listsBranch()],
      ),
      ...pages,
      // Ask, the wall and the kids' app are the family the device shows.
      ...assistantRoutes,
      ...onboardingRoutes,
      accessEndedRoute(),
      ...sharedScreenRoutes,
      ...familiesRoutes,
      GoRoute(
        path: '/l/:log',
        // `/l/<log>` alone, or with one of the app's places, goes to that family's place
        // (householdRedirect), so this route only holds the pages.
        redirect: (_, _) => null,
        routes: [for (final r in pages) _underLog(r, home, top: true)],
      ),
    ],
  );
}

/// [route] as it is under `/l/:log`: its path relative to it, each page in that family's scope
/// ([LogScope]) and each redirect kept in the family.
RouteBase _underLog(RouteBase route, Household home, {bool top = false}) {
  if (route is! GoRoute) return route;
  final builder = route.builder;
  final pageBuilder = route.pageBuilder;
  final redirect = route.redirect;
  return GoRoute(
    path: top && route.path.startsWith('/') ? route.path.substring(1) : route.path,
    name: route.name == null ? null : 'l.${route.name}',
    parentNavigatorKey: route.parentNavigatorKey,
    caseSensitive: route.caseSensitive,
    onExit: route.onExit,
    builder: builder == null ? null : (context, s) => _scoped(home, s, builder(context, s)),
    pageBuilder: pageBuilder == null ? null : (context, s) => _scopedPage(home, s, pageBuilder(context, s)),
    redirect: redirect == null
        ? null
        : (context, s) async {
            final to = await redirect(context, s);
            final log = s.pathParameters['log'];
            return to == null || log == null ? to : inLog(log, to);
          },
    routes: [for (final r in route.routes) _underLog(r, home)],
  );
}

Widget _scoped(Household home, GoRouterState s, Widget page) {
  final log = home.byId(s.pathParameters['log'] ?? '');
  // A family this device no longer holds: the page in the family it shows.
  return log == null ? page : LogScope(log: log, child: page);
}

/// [page] with its content in the family's scope: the kinds of page the family's routes build.
Page<Object?> _scopedPage(Household home, GoRouterState s, Page<Object?> page) {
  Widget wrap(Widget child) => _scoped(home, s, child);
  return switch (page) {
    final MaterialPage<Object?> p => MaterialPage<Object?>(
        key: p.key,
        name: p.name,
        arguments: p.arguments,
        restorationId: p.restorationId,
        maintainState: p.maintainState,
        fullscreenDialog: p.fullscreenDialog,
        allowSnapshotting: p.allowSnapshotting,
        child: wrap(p.child),
      ),
    final DenSheetPage<Object?> p => DenSheetPage<Object?>(
        key: p.key,
        name: p.name,
        dismissible: p.dismissible,
        closeLabel: p.closeLabel,
        theme: p.theme,
        child: wrap(p.child),
      ),
    _ => throw StateError('A page under /l/ must be a MaterialPage or a DenSheetPage: ${page.runtimeType}'),
  };
}

/// What makes the router's redirect run again: who's who or this device's settings in the
/// family the device shows, and which family that is.
class _Routing extends ChangeNotifier {
  _Routing(this.home) {
    home.addListener(_switched);
    _follow();
  }

  final Household home;
  ChangeNotifier? _watching;
  AppState? _state;

  void _switched() {
    if (!identical(home.active.state, _state)) _follow();
    notifyListeners();
  }

  void _follow() {
    _watching?.removeListener(notifyListeners);
    _watching?.dispose();
    _state = home.active.state;
    _watching = _state!.watching({...Changes.people, Changes.prefs})..addListener(notifyListeners);
  }

  @override
  void dispose() {
    home.removeListener(_switched);
    _watching?.removeListener(notifyListeners);
    _watching?.dispose();
    super.dispose();
  }
}
