import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/family_glyphs.dart';
import '../../design/pictograms.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'kid_parts.dart';

/// The little kid's app: three big tabs, "My jobs", "My days" and "My stars". Title, heading and
/// display type only; 72-dp targets; 16-radius cards for the things they act on.
class LittleKidApp extends StatefulWidget {
  const LittleKidApp({super.key, required this.kid, required this.header, this.initialTab = 0});

  final Member kid;
  final Widget header;
  final int initialTab;

  @override
  State<LittleKidApp> createState() => _LittleKidAppState();
}

class _LittleKidAppState extends State<LittleKidApp> {
  late int _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final points = context.den.family?.pointsEnabled ?? true;
    final tabs = [
      const KidTab(PhosphorIconsFill.checkCircle, 'My jobs'),
      const KidTab(PhosphorIconsFill.calendarBlank, 'My days'),
      if (points) const KidTab(PhosphorIconsFill.star, 'My stars'),
    ];
    final tab = _tab.clamp(0, tabs.length - 1);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: widget.header),
            ),
            Expanded(
              child: switch (tab) {
                0 => _Jobs(kid: widget.kid),
                1 => _Days(kid: widget.kid),
                _ => _Stars(kid: widget.kid),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: KidTabs(tabs: tabs, index: tab, onChanged: (i) => setState(() => _tab = i)),
    );
  }
}

/// Wide screens hold cards to a readable width.
class _Page extends StatelessWidget {
  const _Page({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.xl), children: children),
    ),
  );
}

class _Jobs extends StatelessWidget {
  const _Jobs({required this.kid});
  final Member kid;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final jobs = kidJobs(app.den, app.today, kid.id);
    if (jobs.isEmpty) {
      return Center(child: Text('No jobs today', style: context.type.heading(c.ink2)));
    }
    final left = jobs.where((j) => !j.done).length;
    return _Page(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.m),
          child: Text(left == 0 ? 'All done' : '$left to go', style: context.type.title(c.ink2)),
        ),
        for (final j in jobs)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.m),
            child: _JobCard(job: j),
          ),
      ],
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job});
  final KidJob job;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final day = job.day;
    final chore = day.chore;
    final done = job.done;
    final title = context.type
        .title(done ? c.ink2 : c.ink)
        .copyWith(decoration: done ? TextDecoration.lineThrough : null, decorationColor: c.ink2);
    return KidCard(
      done: done,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(choreGlyph(chore.icon, chore.title), size: 48, color: done ? c.ink3 : c.ink),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chore.title, style: title),
                    if (job.points > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: Sp.xs),
                        child: StarCount(job.points, size: 22, style: context.type.title(c.ink2)),
                      ),
                  ],
                ),
              ),
              if (job.owned)
                BigCheck(
                  done: day.done,
                  size: 80,
                  label: chore.title,
                  onChanged: (v) => attempt(context, () => den.setChoreDone(chore.id, day.date, v)),
                ),
            ],
          ),
          if (job.steps.isNotEmpty) ...[
            const SizedBox(height: Sp.s),
            for (final s in job.steps) _StepRow(day: day, step: s),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.day, required this.step});
  final ChoreDay day;
  final ChoreStep step;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final checked = day.steps[step.id] != null;
    return Semantics(
      button: true,
      checked: checked,
      label: step.text,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: () => attempt(context, () => den.setStep(day.chore.id, day.date, step.id, !checked)),
        child: SizedBox(
          height: Targets.kid,
          child: Row(
            children: [
              const SizedBox(width: Sp.s),
              AnimatedContainer(
                duration: Motion.of(context, Motion.state),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: checked ? c.ink : Colors.transparent,
                  border: Border.all(color: checked ? c.ink : c.ink2, width: 3),
                ),
                child: checked ? Icon(PhosphorIconsBold.check, size: 22, color: c.onInk) : null,
              ),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Text(
                  step.text,
                  style: context.type
                      .title(checked ? c.ink2 : c.ink)
                      .copyWith(decoration: checked ? TextDecoration.lineThrough : null, decorationColor: c.ink2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Days extends StatelessWidget {
  const _Days({required this.kid});
  final Member kid;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final today = app.today;
    final tomorrow = f.addDays(today, 1);
    final occurrences = app.den
        .occurrences(f.startOf(today), f.startOf(f.addDays(today, 2)))
        .where((o) => o.assignees.isEmpty || o.assignees.contains(kid.id))
        .toList();
    List<Occurrence> on(String date) => occurrences
        .where(
          (o) => f.localDate(o.start) == date || (o.allDay && o.start <= f.startOf(date) && o.end > f.startOf(date)),
        )
        .toList();

    Widget day(String label, List<Occurrence> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Sp.l, bottom: Sp.s),
          child: Text(label, style: context.type.heading(c.ink)),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s),
            child: Text('Nothing planned', style: context.type.title(c.ink2)),
          ),
        for (final o in items)
          Container(
            constraints: const BoxConstraints(minHeight: Targets.kid),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.rule)),
            ),
            padding: const EdgeInsets.symmetric(vertical: Sp.s),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 112,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(o.allDay ? 'All day' : f.time(o.start), style: context.type.title(c.ink2)),
                    ),
                  ),
                  PersonBar(markers: app.markersFor(o.assignees), width: 6, minHeight: 48),
                  const SizedBox(width: Sp.m),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(o.title, style: context.type.title(c.ink)),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    return _Page(children: [day('Today', on(today)), day('Tomorrow', on(tomorrow))]);
  }
}

class _Stars extends StatelessWidget {
  const _Stars({required this.kid});
  final Member kid;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final points = den.points();
    final total = points.totals[kid.id] ?? 0;
    final goals = [
      for (final g in points.goals)
        if (g.goal.members == null || g.goal.members!.contains(kid.id))
          (g, g.standings.where((s) => s.member == kid.id).firstOrNull?.earned ?? 0),
    ];
    final rewards = points.rewards.where((r) => r.active).toList();
    final asked = {
      for (final r in points.pending)
        if (r.member == kid.id && r.status == RedemptionStatus.requested) r.reward,
    };

    return _Page(
      children: [
        Semantics(
          label: '$total stars',
          excludeSemantics: true,
          child: Row(
            children: [
              const Star(size: 56),
              const SizedBox(width: Sp.m),
              Text('$total', style: context.type.display(c.ink)),
            ],
          ),
        ),
        for (final (g, earned) in goals) ...[
          const SizedBox(height: Sp.xl),
          Text(g.goal.title, style: context.type.title(c.ink)),
          const SizedBox(height: Sp.s),
          _GoalBar(earned: earned, target: g.goal.target),
          const SizedBox(height: Sp.xs),
          Text(
            earned >= g.goal.target ? 'You made it' : '$earned of ${g.goal.target}',
            style: context.type.title(c.ink2),
          ),
        ],
        if (rewards.isNotEmpty) ...[
          const SizedBox(height: Sp.xl),
          Text('Rewards', style: context.type.heading(c.ink)),
          const SizedBox(height: Sp.s),
          for (final r in rewards)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.m),
              child: KidCard(
                child: Row(
                  children: [
                    Icon(Pictograms.reward(r.icon), size: 48, color: c.ink),
                    const SizedBox(width: Sp.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.title, style: context.type.title(c.ink)),
                          const SizedBox(height: Sp.xs),
                          StarCount(r.cost, size: 22, style: context.type.title(c.ink2)),
                        ],
                      ),
                    ),
                    if (asked.contains(r.id))
                      Text('Asked', style: context.type.title(c.ink2))
                    else if (points.available(kid.id) >= r.cost)
                      SizedBox(
                        height: Targets.kid,
                        child: FilledButton(
                          onPressed: () => attempt(context, () => den.requestReward(r.id, member: kid.id)),
                          child: Text('Ask for it', style: context.type.title(c.onInk)),
                        ),
                      )
                    else
                      Text('${r.cost - points.available(kid.id)} more', style: context.type.title(c.ink2)),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _GoalBar extends StatelessWidget {
  const _GoalBar({required this.earned, required this.target});
  final int earned;
  final int target;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fraction = target <= 0 ? 1.0 : (earned / target).clamp(0.0, 1.0);
    return Container(
      height: 28,
      decoration: BoxDecoration(color: c.well, borderRadius: BorderRadius.circular(Radii.round)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction,
        child: Container(
          decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(Radii.round)),
        ),
      ),
    );
  }
}
