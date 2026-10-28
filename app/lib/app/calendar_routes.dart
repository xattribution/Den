import 'package:go_router/go_router.dart';

import 'side_panel.dart';
import '../features/calendar/screens/event_detail.dart';
import '../features/calendar/screens/event_editor.dart';
import '../features/advanced/screens/history_screen.dart';
import '../features/advanced/screens/search_screen.dart';

int? _ms(String? value) => value == null ? null : int.tryParse(value);

/// Routes owned by the calendar area: event detail and editor, history, search.
/// The calendar tab itself lives in the shell (screens/calendar/calendar_screen.dart).
///
/// - `/event/new?date=YYYY-MM-DD&time=HH:mm&who=<memberId>`: add an event
/// - `/event/:id?at=<occurrence start ms>`: an occurrence's detail (a side panel when wide)
/// - `/event/:id/edit?at=<occurrence start ms>`: edit it
/// - `/history?q=`: what changed
/// - `/search?q=`: find an event, chore, list or item
final List<RouteBase> calendarRoutes = [
  GoRoute(
    path: '/event/new',
    pageBuilder: (context, s) => calendarPanelPage(
      context,
      s,
      EventEditorScreen(
        date: s.uri.queryParameters['date'],
        time: s.uri.queryParameters['time'],
        who: s.uri.queryParameters['who'],
      ),
      width: 520,
    ),
  ),
  GoRoute(
    path: '/event/:id/edit',
    pageBuilder: (context, s) => calendarPanelPage(
      context,
      s,
      EventEditorScreen(eventId: s.pathParameters['id'], at: _ms(s.uri.queryParameters['at'])),
      width: 520,
    ),
  ),
  GoRoute(
    path: '/event/:id',
    pageBuilder: (context, s) => calendarPanelPage(
      context,
      s,
      EventDetailScreen(eventId: s.pathParameters['id']!, at: _ms(s.uri.queryParameters['at'])),
    ),
  ),
  GoRoute(path: '/history', builder: (_, s) => HistoryScreen(query: s.uri.queryParameters['q'])),
  GoRoute(path: '/search', builder: (_, s) => SearchScreen(query: s.uri.queryParameters['q'])),
];
