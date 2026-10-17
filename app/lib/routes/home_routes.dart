import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';

/// The Chores tab's root screen.
Widget choresTab() => const PendingScreen('Chores');

/// The Lists tab's root screen.
Widget listsTab() => const PendingScreen('Lists');

/// Routes owned by chores, lists and points.
final List<RouteBase> homeRoutes = [
  GoRoute(path: '/chore/:id', builder: (_, s) => PendingScreen('Chore ${s.pathParameters['id']}')),
  GoRoute(path: '/lists/:id', builder: (_, s) => PendingScreen('List ${s.pathParameters['id']}')),
  GoRoute(path: '/points', builder: (_, _) => const PendingScreen('Points and rewards')),
];
