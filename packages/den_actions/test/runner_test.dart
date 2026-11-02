@Timeout(Duration(seconds: 120))
library;

import 'package:den_actions/den_actions.dart';
import 'package:den_core/den_core.dart';

import 'support.dart';

void main() {
  annotateFailures();
  late Den den;
  late ActionRunner runner;

  setUp(() async {
    den = await demoFamily();
    runner = standardRunner();
  });

  tearDown(() => den.close());

  test('a parent may use every action; a kid only what they are allowed', () {
    final parent = runner.available(parentOn(den)).map((s) => s.mcpName).toSet();
    expect(parent, runner.specs.map((s) => s.mcpName).toSet());
    final leo = ActionContext(den, member: idOf(den, 'Leo'), caller: 'leo');
    final kid = runner.available(leo).map((s) => s.mcpName).toSet();
    expect(kid, containsAll(['complete_chore', 'swap_chore', 'request_reward', 'get_points']));
    expect(kid, isNot(contains('add_items')));
    expect(kid, isNot(contains('adjust_points')));
    expect(runner.refusal(leo, runner.spec('add_items')!)!.text, startsWith('Den didn\'t allow that: Leo can\'t'));
    final reader = ActionContext(den, scopes: {Scope.read}, caller: 'reader');
    expect(runner.refusal(reader, runner.spec('create_event')!)!.message, contains('"calendar" scope'));
  });

  test('a write answers with a receipt whose changes the engine can undo', () async {
    final r = await runner.run(parentOn(den), 'add_items', {
      'list': 'groceries',
      'items': ['Butter', {'text': 'Apples', 'qty': '6'}],
    });
    expect(r.isError, isFalse, reason: r.text);
    expect(r.text, 'Added Butter, Apples to Groceries.');
    final receipt = r.receipt!;
    expect(receipt.tool, 'add_items');
    expect(receipt.changes, hasLength(2));
    expect(receipt.undoable, isTrue);
    expect(r.structured['receipt'], receipt.toJson());
    await den.undo(receipt.changes);
    final groceries = den.lists.firstWhere((l) => l.list.title == 'Groceries');
    expect(groceries.items.map((i) => i.text), isNot(contains('Butter')));
  });

  test('a preview runs on a fork and changes nothing', () async {
    final before = den.versionVector;
    final r = await runner.run(parentOn(den), 'add_items', {'list': 'Groceries', 'items': ['Butter'], 'preview': true});
    expect(r.status, ActionStatus.preview, reason: r.text);
    final preview = (r.data['preview'] as Map).cast<String, Object?>();
    expect((preview['changes'] as List).single, containsPair('verb', 'added'));
    expect(den.versionVector, before);
    // An item already on the list isn't added twice (MCP eval #10): the preview says so.
    final again = await runner.run(parentOn(den), 'add_items', {'list': 'Groceries', 'items': ['eggs']}, mode: RunMode.preview);
    expect(again.text, contains('Eggs is already on Groceries'));
    expect((again.data['preview'] as Map)['changes'], isEmpty);
  });

  test('input is checked against the schema, and names resolve', () async {
    final bad = await runner.run(parentOn(den), 'adjust_points', {'person': 'Leo', 'delta': 'lots', 'reason': 'x'});
    expect(bad.isError, isTrue);
    expect(bad.text, '"delta" must be a whole number.');
    expect(bad.data['field'], 'delta');
    final extra = await runner.run(parentOn(den), 'get_family', {'person': 'Leo'});
    expect(extra.text, contains('doesn\'t take "person"'));
    final ambiguous = await runner.run(parentOn(den), 'complete_chore', {'chore': 'Make bed'});
    expect(ambiguous.isError, isTrue);
    expect(ambiguous.text, contains('More than one chore matches'));
    final unknown = await runner.run(parentOn(den), 'nope', {});
    expect(unknown.code, 'unknown_action');
  });

  test('one bad item refuses the whole call', () async {
    final before = den.lists.firstWhere((l) => l.list.title == 'Groceries').items.length;
    final r = await runner.run(parentOn(den), 'add_items', {
      'list': 'Groceries',
      'items': [
        {'text': 'Butter'},
        {'text': '   '},
      ],
    });
    expect(r.isError, isTrue);
    expect(den.lists.firstWhere((l) => l.list.title == 'Groceries').items.length, before);
  });
}
