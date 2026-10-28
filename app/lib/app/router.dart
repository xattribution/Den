import 'package:go_router/go_router.dart';

import '../features/add/routes.dart';
import '../features/advanced/routes.dart';
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
import 'redirect.dart';
import 'shell.dart';

/// The app's routes, composed from each feature's `routes.dart`: the four tabs in the shell,
/// and every other page over it. The redirect runs again only when who's who, this device or the
/// wall setting changes, never for an event or a chore.
GoRouter buildRouter(AppState state) => GoRouter(
      initialLocation: '/today',
      refreshListenable: state.watching({...Changes.people, Changes.prefs}),
      redirect: (context, route) => familyRedirect(state, route),
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/today'),
        StatefulShellRoute.indexedStack(
          builder: (context, routeState, shell) => AppShell(navigationShell: shell),
          branches: [todayBranch(), calendarBranch(), choresBranch(), listsBranch()],
        ),
        ...calendarRoutes,
        ...advancedRoutes,
        ...addRoutes,
        ...choreRoutes,
        ...listRoutes,
        ...rewardRoutes,
        ...onboardingRoutes,
        familyRoute(addDevice: advancedAddDeviceRoutes),
        settingsRoute(more: advancedSettingsRoutes),
        ...sharedScreenRoutes,
      ],
    );
