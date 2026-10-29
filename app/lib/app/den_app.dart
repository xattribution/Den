export 'router.dart' show buildRouter;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'router.dart';
import '../design/layout.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'app_state.dart';
import 'family_colors.dart';
import 'household.dart';
import 'log_scope.dart';
import '../platform/capabilities.dart';
import '../platform/sync/pairing.dart';
import '../platform/web/web_app.dart';
import '../platform/web/web_insets.dart';
import '../features/add/add.dart';

/// The root widget: theme from tokens (day, night, or following the system) in the family's
/// colors, the system's text size times the person's own (held to 200 %), larger type on a wall
/// display.
///
/// It shows the [household]'s family ([Household.active]): every screen reads that family's
/// state through [DenScope], and switching families swaps it in place. A device in one family
/// (or [state] alone) has a household of one.
class DenApp extends StatefulWidget {
  DenApp({super.key, AppState? state, Household? household})
      : assert(state != null || household != null),
        household = household ?? Household.single(state!);

  final Household household;

  @override
  State<DenApp> createState() => _DenAppState();
}

class _DenAppState extends State<DenApp> {
  Household get _home => widget.household;
  late final GoRouter _router = buildRouter(_home.active.state, household: _home);
  StreamSubscription<String>? _taps;
  StreamSubscription<Object>? _shares;

  /// The theme, the text size and the wall setting, the same for every family on the device:
  /// all that rebuilds the app itself.
  late final DevicePrefs _prefs = _home.active.state.device;

  /// Opens [route] from a tapped reminder or notification: a page over whatever is showing, in
  /// its own family (`/l/<log>/...`); one of the app's places (Today) by going there.
  void _open(String route) {
    final place = isPlaceRoute(splitLog(route)?.rest ?? route);
    if (place) {
      _router.go(route);
    } else {
      _router.push(route);
    }
  }

  /// What the service worker was told last: the families this browser holds, by id.
  String? _told;

  /// In a browser, tells the service worker which families this Den holds and their names: it
  /// titles a family's push with the name kept here, and shows nothing of one from any other.
  void _tellWorker() {
    final families = {for (final l in _home.families) l.id: l.name};
    final told = families.entries.map((e) => '${e.key}=${e.value}').join('\n');
    if (told == _told) return;
    _told = told;
    unawaited(WebApp.setFamilies(families));
  }

  @override
  void initState() {
    super.initState();
    if (Capabilities.web) {
      _home.addListener(_tellWorker);
      _tellWorker();
    }
    // A tapped reminder opens its event or chore over whatever is showing.
    _taps = _home.active.state.reminders?.taps.listen((route) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(route));
      WidgetsBinding.instance.scheduleFrame();
    });
    // In a browser, a tapped notification from the hub opens its event, chore or Today.
    WebApp.listen((route) {
      if (!mounted || !route.startsWith('/')) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(route));
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
    _home.removeListener(_tellWorker);
    _taps?.cancel();
    _shares?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HouseholdScope(
      household: _home,
      child: ListenableBuilder(
        listenable: _home,
        builder: (context, child) {
          final log = _home.active;
          final pairing = log.pairing;
          final scoped = DenScope(state: log.state, child: child!);
          return pairing == null ? scoped : PairingScope(service: pairing, child: scoped);
        },
        child: ListenableBuilder(
          listenable: _prefs,
          builder: (context, _) {
          final scale = _prefs.wall ? DenType.wallScale : 1.0;
          return MaterialApp.router(
            title: 'Den',
            debugShowCheckedModeBanner: false,
            routerConfig: _router,
            builder: (context, child) =>
                FamilyColors(child: DenTextScale(size: _prefs.textSize, child: WebSafeArea(child: child))),
            theme: denTheme(DenColors.day, typeScale: scale),
            darkTheme: denTheme(DenColors.night, typeScale: scale),
            themeMode: switch (_prefs.theme) {
              ThemeChoice.auto => ThemeMode.system,
              ThemeChoice.day => ThemeMode.light,
              ThemeChoice.night => ThemeMode.dark,
            },
          );
          },
        ),
      ),
    );
  }
}
