@Tags(['golden'])
library;

import 'package:den_app/design/mark.dart';
import 'package:den_app/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the app icon source. `flutter test --update-goldens test/icon` writes
/// test/goldens/app_icon.png, which `dart run flutter_launcher_icons` turns into every
/// platform's icon set.
void main() {
  testWidgets('app icon', (tester) async {
    tester.view.physicalSize = const Size(1024, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(extensions: const [DenColors.day]),
        home: const Center(child: RepaintBoundary(child: DenMark(size: 1024, background: true))),
      ),
    );
    await expectLater(find.byType(DenMark), matchesGoldenFile('../goldens/app_icon.png'));
  });

  testWidgets('app icon at night', (tester) async {
    tester.view.physicalSize = const Size(512, 512);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(extensions: const [DenColors.night]),
        home: const Center(child: RepaintBoundary(child: DenMark(size: 512, background: true))),
      ),
    );
    await expectLater(find.byType(DenMark), matchesGoldenFile('../goldens/app_icon_night.png'));
  });
}
