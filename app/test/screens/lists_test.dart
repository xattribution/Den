import 'package:den_app/features/lists/screens/grocery_add.dart';
import 'package:den_app/features/lists/screens/list_detail.dart';
import 'package:den_app/features/lists/screens/list_editor.dart';
import 'package:den_app/features/lists/words/list_words.dart';
import 'package:den_app/features/lists/screens/lists_index.dart';
import 'package:den_app/features/lists/widgets/item_adder.dart';
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

  testWidgets('Checking crosses an item off where it is, and a tap there takes it back', (tester) async {
    final state = await demo(tester);
    final id = _groceries(state);
    await pumpScreen(tester, ListDetailScreen(id: id), state: state, size: tall);
    final names = [for (final i in state.den.list(id)!.items) i.text];
    Map<String, Offset> where() => {for (final n in names) n: tester.getTopLeft(findWords(n))};
    final before = where();
    expect(find.text('In the cart'), findsNothing, reason: 'checked things aren\'t collected at the bottom');

    await tester.tap(findWords('Eggs'));
    await settle(tester);
    final eggs = state.den.list(id)!.items.firstWhere((i) => i.text == 'Eggs');
    expect(eggs.checked, isTrue);
    expect(where(), before, reason: 'nothing moved');
    final struck = tester.widget<Text>(findWords('Eggs'));
    expect(struck.style?.decoration, TextDecoration.lineThrough);
    expect(find.text('Clear checked (4)'), findsOneWidget);

    // A mistap is one more tap in the same place.
    await tester.tap(findWords('Eggs'));
    await settle(tester);
    expect(state.den.list(id)!.items.firstWhere((i) => i.text == 'Eggs').checked, isFalse);
    expect(where(), before);
    expect(find.text('Clear checked (3)'), findsOneWidget);
  });

  testWidgets('Clear checked takes the checked things off, and Undo brings them back in place', (tester) async {
    final state = await demo(tester);
    final id = _groceries(state);
    final done = state.den.list(id)!.items.where((i) => i.checked).length;
    expect(done, greaterThan(0));
    await shootAfter(
      tester,
      'lists_cleared_phone',
      ListDetailScreen(id: id),
      state: state,
      act: (tester) async {
        // Floating at the bottom of the screen, wherever the list is scrolled.
        final clear = find.text('Clear checked ($done)');
        expect(tester.getBottomLeft(clear).dy, greaterThan(phone.height - 80));
        await tester.tap(clear);
        await settle(tester);
      },
    );
    expect(state.den.list(id)!.items.where((i) => i.checked), isEmpty);
    expect(findWords('Cleared $done checked ${done == 1 ? 'item' : 'items'}'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(state.den.list(id)!.items.where((i) => i.checked), hasLength(done));
    expect(find.text('Clear checked ($done)'), findsOneWidget);
  });

  testWidgets('Clear checked on the iPad, over the chosen list', (tester) async {
    final state = await demo(tester);
    await shoot(tester, 'lists_index_tablet_night', const ListsHome(), state: state, size: tablet, night: true);
    final clear = find.text('Clear checked (3)');
    expect(clear, findsOneWidget);
    expect(tester.getTopLeft(clear).dx, greaterThan(tablet.width / 2), reason: 'in the chosen list\'s column');
  });

  testWidgets('New things go to the store showing, the chip stays as picked, and "@" moves it', (tester) async {
    final state = await demo(tester);
    final id = _groceries(state);
    await pumpScreen(tester, ListDetailScreen(id: id), state: state, size: tall);
    final chip = find.byType(StoreChip);
    String chipSays() => tester.widget<StoreChip>(chip).store ?? 'Any store';
    final add = find.byType(TextField).first;
    Item item(String text) => state.den.list(id)!.items.firstWhere((i) => i.text == text);
    Future<void> type(String text) async {
      await tester.enterText(add, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
    }

    expect(chipSays(), 'Any store');
    await tester.tap(find.text('Costco 4'));
    await tester.pumpAndSettle();
    expect(chipSays(), 'Costco', reason: 'it follows the store showing');

    await type('lemons');
    expect(item('Lemons').store, 'Costco');
    expect(findWords('Added Lemons at Costco'), findsOneWidget);
    final focus = tester.widget<EditableText>(find.descendant(of: add, matching: find.byType(EditableText))).focusNode;
    expect(focus.hasFocus, isTrue, reason: 'the field keeps the keyboard for the next thing');

    await type('bread');
    expect(item('Bread').store, 'Costco', reason: 'the choice stays');
    expect(focus.hasFocus, isTrue);

    await type('tape @target');
    expect(item('Tape').store, 'Target');
    expect(chipSays(), 'Target', reason: '"@" moves the chip');
    await type('socks');
    expect(item('Socks').store, 'Target');
  });

  testWidgets('The store picker: a store the family uses, or a new one by name', (tester) async {
    final state = await demo(tester);
    final id = _groceries(state);
    Item item(String text) => state.den.list(id)!.items.firstWhere((i) => i.text == text);
    await shootAfter(
      tester,
      'lists_store_picker_phone',
      ListDetailScreen(id: id),
      state: state,
      act: (tester) async {
        await tester.tap(find.byType(StoreChip));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New store…'));
        await tester.pumpAndSettle();
      },
    );
    expect(find.text('Trader Joe\'s'), findsWidgets);
    await tester.enterText(find.widgetWithText(TextField, 'Store name'), 'corner bakery');
    await tester.tap(find.text('Add store'));
    await tester.pumpAndSettle();
    expect(tester.widget<StoreChip>(find.byType(StoreChip)).store, 'corner bakery');
    expect(find.text('New store…').hitTestable(), findsNothing, reason: 'the picker closes');
    await tester.enterText(find.byType(TextField).first, 'rye bread');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(item('Rye bread').store, 'corner bakery');

    // A store the family already uses keeps its spelling.
    await tester.tap(find.byType(StoreChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New store…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Store name'), 'costco');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.widget<StoreChip>(find.byType(StoreChip)).store, 'Costco');

    await tester.tap(find.byType(StoreChip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any store').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'apples');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(item('Apples').store, isNull);
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
