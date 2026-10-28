import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/chore_pictograms.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/points_model.dart';
import '../state/reward_actions.dart';
import '../widgets/give_stars.dart';
import '../words/points_words.dart';

/// Points and rewards, built from the same system as Chores (there is no board of its own):
/// requests waiting for a parent, each person's stars and the bar toward their goal, the
/// rewards to spend them on, the goals, and what came and went. Every one-tap action (Approve,
/// Decline, Give, Ask for this) says what it did in place, with Undo. `/points`.
class PointsScreen extends StatefulWidget {
  const PointsScreen({super.key});

  /// The content width from which the store and recent sit beside the rest.
  static const double twoColumns = 760;

  @override
  State<PointsScreen> createState() => _PointsScreenState();
}

class _PointsScreenState extends State<PointsScreen> {
  int _recentShown = 10;
  final _decided = <String, Done>{};
  final _asked = <String, Done>{};
  Done? _given;

  Future<void> _undo(Done note, VoidCallback forget) async {
    final receipt = note.receipt;
    if (receipt == null) return;
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(forget);
  }

  Future<void> _decide(Redemption r, Reward? reward, bool approve) async {
    final name = DenScope.read(context).memberById(r.member)?.name ?? 'them';
    final result = await perform(context, () => context.rewardActions.decide(r, approve: approve));
    if (result == null || !mounted) return;
    final what = reward?.title ?? 'The reward';
    setState(() => _decided[r.id] = (message: approve ? '$what approved for $name' : '$what declined for $name', receipt: result.receipt));
  }

  Future<void> _give([String? member]) async {
    final given = await showGiveStars(context, member: member);
    if (given != null && mounted) setState(() => _given = given);
  }

  Future<void> _ask(Reward reward) async {
    final result = await perform(context, () => context.rewardActions.request(reward));
    if (result == null || !mounted) return;
    setState(() => _asked[reward.id] = (message: reward.needsApproval ? 'Asked' : 'Yours', receipt: result.receipt));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final den = app.den;
    final compact = DenLayout.of(context).isCompact;

    if (!(den.family?.pointsEnabled ?? true)) {
      final canTurnOn = app.allowsTrust(DenAction.manageFamily);
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          message: canTurnOn
              ? 'Points are off for this family. Turn them on in Settings, under Family.'
              : 'Points are off for this family. A parent can turn them on.',
          actionLabel: canTurnOn ? 'Open Settings' : null,
          onAction: canTurnOn ? () => context.push('/settings') : null,
        ),
      );
    }

    final summary = context.view(const PointsModel());
    final manage = app.allows(DenAction.managePoints);
    final me = app.me;
    final holders = [
      if (me != null && (me.isKid || (summary.totals[me.id] ?? 0) != 0)) me,
      for (final m in den.members)
        if (m.id != me?.id && m.role != Role.guest && (m.isKid || (summary.totals[m.id] ?? 0) != 0)) m,
    ];
    final rewards = {for (final r in den.rewards) r.id: r};
    // Nobody decides their own request, a points manager's included. A request decided here
    // keeps its place, saying what happened, until the page is left.
    final pendingIds = {for (final r in summary.pending) r.id};
    for (final r in summary.pending) {
      if (manage && r.member != me?.id) _kept.putIfAbsent(r.id, () => r);
    }
    final waiting = [
      for (final e in _kept.entries)
        if (pendingIds.contains(e.key) || _decided.containsKey(e.key)) e.value,
    ];

    final approvals = waiting.isEmpty
        ? null
        : DenSection(
            title: 'Waiting for you',
            trailing: SectionCount('${summary.pending.where((r) => r.member != me?.id).length} to decide'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: ruled([
                for (final r in waiting) _request(app, r, rewards[r.reward], summary.totals[r.member] ?? 0),
              ], indent: RowRule.afterFace),
            ),
          );

    final balances = DenSection(
      title: 'Stars',
      trailing: manage ? SectionLink('Give points', onTap: () => _give()) : null,
      child: holders.isEmpty
          ? const EmptyState(compact: true, message: 'No one has stars yet. Chores with stars earn them.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...ruled([
                  for (final m in holders)
                    _Balance(
                      member: m,
                      stars: summary.totals[m.id] ?? 0,
                      goal: currentGoal(summary, m.id, app.today),
                      onTap: manage && m.id != me?.id ? () => _give(m.id) : null,
                    ),
                ], indent: RowRule.afterFace),
                if (_given case final given?) ...[
                  const RowRule(),
                  DoneRow(
                    message: given.message,
                    onUndo: given.receipt?.undoable == true ? () => _undo(given, () => _given = null) : null,
                  ),
                ],
              ],
            ),
    );

    final store = _Store(
      rewards: summary.rewards,
      pending: summary.pending,
      balance: me == null ? 0 : summary.available(me.id),
      manage: manage,
      asked: _asked,
      onAsk: _ask,
      onUndo: (id) => _undo(_asked[id]!, () => _asked.remove(id)),
    );

    final goals = summary.goals.isEmpty && !manage
        ? null
        : DenSection(
            title: 'Goals',
            trailing: manage ? SectionLink('New goal', onTap: () => context.push('/points/goal/new')) : null,
            carded: false,
            child: summary.goals.isEmpty
                ? const GroupCard(child: EmptyState(compact: true, message: 'No goals yet. A goal is a number of stars to reach by the end of the week.'))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, g) in summary.goals.indexed) ...[
                        if (i > 0) const SizedBox(height: Sp.m),
                        _GoalCard(standing: g, manage: manage),
                      ],
                    ],
                  ),
          );

    final recent = _Recent(lines: summary.recent, shown: _recentShown, onMore: () => setState(() => _recentShown += 20));

    return Scaffold(
      appBar: AppBar(),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final two = constraints.maxWidth >= PointsScreen.twoColumns;
          final side = two ? 32.0 : (compact ? DenLayout.gutter : 24.0);
          Widget column(List<Widget?> parts) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, p) in parts.nonNulls.indexed) ...[if (i > 0) const SizedBox(height: DenLayout.sectionGap), p],
                ],
              );
          final header = PageHeader(title: 'Points and rewards', large: !compact);
          return ListView(
            padding: EdgeInsets.fromLTRB(side, 0, side, Sp.xxl),
            children: [
              header,
              const SizedBox(height: DenLayout.sectionGap),
              if (two)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: column([approvals, balances, goals])),
                    const SizedBox(width: DenLayout.sectionGap),
                    Expanded(child: column([store, recent])),
                  ],
                )
              else
                column([approvals, balances, store, goals, recent]),
            ],
          );
        },
      ),
    );
  }

  /// The requests shown here, in the order they came, so one decided keeps its place.
  final _kept = <String, Redemption>{};

  Widget _request(AppState app, Redemption r, Reward? reward, int balance) {
    final name = app.memberById(r.member)?.name ?? 'Someone';
    final note = _decided[r.id];
    final m = app.memberById(r.member);
    return KeyedSubtree(
      key: ValueKey(r.id),
      child: DoneSwap(
        done: note == null
            ? null
            : DoneRow(
                message: note.message,
                onUndo: note.receipt?.undoable == true ? () => _undo(note, () => _decided.remove(r.id)) : null,
              ),
        child: ActionRow(
          leading: m == null ? null : DenAvatar(m, size: 40),
          title: '$name wants ${reward?.title ?? 'a reward'}',
          detail: 'Costs ${r.cost} stars, $name has $balance',
          action: Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              FilledButton(onPressed: () => _decide(r, reward, true), child: const Text('Approve')),
              TextButton(onPressed: () => _decide(r, reward, false), child: const Text('Decline')),
            ],
          ),
        ),
      ),
    );
  }
}

/// One person's stars: their face and name, the bar toward their goal and what it's for, and
/// the count. A parent taps it to give or take stars.
class _Balance extends StatelessWidget {
  const _Balance({required this.member, required this.stars, required this.goal, required this.onTap});

  final Member member;
  final int stars;
  final (GoalStanding, Standing)? goal;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final c = context.colors;
    final t = context.text;
    final g = goal;
    final line = g == null ? null : goalLine(g.$1, g.$2, app.today, app.formats);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.m),
      child: Row(
        crossAxisAlignment: g == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          DenAvatar(member, size: 40),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(child: Text(member.name, style: t.rowTitle(c.ink))),
                    Text('$stars', style: t.section(c.ink)),
                    const SizedBox(width: 4),
                    const Star(size: 18),
                  ],
                ),
                if (g != null) ...[
                  const SizedBox(height: 6),
                  ProgressBar(fraction: goalFraction(g.$1, g.$2), color: c.marker(member.marker), label: '${member.name}, $line'),
                  const SizedBox(height: 6),
                  ExcludeSemantics(child: Text(tidy(line!), style: t.meta(c.ink2))),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    final labelled = Semantics(label: '${member.name}, $stars stars${line == null ? '' : ', $line'}', excludeSemantics: true, child: row);
    if (onTap == null) return labelled;
    return DenPressable(onTap: onTap, scale: false, shape: const RoundedRectangleBorder(), semanticLabel: 'Give or take stars for ${member.name}', child: labelled);
  }
}

/// The rewards to spend stars on, as cards: what it is and what it costs. A kid asks for one
/// (or, when it needs no approval, gets it); a parent opens it to change it.
class _Store extends StatelessWidget {
  const _Store({
    required this.rewards,
    required this.pending,
    required this.balance,
    required this.manage,
    required this.asked,
    required this.onAsk,
    required this.onUndo,
  });

  final List<Reward> rewards;
  final List<Redemption> pending;

  /// What the person can still spend: their balance less their requests waiting for a parent.
  final int balance;
  final bool manage;
  final Map<String, Done> asked;
  final ValueChanged<Reward> onAsk;
  final ValueChanged<String> onUndo;

  @override
  Widget build(BuildContext context) {
    return DenSection(
      title: 'Rewards',
      trailing: manage ? SectionLink('New reward', onTap: () => context.push('/points/reward/new')) : null,
      carded: false,
      child: rewards.isEmpty
          ? GroupCard(
              child: EmptyState(
                compact: true,
                message: manage ? 'No rewards yet. Add what stars can buy: a later bedtime, picking dinner.' : 'No rewards yet. A parent can add some.',
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 560 ? 3 : 2;
                final width = (constraints.maxWidth - Sp.s * (columns - 1)) / columns;
                return Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  children: [
                    for (final r in rewards)
                      SizedBox(
                        width: width,
                        child: _RewardCard(
                          reward: r,
                          pending: pending,
                          balance: balance,
                          manage: manage,
                          note: asked[r.id],
                          onAsk: () => onAsk(r),
                          onUndo: () => onUndo(r.id),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _RewardCard extends StatelessWidget {
  const _RewardCard({
    required this.reward,
    required this.pending,
    required this.balance,
    required this.manage,
    required this.note,
    required this.onAsk,
    required this.onUndo,
  });

  final Reward reward;
  final List<Redemption> pending;
  final int balance;
  final bool manage;
  final Done? note;
  final VoidCallback onAsk;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final c = context.colors;
    final t = context.text;
    final me = app.me;
    final canAsk = !manage && me != null && app.allows(DenAction.requestReward);
    final asked = me != null && pending.any((p) => p.reward == reward.id && p.member == me.id);
    final short = reward.cost - balance;
    final n = note;

    Widget? foot;
    if (canAsk) {
      if (n != null) {
        foot = Row(
          children: [
            Icon(PhosphorIconsBold.check, size: 18, color: c.ink),
            const SizedBox(width: Sp.xs),
            Expanded(child: Text(n.message, style: t.label(c.ink))),
            if (n.receipt?.undoable == true) UndoButton(onTap: onUndo),
          ],
        );
      } else if (asked) {
        foot = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Asked', style: t.label(c.ink)),
            Text('Waiting for a parent', style: t.meta(c.ink2)),
          ],
        );
      } else if (short > 0) {
        foot = DisabledReason(
          reason: '$short more to go',
          child: OutlinedButton(onPressed: null, child: Text(reward.needsApproval ? 'Ask for this' : 'Get it')),
        );
      } else {
        foot = FilledButton(onPressed: onAsk, child: Text(reward.needsApproval ? 'Ask for this' : 'Get it'));
      }
    }

    final card = GroupCard(
      padding: const EdgeInsets.all(DenLayout.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(HomePictograms.reward(reward.icon), size: 32, color: c.ink),
          const SizedBox(height: Sp.s),
          Text(tidy(reward.title), style: t.rowTitle(c.ink)),
          const SizedBox(height: Sp.xs),
          Row(
            children: [
              Text('${reward.cost}', style: t.body(c.ink)),
              const SizedBox(width: 4),
              const Star(size: 16),
              if (!reward.needsApproval) ...[
                const SizedBox(width: Sp.s),
                Flexible(child: Text('no asking', style: t.meta(c.ink2))),
              ],
            ],
          ),
          if (foot != null) ...[const SizedBox(height: Sp.m), foot],
        ],
      ),
    );
    if (!manage) return card;
    return DenPressable(
      onTap: () => context.push('/points/reward/${reward.id}'),
      scale: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.section))),
      semanticLabel: 'Change ${reward.title}',
      child: card,
    );
  }
}

/// One goal: what it is ("Reach 25 stars, this week"), and each person's bar toward it.
class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.standing, required this.manage});

  final GoalStanding standing;
  final bool manage;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final c = context.colors;
    final t = context.text;
    final goal = standing.goal;
    final target = goal.target < 1 ? 1 : goal.target;
    final when = windowWords(standing, app.today, app.formats).toLowerCase();
    final head = Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tidy(goal.title), style: t.rowTitle(c.ink)),
          const SizedBox(height: 2),
          Text(tidy('Reach $target stars, $when${goal.reward.isEmpty ? '' : '. ${goal.reward}'}'), style: t.meta(c.ink2)),
        ],
      ),
    );
    return GroupCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (manage)
            DenPressable(
              onTap: () => context.push('/points/goal/${goal.id}'),
              scale: false,
              shape: const RoundedRectangleBorder(),
              semanticLabel: 'Change ${goal.title}',
              child: head,
            )
          else
            head,
          for (final s in standing.standings)
            if (app.memberById(s.member) case final m?)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.m),
                child: MergeSemantics(
                  child: Row(
                    children: [
                      DenAvatar(m, size: 26),
                      const SizedBox(width: Sp.s),
                      SizedBox(width: 72, child: Text(m.name, style: t.body(c.ink), overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: Sp.s),
                      Expanded(
                        child: ProgressBar(
                          fraction: s.earned / target,
                          color: c.marker(m.marker),
                          label: '${m.name}, ${s.earned} of $target',
                        ),
                      ),
                      const SizedBox(width: Sp.m),
                      Text(s.earned >= target ? 'Reached' : '${s.earned} of $target', style: s.earned >= target ? t.meta(c.ink).bold : t.meta(c.ink2)),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Stars in and out, newest first.
class _Recent extends StatelessWidget {
  const _Recent({required this.lines, required this.shown, required this.onMore});
  final List<PointsLine> lines;
  final int shown;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    return DenSection(
      title: 'Recent',
      child: lines.isEmpty
          ? const EmptyState(compact: true, message: 'No stars earned or spent yet.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...ruled([
                  for (final line in lines.take(shown))
                    MergeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: Sp.m),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 56,
                              child: Row(
                                children: [
                                  Text(deltaWords(line.delta), style: t.rowTitle(c.ink)),
                                  const SizedBox(width: 2),
                                  const Star(size: 14),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tidy(line.reason.isEmpty ? _sourceWords(line.source) : line.reason), style: t.body(c.ink)),
                                  Text(
                                    tidy('${app.memberById(line.member)?.name ?? 'Someone'}, '
                                        '${f.relative(f.localDate(line.when), app.today)} at ${f.time(line.when)}'),
                                    style: t.meta(c.ink2),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ]),
                if (lines.length > shown)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(onPressed: onMore, child: const Text('Show more')),
                  ),
              ],
            ),
    );
  }

  static String _sourceWords(PointsSource s) => switch (s) {
        PointsSource.chore => 'Chore done',
        PointsSource.step => 'Step done',
        PointsSource.adjustment => 'Stars from a parent',
        PointsSource.reward => 'Reward',
      };
}
