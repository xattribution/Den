import 'package:den_capture/den_capture.dart' show CaptureInput;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../capture/capture_service.dart' show CaptureProblem;
import '../screens/capture/capture_screen.dart';
import '../screens/chores/chore_detail.dart';
import '../screens/chores/chore_editor.dart';
import '../screens/chores/chores_board.dart';
import '../screens/lists/grocery_add.dart';
import '../screens/lists/list_detail.dart';
import '../screens/lists/list_editor.dart';
import '../screens/lists/lists_index.dart';
import '../screens/points/adjust_screen.dart';
import '../screens/points/goal_editor.dart';
import '../screens/points/points_screen.dart';
import '../screens/points/reward_editor.dart';

/// The Chores tab's root screen. The day lives in the URL: `/chores?date=2026-10-17`.
Widget choresTab() => const ChoresTab();

/// The Lists tab's root screen.
Widget listsTab() => const ListsIndex();

/// Routes owned by chores, lists and points. Fixed paths come before their `:id` siblings.
final List<RouteBase> homeRoutes = [
  GoRoute(
    path: '/capture',
    builder: (_, s) => CaptureRoute(
      input: s.extra is CaptureInput ? s.extra! as CaptureInput : null,
      problem: s.extra is CaptureProblem ? (s.extra! as CaptureProblem).message : null,
    ),
  ),
  GoRoute(path: '/chore/new', builder: (_, _) => const ChoreEditorScreen()),
  GoRoute(
    path: '/chore/:id/edit',
    builder: (_, s) => ChoreEditorScreen(id: s.pathParameters['id']),
  ),
  GoRoute(
    path: '/chore/:id',
    builder: (_, s) => ChoreDetailScreen(id: s.pathParameters['id']!, date: s.uri.queryParameters['date']),
  ),
  GoRoute(path: '/lists/new', builder: (_, _) => const ListEditorScreen()),
  GoRoute(path: '/lists/groceries/add', builder: (_, _) => const GroceryAddScreen()),
  GoRoute(
    path: '/lists/:id/edit',
    builder: (_, s) => ListEditorScreen(id: s.pathParameters['id']),
  ),
  GoRoute(
    path: '/lists/:id',
    builder: (_, s) => ListDetailScreen(id: s.pathParameters['id']!),
  ),
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
