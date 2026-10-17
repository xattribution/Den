import 'package:go_router/go_router.dart';

import '../app.dart';

/// Routes owned by the calendar area: event detail and editor, history, search.
/// The calendar tab itself lives in the shell (screens/calendar/calendar_screen.dart).
final List<RouteBase> calendarRoutes = [
  GoRoute(path: '/event/:id', builder: (_, s) => PendingScreen('Event ${s.pathParameters['id']}')),
  GoRoute(path: '/history', builder: (_, _) => const PendingScreen('History')),
];
