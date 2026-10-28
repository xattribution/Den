import 'package:go_router/go_router.dart';

import 'screens/chore_detail.dart';
import 'screens/chore_editor.dart';
import 'screens/chores_board.dart';

/// The Chores tab. The day lives in the URL: `/chores?date=2026-10-17`.
StatefulShellBranch choresBranch() => StatefulShellBranch(
      routes: [GoRoute(path: '/chores', builder: (_, _) => const ChoresTab())],
    );

/// A chore: `/chore/new`, `/chore/:id?date=`, `/chore/:id/edit`. Fixed paths come before their
/// `:id` siblings.
final List<RouteBase> choreRoutes = [
  GoRoute(path: '/chore/new', builder: (_, _) => const ChoreEditorScreen()),
  GoRoute(
    path: '/chore/:id/edit',
    builder: (_, s) => ChoreEditorScreen(id: s.pathParameters['id']),
  ),
  GoRoute(
    path: '/chore/:id',
    builder: (_, s) => ChoreDetailScreen(id: s.pathParameters['id']!, date: s.uri.queryParameters['date']),
  ),
];
