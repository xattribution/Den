import 'package:den_app/features/chores/screens/chore_detail.dart';
import 'package:den_app/features/chores/screens/chore_editor.dart';
import 'package:den_app/features/chores/screens/chores_board.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'chores_shots.dart';

String _chore(AppState state, String title) => state.den.chores.firstWhere((c) => c.title == title).id;

/// Lets the sheet close on the test's clock, then the write it started finish on the real one.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('Chores board, phone, day', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_board_phone',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      size: tall,
    );
  });

  testWidgets('Chores board, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_board_phone_night',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      night: true,
    );
  });

  testWidgets('Chores board, yesterday, phone', (tester) async {
    final state = await demo(tester);
    final yesterday = state.formats.addDays(state.den.todayDate(), -1);
    await shoot(tester, 'chores_board_yesterday_phone', ChoresBoard(date: yesterday), state: state);
  });

  testWidgets('Chores board, tablet columns', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_board_tablet',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      size: tablet,
    );
  });

  testWidgets('Chores board, tablet columns, night', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_board_tablet_night',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      size: tablet,
      night: true,
    );
  });

  testWidgets('Chores board on the wall', (tester) async {
    final state = await demo(tester, wall: true);
    await shoot(
      tester,
      'chores_board_wall',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      size: wall,
      night: true,
    );
  });

  testWidgets('Chores board, a kid\'s phone', (tester) async {
    final state = await kidDemo(tester, 'Leo');
    await shoot(
      tester,
      'chores_board_kid_phone',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      size: tall,
    );
  });

  testWidgets('Chores tab inside the shell, tablet', (tester) async {
    final state = await demo(tester);
    await shootPath(tester, 'chores_tab_shell_tablet', '/chores', state: state, size: tablet);
  });

  testWidgets('Chores tab inside the shell, phone, tomorrow', (tester) async {
    final state = await demo(tester);
    final tomorrow = state.formats.addDays(state.den.todayDate(), 1);
    await shootPath(tester, 'chores_tab_shell_phone', '/chores?date=$tomorrow', state: state);
  });

  testWidgets('A chore opens in place: its steps, Give to… and Details', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'chores_board_open_phone',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      size: tall,
      act: (tester) async {
        await tester.tap(findWords('Clean the kitchen'));
        await tester.pumpAndSettle();
        expect(find.text('Details'), findsOneWidget);
      },
    );
  });

  testWidgets('Give to… from a row: the people sheet, then the row says what it did, with Undo', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'chores_give_sheet_phone',
      ChoresBoard(date: state.den.todayDate()),
      state: state,
      size: tall,
      act: (tester) async {
        await tester.tap(find.text('Give to…').first);
        await tester.pumpAndSettle();
        expect(find.text('Anyone'), findsWidgets);
      },
    );
    ChoreDay day(String title) => state.den.today().chores.firstWhere((d) => d.chore.title == title);
    final first = state.den.today().chores.firstWhere((d) => !d.done && d.owner != null);
    final title = first.chore.title;
    final owner = first.owner;
    await tester.tap(find.text('Anyone').last);
    await settle(tester);
    expect(state.den.today().chores.where((d) => d.chore.id == first.chore.id && d.owner == null), isNotEmpty);
    expect(findWords('Anyone can do $title today'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(day(title).owner, owner);
  });

  testWidgets('Chore detail with step owners, phone', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_detail_steps_phone',
      ChoreDetailScreen(id: _chore(state, 'Clean the kitchen'), date: state.den.todayDate()),
      state: state,
      size: tall,
    );
  });

  testWidgets('Chore detail, rotation, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_detail_rotation_phone_night',
      ChoreDetailScreen(id: _chore(state, 'Dishes'), date: state.den.todayDate()),
      state: state,
      night: true,
    );
  });

  testWidgets('Chore detail, done today, tablet', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_detail_done_tablet',
      ChoreDetailScreen(id: _chore(state, 'Feed the cat'), date: state.den.todayDate()),
      state: state,
      size: tablet,
    );
  });

  testWidgets('Chore detail on a day it is not on the chart', (tester) async {
    final state = await demo(tester);
    final tomorrow = state.formats.addDays(state.den.todayDate(), 1);
    await shoot(
      tester,
      'chores_detail_unscheduled_phone',
      ChoreDetailScreen(id: _chore(state, 'Take out the trash'), date: tomorrow),
      state: state,
    );
  });

  testWidgets('New chore, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'chores_editor_new_phone', const ChoreEditorScreen(), state: state, size: tall);
  });

  testWidgets('Edit chore with steps, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'chores_editor_edit_phone_night',
      ChoreEditorScreen(id: _chore(state, 'Clean the kitchen')),
      state: state,
      size: const Size(390, 2100),
      night: true,
    );
  });

  testWidgets('New chore taking turns on chosen days, phone', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'chores_editor_turns_phone',
      const ChoreEditorScreen(),
      state: state,
      size: tall,
      act: (tester) async {
        await tester.enterText(find.byType(TextField).first, 'Water the plants');
        await tester.tap(find.text('Take turns'));
        await tester.pumpAndSettle();
        for (final name in ['Maya', 'Leo', 'Zoe']) {
          await tester.tap(find.text(name).first);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Chosen days'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tue'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sat'));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
      },
    );
  });

  testWidgets('New chore with missing answers, phone', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'chores_editor_errors_phone',
      const ChoreEditorScreen(),
      state: state,
      act: (tester) async {
        await tester.tap(find.text('Add chore'));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
      },
    );
  });
}
