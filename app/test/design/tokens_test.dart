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

  group('color packs', () {
    test('the validated hexes, in assignment order (DESIGN.md, "Family colors"; never by eye)', () {
      String hex(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
      expect({for (final p in ColorPack.values) p.name: [for (final c in p.colors) hex(c.color)].join(',')}, {
        'bright': '339FEE,4CC157,AD87ED,F88B1C,10CACA,F05653,F4CE23,F075AA',
        'deep': '2682FF,009D4F,9D64F6,E97200,009EA4,F33A3F,ECC906,EC3F94',
        'soft': '71C8FF,7CE695,C7A8FF,FFB072,5DE9E9,FF8482,FEE657,FA96C3',
        'bold': '477FFF,30C532,B853FF,FF7902,06C1EC,FF2920,F5DA04,F33BBF',
      });
      expect(
        [for (final c in ColorPack.bright.colors) (c.label, c.color)],
        [for (final p in PersonColor.values) (p.label, p.color)],
        reason: 'Bright is the first pack',
      );
    });

    test('eight colors each, one per place, every name its own', () {
      for (final p in ColorPack.values) {
        expect(p.colors, hasLength(Marker.values.length), reason: p.name);
        expect(p.colors.map((c) => c.label).toSet(), hasLength(8), reason: p.name);
      }
    });

    test('dark text reads at 4.8:1 or better on every color of every pack, in both themes', () {
      for (final p in ColorPack.values) {
        for (final theme in [DenColors.day, DenColors.night]) {
          final c = theme.withPack(p);
          for (final m in Marker.values) {
            expect(contrast(c.onMarker, c.marker(m)), greaterThanOrEqualTo(4.8), reason: '${p.name} ${p.of(m).label}');
            expect(c.marker(m), DenColors.day.withPack(p).marker(m), reason: 'the same hex by day and at night');
          }
        }
      }
    });

    test('neighbors stay apart: deltaE 15 for everyone, 8 under protan and deutan', () {
      for (final p in ColorPack.values) {
        for (var i = 0; i + 1 < p.colors.length; i++) {
          final (a, b) = (p.colors[i].color, p.colors[i + 1].color);
          final why = '${p.name}: ${p.colors[i].label} and ${p.colors[i + 1].label}';
          expect(_deltaE(a, b), greaterThanOrEqualTo(15), reason: why);
          expect(_deltaE(a, b, _protan), greaterThanOrEqualTo(8), reason: '$why, protan');
          expect(_deltaE(a, b, _deutan), greaterThanOrEqualTo(8), reason: '$why, deutan');
        }
      }
    });

    test('a pack changes the people and nothing else', () {
      final deep = DenColors.night.withPack(ColorPack.deep);
      expect(deep.marker(Marker.sky), ColorPack.deep.color(Marker.sky));
      expect((deep.bg, deep.ink, deep.onMarker, deep.card), (DenColors.night.bg, DenColors.night.ink, DenColors.night.onMarker, DenColors.night.card));
      expect(DenColors.day.withPack(ColorPack.bright), same(DenColors.day));
    });
  });

  test('the engine names the same eight colors in the same order', () {
    expect(Marker.values.map((m) => m.name), PersonColor.values.map((p) => p.name));
    for (final m in Marker.values) {
      expect(PersonColor.forMarker(m).marker, m);
    }
    expect(PersonColor.forMarker(Marker.parse('teal')!), PersonColor.aqua, reason: 'older names read as the nearest');
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
      expect(noOrphan("Maya's picture"), "Maya's picture", reason: 'two words joined would break inside one');
      final long = List.filled(15, 'word').join(' ');
      expect(noOrphan(long), long);
    });
  });
}

// The palette validator's measures (dataviz validate_palette.js): OKLab distance x100, with the
// Machado, Oliveira and Fernandes (2009) color-blindness matrices at full severity.
const _protan = [
  [0.152286, 1.052583, -0.204868],
  [0.114503, 0.786281, 0.099216],
  [-0.003882, -0.048116, 1.051998],
];
const _deutan = [
  [0.367322, 0.860646, -0.227968],
  [0.280085, 0.672501, 0.047413],
  [-0.011820, 0.042940, 0.968881],
];

List<double> _linear(Color c) => [
      for (final v in [c.r, c.g, c.b]) v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble(),
    ];

List<double> _oklab(List<double> rgb) {
  double cbrt(double v) => math.pow(v, 1 / 3).toDouble();
  final [r, g, b] = rgb;
  final l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

double _deltaE(Color a, Color b, [List<List<double>>? sim]) {
  List<double> see(Color c) {
    final rgb = _linear(c);
    if (sim == null) return _oklab(rgb);
    return _oklab([
      for (final row in sim) (row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2]).clamp(0.0, 1.0),
    ]);
  }

  final (x, y) = (see(a), see(b));
  return 100 * math.sqrt(math.pow(x[0] - y[0], 2) + math.pow(x[1] - y[1], 2) + math.pow(x[2] - y[2], 2));
}

Widget _record(List<DenWidth> seen, DenWidth w) {
  seen.add(w);
  return const SizedBox();
}
