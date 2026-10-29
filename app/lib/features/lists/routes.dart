import 'package:go_router/go_router.dart';

import 'screens/grocery_add.dart';
import 'screens/list_detail.dart';
import 'screens/list_editor.dart';
import 'screens/all_lists.dart';

/// The Lists tab: `/lists`.
StatefulShellBranch listsBranch() => StatefulShellBranch(
      routes: [GoRoute(path: '/lists', builder: (_, _) => const ListsTab())],
    );

/// A list: `/lists/new`, `/lists/groceries/add`, `/lists/:id`, `/lists/:id/edit`. Fixed paths
/// come before their `:id` siblings.
final List<RouteBase> listRoutes = [
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
];
