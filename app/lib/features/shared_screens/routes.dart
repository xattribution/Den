import 'package:go_router/go_router.dart';

import 'screens/kid_screen.dart';
import 'screens/wall_screen.dart';

/// The wall display and the kids' screen: `/wall`, `/kid`, and `/kid/:member` for a phone a
/// parent handed to a kid (only the parent's PIN hands it back).
final List<RouteBase> sharedScreenRoutes = [
  GoRoute(path: '/wall', builder: (_, _) => const WallScreen()),
  GoRoute(
    path: '/kid',
    builder: (_, _) => const KidScreen(),
    routes: [GoRoute(path: ':member', builder: (_, s) => KidScreen(memberId: s.pathParameters['member'], handed: true))],
  ),
];
