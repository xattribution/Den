import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../design/sheet.dart' show SheetScope, SheetWrap;
import '../features/add/state/capture_service.dart' show Capture, CaptureScope;
import '../platform/sync/pairing.dart';
import 'app_state.dart';
import 'family_colors.dart';
import 'household.dart';

/// The routes that are places in the app (the shell's tabs) or getting a device into a family:
/// they always mean the family the device shows, never one under `/l/<log>`.
bool isPlaceRoute(String path) {
  final p = path.split('?').first;
  bool under(String base) => p == base || p.startsWith('$base/');
  return p == '/' ||
      under('/today') ||
      under('/calendar') ||
      under('/chores') ||
      p == '/lists' ||
      under('/welcome') ||
      under('/join') ||
      under('/recover') ||
      under('/setup') ||
      under('/l') ||
      under('/families');
}

/// [location] for the family [log]: `/l/<log>/event/E1` for `/event/E1`. A place (a tab) or a
/// location already under a family stays as it is.
String inLog(String log, String location) {
  if (!location.startsWith('/') || isPlaceRoute(location)) return location;
  return '/l/${Uri.encodeComponent(log)}$location';
}

/// The family a location is under (`/l/<log>/...`) and the rest of it, or null. A family part
/// that doesn't decode (a stray `%`) is kept as it is, which names no family.
({String log, String rest})? splitLog(String location) {
  if (!location.startsWith('/l/')) return null;
  final after = location.substring(3);
  final slash = after.indexOf('/');
  final query = after.indexOf('?');
  final end = slash < 0 ? (query < 0 ? after.length : query) : slash;
  final raw = after.substring(0, end);
  String log;
  try {
    log = Uri.decodeComponent(raw);
  } on Object {
    log = raw;
  }
  var rest = after.substring(end);
  if (rest.isEmpty || rest.startsWith('?')) rest = '/today$rest';
  return (log: log, rest: rest);
}

/// [location] when the app can open it; for one whose escapes don't decode (which the router
/// can't match), "That family isn't on this device" for a family's link, Today otherwise. For
/// routes from outside the app's own navigation: a tapped reminder or push.
String openable(String location) {
  try {
    for (final segment in location.split('?').first.split('/')) {
      Uri.decodeComponent(segment);
    }
    return location;
  } on Object {
    return location.startsWith('/l/') ? '/families/missing' : '/today';
  }
}

/// [child] in the family [log]'s scope: its state ([DenScope]), its color pack, its pairing,
/// and a router that keeps pages it opens in the same family (`/event/E1` from here opens
/// `/l/<log>/event/E1`). Pages under `/l/<log>`, and each family's part of "All my families",
/// sit in one. The screens below it are the app's own, unchanged.
///
/// Sheets and dialogs opened below it carry it too ([SheetScope], [capture]): a sheet is a route
/// of its own over the app, and without this would act for the family the device shows. So does
/// everything below it that reaches a hub: its pairing (or none, never the family shown's) and
/// Add's reader ([CaptureScope], through this family's own hub).
class LogScope extends StatelessWidget {
  const LogScope({super.key, required this.log, required this.child});

  final FamilyLog log;
  final Widget child;

  /// The family scope [context] is in, to carry into something shown over the app from there
  /// (a sheet, a dialog, a page opened from a context that outlived it); null in the family the
  /// device shows, whose scope is the app's own.
  static SheetWrap? capture(BuildContext context) => SheetScope.of(context);

  @override
  Widget build(BuildContext context) {
    final home = Household.maybeOf(context);
    Widget scoped = DenScope(
      state: log.state,
      child: FamilyColors(child: SheetScope(wrap: (inner) => LogScope(log: log, child: inner), child: child)),
    );
    scoped = CaptureScope(service: Capture.forFamily(Capture.of(context), den: log.den, network: log.network), child: scoped);
    final pairing = log.pairing;
    if (pairing != null) {
      scoped = PairingScope(service: pairing, child: scoped);
    } else if (home != null && !identical(home.active, log)) {
      // Without a connection of its own, nothing: never the pairing of the family shown.
      scoped = PairingScope(service: const LocalOnlyPairing(), child: scoped);
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      scoped = InheritedGoRouter(
        goRouter: ScopedRouter(
          router is ScopedRouter ? router.inner : router,
          log.id,
          show: home == null
              ? null
              : () async {
                  if (!identical(home.active, log)) await home.choose(log);
                },
        ),
        child: scoped,
      );
    }
    return scoped;
  }
}

/// The app's router as seen from inside one family's scope ([LogScope]): a page of a family's
/// own it pushes or goes to opens in that family (`/l/<log>/...`); the app's places (the tabs)
/// are the app's own; and a page that is always the family the device shows (Ask, the kids'
/// app, the wall) opens once [show] has made this family the one shown.
class ScopedRouter implements GoRouter {
  ScopedRouter(this.inner, this.log, {this.show});

  /// The app's router.
  final GoRouter inner;

  /// The family pages open in.
  final String log;

  /// Shows this family, for a page that is always the family the device shows.
  final Future<void> Function()? show;

  /// Where [location] opens from this family, and whether this family is shown first.
  ({String to, bool showFirst}) _where(String location) {
    if (!location.startsWith('/') || isPlaceRoute(location)) return (to: location, showFirst: false);
    final scoped = inLog(log, location);
    if (_matches(scoped)) return (to: scoped, showFirst: false);
    return (to: location, showFirst: show != null);
  }

  bool _matches(String location) {
    try {
      return inner.configuration.findMatch(Uri.parse(location)).isNotEmpty;
    } on Object {
      return false;
    }
  }

  Future<T> _then<T>(({String to, bool showFirst}) where, Future<T> Function(String to) open) async {
    if (where.showFirst) await show!();
    return open(where.to);
  }

  @override
  void go(String location, {Object? extra}) {
    final where = _where(location);
    if (!where.showFirst) return inner.go(where.to, extra: extra);
    unawaited(_then(where, (to) async => inner.go(to, extra: extra)));
  }

  @override
  Future<T?> push<T extends Object?>(String location, {Object? extra}) =>
      _then(_where(location), (to) => inner.push<T>(to, extra: extra));

  @override
  Future<T?> pushReplacement<T extends Object?>(String location, {Object? extra}) =>
      _then(_where(location), (to) => inner.pushReplacement<T>(to, extra: extra));

  @override
  Future<T?> replace<T>(String location, {Object? extra}) => _then(_where(location), (to) => inner.replace<T>(to, extra: extra));

  @override
  bool canPop() => inner.canPop();

  @override
  void pop<T extends Object?>([T? result]) => inner.pop<T>(result);

  @override
  void refresh() => inner.refresh();

  @override
  void restore(RouteMatchList matchList) => inner.restore(matchList);

  @override
  String namedLocation(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    String? fragment,
  }) =>
      inner.namedLocation(name, pathParameters: pathParameters, queryParameters: queryParameters, fragment: fragment);

  @override
  void goNamed(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
    String? fragment,
  }) =>
      inner.goNamed(name, pathParameters: pathParameters, queryParameters: queryParameters, extra: extra, fragment: fragment);

  @override
  Future<T?> pushNamed<T extends Object?>(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
  }) =>
      inner.pushNamed<T>(name, pathParameters: pathParameters, queryParameters: queryParameters, extra: extra);

  @override
  Future<T?> pushReplacementNamed<T extends Object?>(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
  }) =>
      inner.pushReplacementNamed<T>(name, pathParameters: pathParameters, queryParameters: queryParameters, extra: extra);

  @override
  Future<T?> replaceNamed<T>(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
  }) =>
      inner.replaceNamed<T>(name, pathParameters: pathParameters, queryParameters: queryParameters, extra: extra);

  @override
  GoRouterState get state => inner.state;

  @override
  RouteConfiguration get configuration => inner.configuration;

  @override
  GoRouterDelegate get routerDelegate => inner.routerDelegate;

  @override
  GoRouteInformationProvider get routeInformationProvider => inner.routeInformationProvider;

  @override
  GoRouteInformationParser get routeInformationParser => inner.routeInformationParser;

  @override
  BackButtonDispatcher get backButtonDispatcher => inner.backButtonDispatcher;

  @override
  List<NavigatorObserver>? get observers => inner.observers;

  @override
  bool get overridePlatformDefaultLocation => inner.overridePlatformDefaultLocation;

  @override
  void dispose() {}

  // Anything else a router has goes to the app's own.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ScopedRouter: ${invocation.memberName} is the app router\'s; use GoRouter.of on the app');
}
