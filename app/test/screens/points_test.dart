import 'package:den_app/features/rewards/screens/adjust_screen.dart';
import 'package:den_app/features/rewards/screens/goal_editor.dart';
import 'package:den_app/features/rewards/screens/points_screen.dart';
import 'package:den_app/features/rewards/screens/reward_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'chores_shots.dart';

void main() {
  testWidgets('Points, phone, day', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'points_phone', const PointsScreen(), state: state, size: const Size(390, 2200));
  });

  testWidgets('Points, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'points_phone_night', const PointsScreen(), state: state, night: true);
  });

  testWidgets('Points, tablet', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'points_tablet', const PointsScreen(), state: state, size: tablet);
  });

  testWidgets('Points on a kid\'s phone', (tester) async {
    final state = await kidDemo(tester, 'Maya');
    await shoot(tester, 'points_kid_phone', const PointsScreen(), state: state, size: const Size(390, 2000));
  });

  testWidgets('Points route from the menu, phone', (tester) async {
    final state = await demo(tester);
    await shootPath(tester, 'points_route_phone', '/points', state: state);
  });

  testWidgets('Give or take points, phone', (tester) async {
    final state = await demo(tester);
    final kid = state.den.members.firstWhere((m) => m.isKid);
    await shoot(tester, 'points_adjust_phone', AdjustScreen(member: kid.id), state: state);
  });

  testWidgets('Give points needs a reason', (tester) async {
    final state = await demo(tester);
    final kid = state.den.members.firstWhere((m) => m.isKid);
    await shootAfter(
      tester,
      'points_adjust_error_phone',
      AdjustScreen(member: kid.id),
      state: state,
      act: (tester) async {
        await tester.tap(find.byType(FilledButton).last);
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('New goal, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'points_goal_new_phone', const GoalEditorScreen(), state: state, size: tall);
  });

  testWidgets('Edit a race goal, phone, night', (tester) async {
    final state = await demo(tester);
    final race = state.den.points().goals.firstWhere((g) => g.goal.title == 'First to 25 stars');
    await shoot(
      tester,
      'points_goal_edit_phone_night',
      GoalEditorScreen(id: race.goal.id),
      state: state,
      size: tall,
      night: true,
    );
  });

  testWidgets('New reward, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'points_reward_new_phone', const RewardEditorScreen(), state: state, size: tall);
  });
}
