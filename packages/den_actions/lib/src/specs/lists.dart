import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../wire.dart';
import 'events.dart' show audienceFor;

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

Map<String, Object?> _itemsToCheck(Map<String, Object?> args) {
  final items = args['items'];
  if (items is String) return {...args, 'items': [{'item': items, 'checked': true}]};
  if (items is! List) return args;
  return {
    ...args,
    'items': [for (final i in items) i is String ? {'item': i, 'checked': true} : i],
  };
}

final List<String> _kinds = [for (final k in ListKind.values) k.name];

/// List actions.
List<ActionSpec> listActions() => [
      ActionSpec(
        name: 'lists.create',
        mcpName: 'create_list',
        title: 'Add a list',
        description: 'Adds a list: shopping, checklist, packing or meal plan.',
        input: S.input({
          'title': S.string('The list\'s name.', maxLength: 200),
          'kind': S.string('What kind (default checklist).', oneOf: _kinds),
          'pinned': S.boolean('Show it on Today.'),
          'need_by': S.date('For a list needed by a date, that date.'),
          'event': S.string('The event it is for (title or id), such as a trip it\'s the packing list of.'),
          'who_can_see': S.string('"everyone" (default), "parents", "just me", or a person\'s name.'),
        }, required: ['title']),
        output: S.output({'list': listShape}),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.write,
        engine: const {'addList'},
        example: const {'title': 'Camping trip', 'kind': 'packing', 'event': 'Beach trip'},
        run: _createList,
      ),
      ActionSpec(
        name: 'lists.update',
        mcpName: 'update_list',
        title: 'Change a list',
        description: 'Renames a list, pins or unpins it on Today, changes its kind, the date it\'s needed by or '
            'the event it\'s for, or who can see it. Fields left out stay as they are.',
        input: S.input({
          'list': S.string('The list\'s title or id.'),
          'title': S.string('New name.', maxLength: 200),
          'kind': S.string('What kind.', oneOf: _kinds),
          'pinned': S.boolean('Show it on Today.'),
          'need_by': S.date('Needed by this date; empty for none.'),
          'event': S.string('The event it is for (title or id); empty for none.'),
          'who_can_see': S.string('Move it with its items: "everyone", "parents" or "just me".'),
        }, required: ['list']),
        output: S.output({'list': listShape}),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.client,
        confirmWhen: (c, a) => a.has('who_can_see'),
        engine: const {'updateList'},
        example: const {'list': 'Science fair supplies', 'pinned': true},
        run: _updateList,
      ),
      ActionSpec(
        name: 'lists.delete',
        mcpName: 'delete_list',
        title: 'Remove a list',
        description: 'Removes a list and its items (undo or a parent can bring them back).',
        input: S.input({'list': S.string('The list\'s title or id.')}, required: ['list']),
        output: S.output({'ok': Out.flag('It worked.'), 'list_id': Out.str('The list.')}),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.server,
        ask: (c, a) {
          final l = c.list(a.str('list', required: true)!);
          return 'Remove the list ${l.list.title}${l.items.isEmpty ? '' : ' and its ${l.items.length} items'}?';
        },
        engine: const {'deleteList'},
        example: const {'list': 'Beach trip packing'},
        run: _deleteList,
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
        name: 'lists.update_items',
        mcpName: 'update_items',
        title: 'Check off or change items',
        description: 'Checks or unchecks items, changes their text, quantity or store, or moves them on their list. '
            'Checking items off needs only permission to check items.',
        input: S.input({
          'list': S.string('The list the items are on (title or id), when their text is on several lists.'),
          'items': S.array(
            S.object({
              'item': S.string('The item\'s text or id.'),
              'list': S.string('Its list, when it isn\'t the one above.'),
              'checked': S.boolean('Checked off, or not.'),
              'text': S.string('New text.', maxLength: 200),
              'qty': S.string('New quantity; empty for none.', maxLength: 50),
              'store': S.string('New store; empty for none.', maxLength: 100),
              'to_groceries': S.boolean('On a meal plan: also put it on the groceries.'),
              'move': S.string('Move it to the top or the bottom of its list.', oneOf: ['top', 'bottom']),
              'after': S.string('Move it just after this item (text or id).'),
              'before': S.string('Move it just before this item (text or id).'),
            }, required: ['item']),
            'The items, each with what to change.',
            minItems: 1,
            maxItems: 100,
          ),
        }, required: ['items']),
        output: S.output({
          'items': S.array(itemShape, 'The items as they are now.'),
          'item': itemShape,
        }),
        scopes: const {Scope.lists},
        needs: const [DenAction.checkItems],
        effect: Effect.write,
        idempotent: true,
        engine: const {'setItemChecked', 'updateItem', 'moveItem'},
        example: const {
          'list': 'Groceries',
          'items': [
            {'item': 'Eggs', 'checked': true},
            {'item': 'Milk', 'qty': '2 gal', 'move': 'top'},
          ],
        },
        prepare: _itemsToCheck,
        run: _updateItems,
      ),
      ActionSpec(
        name: 'lists.remove_items',
        mcpName: 'remove_items',
        title: 'Remove items',
        description: 'Removes items from a list, or every checked item with "checked": true.',
        input: S.input({
          'list': S.string('The list (title or id).'),
          'items': S.array(S.string('An item\'s text or id.'), 'Items to remove.', maxItems: 100),
          'checked': S.boolean('Remove every checked item on the list.'),
        }),
        output: S.output({
          'ok': Out.flag('It worked.'),
          'removed': Out.integer('How many.'),
          'item_ids': Out.strings('The items removed.'),
          'item_id': Out.str('The item removed, when it was one.'),
          'list_id': Out.strOrNull('The list.'),
        }),
        scopes: const {Scope.lists},
        needs: const [DenAction.editLists],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.server,
        confirmWhen: (c, a) => _toRemove(c, a).$2.length > 5,
        ask: (c, a) {
          final (list, items) = _toRemove(c, a);
          return 'Remove ${items.length} items${list == null ? '' : ' from ${list.list.title}'}?';
        },
        engine: const {'removeItem', 'clearChecked'},
        example: const {'list': 'Science fair supplies', 'checked': true},
        run: _removeItems,
      ),
    ];

/// Older list tools: one item checked or removed, and clearing what's checked.
List<ActionAlias> listAliases() => [
      ActionAlias('check_item', 'update_items', (args) => {
            'list': ?args['list'],
            'items': [
              {'item': args['item'], 'checked': args['checked'] ?? true},
            ],
          }),
      ActionAlias('remove_item', 'remove_items', (args) => {
            'list': ?args['list'],
            'items': [args['item']],
          }),
      ActionAlias('clear_checked', 'remove_items', (args) => {'list': args['list'], 'checked': true}),
    ];

String? _eventId(ActionContext c, String? query) {
  final q = query?.trim();
  if (q == null || q.isEmpty) return null;
  return c.event(q).id;
}

Future<ActionResult> _createList(ActionContext c, ActionInput a) async {
  final title = a.str('title', required: true)!.trim();
  final kind = ListKind.values.firstWhere((k) => k.name == (a.str('kind') ?? 'checklist'));
  final needBy = a.has('need_by') ? toolDate(a.raw['need_by'], c.zone, 'need_by') : null;
  final event = _eventId(c, a.str('event'));
  final id = await c.den.addList(
    title: title,
    kind: kind,
    lifecycle: event != null
        ? ListLifecycle.event
        : needBy == null
            ? ListLifecycle.running
            : ListLifecycle.dated,
    needBy: needBy,
    event: event,
    icon: kind.name,
    pinned: a.flag('pinned') ?? false,
    space: c.space(a.raw['who_can_see']),
  );
  return ActionResult('Added the list $title [list $id].', {'list': Wire.list(c.den.list(id)!)});
}

Future<ActionResult> _updateList(ActionContext c, ActionInput a) async {
  final l = c.list(a.str('list', required: true)!);
  final needBy = a.str('need_by')?.trim();
  final event = a.str('event')?.trim();
  final patch = <String, Object?>{
    if (a.has('title')) 'title': a.str('title')!.trim(),
    if (a.has('kind')) 'kind': a.str('kind'),
    if (a.has('pinned')) 'pinned': a.flag('pinned'),
    if (needBy != null) ...{
      'needBy': needBy.isEmpty ? null : toolDate(needBy, c.zone, 'need_by'),
      'lifecycle': needBy.isEmpty ? ListLifecycle.running.name : ListLifecycle.dated.name,
    },
    if (event != null) ...{
      'event': _eventId(c, event),
      if (needBy == null) 'lifecycle': event.isEmpty ? ListLifecycle.running.name : ListLifecycle.event.name,
    },
    if (a.has('who_can_see')) 'audience': audienceFor(c, a.raw['who_can_see']),
  };
  if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as title or pinned.');
  await c.den.updateList(l.list.id, patch);
  final after = c.den.list(l.list.id)!;
  return ActionResult('Changed the list ${after.list.title} [list ${after.list.id}].', {'list': Wire.list(after)});
}

Future<ActionResult> _deleteList(ActionContext c, ActionInput a) async {
  final l = c.list(a.str('list', required: true)!);
  await c.den.deleteList(l.list.id);
  return ActionResult('Removed the list ${l.list.title}.', {'ok': true, 'list_id': l.list.id});
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

String? _blank(Object? v) {
  final s = (v as String?)?.trim();
  return s == null || s.isEmpty ? null : s;
}

Future<ActionResult> _updateItems(ActionContext c, ActionInput a) async {
  final top = a.has('list') ? c.list(a.str('list')!) : null;
  final entries = a.objects('items') ?? const [];
  final done = <(String, String)>[];
  final said = <String>[];
  for (final e in entries) {
    final list = e['list'] == null ? top : c.list('${e['list']}');
    final (l, item) = c.item('${e['item']}', list: list);
    final what = <String>[];
    final checked = e['checked'] as bool?;
    if (checked != null && checked != item.checked) {
      await c.den.setItemChecked(item.id, checked);
      what.add(checked ? 'checked off' : 'unchecked');
    }
    final fields = <String, Object?>{
      if (e['text'] != null) 'text': '${e['text']}'.trim(),
      if (e.containsKey('qty')) 'qty': _blank(e['qty']),
      if (e.containsKey('store')) 'store': _blank(e['store']),
      if (e['to_groceries'] != null) 'toGroceries': e['to_groceries'],
    };
    if (fields['text'] == '') throw ActionError('An item\'s text can\'t be empty.', field: 'items');
    if (fields.isNotEmpty) {
      await c.den.updateItem(item.id, fields);
      what.add('changed');
    }
    final others = c.den.list(l.list.id)!.items.where((i) => i.id != item.id).toList();
    String? after;
    String? before;
    if (e['move'] == 'top') before = others.firstOrNull?.id;
    if (e['move'] == 'bottom') after = others.lastOrNull?.id;
    if (e['after'] != null) after = c.item('${e['after']}', list: l).$2.id;
    if (e['before'] != null) before = c.item('${e['before']}', list: l).$2.id;
    if (after != null || before != null) {
      await c.den.moveItem(item.id, after: after, before: before);
      what.add('moved');
    }
    done.add((l.list.id, item.id));
    said.add(what.isEmpty ? '${item.text} was already that way' : '${what.join(' and ')} ${item.text} on ${l.list.title}');
  }
  final items = [
    for (final (listId, itemId) in done) c.den.list(listId)!.items.firstWhere((i) => i.id == itemId),
  ];
  final text = said.join('; ');
  return ActionResult('${text[0].toUpperCase()}${text.substring(1)}.', {
    'items': [for (final i in items) Wire.item(i)],
    if (items.length == 1) 'item': Wire.item(items.single),
  });
}

/// The list and items a removal names.
(ListState?, List<Item>) _toRemove(ActionContext c, ActionInput a) {
  final list = a.has('list') ? c.list(a.str('list')!) : null;
  final names = a.list('items') ?? const [];
  final all = a.flag('checked') ?? false;
  if (names.isEmpty && !all) throw ActionError('Name the items to remove, or say "checked": true.', field: 'items');
  if (all && list == null) throw ActionError('Say which list to clear the checked items from.', field: 'list');
  final items = <Item>[
    if (all) ...list!.items.where((i) => i.checked),
    for (final n in names) c.item('$n', list: list).$2,
  ];
  return (list, {for (final i in items) i.id: i}.values.toList());
}

Future<ActionResult> _removeItems(ActionContext c, ActionInput a) async {
  final (list, items) = _toRemove(c, a);
  final all = a.flag('checked') ?? false;
  var removed = 0;
  if (all) removed += await c.den.clearChecked(list!.list.id);
  for (final i in items.where((i) => !all || !i.checked)) {
    await c.den.removeItem(i.id);
    removed++;
  }
  final lists = {for (final i in items) i.list};
  final place = list?.list.title ?? (lists.length == 1 ? c.lists.firstWhereOrNull((l) => l.list.id == lists.single)?.list.title : null);
  final text = removed == 0
      ? 'Nothing was checked${place == null ? '' : ' on $place'}.'
      : all && items.every((i) => i.checked)
          ? 'Cleared $removed checked item${removed == 1 ? '' : 's'}${place == null ? '' : ' from $place'}.'
          : 'Removed ${items.map((i) => i.text).join(', ')}${place == null ? '' : ' from $place'}.';
  return ActionResult(text, {
    'ok': true,
    'removed': removed,
    'item_ids': [for (final i in items) i.id],
    if (items.length == 1) 'item_id': items.single.id,
    'list_id': list?.list.id ?? (lists.length == 1 ? lists.single : null),
  });
}
