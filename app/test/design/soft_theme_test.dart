import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/den_app.dart';
import 'package:den_app/app/family_colors.dart';
import 'package:den_app/design/day_theme.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';

/// What [context] draws with, read from inside the tree.
DenColors _seen(WidgetTester tester, Finder at) => tester.element(at).colors;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('each choice: its tokens by day and at night, and whether it follows the device', () {
    expect([for (final t in ThemeChoice.values) (t.light, t.dark, t.mode)], [
      (DenColors.day, DenColors.night, ThemeMode.system),
      (DenColors.day, DenColors.night, ThemeMode.light),
      (DenColors.day, DenColors.night, ThemeMode.dark),
      (DenColors.softDay, DenColors.softNight, ThemeMode.system),
    ]);
  });

  test('Soft is kept on this device: a restart reads it back', () async {
    final prefs = await DevicePrefs.load();
    expect(prefs.theme, ThemeChoice.auto);
    prefs.theme = ThemeChoice.soft;
    await Future<void>.delayed(Duration.zero);
    expect((await SharedPreferences.getInstance()).getString('den.theme'), 'soft');
    expect((await DevicePrefs.load()).theme, ThemeChoice.soft);
  });

  test('an older build ignores a choice it does not know, and a newer name reads as Auto', () async {
    SharedPreferences.setMockInitialValues({'den.theme': 'sepia'});
    expect((await DevicePrefs.load()).theme, ThemeChoice.auto);
  });

  group('the family colors under Soft', () {
    Future<void> pumpUnder(WidgetTester tester, AppState state, DenColors theme) => tester.pumpWidget(
          DenScope(
            state: state,
            child: MaterialApp(
              theme: denTheme(theme),
              builder: (context, child) => FamilyColors(child: child!),
              home: const Scaffold(body: SizedBox(key: Key('probe'))),
            ),
          ),
        );

    testWidgets('before a parent picks a pack, Soft draws the Soft pack and Day draws Bright', (tester) async {
      final state = await demoIn(tester);
      expect(state.den.family!.rec.fields['colors'], isNull, reason: 'the demo family never picked one');
      await pumpUnder(tester, state, DenColors.softDay);
      expect(_seen(tester, find.byKey(const Key('probe'))).pack, ColorPack.soft);
      await pumpUnder(tester, state, DenColors.day);
      await tester.pumpAndSettle();
      expect(_seen(tester, find.byKey(const Key('probe'))).pack, ColorPack.bright);
      expect(familyPack(state.den.family, DenPalette.soft), ColorPack.soft);
    });

    testWidgets('a pack the family picked stays, in Soft too', (tester) async {
      final state = await demoIn(tester);
      await tester.runAsync(() => state.den.updateFamily({'colors': 'deep'}));
      await pumpUnder(tester, state, DenColors.softNight);
      expect(_seen(tester, find.byKey(const Key('probe'))).pack, ColorPack.deep);
      await tester.runAsync(() => state.den.updateFamily({'colors': 'bright'}));
      await tester.pump();
      expect(_seen(tester, find.byKey(const Key('probe'))).pack, ColorPack.bright, reason: 'Bright picked is kept, not defaulted');
    });
  });

  testWidgets('a calendar kept light is Soft by day in Soft, and Day otherwise', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: denTheme(DenColors.softNight),
        home: const Scaffold(body: DayTheme(child: SizedBox(key: Key('soft')))),
      ),
    );
    final soft = _seen(tester, find.byKey(const Key('soft')));
    expect((soft.palette, soft.brightness, soft.bg), (DenPalette.soft, Brightness.light, DenColors.softDay.bg));
    await tester.pumpWidget(
      MaterialApp(
        theme: denTheme(DenColors.night),
        home: const Scaffold(body: DayTheme(child: SizedBox(key: Key('day')))),
      ),
    );
    await tester.pumpAndSettle();
    expect(_seen(tester, find.byKey(const Key('day'))).bg, DenColors.day.bg);
  });

  testWidgets('Day to Soft to Night: the colors move between themes and the screen keeps its state', (tester) async {
    final state = await demoIn(tester);
    state.theme = ThemeChoice.day;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(DenApp(state: state));
    await tester.pumpAndSettle();
    final screen = find.byType(Scaffold).first;
    final element = tester.element(screen);
    expect(_seen(tester, screen).bg, DenColors.day.bg);

    state.theme = ThemeChoice.soft;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final between = _seen(tester, screen).bg;
    expect(between, isNot(DenColors.day.bg), reason: 'it is moving');
    expect(between, isNot(DenColors.softDay.bg), reason: 'and not there yet: no jump');
    await tester.pumpAndSettle();
    expect(_seen(tester, screen).bg, DenColors.softDay.bg);
    expect(_seen(tester, screen).palette, DenPalette.soft);
    expect(_seen(tester, screen).pack, ColorPack.soft, reason: 'the demo family never picked a pack');

    state.theme = ThemeChoice.night;
    await tester.pumpAndSettle();
    expect(_seen(tester, screen).bg, DenColors.night.bg);
    expect(tester.element(screen), same(element), reason: 'the same screen, never rebuilt from scratch');
  });

  testWidgets('Soft follows the device: Soft at night when the device is dark', (tester) async {
    final state = await demoIn(tester);
    state.theme = ThemeChoice.soft;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(DenApp(state: state));
    await tester.pumpAndSettle();
    final seen = _seen(tester, find.byType(Scaffold).first);
    expect((seen.bg, seen.card, seen.palette), (DenColors.softNightGround, DenColors.softNight.card, DenPalette.soft));
  });
}
