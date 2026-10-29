import 'package:den_app/features/lists/screens/grocery_add.dart';
import 'package:den_app/features/lists/screens/list_detail.dart';
import 'package:den_app/features/lists/screens/list_editor.dart';
import 'package:den_app/features/lists/words/list_words.dart';
import 'package:den_app/features/lists/screens/lists_index.dart';
import 'package:den_app/app/app_state.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/shots.dart';
import 'chores_shots.dart';
import 'family_fakes.dart' show pumpScreen;

String _groceries(AppState state) => groceriesList(state.den)!.list.id;

String _kind(AppState state, ListKind kind) => state.den.lists.firstWhere((l) => l.list.kind == kind).list.id;

/// Lets a write started on the test's clock finish on the real one, then the screen catch up.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }
}

void main() {
  group('The add field reads', () {
    test('a quantity up front, a store after @, and commas between things', () {
      final items = parseItems('2 milk @costco, eggs, 3 lb ground beef, paper towels x2', knownStores: const ['Costco']);
      expect(items, [
        (text: 'Milk', qty: '2', store: 'Costco'),
        (text: 'Eggs', qty: null, store: null),
        (text: 'Ground beef', qty: '3 lb', store: null),
        (text: 'Paper towels', qty: '2', store: null),
      ]);
    });

    test('a name that starts with a number stays whole', () {
      expect(parseItems('7up'), [(text: '7up', qty: null, store: null)]);
      expect(parseItems('  ,  '), isEmpty);
    });

    test('a store nobody uses yet keeps its words', () {
      expect(parseItems('bread @Corner Bakery'), [(text: 'Bread', qty: null, store: 'Corner Bakery')]);
    });
  });

  testWidgets('Lists, phone, day', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_index_phone', const ListsHome(), state: state, size: tall);
  });

  testWidgets('Lists, phone, night', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_index_phone_night', const ListsHome(), state: state, night: true);
  });

  testWidgets('Lists, iPad: the lists beside the chosen one', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_index_tablet', const ListsHome(), state: state, size: tablet);
  });

  testWidgets('Groceries, phone, day', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_groceries_phone', ListDetailScreen(id: _groceries(state)), state: state, size: tall);
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

  testWidgets('Groceries at one store, phone', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'lists_groceries_store_phone',
      ListDetailScreen(id: _groceries(state)),
      state: state,
      size: tall,
      act: (tester) async {
        await tester.tap(find.textContaining('Target ').first);
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('"2 milk @Costco, eggs" adds two things, and Undo takes both back', (tester) async {
    final state = await demo(tester);
    final id = _groceries(state);
    await shootAfter(
      tester,
      'lists_added_phone',
      ListDetailScreen(id: id),
      state: state,
      act: (tester) async {
        await tester.enterText(find.byType(TextField).first, '2 lemons @costco, cilantro');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
      },
    );
    final items = state.den.list(id)!.items;
    expect(items.where((i) => i.text == 'Lemons' && i.qty == '2' && i.store == 'Costco'), hasLength(1));
    expect(items.where((i) => i.text == 'Cilantro'), hasLength(1));
    expect(findWords('Added Lemons and Cilantro'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(state.den.list(id)!.items.where((i) => i.text == 'Lemons' || i.text == 'Cilantro'), isEmpty);
  });

  testWidgets('Something already on the list isn\'t added twice, whatever its case (MCP eval #10)', (tester) async {
    final state = await demo(tester);
    final id = _groceries(state);
    final open = state.den.list(id)!.items.firstWhere((i) => !i.checked && i.store == null);
    final before = state.den.list(id)!.items.length;
    await pumpScreen(tester, ListDetailScreen(id: id), state: state);
    await tester.enterText(find.byType(TextField).first, open.text.toLowerCase());
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(state.den.list(id)!.items, hasLength(before));
    expect(findWords('${open.text} is already on the list'), findsOneWidget);
  });

  testWidgets('Clear takes the done things off, and Undo brings them back in place', (tester) async {
    final state = await demo(tester);
    final id = _groceries(state);
    final done = state.den.list(id)!.items.where((i) => i.checked).length;
    expect(done, greaterThan(0));
    await shootAfter(
      tester,
      'lists_cleared_phone',
      ListDetailScreen(id: id),
      state: state,
      size: tall,
      act: (tester) async {
        await tester.tap(find.text('Clear $done'));
        await settle(tester);
      },
    );
    expect(state.den.list(id)!.items.where((i) => i.checked), isEmpty);
    expect(findWords('Cleared $done done ${done == 1 ? 'item' : 'items'}'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(state.den.list(id)!.items.where((i) => i.checked), hasLength(done));
  });

  testWidgets('More: Share, Copy, Reorder, Edit and Delete', (tester) async {
    final state = await demo(tester);
    await shootAfter(
      tester,
      'lists_menu_phone',
      ListDetailScreen(id: _groceries(state)),
      state: state,
      act: (tester) async {
        await tester.tap(find.byTooltip('More for Groceries'));
        await tester.pumpAndSettle();
        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Reorder'), findsOneWidget);
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
      size: tall,
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

  testWidgets('Meal plan: Add to groceries, then Undo in place', (tester) async {
    final state = await demo(tester);
    final meals = _kind(state, ListKind.meal);
    await shootAfter(
      tester,
      'lists_meal_phone',
      ListDetailScreen(id: meals),
      state: state,
      size: tall,
      act: (tester) async {
        await tester.tap(find.text('Add to groceries').first);
        await settle(tester);
        expect(find.text('On groceries'), findsWidgets);
      },
    );
    expect(state.den.list(meals)!.items.where((i) => i.toGroceries), isNotEmpty);
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
      size: tall,
      night: true,
    );
  });

  testWidgets('Lists tab inside the shell, phone', (tester) async {
    final state = await demo(tester);
    await shootPath(tester, 'lists_tab_shell_phone', '/lists', state: state);
  });

  testWidgets('At 200 % text the add field, chips and rows wrap', (tester) async {
    final state = await demo(tester);
    withTextScale(tester, 2);
    await shoot(tester, 'lists_groceries_phone_200', ListDetailScreen(id: _groceries(state)), state: state, size: const Size(390, 2600));
  });
}
