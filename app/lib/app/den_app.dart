export 'router.dart' show buildRouter;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'router.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'app_state.dart';
import '../platform/web/web_app.dart';
import '../platform/web/web_insets.dart';
import '../features/add/add.dart';

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
  StreamSubscription<String>? _taps;
  StreamSubscription<Object>? _shares;

  /// The theme and the wall setting: all that rebuilds the app itself.
  late final ChangeNotifier _prefs = widget.state.watching(const {Changes.prefs});

  @override
  void initState() {
    super.initState();
    // A tapped reminder opens its event or chore over whatever is showing.
    _taps = widget.state.reminders?.taps.listen((route) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _router.push(route));
      WidgetsBinding.instance.scheduleFrame();
    });
    // In a browser, a tapped notification from the hub opens its event, chore or Today.
    WebApp.listen((route) {
      if (!mounted || !route.startsWith('/')) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route == '/today') {
          _router.go(route);
        } else {
          _router.push(route);
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    });
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
    _taps?.cancel();
    _shares?.cancel();
    _prefs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DenScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: _prefs,
        builder: (context, _) {
          final scale = widget.state.wall ? DenType.wallScale : 1.0;
          return MaterialApp.router(
            title: 'Den',
            debugShowCheckedModeBanner: false,
            routerConfig: _router,
            builder: (context, child) => WebSafeArea(child: child),
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
