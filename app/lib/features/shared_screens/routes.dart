import 'package:go_router/go_router.dart';

import 'screens/kid_screen.dart';
import 'screens/wall_screen.dart';

/// The wall display and the kids' app: `/wall`, `/kid`.
final List<RouteBase> sharedScreenRoutes = [
  GoRoute(path: '/wall', builder: (_, _) => const WallScreen()),
  GoRoute(path: '/kid', builder: (_, _) => const KidScreen()),
];
