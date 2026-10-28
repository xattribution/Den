import 'dart:math' as math;

import 'package:den_app/design/layout.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/design/words.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast ratio between two opaque colors.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

int _channel(double v) => (v * 255).round();

void main() {
  for (final (name, c) in [('light', DenColors.day), ('dark', DenColors.night)]) {
    group('$name colors', () {
      test('text reads at 4.5:1 or better on the page, on cards and on overlays', () {
        final texts = {'ink': c.ink, 'ink2': c.ink2, 'ink3': c.ink3, 'destructive': c.destructive};
        final surfaces = {'bg': c.bg, 'card': c.card, 'raised': c.raised};
        for (final t in texts.entries) {
          for (final s in surfaces.entries) {
            expect(contrast(t.value, s.value), greaterThanOrEqualTo(4.5), reason: '${t.key} on ${s.key}');
          }
        }
      });

      test('a primary button reads', () {
        expect(contrast(c.onPrimary, c.primary), greaterThanOrEqualTo(4.5));
        expect(c.primary, c.ink, reason: 'there is no brand accent: actions are ink');
      });

      test('dark text reads at 4.5:1 or better on every person color', () {
        for (final p in PersonColor.values) {
          expect(contrast(c.onMarker, p.color), greaterThanOrEqualTo(4.5), reason: p.label);
        }
      });

      test('every gray is neutral: R, G and B within 2', () {
        final grays = {
          'bg': c.bg,
          'card': c.card,
          'raised': c.raised,
          'fill': c.fill,
          'line': c.line,
          'ink': c.ink,
          'ink2': c.ink2,
          'ink3': c.ink3,
          'onPrimary': c.onPrimary,
          'onMarker': c.onMarker,
          'scrim': c.scrim,
          'handle': c.handle,
          'track': c.track,
          'switchOff': c.switchOff,
          'knob': c.knob,
          'pictureBg': c.pictureBg,
          'photoBg': c.photoBg,
          'photoFg': c.photoFg,
          'bar': c.bar,
        };
        for (final g in grays.entries) {
          final channels = [_channel(g.value.r), _channel(g.value.g), _channel(g.value.b)];
          expect(channels.reduce(math.max) - channels.reduce(math.min), lessThanOrEqualTo(2), reason: g.key);
        }
      });

      test('surfaces step by gray, cards apart from the page', () {
        expect(c.card, isNot(c.bg));
        expect(c.pictureBg, isNot(c.card));
      });

      test('the old names map onto the new tokens', () {
        final (paper, well, rule, onInk, bad, caution) = (c.paper, c.well, c.rule, c.onInk, c.bad, c.caution);
        expect(paper, c.bg);
        expect(well, c.card);
        expect(rule, c.line);
        expect(onInk, c.onPrimary);
        expect(bad, c.destructive);
        expect(caution, c.ink, reason: 'there is no amber: attention is position, a word and an ink icon');
      });
    });
  }

  test('light is #F2F2F2 behind white cards; dark is true black behind #141414 cards', () {
    expect(DenColors.day.bg, const Color(0xFFF2F2F2));
    expect(DenColors.day.card, const Color(0xFFFFFFFF));
    expect(DenColors.day.ink, const Color(0xFF141414));
    expect(DenColors.night.bg, const Color(0xFF000000));
    expect(DenColors.night.card, const Color(0xFF141414));
    expect(DenColors.night.ink, const Color(0xFFF2F2F2));
  });

  test('text on a person color is #141414 in both themes', () {
    expect(DenColors.day.onMarker, const Color(0xFF141414));
    expect(DenColors.night.onMarker, const Color(0xFF141414));
  });

  test('the family colors, in assignment order', () {
    expect(PersonColor.assignmentOrder.map((p) => (p.label, p.color.toARGB32())), [
      ('Sky', 0xFF339FEE),
      ('Grass', 0xFF4CC157),
      ('Lavender', 0xFFAD87ED),
      ('Tangerine', 0xFFF88B1C),
      ('Aqua', 0xFF10CACA),
      ('Coral', 0xFFF05653),
      ('Sunshine', 0xFFF4CE23),
      ('Bubblegum', 0xFFF075AA),
    ]);
  });

  test('a person color is the same hex in light and dark', () {
    for (final m in Marker.values) {
      expect(DenColors.day.marker(m), DenColors.night.marker(m), reason: m.name);
    }
  });

  test('the old ten markers map onto the eight family colors', () {
    expect({for (final m in Marker.values) m: PersonColor.forMarker(m)}, {
      Marker.blue: PersonColor.sky,
      Marker.green: PersonColor.grass,
      Marker.plum: PersonColor.lavender,
      Marker.orange: PersonColor.tangerine,
      Marker.teal: PersonColor.aqua,
      Marker.brown: PersonColor.coral,
      Marker.olive: PersonColor.sunshine,
      Marker.pink: PersonColor.bubblegum,
      Marker.sky: PersonColor.sky,
      Marker.slate: PersonColor.lavender,
    });
  });

  test('the next person gets the first color nobody has, then the least shared', () {
    expect(PersonColor.next([]), PersonColor.sky);
    expect(PersonColor.next([PersonColor.sky, PersonColor.grass]), PersonColor.lavender);
    expect(PersonColor.next([PersonColor.grass]), PersonColor.sky);
    expect(PersonColor.next([...PersonColor.values, PersonColor.sky]), PersonColor.grass);
  });

  group('type', () {
    const t = DenText();
    const ink = Color(0xFF141414);

    test('body is 17, and every role is Atkinson Hyperlegible Next', () {
      expect(t.body(ink).fontSize, 17);
      for (final style in [
        t.screenTitle(ink),
        t.sheetTitle(ink),
        t.section(ink),
        t.rowTitle(ink),
        t.body(ink),
        t.label(ink),
        t.control(ink),
        t.meta(ink),
        t.caption(ink),
        t.tab(ink),
        t.display(ink),
      ]) {
        expect(style.fontFamily, DenType.family);
      }
    });

    test('two weights, and 800 only for the one heading on a screen or sheet', () {
      final regular = [t.body(ink), t.control(ink), t.meta(ink), t.caption(ink), t.tab(ink)];
      final bold = [t.section(ink), t.rowTitle(ink), t.label(ink), t.display(ink), t.tab(ink, selected: true)];
      for (final s in regular) {
        expect(s.fontWeight, FontWeight.w400);
      }
      for (final s in bold) {
        expect(s.fontWeight, FontWeight.w700);
      }
      expect(t.screenTitle(ink).fontWeight, FontWeight.w800);
      expect(t.sheetTitle(ink).fontWeight, FontWeight.w800);
    });

    test('line height is 1.25 for titles and 1.35 for reading text', () {
      expect(t.rowTitle(ink).height, 1.25);
      expect(t.section(ink).height, 1.25);
      expect(t.body(ink).height, 1.35);
      expect(t.meta(ink).height, 1.35);
    });

    test('the wall display scales every role', () {
      expect(const DenText(DenType.wallScale).body(ink).fontSize, closeTo(17 * 1.3, 0.001));
    });
  });

  test('touch targets: 44 for adults, 72 for kids', () {
    expect(Targets.adult, greaterThanOrEqualTo(44));
    expect(Targets.kid, greaterThanOrEqualTo(72));
  });

  test('radius follows the object', () {
    expect(Radii.input, 14);
    expect(Radii.section, 20);
    expect(Radii.pill, greaterThan(100));
  });

  group('layout', () {
    test('breakpoints by available width', () {
      expect(DenLayout.forWidth(390), DenWidth.compact);
      expect(DenLayout.forWidth(699.9), DenWidth.compact);
      expect(DenLayout.forWidth(700), DenWidth.regular);
      expect(DenLayout.forWidth(834), DenWidth.regular);
      expect(DenLayout.forWidth(1099.9), DenWidth.regular);
      expect(DenLayout.forWidth(1100), DenWidth.wide);
      expect(DenLayout.forWidth(1180), DenWidth.wide);
    });

    test('a sidebar and centered sheets from regular up; kid tiles 2, 3, 4 across', () {
      expect(DenWidth.compact.hasSidebar, isFalse);
      expect(DenWidth.regular.hasSidebar, isTrue);
      expect(DenWidth.wide.centersSheets, isTrue);
      expect([for (final w in DenWidth.values) w.kidColumns], [2, 3, 4]);
    });

    testWidgets('DenLayoutBuilder uses the width it is given, not the window', (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final seen = <DenWidth>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              SizedBox(width: 400, child: DenLayoutBuilder(builder: (context, w) => _record(seen, w))),
              Expanded(child: DenLayoutBuilder(builder: (context, w) => _record(seen, w))),
            ],
          ),
        ),
      );
      expect(seen, [DenWidth.compact, DenWidth.regular]);
    });

    testWidgets('text follows the system size up to 200 %', (tester) async {
      late TextScaler seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: DenTextScale(
            child: Builder(builder: (context) {
              seen = MediaQuery.textScalerOf(context);
              return const SizedBox();
            }),
          ),
        ),
      );
      expect(seen.scale(10), 20);
    });
  });

  group('words', () {
    test('numbers stay with their units, meridiems and labels', () {
      expect(keepUnits('Soccer, 3:30 PM at Field 4'), 'Soccer, 3:30${nbsp}PM at Field${nbsp}4');
      expect(keepUnits('Costs 40 stars, she has 52'), 'Costs 40${nbsp}stars, she has${nbsp}52');
      expect(keepUnits('Wednesday, October 28'), 'Wednesday, October${nbsp}28');
    });

    test('a short line never ends with one lonely word', () {
      expect(noOrphan('Movie night approved for Mia'), 'Movie night approved for${nbsp}Mia');
      expect(noOrphan('Approve'), 'Approve');
      final long = List.filled(15, 'word').join(' ');
      expect(noOrphan(long), long);
    });
  });
}

Widget _record(List<DenWidth> seen, DenWidth w) {
  seen.add(w);
  return const SizedBox();
}
