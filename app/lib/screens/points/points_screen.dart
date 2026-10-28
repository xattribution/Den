import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/home_goal_bar.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'points_words.dart';
import '../../design/parts/home_pictograms.dart';

/// Points and rewards: everyone's balance, goals as each person's progress in their marker,
/// requests waiting for a parent, the rewards store, and recent points in and out. `/points`.
class PointsScreen extends StatefulWidget {
  const PointsScreen({super.key});

  @override
  State<PointsScreen> createState() => _PointsScreenState();
}

class _PointsScreenState extends State<PointsScreen> {
  int _recentShown = 12;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final family = den.family;
    final manage = app.allows(DenAction.managePoints);

    if (!(family?.pointsEnabled ?? true)) {
      final canTurnOn = app.allows(DenAction.manageFamily);
      return Scaffold(
        appBar: AppBar(title: const Text('Points and rewards')),
        body: EmptyLine(
          message: canTurnOn
              ? 'Points are turned off for this family.'
              : 'Points are turned off for this family. A parent can turn them on.',
          actionLabel: canTurnOn ? 'Turn on points' : null,
          onAction: () => attempt(context, () => den.updateFamily({'pointsEnabled': true})),
        ),
      );
    }

    final summary = den.points();
    final me = app.me;
    final members = den.members;
    final holders = [
      if (me != null && (me.isKid || (summary.totals[me.id] ?? 0) != 0)) me,
      for (final m in members)
        if (m.id != me?.id && m.role != Role.guest && (m.isKid || (summary.totals[m.id] ?? 0) != 0)) m,
    ];
    final pending = manage ? summary.pending : summary.pending.where((r) => r.member == me?.id).toList();
    final rewards = summary.rewards;

    return Scaffold(
      appBar: AppBar(title: const Text('Points and rewards')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth > 960 ? 960.0 : constraints.maxWidth) - Sp.l * 2;
          return ListView(
            padding: const EdgeInsets.only(bottom: Sp.xxxl),
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width + Sp.l * 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Balances(holders: holders, totals: summary.totals, width: width, manage: manage, me: me?.id),
                      if (pending.isNotEmpty) _Pending(pending: pending, rewards: summary.rewards, manage: manage),
                      _Goals(goals: summary.goals, manage: manage),
                      _Store(
                        rewards: rewards,
                        pending: summary.pending,
                        // Requests still waiting for a parent count against what's left to spend.
                        balance: me == null ? 0 : summary.available(me.id),
                        width: width,
                        manage: manage,
                      ),
                      _Recent(
                        lines: summary.recent,
                        shown: _recentShown,
                        onMore: () => setState(() => _recentShown += 20),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Balances extends StatelessWidget {
  const _Balances({required this.holders, required this.totals, required this.width, required this.manage, this.me});
  final List<Member> holders;
  final Map<String, int> totals;
  final double width;
  final bool manage;

  /// Who is looking: nobody gives themselves points, so their own balance doesn't open Give.
  final String? me;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final header = SectionHeader(
      'Balances',
      action: manage
          ? TextButton.icon(
              onPressed: () => context.push('/points/adjust?back=1'),
              icon: const Star(size: 18),
              label: const Text('Give points'),
            )
          : null,
    );
    if (holders.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const EmptyLine(message: 'No one has points yet.'),
        ],
      );
    }
    final columns = (width / 164).floor().clamp(1, 6);
    final tileWidth = (width - (columns - 1) * Sp.s) / columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, 0),
          child: Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              for (final m in holders)
                SizedBox(
                  width: tileWidth,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.control),
                    onTap: manage && m.id != me ? () => context.push('/points/adjust?back=1&member=${m.id}') : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Sp.s),
                      child: Semantics(
                        label: '${m.name}, ${totals[m.id] ?? 0} points',
                        excludeSemantics: true,
                        child: Row(
                          children: [
                            DenAvatar(m, size: 44),
                            const SizedBox(width: Sp.m),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.name, style: context.type.body(c.ink2), overflow: TextOverflow.ellipsis),
                                  StarCount(totals[m.id] ?? 0, size: 30, style: context.type.display(c.ink)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending({required this.pending, required this.rewards, required this.manage});
  final List<Redemption> pending;
  final List<Reward> rewards;
  final bool manage;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final den = app.den;
    String rewardTitle(Redemption r) => rewards.where((x) => x.id == r.reward).firstOrNull?.title ?? 'a reward';
    // Nobody decides their own request, a points manager's included.
    bool decides(Redemption r) => manage && r.member != app.me?.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.l, Sp.s),
          child: Semantics(
            header: true,
            child: Row(
              children: [
                Icon(PhosphorIconsFill.warning, size: 18, color: c.caution),
                const SizedBox(width: Sp.s),
                Expanded(child: Text('Waiting for approval', style: context.type.title(c.ink))),
              ],
            ),
          ),
        ),
        for (final r in pending)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, Sp.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (den.member(r.member) case final m?) DenAvatar(m, size: 28),
                    const SizedBox(width: Sp.s),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: decides(r) ? (den.member(r.member)?.name ?? 'Someone') : 'You',
                              style: context.type.bodyStrong(c.ink),
                            ),
                            TextSpan(text: decides(r) ? ' asks for ' : ' asked for ', style: context.type.body(c.ink)),
                            TextSpan(text: rewardTitle(r), style: context.type.bodyStrong(c.ink)),
                          ],
                        ),
                      ),
                    ),
                    StarCount(r.cost, size: 18, style: context.type.body(c.ink)),
                  ],
                ),
                if (decides(r))
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => attempt(context, () => den.decideRedemption(r.id, approve: false)),
                        child: const Text('Decline'),
                      ),
                      const SizedBox(width: Sp.s),
                      FilledButton(
                        onPressed: () => attempt(context, () => den.decideRedemption(r.id, approve: true)),
                        child: const Text('Approve'),
                      ),
                    ],
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(left: 28 + Sp.s, top: Sp.xs),
                    child: Text('Waiting for a parent to approve', style: context.type.meta(c.ink2)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Goals extends StatelessWidget {
  const _Goals({required this.goals, required this.manage});
  final List<GoalStanding> goals;
  final bool manage;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    if (goals.isEmpty && !manage) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Goals',
          action: manage
              ? TextButton.icon(
                  onPressed: () => context.push('/points/goal/new'),
                  icon: const Icon(PhosphorIconsBold.plus, size: 18),
                  label: const Text('Add goal'),
                )
              : null,
        ),
        if (goals.isEmpty) const EmptyLine(message: 'No goals yet.'),
        for (final (i, g) in goals.indexed) ...[
          if (i > 0) Divider(height: Sp.xl, indent: Sp.l, endIndent: Sp.l, color: c.rule),
          _GoalBlock(standing: g, manage: manage, today: app.today),
        ],
      ],
    );
  }
}

class _GoalBlock extends StatelessWidget {
  const _GoalBlock({required this.standing, required this.manage, required this.today});
  final GoalStanding standing;
  final bool manage;
  final String today;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final goal = standing.goal;
    final target = goal.target < 1 ? 1 : goal.target;
    final winner = goal.mode == GoalMode.race ? standing.winner : null;
    final byMember = {for (final s in standing.standings) s.member: s};
    final people = [for (final s in standing.standings) ?den.member(s.member)];

    return InkWell(
      onTap: manage ? () => context.push('/points/goal/${goal.id}') : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, Sp.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: Text(goal.title, style: context.type.bodyStrong(c.ink))),
                const SizedBox(width: Sp.s),
                Text(windowWords(standing, today, app.formats), style: context.type.meta(c.ink2)),
                if (manage) ...[
                  const SizedBox(width: Sp.xs),
                  Icon(PhosphorIconsRegular.caretRight, size: 14, color: c.ink3),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: Sp.s),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Sp.xs,
                children: [
                  Text(goal.mode == GoalMode.race ? 'First to' : 'Reach', style: context.type.meta(c.ink2)),
                  StarCount(target),
                  if (goal.reward.isNotEmpty) ...[
                    const SizedBox(width: Sp.s),
                    Icon(PhosphorIconsRegular.gift, size: 14, color: c.ink2),
                    Text(goal.reward, style: context.type.meta(c.ink2)),
                  ],
                ],
              ),
            ),
            for (final m in people)
              _StandingRow(member: m, standing: byMember[m.id]!, target: target, winner: winner == m.id),
            if (winner != null && den.member(winner) != null)
              Padding(
                padding: const EdgeInsets.only(top: Sp.xs),
                child: Row(
                  children: [
                    Icon(PhosphorIconsFill.trophy, size: 16, color: c.ink),
                    const SizedBox(width: Sp.s),
                    Text('${den.member(winner)!.name} got there first', style: context.type.body(c.ink)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StandingRow extends StatelessWidget {
  const _StandingRow({required this.member, required this.standing, required this.target, required this.winner});
  final Member member;
  final Standing standing;
  final int target;
  final bool winner;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reached = standing.reachedAt != null || standing.earned >= target;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.xs),
      child: Row(
        children: [
          DenAvatar(member, size: 24),
          const SizedBox(width: Sp.s),
          SizedBox(
            width: 64,
            child: Text(member.name, style: context.type.body(c.ink), overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: Sp.s),
          Expanded(
            child: GoalBar(
              fraction: standing.earned / target,
              color: c.marker(member.marker),
              semanticLabel: '${member.name}, ${standing.earned} of $target',
            ),
          ),
          const SizedBox(width: Sp.m),
          SizedBox(
            width: 84,
            child: reached
                ? Row(
                    children: [
                      Icon(PhosphorIconsBold.check, size: 16, color: c.ink),
                      const SizedBox(width: Sp.xs),
                      Text('Reached', style: context.type.bodyStrong(c.ink)),
                    ],
                  )
                : Text('${standing.earned} of $target', style: context.type.meta(c.ink2)),
          ),
        ],
      ),
    );
  }
}

class _Store extends StatelessWidget {
  const _Store({
    required this.rewards,
    required this.pending,
    required this.balance,
    required this.width,
    required this.manage,
  });
  final List<Reward> rewards;
  final List<Redemption> pending;
  final int balance;
  final double width;
  final bool manage;

  @override
  Widget build(BuildContext context) {
    final columns = (width / 200).floor().clamp(2, 5);
    final cardWidth = (width - (columns - 1) * Sp.s) / columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Rewards',
          action: manage
              ? TextButton.icon(
                  onPressed: () => context.push('/points/reward/new'),
                  icon: const Icon(PhosphorIconsBold.plus, size: 18),
                  label: const Text('Add reward'),
                )
              : null,
        ),
        if (rewards.isEmpty)
          EmptyLine(message: manage ? 'No rewards yet.' : 'No rewards yet. A parent can add some.')
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l),
            child: Wrap(
              spacing: Sp.s,
              runSpacing: Sp.s,
              children: [
                for (final r in rewards)
                  SizedBox(
                    width: cardWidth,
                    child: _RewardCard(reward: r, pending: pending, balance: balance, manage: manage),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RewardCard extends StatelessWidget {
  const _RewardCard({required this.reward, required this.pending, required this.balance, required this.manage});
  final Reward reward;
  final List<Redemption> pending;

  /// What the person can still spend: their balance less their requests waiting for a parent.
  final int balance;
  final bool manage;

  Future<void> _ask(BuildContext context) async {
    final den = context.den;
    if (!reward.needsApproval) {
      final c = context.colors;
      final sure = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Spend ${reward.cost} points on ${reward.title}?'),
          content: Text('Points spent on a reward don\'t come back.', style: dialogContext.type.body(c.ink2)),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep points')),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('Spend ${reward.cost} points'),
            ),
          ],
        ),
      );
      if (sure != true || !context.mounted) return;
    }
    await attempt(context, () => den.requestReward(reward.id));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final me = app.me;
    final canAsk = !manage && me != null && app.allows(DenAction.requestReward);
    final asked = me != null && pending.any((p) => p.reward == reward.id && p.member == me.id);
    final short = reward.cost - balance;

    return Material(
      color: c.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        side: BorderSide(color: c.rule),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: manage ? () => context.push('/points/reward/${reward.id}') : null,
        child: Padding(
          padding: const EdgeInsets.all(Sp.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(HomePictograms.reward(reward.icon), size: 32, color: c.ink),
              const SizedBox(height: Sp.s),
              Text(reward.title, style: context.type.bodyStrong(c.ink), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: Sp.xs),
              StarCount(reward.cost, size: 18, style: context.type.body(c.ink)),
              if (canAsk) ...[
                const SizedBox(height: Sp.m),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: asked || short > 0 ? null : () => _ask(context),
                    child: Text(asked ? 'Asked' : 'Ask for this'),
                  ),
                ),
                if (!asked && short > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: Sp.xs),
                    child: Text('$short more to go', style: context.type.meta(c.ink2)),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Recent extends StatelessWidget {
  const _Recent({required this.lines, required this.shown, required this.onMore});
  final List<PointsLine> lines;
  final int shown;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Recent'),
        if (lines.isEmpty) const EmptyLine(message: 'No points earned or spent yet.'),
        for (final line in lines.take(shown))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s - 2),
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Row(
                      children: [
                        Text(deltaWords(line.delta), style: context.type.bodyStrong(c.ink)),
                        const SizedBox(width: 2),
                        const Star(size: 14),
                      ],
                    ),
                  ),
                  if (app.memberById(line.member) case final m?) ...[
                    DenAvatar(m, size: 22),
                    const SizedBox(width: Sp.s),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          line.reason.isEmpty ? _sourceWords(line.source) : line.reason,
                          style: context.type.body(c.ink),
                        ),
                        Text(
                          '${app.memberById(line.member)?.name ?? 'Someone'}, '
                          '${f.relative(f.localDate(line.when), app.today)} at ${f.time(line.when)}',
                          style: context.type.meta(c.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (lines.length > shown)
          Padding(
            padding: const EdgeInsets.only(left: Sp.s),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: onMore, child: const Text('Show more')),
            ),
          ),
      ],
    );
  }

  static String _sourceWords(PointsSource s) => switch (s) {
    PointsSource.chore => 'Chore done',
    PointsSource.step => 'Step done',
    PointsSource.adjustment => 'Points from a parent',
    PointsSource.reward => 'Reward',
  };
}
