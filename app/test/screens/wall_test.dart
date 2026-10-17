import 'package:den_app/app.dart';
import 'package:den_app/design/parts/family_sign_in.dart';
import 'package:den_app/design/theme.dart';
import 'package:den_app/design/tokens.dart';
import 'package:den_app/screens/wall/wall_screen.dart';
import 'package:den_app/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

void main() {
  WallScreen wallAt() => WallScreen(now: () => demoNow, keepAwake: false);

  testWidgets('Wall, 1080p, day', (tester) async {
    final state = await kitchen(tester);
    await shoot(tester, 'wall_1080p', wallAt(), state: state, size: wall);
  });

  testWidgets('Wall, 1080p, night', (tester) async {
    final state = await kitchen(tester);
    await shoot(tester, 'wall_1080p_night', wallAt(), state: state, size: wall, night: true);
  });

  testWidgets('Wall, Today layout, 1080p', (tester) async {
    final state = await kitchen(tester, layout: 'today');
    await shoot(tester, 'wall_today_1080p', wallAt(), state: state, size: wall);
  });

  testWidgets('Wall, tablet landscape', (tester) async {
    final state = await demo(tester, wall: true);
    await shoot(tester, 'wall_tablet', wallAt(), state: state, size: tablet);
  });

  testWidgets('Wall, phone portrait', (tester) async {
    final state = await demo(tester, wall: true);
    await shoot(tester, 'wall_phone', wallAt(), state: state);
  });

  testWidgets('Wall while someone is acting', (tester) async {
    final state = await kitchen(tester);
    state.den.actAs(kidOf(state).id);
    await shoot(tester, 'wall_acting_1080p', wallAt(), state: state, size: wall);
    state.den.actAs(null);
  });

  testWidgets("Who's doing this?", (tester) async {
    final state = await demo(tester, wall: true);
    await pumpScreen(
      tester,
      Builder(
        builder: (context) => Center(
          child: FilledButton(onPressed: () => showWhoSheet(context), child: const Text('Open')),
        ),
      ),
      state: state,
      size: tablet,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await matchShot('wall_who_sheet_tablet');
  });

  testWidgets('Use as wall display sends Today to the wall', (tester) async {
    final state = await demo(tester, wall: true);
    await tester.pumpWidget(
      DenScope(state: state, child: MaterialApp.router(theme: denTheme(DenColors.day), routerConfig: buildRouter(state))),
    );
    await tester.pump();
    expect(find.byType(WallScreen), findsOneWidget);
  });
}
