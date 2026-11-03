import 'package:den_app/app/app_state.dart';
import 'package:den_app/features/linked/linked_families.dart';
import 'package:den_app/features/linked/linked_families_screen.dart';
import 'package:den_app/features/linked/linked_family_screen.dart';
import 'package:den_app/features/lists/screens/list_detail.dart';
import 'package:den_app/features/lists/widgets/item_adder.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chores_shots.dart';
import 'family_fakes.dart' show pumpScreen;

/// Text that reads [text], whatever spaces the app keeps from breaking.
Finder words(String text) =>
    find.byWidgetPredicate((w) => w is Text && (w.data ?? w.textSpan?.toPlainText())?.replaceAll('\u00a0', ' ') == text);

/// Linked families on the app's side: the Smiths' list shared only to see, what a parent shares
/// back, and the links' addresses.
void main() {
  /// The demo family linked with the Smiths, who share a grocery list with them to see.
  Future<String> linkSmiths(WidgetTester tester, AppState state) async {
    final den = state.den;
    late String id;
    await tester.runAsync(() async {
      id = await den.addFamilyLink();
      await den.noteFamilyLink(id, {
        'status': LinkStatus.linked.name,
        'name': 'Smith',
        'peer': 'abcdefghijklmnop',
        'theirs': {'smithgrocerylist': 'see'},
      });
      await den.writeLinked(RecordType.list, 'smithgrocerylist', Space.family,
          {'title': 'Smith groceries', 'kind': 'shopping', 'link': id});
      await den.writeLinked(RecordType.item, 'smithmilkitem000', Space.family,
          {'list': 'smithgrocerylist', 'text': 'Milk', 'checked': false});
    });
    return id;
  }

  testWidgets('a list another family shares to see says whose it is, and takes nothing new', (tester) async {
    final state = await demo(tester);
    await linkSmiths(tester, state);
    await pumpScreen(tester, const ListDetailScreen(id: 'smithgrocerylist'), state: state);
    await tester.pumpAndSettle();
    expect(words("The Smith family's list, to see"), findsOneWidget);
    expect(words('Milk'), findsOneWidget);
    expect(find.byType(AddItemRow), findsNothing);
  });

  testWidgets('a linked family\'s page shows what they share, and a parent picks what goes to them', (tester) async {
    final state = await demo(tester);
    final id = await linkSmiths(tester, state);
    await pumpScreen(tester, LinkedFamilyScreen(id: id), state: state);
    await tester.pumpAndSettle();
    expect(words('The Smith family'), findsWidgets);
    expect(words('Their lists'), findsOneWidget);
    expect(words('Smith groceries'), findsOneWidget);
    expect(words('To see'), findsOneWidget);
    expect(words('Your calendar'), findsOneWidget);
    await tester.tap(words('See').first);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(state.den.familyLink(id)!.share[Shared.calendar], ShareLevel.see);
  });

  testWidgets('Linked families lists each family; Link a family shows the address to send', (tester) async {
    final state = await demo(tester);
    await linkSmiths(tester, state);
    final source = _FakeLinks();
    await pumpScreen(tester, LinkedFamiliesScreen(source: source), state: state);
    await tester.pumpAndSettle();
    expect(words('The Smith family'), findsOneWidget);
    expect(words('Shares 1 list with you'), findsOneWidget);
    await tester.tap(words('Link a family'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.textContaining('/family-link/'), findsOneWidget);
    expect(words('Copy link'), findsOneWidget);
  });

  test('a family link\'s address gives its id', () {
    expect(familyLinkId('http://100.118.184.55:47733/family-link/abcdefgh12345678/${'s' * 43}'), 'abcdefgh12345678');
    expect(familyLinkId('https://den.example.com/family-link/abcdefgh12345678'), isNull);
    expect(familyLinkId('not a link'), isNull);
    expect(linkedFamilyName('The Riveras'), 'The Riveras');
    expect(linkedFamilyName('Carter family'), 'The Carter family');
  });
}

class _FakeLinks implements FamilyLinksSource {
  @override
  Future<String> offer(String id) async => 'https://den.example.com/family-link/$id/${'s' * 43}';

  @override
  Future<String> accept(String url) async => 'Jones';
}
