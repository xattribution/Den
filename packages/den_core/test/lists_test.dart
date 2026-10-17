import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/order_keys.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('order keys', () {
    test('there is always a key between two keys, and they sort as placed', () {
      final random = Random(42);
      final keys = <String>[];
      for (var i = 0; i < 2000; i++) {
        final at = random.nextInt(keys.length + 1);
        final key = keyBetween(at == 0 ? null : keys[at - 1], at == keys.length ? null : keys[at]);
        expect(isOrderKey(key), isTrue, reason: key);
        if (at > 0) expect(keys[at - 1].compareTo(key), lessThan(0));
        if (at < keys.length) expect(key.compareTo(keys[at]), lessThan(0));
        keys.insert(at, key);
      }
      expect([...keys]..sort(), keys);
    });

    test('appending stays short', () {
      String? last;
      for (var i = 0; i < 5000; i++) {
        last = keyBetween(last, null);
      }
      expect(last!.length, lessThanOrEqualTo(4));
      String? first;
      for (var i = 0; i < 1000; i++) {
        first = keyBetween(null, first);
      }
      expect(first!.length, lessThanOrEqualTo(4));
    });

    test('malformed neighbors are treated as open ends', () {
      expect(isOrderKey(keyBetween('m', null)), isTrue);
      expect(isOrderKey(keyBetween('a5', 'a3')), isTrue);
    });
  });

  group('lists', () {
    late TestClock clock;
    late Den den;
    late String groceries;

    setUp(() async {
      clock = TestClock.at(DateTime.utc(2026, 4, 1, 15));
      den = await foundFamily(clock);
      groceries = await den.addList(title: 'Groceries', kind: ListKind.shopping, pinned: true);
    });

    List<String> texts(String list) => den.list(list)!.items.map((i) => i.text).toList();

    test('items keep their order and move between neighbors', () async {
      final ids = {
        for (final t in ['Milk', 'Eggs', 'Bread', 'Apples']) t: await den.addItem(groceries, text: t),
      };
      expect(texts(groceries), ['Milk', 'Eggs', 'Bread', 'Apples']);
      await den.moveItem(ids['Apples']!, before: ids['Milk']);
      expect(texts(groceries), ['Apples', 'Milk', 'Eggs', 'Bread']);
      await den.moveItem(ids['Milk']!, after: ids['Bread']);
      expect(texts(groceries), ['Apples', 'Eggs', 'Bread', 'Milk']);
      await den.moveItem(ids['Bread']!, after: ids['Apples'], before: ids['Eggs']);
      expect(texts(groceries), ['Apples', 'Bread', 'Eggs', 'Milk']);
      await den.moveItem(ids['Apples']!, after: ids['Eggs']);
      expect(texts(groceries), ['Bread', 'Eggs', 'Apples', 'Milk']);
      final other = await den.addList(title: 'Hardware');
      final nails = await den.addItem(other, text: 'Nails');
      await expectLater(den.moveItem(nails, after: ids['Milk']), throwsA(isA<InvalidInput>()));
    });

    test('concurrent appends from two devices settle into one stable order', () async {
      final second = await joinDevice(den, clock, member: den.actor!.id, name: 'Second');
      await den.addItem(groceries, text: 'Milk');
      await sync(den, second);
      await den.addItem(groceries, text: 'From one');
      await second.addItem(groceries, text: 'From two');
      await exchange(den, second);
      expect(texts(groceries), second.list(groceries)!.items.map((i) => i.text).toList());
      expect(texts(groceries).first, 'Milk');
    });

    test('clearing checked items removes them and says how many', () async {
      final a = await den.addItem(groceries, text: 'Milk');
      await den.addItem(groceries, text: 'Eggs');
      final c = await den.addItem(groceries, text: 'Bread');
      await den.setItemChecked(a, true);
      await den.setItemChecked(c, true);
      expect(den.list(groceries)!.open, 1);
      expect(den.list(groceries)!.items.firstWhere((i) => i.id == a).checkedBy, den.actor!.id);
      expect(await den.clearChecked(groceries), 2);
      expect(texts(groceries), ['Eggs']);
      expect(await den.clearChecked(groceries), 0);
    });

    test('meal items marked for groceries land on the pinned shopping list', () async {
      final other = await den.addList(title: 'Hardware store', kind: ListKind.shopping);
      final meals = await den.addList(title: 'Meal plan', kind: ListKind.meal);
      await den.addItem(meals, text: 'Tacos');
      await den.addItem(meals, text: 'Taco shells', toGroceries: true, store: 'Target');
      expect(texts(groceries), ['Taco shells']);
      expect(den.list(groceries)!.items.single.store, 'Target');
      expect(texts(other), isEmpty);
      final salsa = await den.addItem(meals, text: 'Salsa');
      await den.updateItem(salsa, {'toGroceries': true});
      expect(texts(groceries), ['Taco shells', 'Salsa']);
      await den.addItem(meals, text: 'taco shells', toGroceries: true);
      expect(texts(groceries), ['Taco shells', 'Salsa'], reason: 'already on the list');
      expect(texts(meals), ['Tacos', 'Taco shells', 'Salsa', 'taco shells']);
    });

    test('stores are listed by how often they\'re used', () async {
      for (final (t, s) in [('Milk', 'Costco'), ('Eggs', 'Target'), ('Bread', 'Costco'), ('Jam', 'Trader Joe\'s'), ('Rice', 'Costco'), ('Soap', 'Target')]) {
        await den.addItem(groceries, text: t, store: s);
      }
      expect(den.stores, ['Costco', 'Target', 'Trader Joe\'s']);
      expect(den.list(groceries)!.openByStore, {'Costco': 3, 'Target': 2, 'Trader Joe\'s': 1});
    });

    test('kids check items but need the lists grant to add them', () async {
      final leo = await den.addMember(name: 'Leo', role: Role.kid);
      final milk = await den.addItem(groceries, text: 'Milk');
      final tablet = await joinDevice(den, clock, member: leo);
      await tablet.setItemChecked(milk, true);
      await expectLater(tablet.addItem(groceries, text: 'Candy'), throwsA(isA<PermissionDenied>()));
      await expectLater(tablet.clearChecked(groceries), throwsA(isA<PermissionDenied>()));
      await den.updateMember(leo, {'grants': [Grant.lists]});
      await sync(den, tablet);
      await tablet.addItem(groceries, text: 'Candy');
      await sync(tablet, den);
      expect(texts(groceries), ['Milk', 'Candy']);
      expect(den.history().first.actorName, 'Leo');
    });

    test('a list\'s icon defaults to its kind', () async {
      final packing = await den.addList(title: 'Beach bag', kind: ListKind.packing);
      expect(den.list(packing)!.list.icon, 'packing');
      expect(den.list(groceries)!.list.icon, 'shopping');
      final custom = await den.addList(title: 'Dinners', kind: ListKind.meal, icon: 'meal');
      expect(den.list(custom)!.list.icon, 'meal');
    });

    test('lists sort pinned first, then in the order they were added', () async {
      await den.addList(title: 'Packing');
      await den.addList(title: 'Chores for the sitter');
      expect(den.lists.map((l) => l.list.title), ['Groceries', 'Packing', 'Chores for the sitter']);
      await den.deleteList(groceries);
      expect(den.lists.map((l) => l.list.title), ['Packing', 'Chores for the sitter']);
    });
  });
}
