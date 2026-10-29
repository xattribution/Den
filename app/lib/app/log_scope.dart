import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../design/sheet.dart' show SheetScope, SheetWrap;
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

/// The family a location is under (`/l/<log>/...`) and the rest of it, or null.
({String log, String rest})? splitLog(String location) {
  if (!location.startsWith('/l/')) return null;
  final after = location.substring(3);
  final slash = after.indexOf('/');
  final query = after.indexOf('?');
  final end = slash < 0 ? (query < 0 ? after.length : query) : slash;
  final log = Uri.decodeComponent(after.substring(0, end));
  var rest = after.substring(end);
  if (rest.isEmpty || rest.startsWith('?')) rest = '/today$rest';
  return (log: log, rest: rest);
}

/// [child] in the family [log]'s scope: its state ([DenScope]), its color pack, its pairing,
/// and a router that keeps pages it opens in the same family (`/event/E1` from here opens
/// `/l/<log>/event/E1`). Pages under `/l/<log>`, and each family's part of "All my families",
/// sit in one. The screens below it are the app's own, unchanged.
///
/// Sheets and dialogs opened below it carry it too ([SheetScope], [capture]): a sheet is a route
/// of its own over the app, and without this would act for the family the device shows.
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
    Widget scoped = DenScope(
      state: log.state,
      child: FamilyColors(child: SheetScope(wrap: (inner) => LogScope(log: log, child: inner), child: child)),
    );
    final pairing = log.pairing;
    if (pairing != null) scoped = PairingScope(service: pairing, child: scoped);
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      scoped = InheritedGoRouter(goRouter: ScopedRouter(router is ScopedRouter ? router.inner : router, log.id), child: scoped);
    }
    return scoped;
  }
}

/// The app's router as seen from inside one family's scope ([LogScope]): a page it pushes or
/// goes to opens in that family (`/l/<log>/...`); the app's places (the tabs) and everything
/// else are the app's router's own.
class ScopedRouter implements GoRouter {
  ScopedRouter(this.inner, this.log);

  /// The app's router.
  final GoRouter inner;

  /// The family pages open in.
  final String log;

  String _in(String location) => inLog(log, location);

  @override
  void go(String location, {Object? extra}) => inner.go(_in(location), extra: extra);

  @override
  Future<T?> push<T extends Object?>(String location, {Object? extra}) => inner.push<T>(_in(location), extra: extra);

  @override
  Future<T?> pushReplacement<T extends Object?>(String location, {Object? extra}) =>
      inner.pushReplacement<T>(_in(location), extra: extra);

  @override
  Future<T?> replace<T>(String location, {Object? extra}) => inner.replace<T>(_in(location), extra: extra);

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
