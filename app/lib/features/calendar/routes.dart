import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design/layout.dart';
import '../../design/sheet_page.dart';
import 'screens/calendar_screen.dart';
import 'screens/event_detail.dart';
import 'screens/event_editor.dart';

int? _ms(String? value) => value == null ? null : int.tryParse(value);

CalendarView? _view(String? name) => CalendarView.values.asNameMap()[name];

/// The Calendar tab: `/calendar?view=month&date=2026-10-28` (both optional; the view defaults to
/// the list on a phone and the family week with room for it). The older `/calendar/:view/:date`
/// links land on the same thing.
StatefulShellBranch calendarBranch() => StatefulShellBranch(
      routes: [
        GoRoute(
          path: '/calendar',
          builder: (_, s) => CalendarScreen(
            view: _view(s.uri.queryParameters['view']),
            date: s.uri.queryParameters['date'],
          ),
          routes: [
            GoRoute(
              path: ':view/:date',
              redirect: (_, s) => CalendarScreen.location(_view(s.pathParameters['view']), s.pathParameters['date']),
            ),
          ],
        ),
      ],
    );

/// Whether the window has room for sheets in the middle of the screen (iPad).
bool _wide(BuildContext context) => DenLayout.of(context).centersSheets;

/// Events, over whatever is showing:
///
/// - `/event/new?date=YYYY-MM-DD&time=HH:mm&who=<memberId>`: add an event, in a sheet
/// - `/event/:id?at=<occurrence start ms>&from=calendar`: an occurrence, to look at and change
///   in place; a page on phones, a form sheet on iPad
/// - `/event/:id/edit?at=`: the same, as older links name it
final List<RouteBase> calendarRoutes = [
  GoRoute(
    path: '/event/new',
    pageBuilder: (context, s) => DenSheetPage<void>(
      key: s.pageKey,
      child: EventEditorScreen(
        date: s.uri.queryParameters['date'],
        time: s.uri.queryParameters['time'],
        who: s.uri.queryParameters['who'],
      ),
    ),
  ),
  GoRoute(
    path: '/event/:id/edit',
    redirect: (_, s) => Uri(
      path: '/event/${s.pathParameters['id']}',
      queryParameters: {'at': ?s.uri.queryParameters['at']},
    ).toString(),
  ),
  GoRoute(
    path: '/event/:id',
    pageBuilder: (context, s) {
      final id = s.pathParameters['id']!;
      final at = _ms(s.uri.queryParameters['at']);
      final from = s.uri.queryParameters['from'];
      if (_wide(context)) {
        return DenSheetPage<void>(key: s.pageKey, child: EventDetailScreen(eventId: id, at: at, from: from, inSheet: true));
      }
      return MaterialPage<void>(key: s.pageKey, child: EventDetailScreen(eventId: id, at: at, from: from));
    },
  ),
];
