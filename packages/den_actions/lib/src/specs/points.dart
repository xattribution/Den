import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';

/// Points actions: stars given or taken, goals, and rewards asked for and decided.
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
        name: 'points.create_goal',
        mcpName: 'create_goal',
        title: 'Add a goal',
        description: 'Adds a star goal: reach a target, or race to it first.',
        input: S.input({
          'title': S.string('The goal.', maxLength: 200),
          'target': S.integer('Stars to reach.', min: 1, max: 100000),
          'mode': S.string('target (everyone can reach it) or race (first to reach it wins).', oneOf: ['target', 'race']),
          'people': S.people('Who takes part (default every kid).'),
          'start': S.date('First day (default today).'),
          'end': S.date('Last day (default open-ended).'),
          'repeat': S.string('Start over every week or month.', oneOf: ['none', 'weekly', 'monthly']),
          'reward': S.string('What reaching it earns.', maxLength: 200),
        }, required: ['title', 'target']),
        output: S.output({'goal_id': Out.str('The new goal.')}),
        scopes: const {Scope.points},
        needs: const [DenAction.managePoints],
        effect: Effect.write,
        engine: const {'addGoal'},
        example: const {'title': 'Summer reading', 'target': 40, 'reward': 'A trip to the bookstore'},
        run: _goal,
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
        mcpName: 'decide_redemption',
        title: 'Approve or decline a reward request',
        description: 'Approves or declines a pending reward request.',
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

Future<ActionResult> _goal(ActionContext c, ActionInput a) async {
  final title = a.str('title', required: true)!.trim();
  final id = await c.den.addGoal(
    title: title,
    target: a.integer('target', required: true)!,
    mode: a.str('mode') == 'race' ? GoalMode.race : GoalMode.target,
    members: a.has('people') ? c.people.many(a.raw['people'], 'people') : null,
    start: a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : null,
    end: a.has('end') ? toolDate(a.raw['end'], c.zone, 'end') : null,
    repeat: GoalRepeat.values.firstWhere((r) => r.name == (a.str('repeat') ?? 'none')),
    reward: a.str('reward') ?? '',
  );
  return ActionResult('Added the goal $title [goal $id].', {'goal_id': id});
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
  final titles = {for (final r in summary.rewards) r.id: r.title};
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
  final titles = {for (final r in c.den.points().rewards) r.id: r.title};
  await c.den.decideRedemption(request.id, approve: approve);
  return ActionResult(
    '${approve ? 'Approved' : 'Declined'} ${titles[request.reward] ?? 'the reward'} for ${c.people.name(request.member)}'
    ' (${shortDate(dateIn(c.zone, request.rec.created.millis))}).',
    {'request_id': request.id, 'status': approve ? 'approved' : 'declined'},
  );
}
