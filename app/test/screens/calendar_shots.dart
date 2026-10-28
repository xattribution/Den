import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/shots.dart';

/// A tall phone, for reviewing a whole form or detail at once.
const Size tallPhone = Size(390, 2000);

/// The iPad in landscape (the canvas's boards), and the room the calendar gets beside the
/// 248 pt sidebar there.
const Size pad = Size(1180, 820);
const Size padContent = Size(932, 820);

/// Renders the whole app at [location] (pushed over [base] when given, so sheets and pages show
/// what's behind them) and compares it with `test/goldens/<name>.png`. [text] is the system
/// text size (2 for 200 %).
Future<void> shootAt(
  WidgetTester tester,
  String name, {
  required AppState state,
  required String location,
  String? base,
  Size size = phone,
  bool night = false,
  double text = 1,
  Future<void> Function()? act,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final GoRouter router = buildRouter(state);
  final scale = state.wall ? DenType.wallScale : 1.0;
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: denTheme(night ? DenColors.night : DenColors.day, typeScale: scale),
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)), child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (base != null) {
    router.go(base);
    await tester.pumpAndSettle();
    router.push(location);
  } else {
    router.go(location);
  }
  await tester.pumpAndSettle();
  if (act != null) {
    await act();
    await tester.pumpAndSettle();
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));
}

/// Pumps [screen] alone (no tab bar or sidebar: the calendar's own pixels, as the canvas board
/// draws them) at [size], with the system text size [text].
Future<void> pumpCalendar(
  WidgetTester tester,
  Widget screen, {
  required AppState state,
  Size size = phone,
  bool night = false,
  double text = 1,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: denTheme(night ? DenColors.night : DenColors.day),
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)), child: child!),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [pumpCalendar], then compares it with `test/goldens/<name>.png`.
Future<void> shootCalendar(
  WidgetTester tester,
  String name,
  Widget screen, {
  required AppState state,
  Size size = phone,
  bool night = false,
  double text = 1,
  Future<void> Function()? act,
}) async {
  await pumpCalendar(tester, screen, state: state, size: size, night: night, text: text);
  if (act != null) {
    await act();
    await tester.pumpAndSettle();
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));
}

/// The first occurrence today or later whose title contains [text].
Occurrence findEvent(AppState state, String text, {int days = 60}) {
  final f = state.formats;
  final from = f.startOf(state.today);
  final to = f.startOf(f.addDays(state.today, days));
  return state.den.occurrences(from, to).firstWhere(
        (o) => o.title.toLowerCase().contains(text.toLowerCase()),
        orElse: () => throw StateError('No event like "$text" in the demo family'),
      );
}

/// The demo family, built outside the test's fake clock: the engine signs every change, and
/// that work never finishes inside `testWidgets`' fake async zone.
Future<AppState> demo(WidgetTester tester, {bool wall = false}) async =>
    (await tester.runAsync(() => demoState(wall: wall)))!;

/// The demo family with a fuller today, the way the canvas draws one: two people's events at the
/// same time (Zoe's swim lesson and Maya's piano lesson, 4:30 PM), an event for two (the
/// dentist, Leo with Priya) and one for everyone (movie night).
Future<AppState> busyDemo(WidgetTester tester) async => (await tester.runAsync(() async {
      final state = await demoState();
      final den = state.den;
      final f = state.formats;
      String id(String name) => den.members.firstWhere((m) => m.name == name).id;
      int at(int hour, [int minute = 0]) => f.startOf(state.today) + (hour * 60 + minute) * 60000;
      await den.addEvent(title: 'Piano lesson', start: at(16, 30), end: at(17, 15), assignees: [id('Maya')], location: 'Music Room');
      await den.addEvent(title: 'Dentist', start: at(9), end: at(10), assignees: [id('Leo'), id('Priya')], location: 'Bright Smiles Dental');
      await den.addEvent(title: 'Movie night', start: at(19), end: at(21));
      return state;
    }))!;

/// Runs an engine write outside the fake clock and lets the screen rebuild.
Future<void> write(WidgetTester tester, Future<void> Function() body) async {
  await tester.runAsync(body);
  await tester.pumpAndSettle();
}

/// Taps on the real clock, so the engine can sign what the tap writes, then lets the screen
/// catch up.
Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}
