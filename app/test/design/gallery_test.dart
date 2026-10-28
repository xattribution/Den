import 'package:den_app/design/layout.dart';
import 'package:den_app/design/pictures.dart';
import 'package:den_app/design/sheet.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart' show loadFonts;
import 'gallery.dart';

/// Screenshots of the design foundation, for checking against the approved canvas. Rendered at
/// 2x with the real bundled fonts into test/design/goldens/. On CI (Linux) they render without
/// comparing pixels; the Screenshots workflow runs them with --update-goldens and pushes the
/// images to the `screenshots/<branch>` branch. See DESIGN.md, "Screenshots".
const Size galleryPhone = Size(390, 844);
const Size galleryPad = Size(1180, 820);

Future<void> shootDesign(
  WidgetTester tester,
  String name,
  Widget page, {
  Size size = galleryPhone,
  bool night = false,
  double textScale = 1,
  WidgetBuilder? sheet,
}) async {
  await loadFonts();
  await tester.runAsync(DenPictures.load);
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final colors = night ? DenColors.night : DenColors.day;
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigator,
      theme: denTheme(colors),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Material(color: colors.bg, child: page),
    ),
  );
  if (sheet != null) navigator.currentState!.push(DenSheetRoute<void>(builder: sheet));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  for (final night in [false, true]) {
    final n = night ? '_night' : '';

    testWidgets('Today, phone$n', (tester) => shootDesign(tester, 'today_phone$n', const TodaySample(), night: night));

    testWidgets('type and controls, phone$n', (tester) {
      return shootDesign(tester, 'controls_phone$n', const ControlsSample(), size: const Size(390, 1360), night: night);
    });

    testWidgets('picture sheet, phone$n', (tester) {
      return shootDesign(tester, 'sheet_phone$n', const TodaySample(), night: night, sheet: (_) => const PickerSheet());
    });

    testWidgets('picture pack, iPad$n', (tester) {
      return shootDesign(tester, 'pictures_pad$n', const PackSample(), size: const Size(1180, 1660), night: night);
    });
  }

  testWidgets('family colors', (tester) {
    return shootDesign(tester, 'palette', const PaletteSample(), size: const Size(760, 700));
  });

  testWidgets('form sheet, iPad', (tester) {
    return shootDesign(
      tester,
      'sheet_pad',
      const ReadableWidth(child: TodaySample(tabBar: false)),
      size: galleryPad,
      sheet: (_) => const PickerSheet(),
    );
  });

  testWidgets('Today at 200 % text, phone', (tester) {
    return shootDesign(
      tester,
      'today_text200_phone',
      const TodaySample(tabBar: false),
      size: const Size(390, 1800),
      textScale: 2,
    );
  });
}
