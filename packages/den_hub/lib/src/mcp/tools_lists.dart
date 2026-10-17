import 'package:den_core/den_core.dart';

import '../times.dart';
import '../wire.dart';
import 'resolve.dart';
import 'tool.dart';

/// List and points tools.
List<Tool> listAndPointsTools() => [
      Tool(
        name: 'create_list',
        title: 'Add a list',
        description: 'Adds a list: shopping, checklist, packing or meal plan.',
        properties: {
          'title': sString('The list\'s name.'),
          'kind': sString('What kind (default checklist).', oneOf: ListKind.values.map((k) => k.name).toList()),
          'pinned': sBool('Show it on Today.'),
          'need_by': sTime('For a list needed by a date, that date.'),
          'who_can_see': sString('"everyone" (default), "parents", "just me", or a person\'s name.'),
        },
        required: ['title'],
        scope: Scope.lists,
        readOnly: false,
        run: _createList,
      ),
      Tool(
        name: 'add_items',
        title: 'Add items to a list',
        description: 'Adds items to the end of a list.',
        properties: {
          'list': sString('The list\'s title or id.'),
          'items': sList({
            'anyOf': [
              sString('The item.'),
              {
                'type': 'object',
                'properties': {'text': sString('The item.'), 'qty': sString('How many.'), 'store': sString('Where to buy it.')},
                'required': ['text'],
              },
            ],
          }, 'Items: text, or {text, qty, store}.', max: 100),
        },
        required: ['list', 'items'],
        scope: Scope.lists,
        readOnly: false,
        run: _addItems,
      ),
      Tool(
        name: 'check_item',
        title: 'Check off an item',
        description: 'Checks (or unchecks) an item on a list.',
        properties: {
          'item': sString('The item\'s text or id.'),
          'list': sString('The list it is on (title or id), when the text is on several lists.'),
          'checked': sBool('Checked (default true).'),
        },
        required: ['item'],
        scope: Scope.lists,
        readOnly: false,
        idempotent: true,
        run: _checkItem,
      ),
      Tool(
        name: 'remove_item',
        title: 'Remove an item',
        description: 'Removes an item from a list.',
        properties: {'item': sString('The item\'s text or id.'), 'list': sString('The list it is on (title or id).')},
        required: ['item'],
        scope: Scope.lists,
        readOnly: false,
        destructive: true,
        idempotent: true,
        run: _removeItem,
      ),
      Tool(
        name: 'clear_checked',
        title: 'Clear checked items',
        description: 'Removes every checked item from a list.',
        properties: {'list': sString('The list\'s title or id.')},
        required: ['list'],
        scope: Scope.lists,
        readOnly: false,
        destructive: true,
        idempotent: true,
        run: _clearChecked,
      ),
      Tool(
        name: 'adjust_points',
        title: 'Give or take stars',
        description: 'Gives (positive) or takes (negative) stars from a person, with a reason.',
        properties: {
          'person': sPerson('Who.'),
          'delta': sInt('Stars to give (positive) or take (negative).', min: -10000, max: 10000),
          'reason': sString('Why, shown in their points history.'),
        },
        required: ['person', 'delta', 'reason'],
        scope: Scope.points,
        readOnly: false,
        run: _adjust,
      ),
      Tool(
        name: 'create_goal',
        title: 'Add a goal',
        description: 'Adds a star goal: reach a target, or race to it first.',
        properties: {
          'title': sString('The goal.'),
          'target': sInt('Stars to reach.', min: 1, max: 100000),
          'mode': sString('target (everyone can reach it) or race (first to reach it wins).', oneOf: ['target', 'race']),
          'people': sList(sString('A name or member id.'), 'Who takes part (default every kid).'),
          'start': sTime('First day (default today).'),
          'end': sTime('Last day (default open-ended).'),
          'repeat': sString('Start over every week or month.', oneOf: ['none', 'weekly', 'monthly']),
          'reward': sString('What reaching it earns.'),
        },
        required: ['title', 'target'],
        scope: Scope.points,
        readOnly: false,
        run: _goal,
      ),
      Tool(
        name: 'request_reward',
        title: 'Ask for a reward',
        description: 'Spends a person\'s stars on a reward. Rewards that need a parent wait for approval.',
        properties: {'reward': sString('The reward\'s title or id.'), 'person': sPerson('Who it is for (default this connection\'s person).')},
        required: ['reward'],
        scope: Scope.points,
        readOnly: false,
        run: _request,
      ),
      Tool(
        name: 'decide_redemption',
        title: 'Approve or decline a reward request',
        description: 'Approves or declines a pending reward request.',
        properties: {
          'request': sString('The request id, or the name of the person who asked.'),
          'approve': sBool('True approves, false declines.'),
        },
        required: ['request', 'approve'],
        scope: Scope.points,
        readOnly: false,
        destructive: true,
        idempotent: true,
        run: _decide,
      ),
    ];

Future<ToolResult> _createList(ToolContext c, Args a) async {
  final title = a.str('title', required: true, max: 200)!.trim();
  final kindName = a.str('kind') ?? 'checklist';
  final kind = ListKind.values.where((k) => k.name == kindName).firstOrNull ??
      (throw ToolError('"kind" must be one of ${ListKind.values.map((k) => k.name).join(', ')}.'));
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
  return ToolResult('Added the list $title [list $id].', {'list': Wire.list(c.den.list(id)!)});
}

Future<ToolResult> _addItems(ToolContext c, Args a) async {
  final list = c.list(a.str('list', required: true)!);
  final raw = a.list('items');
  if (raw == null || raw.isEmpty) throw ToolError('"items" needs at least one item.');
  final added = <String>[];
  for (final entry in raw) {
    final Map<Object?, Object?> m = entry is Map ? entry : {'text': entry};
    final text = '${m['text'] ?? ''}'.trim();
    if (text.isEmpty || text.length > 200) throw ToolError('Each item needs text of 1 to 200 characters.');
    added.add(await c.den.addItem(list.list.id, text: text, qty: m['qty'] as String?, store: m['store'] as String?));
  }
  final after = c.den.list(list.list.id)!;
  final items = [for (final i in after.items) if (added.contains(i.id)) i];
  return ToolResult('Added ${items.map((i) => i.text).join(', ')} to ${list.list.title}.', {
    'list_id': list.list.id,
    'items': [for (final i in items) Wire.item(i)],
  });
}

Future<ToolResult> _checkItem(ToolContext c, Args a) async {
  final list = a.has('list') ? c.list(a.str('list')!) : null;
  final (l, item) = c.item(a.str('item', required: true)!, list: list);
  final checked = a.flag('checked') ?? true;
  await c.den.setItemChecked(item.id, checked);
  final now = c.den.list(l.list.id)!.items.firstWhere((i) => i.id == item.id);
  return ToolResult('${checked ? 'Checked off' : 'Unchecked'} ${item.text} on ${l.list.title}.', {'item': Wire.item(now)});
}

Future<ToolResult> _removeItem(ToolContext c, Args a) async {
  final list = a.has('list') ? c.list(a.str('list')!) : null;
  final (l, item) = c.item(a.str('item', required: true)!, list: list);
  await c.den.removeItem(item.id);
  return ToolResult('Removed ${item.text} from ${l.list.title}.', {'ok': true, 'item_id': item.id, 'list_id': l.list.id});
}

Future<ToolResult> _clearChecked(ToolContext c, Args a) async {
  final list = c.list(a.str('list', required: true)!);
  final n = await c.den.clearChecked(list.list.id);
  return ToolResult(n == 0 ? 'Nothing was checked on ${list.list.title}.' : 'Cleared $n checked item${n == 1 ? '' : 's'} from ${list.list.title}.',
      {'ok': true, 'removed': n});
}

Future<ToolResult> _adjust(ToolContext c, Args a) async {
  final member = c.people.one(a.str('person', required: true)!);
  final delta = a.integer('delta', required: true, min: -10000, max: 10000)!;
  if (delta == 0) throw ToolError('"delta" can\'t be zero.');
  final reason = a.str('reason', required: true, max: 200)!.trim();
  if (c.den.family?.pointsEnabled == false) throw ToolError('Points are turned off for this family.');
  await c.den.adjustPoints(member, delta, reason);
  final balance = c.den.points().totals[member] ?? 0;
  final name = c.people.name(member);
  return ToolResult('${delta > 0 ? 'Gave' : 'Took'} ${delta.abs()} star${delta.abs() == 1 ? '' : 's'} ${delta > 0 ? 'to' : 'from'} $name. $name has $balance.',
      {'member': member, 'delta': delta, 'reason': reason, 'balance': balance});
}

Future<ToolResult> _goal(ToolContext c, Args a) async {
  final title = a.str('title', required: true, max: 200)!.trim();
  final mode = a.str('mode') == 'race' ? GoalMode.race : GoalMode.target;
  final repeat = GoalRepeat.values.where((r) => r.name == (a.str('repeat') ?? 'none')).firstOrNull ?? GoalRepeat.none;
  final id = await c.den.addGoal(
    title: title,
    target: a.integer('target', required: true, min: 1, max: 100000)!,
    mode: mode,
    members: a.list('people') == null ? null : c.people.many(a.raw['people'], 'people'),
    start: a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : null,
    end: a.has('end') ? toolDate(a.raw['end'], c.zone, 'end') : null,
    repeat: repeat,
    reward: a.str('reward', max: 200) ?? '',
  );
  return ToolResult('Added the goal $title [goal $id].', {'goal_id': id});
}

Future<ToolResult> _request(ToolContext c, Args a) async {
  final reward = c.reward(a.str('reward', required: true)!);
  final who = a.has('person') ? c.people.one(a.str('person')!) : c.access.member;
  if (who == null) throw ToolError('Say who the reward is for with "person".');
  final id = await c.den.requestReward(reward.id, member: who);
  final r = c.den.points();
  final pending = r.pending.any((p) => p.id == id);
  return ToolResult(
    pending
        ? '${c.people.name(who)} asked for ${reward.title}; a parent needs to approve it [request $id].'
        : '${c.people.name(who)} got ${reward.title} for ${reward.cost} stars.',
    {'request_id': id, 'status': pending ? 'requested' : 'approved', 'balance': r.totals[who] ?? 0},
  );
}

Future<ToolResult> _decide(ToolContext c, Args a) async {
  final query = a.str('request', required: true)!;
  final approve = a.flag('approve') ?? (throw ToolError('"approve" is required.'));
  final summary = c.den.points();
  final titles = {for (final r in summary.rewards) r.id: r.title};
  final request = pick(
    query,
    summary.pending,
    id: (p) => p.id,
    name: (p) => c.people.name(p.member),
    kind: 'pending reward request',
    describe: (p) => '${c.people.name(p.member)} asked for ${titles[p.reward] ?? 'a reward'} (id ${p.id})',
  );
  await c.den.decideRedemption(request.id, approve: approve);
  return ToolResult(
    '${approve ? 'Approved' : 'Declined'} ${titles[request.reward] ?? 'the reward'} for ${c.people.name(request.member)}'
    ' (${shortDate(dateIn(c.zone, request.rec.created.millis))}).',
    {'request_id': request.id, 'status': approve ? 'approved' : 'declined'},
  );
}
