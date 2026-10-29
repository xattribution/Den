import 'dart:convert';

import 'package:den_app/design/layout.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_core/demo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// A fixed moment for the demo family so screenshots are stable: Friday, October 16, 2026,
/// 8 AM in Chicago, the demo family's time zone.
final DateTime demoNow = DateTime.utc(2026, 10, 16, 13);

const Size phone = Size(390, 844);
const Size tablet = Size(1194, 834);
const Size wall = Size(1920, 1080);

bool _fontsLoaded = false;

/// Loads every font the app bundles (Atkinson Hyperlegible Next, Phosphor, Material Icons) so
/// screenshots show real text and icons instead of test boxes.
Future<void> loadFonts() async {
  if (_fontsLoaded) return;
  tzdata.initializeTimeZones();
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  _fontsLoaded = true;
}

/// A demo family as the acting parent sees it. Call it through [WidgetTester.runAsync] (or use
/// [demoIn]): the engine signs changes with real async crypto, which never completes inside a
/// widget test's fake clock.
Future<AppState> demoState({bool wall = false}) async {
  final den = await createDemoFamily(now: demoNow);
  return AppState(den, wall: wall);
}

/// [demoState] built on the real event loop from inside a widget test.
Future<AppState> demoIn(WidgetTester tester, {bool wall = false}) async =>
    (await tester.runAsync(() => demoState(wall: wall)))!;

/// Renders [screen] inside the app's theme at [size] and compares it with
/// `test/goldens/<name>.png`. Run `flutter test --update-goldens` to write the images, then
/// open them to review the screen.
Future<void> shoot(
  WidgetTester tester,
  String name,
  Widget screen, {
  required AppState state,
  Size size = phone,
  bool night = false,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final scale = state.wall ? DenType.wallScale : 1.0;
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: denTheme(night ? DenColors.night : DenColors.day, typeScale: scale),
        builder: (context, child) => TextSizeFromState(child: child!),
        home: Scaffold(body: SafeArea(child: screen)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));
}

/// Renders a whole route of the app (shell included) for screens that depend on navigation.
Future<void> shootRoute(
  WidgetTester tester,
  String name,
  GoRouter router, {
  required AppState state,
  Size size = phone,
  bool night = false,
}) async {
  await loadFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final scale = state.wall ? DenType.wallScale : 1.0;
  await tester.pumpWidget(
    DenScope(
      state: state,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: denTheme(night ? DenColors.night : DenColors.day, typeScale: scale),
        builder: (context, child) => TextSizeFromState(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../goldens/$name.png'));
}

/// Text that reads [words], whatever spaces the line-breaking helpers made unbreakable
/// ("3:30 PM", "same time").
Finder findWords(String words) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? w.textSpan?.toPlainText())?.replaceAll(RegExp('[\u00a0\u202f]'), ' ') == words,
      description: 'text "$words"',
    );

/// The person's own text size ([AppState.textSize]) on top of the system's, held to 200 %,
/// following the setting when it changes, the way the app's root does.
class TextSizeFromState extends StatelessWidget {
  const TextSizeFromState({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      DenTextScale(size: DenScope.watch(context, const {Changes.prefs}).textSize, child: child);
}

/// Sets the system text size to [scale] (2.0 is 200 %) for the rest of the test.
void withTextScale(WidgetTester tester, double scale) {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// [child] with the system text size [text] (null keeps what [withTextScale] set), then the
/// person's own text size on top, held to 200 %, the way the app's root does it. Asking for a
/// text size here after [withTextScale] set another is a mistake in the test, so it fails.
Widget systemText(WidgetTester tester, double? text, {required AppState state, required Widget child}) {
  final scaled = TextSizeFromState(child: child);
  if (text == null) return scaled;
  final set = tester.platformDispatcher.textScaleFactor;
  if (set != 1 && set != text) {
    throw StateError('withTextScale set the text size to $set and the shot asks for $text; use one of them.');
  }
  return Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)),
      child: scaled,
    ),
  );
}
