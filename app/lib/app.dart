import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'capture/capture_service.dart';
import 'design/theme.dart';
import 'design/tokens.dart';
import 'routes/calendar_routes.dart';
import 'routes/family_routes.dart';
import 'routes/home_routes.dart';
import 'screens/calendar/calendar_screen.dart';
import 'screens/today/today_screen.dart';
import 'shell/shell.dart';
import 'state/app_state.dart';

/// A route whose screen hasn't been built yet. Every use is replaced before release.
class PendingScreen extends StatelessWidget {
  const PendingScreen(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const SizedBox.shrink(),
      );
}

GoRouter buildRouter(AppState state) => GoRouter(
      initialLocation: '/today',
      refreshListenable: state,
      redirect: (context, route) => familyRedirect(state, route),
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/today'),
        StatefulShellRoute.indexedStack(
          builder: (context, routeState, shell) => AppShell(navigationShell: shell),
          branches: [
            StatefulShellBranch(routes: [GoRoute(path: '/today', builder: (_, _) => const TodayScreen())]),
            StatefulShellBranch(routes: [
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
            ]),
            StatefulShellBranch(routes: [GoRoute(path: '/chores', builder: (_, _) => choresTab())]),
            StatefulShellBranch(routes: [GoRoute(path: '/lists', builder: (_, _) => listsTab())]),
          ],
        ),
        ...calendarRoutes,
        ...homeRoutes,
        ...familyRoutes,
      ],
    );

/// The root widget: theme from tokens (day, night, or following the system), larger type on a
/// wall display.
class DenApp extends StatefulWidget {
  const DenApp({super.key, required this.state});
  final AppState state;

  @override
  State<DenApp> createState() => _DenAppState();
}

class _DenAppState extends State<DenApp> {
  late final GoRouter _router = buildRouter(widget.state);
  StreamSubscription<Object>? _shares;

  @override
  void initState() {
    super.initState();
    // Something shared from another app opens straight on what Den found in it.
    _shares = Capture.inbox.stream.listen((input) => _router.push('/capture', extra: input));
    if (Capture.waiting.isNotEmpty) {
      final early = [...Capture.waiting];
      Capture.waiting.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final input in early) {
          _router.push('/capture', extra: input);
        }
      });
    }
  }

  @override
  void dispose() {
    _shares?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DenScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final scale = widget.state.wall ? DenType.wallScale : 1.0;
          return MaterialApp.router(
            title: 'Den',
            debugShowCheckedModeBanner: false,
            routerConfig: _router,
            theme: denTheme(DenColors.day, typeScale: scale),
            darkTheme: denTheme(DenColors.night, typeScale: scale),
            themeMode: switch (widget.state.theme) {
              ThemeChoice.auto => ThemeMode.system,
              ThemeChoice.day => ThemeMode.light,
              ThemeChoice.night => ThemeMode.dark,
            },
          );
        },
      ),
    );
  }
}
