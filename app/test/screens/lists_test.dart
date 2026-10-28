import 'package:den_app/features/add/screens/grocery_add.dart';
import 'package:den_app/features/lists/screens/list_detail.dart';
import 'package:den_app/features/lists/screens/list_editor.dart';
import 'package:den_app/features/lists/words/list_words.dart';
import 'package:den_app/features/lists/screens/lists_index.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'chores_shots.dart';

String _groceries(AppState state) => groceriesList(state.den)!.list.id;

String _kind(AppState state, ListKind kind) => state.den.lists.firstWhere((l) => l.list.kind == kind).list.id;

void main() {
  testWidgets('Lists, phone, day', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_index_phone', const ListsIndex(), state: state);
  });

  testWidgets('Lists, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_index_phone_night', const ListsIndex(), state: state, night: true);
  });

  testWidgets('Lists, tablet', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_index_tablet', const ListsIndex(), state: state, size: tablet);
  });

  testWidgets('Groceries, phone, day', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_groceries_phone', ListDetailScreen(id: _groceries(state)), state: state);
  });

  testWidgets('Groceries, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'lists_groceries_phone_night',
      ListDetailScreen(id: _groceries(state)),
      state: state,
      night: true,
    );
  });

  testWidgets('Groceries by store, phone', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'lists_groceries_by_store_phone',
      ListDetailScreen(id: _groceries(state)),
      state: state,
      size: tall,
      act: (tester) async {
        await tester.tap(find.text('By store'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('Groceries at one store, tablet', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'lists_groceries_store_tablet',
      ListDetailScreen(id: _groceries(state)),
      state: state,
      size: tablet,
      act: (tester) async {
        await tester.tap(find.text('Target').first);
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('Share sheet with QR code', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'lists_share_sheet_phone',
      ListDetailScreen(id: _groceries(state)),
      state: state,
      act: (tester) async {
        await tester.tap(find.byTooltip('Share list'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('Edit an item, phone', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'lists_item_sheet_phone',
      ListDetailScreen(id: _groceries(state)),
      state: state,
      act: (tester) async {
        await tester.longPress(find.text('Toothpaste'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('Grocery quick add, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_grocery_add_phone', const GroceryAddScreen(), state: state);
  });

  testWidgets('Packing list for an event, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_packing_phone', ListDetailScreen(id: _kind(state, ListKind.packing)), state: state);
  });

  testWidgets('Meal plan, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_meal_phone', ListDetailScreen(id: _kind(state, ListKind.meal)), state: state);
  });

  testWidgets('Dated checklist, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'lists_dated_phone_night',
      ListDetailScreen(id: _kind(state, ListKind.checklist)),
      state: state,
      night: true,
    );
  });

  testWidgets('New list, phone', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_editor_new_phone', const ListEditorScreen(), state: state);
  });

  testWidgets('Edit list for an event, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(
      tester,
      'lists_editor_edit_phone_night',
      ListEditorScreen(id: _kind(state, ListKind.packing)),
      state: state,
      night: true,
    );
  });

  testWidgets('Lists tab inside the shell, phone', (tester) async {
    final state = await demo(tester);
    await shootPath(tester, 'lists_tab_shell_phone', '/lists', state: state);
  });
}
