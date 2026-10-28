import 'package:go_router/go_router.dart';

import '../../app/side_panel.dart';
import 'screens/calendar_screen.dart';
import 'screens/event_detail.dart';
import 'screens/event_editor.dart';

int? _ms(String? value) => value == null ? null : int.tryParse(value);

/// The Calendar tab: `/calendar`, or `/calendar/:view/:date` for a view on a day.
StatefulShellBranch calendarBranch() => StatefulShellBranch(
      routes: [
        GoRoute(
          path: '/calendar',
          builder: (_, _) => const CalendarScreen(),
          routes: [
            GoRoute(
              path: ':view/:date',
              builder: (_, s) => CalendarScreen(
                view: CalendarView.values.firstWhere(
                  (v) => v.name == s.pathParameters['view'],
                  orElse: () => CalendarView.family,
                ),
                date: s.pathParameters['date'],
              ),
            ),
          ],
        ),
      ],
    );

/// Events, over whatever is showing (a side panel when wide):
///
/// - `/event/new?date=YYYY-MM-DD&time=HH:mm&who=<memberId>`: add an event
/// - `/event/:id?at=<occurrence start ms>`: an occurrence's detail
/// - `/event/:id/edit?at=<occurrence start ms>`: edit it
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
];
