import 'package:den_app/features/rewards/screens/adjust_screen.dart';
import 'package:den_app/features/rewards/screens/goal_editor.dart';
import 'package:den_app/features/rewards/screens/points_screen.dart';
import 'package:den_app/features/rewards/screens/reward_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'chores_shots.dart';

/// Lets a sheet close on the test's clock, then the write it started finish on the real one.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }
}

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

  testWidgets('A goal from an older app\'s race opens as the one kind there is, phone, night', (tester) async {
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

  testWidgets('Approve in place, then Undo', (tester) async {
    final state = await demo(tester);
    final request = state.den.points().pending.first;
    await shootAfter(
      tester,
      'points_approved_phone',
      const PointsScreen(),
      state: state,
      size: const Size(390, 2200),
      act: (tester) async {
        await tester.tap(find.text('Approve').first);
        await settle(tester);
      },
    );
    expect(state.den.points().pending.where((r) => r.id == request.id), isEmpty);
    expect(find.textContaining('approved for'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(state.den.points().pending.where((r) => r.id == request.id), hasLength(1));
  });

  testWidgets('Give points: the sheet, then what it gave with Undo', (tester) async {
    final state = await demo(tester);
    final kid = state.den.members.firstWhere((m) => m.isKid);
    final before = state.den.points().totals[kid.id] ?? 0;
    await shootAfter(
      tester,
      'points_give_sheet_phone',
      const PointsScreen(),
      state: state,
      size: const Size(390, 1200),
      act: (tester) async {
        await tester.tap(find.text('Give points'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kid.name).last);
        await tester.tap(find.text('5').last);
        await tester.enterText(find.byType(TextField).last, 'Helped with the groceries');
        await tester.pumpAndSettle();
      },
    );
    await tester.tap(find.text('Give ${kid.name} 5 stars'));
    await settle(tester);
    expect(state.den.points().totals[kid.id], before + 5);
    expect(findWords('Gave ${kid.name} 5 stars'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(state.den.points().totals[kid.id], before);
  });

  testWidgets('New reward, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'points_reward_new_phone', const RewardEditorScreen(), state: state, size: tall);
  });
}
