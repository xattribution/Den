import 'dart:io';
import 'dart:ui' as ui;

import 'package:den_app/design/avatar.dart';
import 'package:den_app/design/pictures.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ids = [
  'fox', 'bear', 'cat', 'dog', 'bunny', 'owl', 'panda', 'frog', //
  'whale', 'octopus', 'turtle', 'ladybug', 'bee', 'butterfly', 'snail', 'chick',
  'strawberry', 'avocado', 'pizza', 'cupcake', 'watermelon', 'banana', 'icecream', 'pancakes',
  'sunflower', 'cactus', 'mushroom', 'tree', 'rainbow', 'sun', 'moon', 'cloud',
  'soccer', 'basketball', 'rocket', 'guitar', 'palette', 'kite', 'dinosaur', 'robot',
  'house', 'sailboat', 'balloon', 'teacup', 'tent', 'star', 'crown', 'camera',
  'firefighter', 'police', 'doctor', 'spy', 'ninja', 'armyman', 'astronaut', 'pirate',
  'tank', 'jet', 'racecar', 'firetruck', 'helicopter', 'train', 'sheriff', 'revolver',
];

/// What flutter_svg draws faithfully, and all the pack may use.
const _elements = {'svg', 'g', 'circle', 'ellipse', 'rect', 'path'};
const _attributes = {
  'xmlns', 'viewBox', 'width', 'height', 'x', 'y', 'rx', 'ry', 'cx', 'cy', 'r', 'd', 'transform', //
  'fill', 'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin',
};

void main() {
  // First, while nothing is parsed yet: the avatar falls back to loading its own asset.
  testWidgets('a picture draws even before the pack has loaded', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: denTheme(DenColors.day),
      home: const Center(child: DenAvatar.picture('owl', color: Color(0xFF339FEE), size: 96)),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('the pack is the canvas\'s 64 pictures, in its order, eight to a group', () {
    expect(DenPictures.all.map((p) => p.id), _ids);
    expect(DenPictures.groups.map((g) => g.name), [
      'Animals',
      'Critters',
      'Snacks',
      'Outdoors',
      'Play',
      'Home and adventure',
      'Heroes and jobs',
      'Action and wheels',
    ]);
    for (final g in DenPictures.groups) {
      expect(g.pictures, hasLength(8), reason: g.name);
    }
    expect(DenPictures.find('watermelon')!.label, 'Melon');
    expect(DenPictures.find('watermelon')!.name, 'Watermelon');
    expect(DenPictures.find('unicorn'), isNull);
    // MCP and the assistant offer the pack by name from den_core's list.
    expect(DenPictures.all.map((p) => p.id), Picture.pack);
  });

  test('every picture is a 64 x 64 SVG asset that uses only what flutter_svg draws', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/pictures/'));
    final files = Directory('assets/pictures').listSync().whereType<File>().map((f) => f.uri.pathSegments.last);
    expect(files.toSet(), {for (final id in _ids) '$id.svg'});
    for (final p in DenPictures.all) {
      final svg = File(p.asset).readAsStringSync();
      expect(svg, startsWith('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"'), reason: p.id);
      final elements = RegExp(r'<([a-zA-Z]+)').allMatches(svg).map((m) => m[1]!).toSet();
      expect(elements.difference(_elements), isEmpty, reason: '${p.id} uses unsupported elements');
      final attributes = RegExp(r'\s([a-zA-Z-]+)="').allMatches(svg).map((m) => m[1]!).toSet();
      expect(attributes.difference(_attributes), isEmpty, reason: '${p.id} uses unsupported attributes');
      final transforms = RegExp(r'transform="([^"]*)"').allMatches(svg).map((m) => m[1]!);
      for (final t in transforms) {
        expect(t, matches(RegExp(r'^rotate\(-?[\d.]+ [\d.]+ [\d.]+\)$')), reason: p.id);
      }
    }
  });

  testWidgets('every picture parses and draws', (tester) async {
    await tester.runAsync(DenPictures.load);
    for (final p in DenPictures.all) {
      final drawn = DenPictures.drawn(p.id);
      expect(drawn, isNotNull, reason: p.id);
      expect(drawn!.size, const Size(64, 64), reason: p.id);
      final painted = await tester.runAsync(() async {
        final image = await drawn.picture.toImage(64, 64);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        var count = 0;
        for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) > 0) count++;
        }
        return count;
      });
      // Each picture draws something real in its square; thin ones like the six-shooter cover
      // less of it than the animals do.
      expect(painted, greaterThan(64 * 64 ~/ 14), reason: p.id);
    }
  });

  testWidgets('every picture renders in its ring, light and dark', (tester) async {
    await tester.runAsync(DenPictures.load);
    for (final colors in [DenColors.day, DenColors.night]) {
      await tester.pumpWidget(MaterialApp(
        theme: denTheme(colors),
        home: SingleChildScrollView(
          child: Wrap(
            children: [
              for (final (i, p) in DenPictures.all.indexed)
                DenAvatar.picture(p.id, color: PersonColor.values[i % 8].color, size: 64),
            ],
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(DenAvatar), findsNWidgets(64));
      expect(find.bySemanticsLabel('Watermelon'), findsOneWidget);
    }
  });

  group('avatar', () {
    Widget host(Widget child, {DenColors colors = DenColors.day}) =>
        MaterialApp(theme: denTheme(colors), home: Center(child: child));

    testWidgets('a picture sits in a solid ring of their color', (tester) async {
      await tester.pumpWidget(host(const DenAvatar.picture('fox', color: Color(0xFFF075AA), size: 96)));
      final ring = tester.widget<DecoratedBox>(
        find.descendant(of: find.byType(DenAvatar), matching: find.byType(DecoratedBox)).first,
      );
      final decoration = ring.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, DenColors.day.pictureBg);
      expect((decoration.border! as Border).top.color, const Color(0xFFF075AA));
      expect((decoration.border! as Border).top.width, 4);
      expect(tester.getSize(find.byType(DenAvatar)), const Size(96, 96));
    });

    testWidgets('an initial is the letter in dark ink on their color, in both themes', (tester) async {
      for (final colors in [DenColors.day, DenColors.night]) {
        await tester.pumpWidget(host(const DenAvatar.initial('mia', color: Color(0xFF4CC157), size: 40), colors: colors));
        final letter = tester.widget<Text>(find.text('M'));
        expect(letter.style!.color, const Color(0xFF141414));
        expect(letter.style!.fontWeight, FontWeight.w700);
        final disc = tester.widget<DecoratedBox>(
          find.descendant(of: find.byType(DenAvatar), matching: find.byType(DecoratedBox)).first,
        );
        expect((disc.decoration as BoxDecoration).color, const Color(0xFF4CC157));
        expect((disc.decoration as BoxDecoration).border, isNull);
      }
    });

    testWidgets('an initial keeps its size at any text size', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: denTheme(DenColors.day),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Center(child: DenAvatar.initial('L', color: Color(0xFF4CC157), size: 40)),
      ));
      expect(tester.getSize(find.byType(DenAvatar)), const Size(40, 40));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a photo that isn\'t there shows the silhouette in their ring', (tester) async {
      await tester.pumpWidget(host(const DenAvatar.photo(null, color: Color(0xFF339FEE), size: 64, semanticLabel: 'Dad')));
      expect(find.bySemanticsLabel('Dad'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
