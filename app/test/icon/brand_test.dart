@Tags(['golden'])
library;

import 'package:den_app/design/mark.dart';
import 'package:den_app/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';

/// Renders the Home Assistant integration's brand images from the app's mark, into
/// integrations/homeassistant/custom_components/den/brand/. `flutter test --update-goldens
/// test/icon` rewrites them along with the app icon.
///
/// Home Assistant wants them trimmed, on a transparent background: a 256 px square icon and a
/// logo whose short side is 128 to 256 px, each again at twice the size (@2x), and dark_
/// versions for dark themes. The light ones take the day colors, the dark ones the night colors.
const _brand = '../../../integrations/homeassistant/custom_components/den/brand';

void main() {
  for (final (prefix, colors) in [('', DenColors.day), ('dark_', DenColors.night)]) {
    for (final (suffix, scale) in [('', 1), ('@2x', 2)]) {
      testWidgets('${prefix}icon$suffix', (tester) async {
        await _shoot(tester, _BrandPainter(colors, 256.0 * scale), '${prefix}icon$suffix');
      });
      testWidgets('${prefix}logo$suffix', (tester) async {
        await _shoot(tester, _BrandPainter(colors, 256.0 * scale, name: true), '${prefix}logo$suffix');
      });
    }
  }
}

Future<void> _shoot(WidgetTester tester, _BrandPainter painter, String name) async {
  await loadFonts();
  final size = painter.imageSize;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  const key = ValueKey('brand');
  await tester.pumpWidget(
    Center(child: RepaintBoundary(child: CustomPaint(key: key, size: size, painter: painter))),
  );
  await expectLater(find.byKey(key), matchesGoldenFile('$_brand/$name.png'));
}

/// The mark cut down to its doorway, which fills the image's [height]: alone and centered in a
/// square (the icon), or with Den's name beside it (the logo).
class _BrandPainter extends CustomPainter {
  _BrandPainter(this.colors, this.height, {this.name = false});

  final DenColors colors;
  final double height;
  final bool name;

  static const _door = DenMarkPainter.doorway;

  /// Atkinson Hyperlegible Next's capital height, in ems (OS/2 sCapHeight 668 of 1000).
  static const _capHeight = 0.668;

  /// The name's capitals reach about as high as the tallest person in the doorway.
  static const _capLine = 0.75;

  /// Space between the doorway and the name, in doorway heights.
  static const _gap = 0.22;

  double get _side => height / _door.height;
  double get _doorWidth => _side * _door.width;

  late final TextPainter _text = TextPainter(
    text: TextSpan(
      text: 'Den',
      style: TextStyle(
        fontFamily: DenType.family,
        fontSize: height * _capLine / _capHeight,
        fontWeight: FontWeight.w700,
        fontVariations: const [FontVariation.weight(700)],
        color: colors.ink,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  Size get imageSize =>
      name ? Size((_doorWidth + height * _gap + _text.width).ceilToDouble(), height) : Size.square(height);

  @override
  void paint(Canvas canvas, Size size) {
    final left = name ? 0.0 : (size.width - _doorWidth) / 2;
    canvas
      ..save()
      ..translate(left - _door.left * _side, -_door.top * _side);
    DenMarkPainter(colors).paint(canvas, Size.square(_side));
    canvas.restore();
    if (name) {
      // The name stands on the doorway's floor.
      final baseline = _text.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      _text.paint(canvas, Offset(_doorWidth + height * _gap, height - baseline));
    }
  }

  @override
  bool shouldRepaint(_BrandPainter old) => old.colors != colors || old.height != height || old.name != name;
}
