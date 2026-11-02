import 'package:den_app/design/layout.dart';
import 'package:den_app/features/settings/screens/settings_screen.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'calendar_shots.dart';
import 'family_fakes.dart';

/// The system text size that, times Largest, reaches the most Den draws: 200 %.
final double _systemForMax = DenLayout.maxTextScale / TextSize.largest.factor;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('The text size setting', () {
    test("multiplies the system's size and stops at 200 %", () {
      expect(DenTextScale.combined(1, TextSize.standard), 1);
      expect(DenTextScale.combined(1, TextSize.larger), closeTo(20 / 17, 1e-9));
      expect(DenTextScale.combined(1, TextSize.largest), closeTo(23 / 17, 1e-9));
      expect(DenTextScale.combined(1.5, TextSize.largest), DenLayout.maxTextScale);
      expect(DenTextScale.combined(3.1, TextSize.standard), DenLayout.maxTextScale, reason: "iOS's largest sizes stop at 200 %");
      expect(DenTextScale.combined(0.85, TextSize.standard), 0.85, reason: 'a smaller system size is kept');
    });

    testWidgets('Settings, Text size: a short sheet, one tap makes text larger, and this device remembers it', (tester) async {
      final state = await demoIn(tester);
      await pumpScreen(tester, const SettingsScreen(version: '1.0.0'), state: state, pushed: true);
      await tester.tap(find.text('Text size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Largest'));
      await tester.pumpAndSettle();
      await matchShot('settings_text_size_phone');
      expect(state.textSize, TextSize.largest);
      expect(find.text('Largest'), findsOneWidget, reason: 'the row says the size now');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('den.textSize'), 'largest');
      final text = tester.element(find.text('Text size'));
      expect(MediaQuery.textScalerOf(text).scale(1), closeTo(23 / 17, 1e-9));
    });

    testWidgets('it rides on the system size: 148 % and Largest is 200 %', (tester) async {
      final state = await demoIn(tester);
      state.textSize = TextSize.largest;
      await shootAt(tester, 'today_phone_largest', state: state, location: '/today', text: _systemForMax, size: tallPhone);
      expect(MediaQuery.textScalerOf(tester.element(find.text('Today').first)).scale(1), closeTo(2, 1e-9));
    });
  });

  group('Shots keep the text size a test set', () {
    testWidgets('withTextScale reaches a shot that names no size of its own', (tester) async {
      final state = await demoIn(tester);
      withTextScale(tester, 2);
      await pumpCalendar(tester, const Text('Words'), state: state);
      expect(MediaQuery.textScalerOf(tester.element(find.text('Words'))).scale(1), 2);
    });

    testWidgets('a shot that names another size after withTextScale fails, rather than quietly winning', (tester) async {
      final state = await demoIn(tester);
      withTextScale(tester, 2);
      expect(() => systemText(tester, 1.35, state: state, child: const SizedBox()), throwsStateError);
      expect(systemText(tester, 2, state: state, child: const SizedBox()), isA<Widget>(), reason: 'the same size is fine');
    });
  });

  group('Every screen at the most text Den draws (the system size times Largest, 200 %)', () {
    Future<void> at(WidgetTester tester, String location, {Size size = phone, String? base}) async {
      final state = await demoIn(tester);
      state.textSize = TextSize.largest;
      final den = state.den;
      String id(String name) => den.members.firstWhere((m) => m.name == name).id;
      final resolved = location
          .replaceAll('{leo}', id('Leo'))
          .replaceAll('{event}', findEvent(state, 'Soccer').event.id)
          .replaceAll('{chore}', den.chores.firstWhere((c) => c.title == 'Dishes').id)
          .replaceAll('{groceries}', den.lists.firstWhere((l) => l.list.kind == ListKind.shopping).list.id)
          .replaceAll('{reward}', den.rewards.first.id);
      await pumpAt(tester, state: state, location: resolved, base: base, size: size, text: _systemForMax);
      expect(tester.takeException(), isNull);
    }

    const phoneRoutes = [
      '/today',
      '/calendar',
      '/chores',
      '/lists',
      '/lists/{groceries}',
      '/lists/new',
      '/family',
      '/family/member/{leo}',
      '/points',
      '/points/goal/new',
      '/points/reward/new',
      '/points/reward/{reward}',
      '/event/{event}',
      '/event/new',
      '/chore/{chore}',
      '/chore/new',
      '/chore/{chore}/edit',
      '/settings',
      '/settings/family',
      '/settings/calendars',
      '/settings/advanced',
      '/settings/advanced/hub',
      '/settings/advanced/displays',
      '/settings/advanced/data',
      '/settings/connections',
      '/settings/home-assistant',
      '/history',
      '/search?q=ma',
    ];
    for (final route in phoneRoutes) {
      testWidgets('phone: $route', (tester) => at(tester, route));
    }
    for (final route in const ['/today', '/calendar', '/chores', '/lists', '/family', '/history']) {
      testWidgets('iPad: $route', (tester) => at(tester, route, size: tablet));
    }
  });
}
