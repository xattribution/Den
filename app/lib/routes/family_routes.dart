import 'package:go_router/go_router.dart';

import '../app.dart';
import '../state/app_state.dart';

/// Where the app sends someone before the main shell: onboarding when there's no family yet,
/// the wall display on shared devices, the kids' app for younger kids. Null means the shell.
String? familyRedirect(AppState state, GoRouterState route) {
  if (!state.den.hasFamily && !route.matchedLocation.startsWith('/welcome')) return '/welcome';
  return null;
}

/// Routes owned by family, devices, settings, onboarding, the wall display and the kids' apps.
final List<RouteBase> familyRoutes = [
  GoRoute(path: '/welcome', builder: (_, _) => const PendingScreen('Welcome')),
  GoRoute(path: '/family', builder: (_, _) => const PendingScreen('Family and devices')),
  GoRoute(path: '/settings', builder: (_, _) => const PendingScreen('Settings')),
];
