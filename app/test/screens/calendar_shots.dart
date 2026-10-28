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

/// Renders the whole app at [location] (pushed over [base] when given, so side panels show the
/// page behind them) and compares it with `test/goldens/<name>.png`.
Future<void> shootAt(
  WidgetTester tester,
  String name, {
  required AppState state,
  required String location,
  String? base,
  Size size = phone,
  bool night = false,
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

/// Runs an engine write outside the fake clock and lets the screen rebuild.
Future<void> write(WidgetTester tester, Future<void> Function() body) async {
  await tester.runAsync(body);
  await tester.pumpAndSettle();
}
