import 'package:den_app/app/den_app.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_app/platform/sync/pairing.dart';
import 'package:den_app/features/onboarding/screens/add_people_screen.dart';
import 'package:den_app/features/onboarding/screens/join_screen.dart';
import 'package:den_app/features/onboarding/screens/start_family_screen.dart';
import 'package:den_app/features/onboarding/screens/waiting_screen.dart';
import 'package:den_app/features/onboarding/screens/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

void main() {
  testWidgets('Welcome, phone, day', (tester) async {
    await shootWith(tester, 'onboarding_welcome_phone', const WelcomeScreen(), state: await empty(tester));
  });

  testWidgets('Welcome, phone, night', (tester) async {
    await shootWith(tester, 'onboarding_welcome_phone_night', const WelcomeScreen(), state: await empty(tester), night: true);
  });

  testWidgets('Welcome, tablet', (tester) async {
    await shootWith(tester, 'onboarding_welcome_tablet', const WelcomeScreen(), state: await empty(tester), size: tablet);
  });

  testWidgets('Start a family, phone', (tester) async {
    final state = await empty(tester);
    await pumpScreen(tester, const StartFamilyScreen(initialTimeZone: 'America/Chicago'), state: state);
    await tester.enterText(find.widgetWithText(TextField, 'Family name'), 'The Riveras');
    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Sam');
    await tester.pumpAndSettle();
    await matchShot('onboarding_start_phone');
  });

  testWidgets('Start a family, missing names', (tester) async {
    final state = await empty(tester);
    await pumpScreen(tester, const StartFamilyScreen(initialTimeZone: 'America/Chicago'), state: state, night: true);
    await tester.tap(find.text('Create family'));
    await tester.pumpAndSettle();
    await matchShot('onboarding_start_phone_night_errors');
  });

  testWidgets('Add people after starting', (tester) async {
    final state = await demo(tester);
    await shootWith(tester, 'onboarding_people_phone', const AddPeopleScreen(), state: state);
  });

  testWidgets('Add a kid sheet', (tester) async {
    final state = await demo(tester);
    await pumpScreen(tester, const AddPeopleScreen(), state: state);
    await tester.tap(find.text('Add a kid'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Ava');
    await tester.pumpAndSettle();
    await matchShot('onboarding_add_kid_phone');
  });

  testWidgets('Join by code, phone', (tester) async {
    final state = await empty(tester);
    await shootWith(tester, 'onboarding_join_phone', const JoinScreen(scan: false), state: state);
  });

  testWidgets('Join without a hub says so', (tester) async {
    final state = await empty(tester);
    await pumpScreen(tester, const JoinScreen(scan: false), state: state);
    await tester.enterText(find.widgetWithText(TextField, 'Device name (optional)'), "Leo's iPad");
    await tester.enterText(find.widgetWithText(TextField, 'The four words'), 'maple river candle tiger');
    await tester.tap(find.text('Join the family'));
    await tester.pumpAndSettle();
    expect(find.text(LocalOnlyPairing.message), findsOneWidget);
    await matchShot('onboarding_join_no_hub_phone');
  });

  testWidgets('Waiting for approval with matching words', (tester) async {
    final state = await empty(tester);
    await shootWith(
      tester,
      'onboarding_waiting_phone',
      const WaitingScreen(ticket: JoinTicket(familyId: 'F', inviterName: "Sam's phone", words: ['maple', 'river', 'candle'])),
      state: state,
    );
  });

  testWidgets('Waiting, declined, night', (tester) async {
    final state = await empty(tester);
    await shootWith(
      tester,
      'onboarding_waiting_declined_phone_night',
      const WaitingScreen(ticket: JoinTicket(familyId: 'F', words: ['maple', 'river', 'candle'])),
      state: state,
      night: true,
      pairing: FakePairing(now: demoNow, status: const JoinStatus(JoinState.declined, message: "Sam's phone declined this device.")),
    );
  });

  testWidgets('No family sends the app to Welcome', (tester) async {
    final state = await empty(tester);
    await shootRoute(tester, 'onboarding_route_welcome_phone', buildRouter(state), state: state);
    expect(find.text('Set up Den'), findsOneWidget);
  });

  testWidgets('Creating a family moves on to Add people', (tester) async {
    final state = await empty(tester);
    final router = buildRouter(state);
    await loadFonts();
    await tester.pumpWidget(
      DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: router)),
    );
    await tester.pumpAndSettle();
    router.go('/welcome/start');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Family name'), 'The Riveras');
    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Sam');
    await tester.tap(find.text('Create family'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(state.den.family?.name, 'The Riveras');
    expect(find.text('Add people'), findsOneWidget);
    expect(find.text('Sam (you)'), findsOneWidget);
  });
}

