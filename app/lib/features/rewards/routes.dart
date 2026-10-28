import 'package:go_router/go_router.dart';

import 'screens/adjust_screen.dart';
import 'screens/goal_editor.dart';
import 'screens/points_screen.dart';
import 'screens/reward_editor.dart';

/// Points, goals and rewards: `/points`, `/points/adjust?member=&back=1`, `/points/goal/new`,
/// `/points/goal/:id`, `/points/reward/new`, `/points/reward/:id`.
final List<RouteBase> rewardRoutes = [
  GoRoute(path: '/points', builder: (_, _) => const PointsScreen()),
  GoRoute(
    path: '/points/adjust',
    builder: (_, s) =>
        AdjustScreen(member: s.uri.queryParameters['member'], returnsToPoints: s.uri.queryParameters['back'] == '1'),
  ),
  GoRoute(path: '/points/goal/new', builder: (_, _) => const GoalEditorScreen()),
  GoRoute(
    path: '/points/goal/:id',
    builder: (_, s) => GoalEditorScreen(id: s.pathParameters['id']),
  ),
  GoRoute(path: '/points/reward/new', builder: (_, _) => const RewardEditorScreen()),
  GoRoute(
    path: '/points/reward/:id',
    builder: (_, s) => RewardEditorScreen(id: s.pathParameters['id']),
  ),
];
