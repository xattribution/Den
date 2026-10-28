import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../wire.dart';

/// Items given as plain strings become `{text}`, as older clients send them.
Map<String, Object?> itemsAsObjects(Map<String, Object?> args) {
  final items = args['items'];
  if (items is String) return {...args, 'items': [{'text': items}]};
  if (items is! List) return args;
  return {
    ...args,
    'items': [for (final i in items) i is String ? {'text': i} : i],
  };
}

/// List actions.
List<ActionSpec> listActions() => [
      ActionSpec(
        name: 'lists.create',
        mcpName: 'create_list',
        title: 'Add a list',
        description: 'Adds a list: shopping, checklist, packing or meal plan.',
        input: S.input({
          'title': S.string('The list\'s name.', maxLength: 200),
          'kind': S.string('What kind (default checklist).', oneOf: [for (final k in ListKind.values) k.name]),
          'pinned': S.boolean('Show it on Today.'),
          'need_by': S.date('For a list needed by a date, that date.'),
          'who_can_see': S.string('"everyone" (default), "parents", "just me", or a person\'s name.'),
        }, required: ['title']),
        output: S.output({'list': listShape}),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.write,
        engine: const {'addList'},
        example: const {'title': 'Camping trip', 'kind': 'packing'},
        run: _createList,
      ),
      ActionSpec(
        name: 'lists.add_items',
        mcpName: 'add_items',
        title: 'Add items to a list',
        description: 'Adds items to the end of a list.',
        input: S.input({
          'list': S.string('The list\'s title or id.'),
          'items': S.array(
            S.object({
              'text': S.string('The item.', maxLength: 200),
              'qty': S.string('How many.', maxLength: 50),
              'store': S.string('Where to buy it.', maxLength: 100),
              'to_groceries': S.boolean('On a meal plan: also put it on the groceries.'),
            }, required: ['text']),
            'Items to add.',
            minItems: 1,
            maxItems: 100,
          ),
        }, required: ['list', 'items']),
        output: S.output({'list_id': Out.str('The list.'), 'items': S.array(itemShape, 'The items added.')}),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.write,
        engine: const {'addItem'},
        example: const {
          'list': 'Groceries',
          'items': [
            {'text': 'Butter', 'store': 'Costco'},
            {'text': 'Apples', 'qty': '6'},
          ],
        },
        prepare: itemsAsObjects,
        run: _addItems,
      ),
      ActionSpec(
        name: 'lists.check_item',
        mcpName: 'check_item',
        title: 'Check off an item',
        description: 'Checks (or unchecks) an item on a list.',
        input: S.input({
          'item': S.string('The item\'s text or id.'),
          'list': S.string('The list it is on (title or id), when the text is on several lists.'),
          'checked': S.boolean('Checked (default true).'),
        }, required: ['item']),
        output: S.output({'item': itemShape}),
        scopes: const {Scope.lists},
        needs: const [DenAction.checkItems],
        effect: Effect.write,
        idempotent: true,
        engine: const {'setItemChecked'},
        example: const {'item': 'Eggs', 'list': 'Groceries'},
        run: _checkItem,
      ),
      ActionSpec(
        name: 'lists.remove_item',
        mcpName: 'remove_item',
        title: 'Remove an item',
        description: 'Removes an item from a list.',
        input: S.input({'item': S.string('The item\'s text or id.'), 'list': S.string('The list it is on (title or id).')}, required: ['item']),
        output: S.output({'ok': Out.flag('It worked.'), 'item_id': Out.str('The item.'), 'list_id': Out.str('Its list.')}),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.destructive,
        idempotent: true,
        engine: const {'removeItem'},
        example: const {'item': 'AA batteries'},
        run: _removeItem,
      ),
      ActionSpec(
        name: 'lists.clear_checked',
        mcpName: 'clear_checked',
        title: 'Clear checked items',
        description: 'Removes every checked item from a list.',
        input: S.input({'list': S.string('The list\'s title or id.')}, required: ['list']),
        output: S.output({'ok': Out.flag('It worked.'), 'removed': Out.integer('How many.')}),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.destructive,
        idempotent: true,
        engine: const {'clearChecked'},
        example: const {'list': 'Science fair supplies'},
        run: _clearChecked,
      ),
    ];

Future<ActionResult> _createList(ActionContext c, ActionInput a) async {
  final title = a.str('title', required: true)!.trim();
  final kind = ListKind.values.firstWhere((k) => k.name == (a.str('kind') ?? 'checklist'));
  final needBy = a.has('need_by') ? toolDate(a.raw['need_by'], c.zone, 'need_by') : null;
  final id = await c.den.addList(
    title: title,
    kind: kind,
    lifecycle: needBy == null ? ListLifecycle.running : ListLifecycle.dated,
    needBy: needBy,
    icon: kind.name,
    pinned: a.flag('pinned') ?? false,
    space: c.space(a.raw['who_can_see']),
  );
  return ActionResult('Added the list $title [list $id].', {'list': Wire.list(c.den.list(id)!)});
}

Future<ActionResult> _addItems(ActionContext c, ActionInput a) async {
  final list = c.list(a.str('list', required: true)!);
  final raw = a.objects('items') ?? const [];
  if (raw.isEmpty) throw ActionError('"items" needs at least one item.', field: 'items');
  final added = <String>[];
  for (final m in raw) {
    final text = '${m['text'] ?? ''}'.trim();
    if (text.isEmpty) throw ActionError('Each item needs text of 1 to 200 characters.', field: 'items');
    added.add(await c.den.addItem(
      list.list.id,
      text: text,
      qty: m['qty'] as String?,
      store: m['store'] as String?,
      toGroceries: m['to_groceries'] as bool? ?? false,
    ));
  }
  final after = c.den.list(list.list.id)!;
  final items = [for (final i in after.items) if (added.contains(i.id)) i];
  return ActionResult('Added ${items.map((i) => i.text).join(', ')} to ${list.list.title}.', {
    'list_id': list.list.id,
    'items': [for (final i in items) Wire.item(i)],
  });
}

Future<ActionResult> _checkItem(ActionContext c, ActionInput a) async {
  final list = a.has('list') ? c.list(a.str('list')!) : null;
  final (l, item) = c.item(a.str('item', required: true)!, list: list);
  final checked = a.flag('checked') ?? true;
  await c.den.setItemChecked(item.id, checked);
  final now = c.den.list(l.list.id)!.items.firstWhere((i) => i.id == item.id);
  return ActionResult('${checked ? 'Checked off' : 'Unchecked'} ${item.text} on ${l.list.title}.', {'item': Wire.item(now)});
}

Future<ActionResult> _removeItem(ActionContext c, ActionInput a) async {
  final list = a.has('list') ? c.list(a.str('list')!) : null;
  final (l, item) = c.item(a.str('item', required: true)!, list: list);
  await c.den.removeItem(item.id);
  return ActionResult('Removed ${item.text} from ${l.list.title}.', {'ok': true, 'item_id': item.id, 'list_id': l.list.id});
}

Future<ActionResult> _clearChecked(ActionContext c, ActionInput a) async {
  final list = c.list(a.str('list', required: true)!);
  final n = await c.den.clearChecked(list.list.id);
  return ActionResult(
    n == 0 ? 'Nothing was checked on ${list.list.title}.' : 'Cleared $n checked item${n == 1 ? '' : 's'} from ${list.list.title}.',
    {'ok': true, 'removed': n},
  );
}
