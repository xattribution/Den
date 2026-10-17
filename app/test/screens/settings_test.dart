import 'package:den_app/screens/settings/connections_screen.dart';
import 'package:den_app/screens/settings/create_token_screen.dart';
import 'package:den_app/screens/settings/home_assistant_screen.dart';
import 'package:den_app/screens/settings/settings_screen.dart';
import 'package:den_app/state/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// A demo family with a Home Assistant token, a kid's homework helper and a pending Claude request.
Future<AppState> connected(WidgetTester tester) => real(tester, () async {
      final state = await demoState();
      final den = state.den;
      final kid = kidOf(state);
      await den.addTokenConnection(label: 'Home Assistant', scopes: {Scope.read, Scope.calendar, Scope.chores, Scope.lists});
      await den.addTokenConnection(label: 'Homework helper', scopes: {Scope.read, Scope.lists}, member: kid.id);
      await den.requestOAuthConnection(label: 'Claude', client: 'claude.ai', scopes: {Scope.read, Scope.calendar, Scope.lists});
      return state;
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Settings, phone, day', (tester) async {
    final state = await connected(tester);
    await shootWith(tester, 'settings_phone', const SettingsScreen(version: '1.0.0'), state: state);
  });

  testWidgets('Settings, scrolled, night', (tester) async {
    final state = await connected(tester);
    await pumpScreen(tester, const SettingsScreen(version: '1.0.0'), state: state, night: true);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await matchShot('settings_lower_phone_night');
  });

  testWidgets('Settings, tablet', (tester) async {
    final state = await connected(tester);
    await shootWith(tester, 'settings_tablet', const SettingsScreen(version: '1.0.0'), state: state, size: tablet);
  });

  testWidgets('AI and automations, phone', (tester) async {
    final state = await connected(tester);
    await shootWith(tester, 'settings_connections_phone', const ConnectionsScreen(), state: state);
  });

  testWidgets('AI and automations, night', (tester) async {
    final state = await connected(tester);
    await shootWith(tester, 'settings_connections_phone_night', const ConnectionsScreen(), state: state, night: true);
  });

  testWidgets('Approving a request narrows scopes', (tester) async {
    final state = await connected(tester);
    await pumpScreen(tester, const ConnectionsScreen(), state: state);
    await tester.tap(find.text('Approve Claude'));
    await tester.pumpAndSettle();
    await matchShot('settings_connection_approve_phone');
  });

  testWidgets('Create token, phone', (tester) async {
    final state = await demo(tester);
    await pumpScreen(tester, const CreateTokenScreen(), state: state);
    await tester.enterText(find.widgetWithText(TextField, 'Label'), 'Home Assistant');
    await tester.pumpAndSettle();
    await matchShot('settings_create_token_phone');
  });

  testWidgets('Token shown once, phone', (tester) async {
    final state = await demo(tester);
    await shootWith(
      tester,
      'settings_token_once_phone',
      const CreateTokenScreen(token: 'den_7Kq2mX9vB4nR8wT1pL6sY3hF0cJ5gD2a', label: 'Home Assistant'),
      state: state,
    );
  });

  testWidgets('Home Assistant, phone', (tester) async {
    final state = await connected(tester);
    await shootWith(tester, 'settings_home_assistant_phone', const HomeAssistantScreen(), state: state);
  });
}
