import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'design/theme.dart';
import 'design/tokens.dart';
import 'screens/calendar/calendar_screen.dart';
import 'screens/today/today_screen.dart';
import 'shell/shell.dart';
import 'state/app_state.dart';

/// Screens still being built register here so routes resolve while the app comes together.
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
      redirect: (context, route) {
        if (!state.den.hasFamily && !route.matchedLocation.startsWith('/welcome')) return '/welcome';
        return null;
      },
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/today'),
        GoRoute(path: '/welcome', builder: (_, _) => const PendingScreen('Welcome')),
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
            StatefulShellBranch(routes: [GoRoute(path: '/chores', builder: (_, _) => const PendingScreen('Chores'))]),
            StatefulShellBranch(routes: [GoRoute(path: '/lists', builder: (_, _) => const PendingScreen('Lists'))]),
          ],
        ),
        GoRoute(path: '/lists/:id', builder: (_, s) => PendingScreen('List ${s.pathParameters['id']}')),
        GoRoute(path: '/event/:id', builder: (_, s) => PendingScreen('Event ${s.pathParameters['id']}')),
        GoRoute(path: '/chore/:id', builder: (_, s) => PendingScreen('Chore ${s.pathParameters['id']}')),
        GoRoute(path: '/points', builder: (_, _) => const PendingScreen('Points and rewards')),
        GoRoute(path: '/family', builder: (_, _) => const PendingScreen('Family and devices')),
        GoRoute(path: '/history', builder: (_, _) => const PendingScreen('History')),
        GoRoute(path: '/settings', builder: (_, _) => const PendingScreen('Settings')),
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
