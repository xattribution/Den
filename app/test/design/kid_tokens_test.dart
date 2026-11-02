import 'dart:math' as math;

import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

void main() {
  group('kid colors', () {
    test("the spec's six primaries, face and lip, in order", () {
      expect([for (final p in KidColors.all) '${p.name} ${_hex(p.face)} ${_hex(p.lip)}'], [
        'sky #4FB4F7 #2C8FD6',
        'leaf #4CC968 #2FA34C',
        'sun #FFD23F #E8B400',
        'tangerine #FF9B3F #E87A1C',
        'berry #FF6F7D #E04A5C',
        'bubble #F58BC0 #D9619E',
      ]);
    });

    test('navy on every face reads at 4.5:1 or better (5.94:1 at the lowest, on berry)', () {
      expect(KidColors.navy, const Color(0xFF0F2338));
      for (final p in KidColors.all) {
        expect(_contrast(KidColors.navy, p.face), greaterThanOrEqualTo(4.5), reason: p.name);
      }
      expect(_contrast(KidColors.navy, KidColors.berry.face), closeTo(5.94, 0.01));
    });

    test('the todo ring is 3:1 or better on the card, in every theme', () {
      for (final theme in [DenColors.day, DenColors.night, DenColors.softDay, DenColors.softNight]) {
        final kid = KidColors.of(theme);
        expect(_contrast(kid.todoRing, theme.card), greaterThanOrEqualTo(3), reason: '${theme.palette} ${theme.brightness}');
      }
      expect(KidColors.softDay.todoRing, const Color(0xFF7F96AE));
      expect(KidColors.softNight.todoRing, const Color(0xFF5F7894));
    });

    test('each theme gets its own kid tokens, and denTheme carries them', () {
      expect(KidColors.of(DenColors.day), KidColors.day);
      expect(KidColors.of(DenColors.night), KidColors.night);
      expect(KidColors.of(DenColors.softDay), KidColors.softDay);
      expect(KidColors.of(DenColors.softNight), KidColors.softNight);
      expect(denTheme(DenColors.softNight).extension<KidColors>(), KidColors.softNight);
    });

    test("a job's disc color comes from its chore id: the same every time, and spread over all six", () {
      const kid = KidColors.day;
      expect(kid.forJob('chore-1'), kid.forJob('chore-1'));
      final seen = {for (var i = 0; i < 60; i++) kid.forJob('chore-$i')};
      expect(seen, hasLength(6));
      expect(KidColors.stableIndex('make-bed', 6), KidColors.stableIndex('make-bed', 6));
      expect(KidColors.stableIndex('', 6), inInclusiveRange(0, 5));
    });

    test("on a board no disc matches the three before it (beside or above), and it's stable", () {
      const kid = KidColors.day;
      final ids = [for (var i = 0; i < 40; i++) 'job-${i * 7}'];
      final colors = kid.forJobs(ids);
      for (var i = 0; i < colors.length; i++) {
        for (var back = 1; back <= 3 && i - back >= 0; back++) {
          expect(colors[i], isNot(colors[i - back]), reason: 'job $i and ${i - back}');
        }
      }
      expect(kid.forJobs(ids), colors);
      expect(kid.forJobs(['only']).single, kid.forJob('only'), reason: 'a lone job keeps its own color');
    });

    test("a derived lip is darker than its face and close to the spec's own lips", () {
      for (final p in KidColors.all) {
        final lip = KidColors.lipOf(p.face);
        expect(lip.computeLuminance(), lessThan(p.face.computeLuminance()), reason: p.name);
        final (a, b) = (HSLColor.fromColor(lip), HSLColor.fromColor(p.lip));
        expect((a.lightness - b.lightness).abs(), lessThan(0.05), reason: '${p.name}: ${_hex(lip)} vs ${_hex(p.lip)}');
        expect((a.hue - b.hue).abs(), lessThan(4), reason: p.name);
      }
    });

    test('lerping keeps the primaries and moves the ring', () {
      final mid = KidColors.day.lerp(KidColors.softDay, 0.5);
      expect(mid.primaries, KidColors.all);
      expect(mid.todoRing, Color.lerp(KidColors.day.todoRing, KidColors.softDay.todoRing, 0.5));
    });
  });

  group('kid type', () {
    const t = DenText();
    const ink = KidColors.navy;

    test('four roles: hello 30, job 20, meta 15, count 46, all heavy', () {
      expect([t.kidHello(ink), t.kidJob(ink), t.kidMeta(ink), t.kidCount(ink)].map((s) => (s.fontSize, s.fontWeight, s.height)), [
        (30, FontWeight.w800, 1.15),
        (20, FontWeight.w800, 1.2),
        (15, FontWeight.w700, 1.2),
        (46, FontWeight.w800, 1.0),
      ]);
      expect(t.kidJob(ink).fontFamily, DenType.family);
      expect(t.kidJob(ink).fontVariations, [const FontVariation.weight(800)], reason: 'the variable font moves its axis too');
    });

    test('the wall scales them like every other role', () {
      expect(const DenText(DenType.wallScale).kidJob(ink).fontSize, closeTo(26, 0.001));
    });
  });

  test("kids mode's shapes: radii 24 to 32, a solid lip, 64 or more to press", () {
    expect((Radii.kidTile, Radii.kidTileWall, Radii.kidCard, Radii.kidButton), (24, 32, 28, 24));
    expect((Lip.tile, Lip.card, Lip.wall), (6, 4, 8));
    expect(KidLayout.minTarget, greaterThanOrEqualTo(64));
    expect(KidLayout.tileMinHeight, greaterThanOrEqualTo(136));
    expect(KidLayout.readBarHeight, greaterThanOrEqualTo(Targets.kid));
    expect((KidLayout.gridGap, KidLayout.tilePadding, KidLayout.sectionGap), (16, 16, 20));
    expect((KidLayout.wallMargin, KidLayout.wallColumnGap, KidLayout.wallTileGap), (64, 48, 22));
  });
}
