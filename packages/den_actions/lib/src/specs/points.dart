import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';
import '../wire.dart';

/// Points actions: stars given or taken, goals, rewards, and requests for rewards.
List<ActionSpec> pointsActions() => [
      ActionSpec(
        name: 'points.adjust',
        mcpName: 'adjust_points',
        title: 'Give or take stars',
        description: 'Gives (positive) or takes (negative) stars from a person, with a reason.',
        input: S.input({
          'person': S.person('Who.'),
          'delta': S.integer('Stars to give (positive) or take (negative).', min: -10000, max: 10000),
          'reason': S.string('Why, shown in their points history.', maxLength: 200),
        }, required: ['person', 'delta', 'reason']),
        output: S.output({
          'member': Out.str('Who.'),
          'delta': Out.integer('Stars given (positive) or taken.'),
          'reason': Out.str('Why.'),
          'balance': Out.integer('Their balance now.'),
        }),
        scopes: const {Scope.points},
        needs: const [DenAction.managePoints],
        effect: Effect.destructive,
        confirm: Confirm.client,
        engine: const {'adjustPoints'},
        example: const {'person': 'Leo', 'delta': 3, 'reason': 'Helped carry the groceries'},
        run: _adjust,
      ),
      ActionSpec(
        name: 'points.save_goal',
        mcpName: 'save_goal',
        title: 'Add or change a goal',
        description: 'Adds a star goal (reach a target, or race to it first), or with "goal" changes one. Fields '
            'left out stay as they are.',
        input: S.input({
          'goal': S.string('The goal to change (title or id); leave out to add one.'),
          'title': S.string('The goal.', maxLength: 200),
          'target': S.integer('Stars to reach.', min: 1, max: 100000),
          'mode': S.string('target (everyone can reach it) or race (first to reach it wins).', oneOf: ['target', 'race']),
          'people': S.people('Who takes part; empty for every kid.'),
          'start': S.date('First day (default today).'),
          'end': S.date('Last day; empty for open-ended.'),
          'repeat': S.string('Start over every week or month.', oneOf: ['none', 'weekly', 'monthly']),
          'reward': S.string('What reaching it earns.', maxLength: 200),
        }),
        output: S.output({'goal_id': Out.str('The goal.'), 'goal': {...goalShape, 'type': ['object', 'null']}}),
        scopes: const {Scope.points},
        needs: const [DenAction.managePoints],
        effect: Effect.destructive,
        confirm: Confirm.client,
        confirmWhen: (c, a) => a.has('goal'),
        engine: const {'addGoal', 'updateGoal'},
        example: const {'title': 'Summer reading', 'target': 40, 'reward': 'A trip to the bookstore'},
        run: _saveGoal,
      ),
      ActionSpec(
        name: 'points.delete_goal',
        mcpName: 'delete_goal',
        title: 'Remove a goal',
        description: 'Removes a star goal. Stars people earned stay theirs.',
        input: S.input({'goal': S.string('The goal (title or id).')}, required: ['goal']),
        output: S.output({'ok': Out.flag('It worked.'), 'goal_id': Out.str('The goal.')}),
        scopes: const {Scope.points},
        needs: const [DenAction.managePoints],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.server,
        ask: (c, a) => 'Remove the goal ${_goal(c, a.str('goal', required: true)!).title}?',
        engine: const {'deleteGoal'},
        example: const {'goal': 'First to 25 stars'},
        run: _deleteGoal,
      ),
      ActionSpec(
        name: 'points.save_reward',
        mcpName: 'save_reward',
        title: 'Add or change a reward',
        description: 'Adds a reward people can spend stars on, or with "reward" changes one; "active": false '
            'retires it and true brings it back.',
        input: S.input({
          'reward': S.string('The reward to change (title or id); leave out to add one.'),
          'title': S.string('What it is.', maxLength: 200),
          'cost': S.integer('Stars it costs.', min: 0, max: 100000),
          'icon': S.string('A pictogram.', oneOf: PictogramKeys.rewards),
          'needs_approval': S.boolean('Whether a parent approves each request (default true).'),
          'active': S.boolean('Whether it can be asked for.'),
        }),
        output: S.output({'reward': rewardShape}),
        scopes: const {Scope.points},
        needs: const [DenAction.managePoints],
        effect: Effect.destructive,
        confirm: Confirm.client,
        confirmWhen: (c, a) => a.has('reward'),
        engine: const {'addReward', 'updateReward'},
        example: const {'title': 'Ice cream trip', 'cost': 40, 'icon': 'treat'},
        run: _saveReward,
      ),
      ActionSpec(
        name: 'points.request_reward',
        mcpName: 'request_reward',
        title: 'Ask for a reward',
        description: 'Spends a person\'s stars on a reward. Rewards that need a parent wait for approval.',
        input: S.input({
          'reward': S.string('The reward\'s title or id.'),
          'person': S.person('Who it is for (default this connection\'s person).'),
        }, required: ['reward']),
        output: S.output({
          'request_id': Out.str('The request.'),
          'status': Out.str('requested (waiting for a parent) or approved.'),
          'balance': Out.integer('Their balance now.'),
        }),
        scopes: const {Scope.points},
        needs: const [DenAction.requestReward],
        effect: Effect.write,
        engine: const {'requestReward'},
        example: const {'reward': 'Later bedtime', 'person': 'Leo'},
        run: _request,
      ),
      ActionSpec(
        name: 'points.decide',
        mcpName: 'decide_reward_request',
        title: 'Approve or decline a reward request',
        description: 'Approves or declines a reward request waiting for a parent.',
        input: S.input({
          'request': S.string('The request id, or the name of the person who asked.'),
          'approve': S.boolean('True approves, false declines.'),
        }, required: ['request', 'approve']),
        output: S.output({'request_id': Out.str('The request.'), 'status': Out.str('approved or declined.')}),
        scopes: const {Scope.points},
        needs: const [DenAction.managePoints],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.client,
        engine: const {'decideRedemption'},
        example: const {'request': 'Maya', 'approve': false},
        run: _decide,
      ),
    ];

/// Older points tools.
List<ActionAlias> pointsAliases() => const [
      ActionAlias('create_goal', 'save_goal'),
      ActionAlias('decide_redemption', 'decide_reward_request'),
    ];

Future<ActionResult> _adjust(ActionContext c, ActionInput a) async {
  final member = c.people.one(a.str('person', required: true)!);
  final delta = a.integer('delta', required: true)!;
  if (delta == 0) throw ActionError('"delta" can\'t be zero.', field: 'delta');
  final reason = a.str('reason', required: true)!.trim();
  if (c.den.family?.pointsEnabled == false) throw ActionError('Points are turned off for this family.');
  await c.den.adjustPoints(member, delta, reason);
  final balance = c.den.points().totals[member] ?? 0;
  final name = c.people.name(member);
  return ActionResult(
    '${delta > 0 ? 'Gave' : 'Took'} ${delta.abs()} star${delta.abs() == 1 ? '' : 's'} ${delta > 0 ? 'to' : 'from'} $name. $name has $balance.',
    {'member': member, 'delta': delta, 'reason': reason, 'balance': balance},
  );
}

Goal _goal(ActionContext c, String query) => pick(query, c.den.goals, id: (g) => g.id, name: (g) => g.title, kind: 'goal');

Reward _reward(ActionContext c, String query) =>
    pick(query, c.den.rewards, id: (r) => r.id, name: (r) => r.title, kind: 'reward');

Future<ActionResult> _saveGoal(ActionContext c, ActionInput a) async {
  final people = a.has('people') ? c.people.many(a.raw['people'], 'people') : null;
  final end = a.str('end')?.trim();
  final String id;
  if (a.has('goal')) {
    final goal = _goal(c, a.str('goal')!);
    final patch = <String, Object?>{
      if (a.has('title')) 'title': a.str('title')!.trim(),
      if (a.has('target')) 'target': a.integer('target'),
      if (a.has('mode')) 'mode': a.str('mode'),
      if (people != null) 'members': people.isEmpty ? null : people,
      if (a.has('start')) 'start': toolDate(a.raw['start'], c.zone, 'start'),
      if (end != null) 'end': end.isEmpty ? null : toolDate(end, c.zone, 'end'),
      if (a.has('repeat')) 'repeat': a.str('repeat'),
      if (a.has('reward')) 'reward': a.str('reward'),
    };
    if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as target or reward.');
    await c.den.updateGoal(goal.id, patch);
    id = goal.id;
  } else {
    if (!a.has('title')) throw ActionError('A new goal needs a "title".', field: 'title');
    if (!a.has('target')) throw ActionError('A new goal needs a "target".', field: 'target');
    id = await c.den.addGoal(
      title: a.str('title', required: true)!.trim(),
      target: a.integer('target')!,
      mode: a.str('mode') == 'race' ? GoalMode.race : GoalMode.target,
      members: people == null || people.isEmpty ? null : people,
      start: a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : null,
      end: end == null || end.isEmpty ? null : toolDate(end, c.zone, 'end'),
      repeat: GoalRepeat.values.firstWhere((r) => r.name == (a.str('repeat') ?? 'none')),
      reward: a.str('reward') ?? '',
    );
  }
  final standing = c.den.points().goals.firstWhereOrNull((g) => g.goal.id == id);
  final title = standing?.goal.title ?? a.str('title') ?? 'the goal';
  return ActionResult(
    '${a.has('goal') ? 'Changed' : 'Added'} the goal $title [goal $id].',
    {'goal_id': id, 'goal': standing == null ? null : c.wire.goal(standing)},
  );
}

Future<ActionResult> _deleteGoal(ActionContext c, ActionInput a) async {
  final goal = _goal(c, a.str('goal', required: true)!);
  await c.den.deleteGoal(goal.id);
  return ActionResult('Removed the goal ${goal.title}.', {'ok': true, 'goal_id': goal.id});
}

Future<ActionResult> _saveReward(ActionContext c, ActionInput a) async {
  final String id;
  if (a.has('reward')) {
    final reward = _reward(c, a.str('reward')!);
    final patch = <String, Object?>{
      if (a.has('title')) 'title': a.str('title')!.trim(),
      if (a.has('cost')) 'cost': a.integer('cost'),
      if (a.has('icon')) 'icon': a.str('icon'),
      if (a.has('needs_approval')) 'needsApproval': a.flag('needs_approval'),
      if (a.has('active')) 'active': a.flag('active'),
    };
    if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as cost or active.');
    await c.den.updateReward(reward.id, patch);
    id = reward.id;
  } else {
    if (!a.has('title')) throw ActionError('A new reward needs a "title".', field: 'title');
    if (!a.has('cost')) throw ActionError('A new reward needs a "cost" in stars.', field: 'cost');
    id = await c.den.addReward(
      title: a.str('title', required: true)!.trim(),
      cost: a.integer('cost')!,
      icon: a.str('icon') ?? 'gift',
      needsApproval: a.flag('needs_approval') ?? true,
    );
    if (a.flag('active') == false) await c.den.updateReward(id, {'active': false});
  }
  final reward = c.den.rewards.firstWhere((r) => r.id == id);
  final how = reward.active ? '${reward.cost} stars${reward.needsApproval ? ', a parent approves it' : ''}' : 'retired';
  return ActionResult(
    '${a.has('reward') ? 'Changed' : 'Added'} the reward ${reward.title} ($how) [reward $id].',
    {'reward': Wire.reward(reward)},
  );
}

Future<ActionResult> _request(ActionContext c, ActionInput a) async {
  final reward = c.reward(a.str('reward', required: true)!);
  final who = a.has('person') ? c.people.one(a.str('person')!) : c.member;
  if (who == null) throw ActionError('Say who the reward is for with "person".', field: 'person');
  final id = await c.den.requestReward(reward.id, member: who);
  final r = c.den.points();
  final pending = r.pending.any((p) => p.id == id);
  return ActionResult(
    pending
        ? '${c.people.name(who)} asked for ${reward.title}; a parent needs to approve it [request $id].'
        : '${c.people.name(who)} got ${reward.title} for ${reward.cost} stars.',
    {'request_id': id, 'status': pending ? 'requested' : 'approved', 'balance': r.totals[who] ?? 0},
  );
}

/// A pending reward request by id or by the name of who asked.
Redemption pendingRequest(ActionContext c, String query) {
  final summary = c.den.points();
  final titles = {for (final r in c.den.rewards) r.id: r.title};
  return pick(
    query,
    summary.pending,
    id: (p) => p.id,
    name: (p) => c.people.name(p.member),
    kind: 'pending reward request',
    describe: (p) => '${c.people.name(p.member)} asked for ${titles[p.reward] ?? 'a reward'} (id ${p.id})',
  );
}

Future<ActionResult> _decide(ActionContext c, ActionInput a) async {
  final approve = a.flag('approve') ?? (throw ActionError('"approve" is required.', field: 'approve'));
  final request = pendingRequest(c, a.str('request', required: true)!);
  final titles = {for (final r in c.den.rewards) r.id: r.title};
  await c.den.decideRedemption(request.id, approve: approve);
  return ActionResult(
    '${approve ? 'Approved' : 'Declined'} ${titles[request.reward] ?? 'the reward'} for ${c.people.name(request.member)}'
    ' (${shortDate(dateIn(c.zone, request.rec.created.millis))}).',
    {'request_id': request.id, 'status': approve ? 'approved' : 'declined'},
  );
}
