@Tags(['golden'])
library;

import 'package:den_app/design/mark.dart';
import 'package:den_app/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the app icon and the web app's icons from the mark, in the day colors.
/// `flutter test --update-goldens test/icon` writes:
///
/// - test/goldens/app_icon.png and app_icon_night.png, for review;
/// - assets/icon/app_icon.png, which `dart run flutter_launcher_icons` turns into the Android,
///   iOS, macOS and Windows icon sets;
/// - web/icons (the manifest's icons, the maskable ones with the mark inside the safe circle, and
///   the Home Screen's apple-touch-icon) and web/favicon.png.
void main() {
  testWidgets('app icon', (tester) async {
    await _shoot(tester, 1024, '../goldens/app_icon.png');
  });

  testWidgets('app icon at night', (tester) async {
    await _shoot(tester, 512, '../goldens/app_icon_night.png', colors: DenColors.night);
  });

  testWidgets('app icon source for flutter_launcher_icons', (tester) async {
    await _shoot(tester, 1024, '../../assets/icon/app_icon.png');
  });

  for (final size in [192, 512]) {
    testWidgets('web icon $size', (tester) async {
      await _shoot(tester, size, '../../web/icons/Icon-$size.png');
    });
    testWidgets('web maskable icon $size', (tester) async {
      await _shoot(tester, size, '../../web/icons/Icon-maskable-$size.png', mark: _maskable);
    });
  }

  testWidgets('apple-touch-icon', (tester) async {
    await _shoot(tester, 180, '../../web/icons/apple-touch-icon.png');
  });

  testWidgets('favicon', (tester) async {
    await _shoot(tester, 16, '../../web/favicon.png');
  });
}

/// How much of the square the mark takes in a maskable icon: the platform may cut it to a circle
/// 80 % across, and the doorway's corners have to stay inside it.
const double _maskable = 0.8;

Future<void> _shoot(WidgetTester tester, int size, String path, {DenColors colors = DenColors.day, double mark = 1}) async {
  final side = size.toDouble();
  tester.view.physicalSize = Size.square(side);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  const key = ValueKey('icon');
  await tester.pumpWidget(
    Center(
      child: RepaintBoundary(
        child: CustomPaint(key: key, size: Size.square(side), painter: _IconPainter(colors, mark)),
      ),
    ),
  );
  await expectLater(find.byKey(key), matchesGoldenFile(path));
}

/// The page color edge to edge, and the mark over it at [mark] of the square, centered.
class _IconPainter extends CustomPainter {
  _IconPainter(this.colors, this.mark);

  final DenColors colors;
  final double mark;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.bg);
    final inset = size.width * (1 - mark) / 2;
    canvas
      ..save()
      ..translate(inset, inset);
    DenMarkPainter(colors).paint(canvas, size * mark);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.colors != colors || old.mark != mark;
}
