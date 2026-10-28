import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/glyphs.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/pictograms.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../chores/chores.dart';
import '../../rewards/rewards.dart';
import '../widgets/kid_parts.dart';

/// The corners of everything a kid acts on.
const double kidRadius = 24;

/// A kid's own screen (Kid.dc.html), for pre-readers and little kids: their picture and "Hi,
/// Leo", their stars and what they're saving toward in their color, then today's jobs as big
/// tiles, 168 tall, that a tap checks off (a job with steps opens them). Pre-readers can have
/// their jobs read to them. Little kids also see their rewards and what's on today. Every
/// target is 72 or more.
class KidHome extends StatelessWidget {
  const KidHome({super.key, required this.kid, this.action});

  final Member kid;

  /// At the end of the header: Done on a shared screen, Grown-ups on a parent's phone.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {
      RecordType.chore,
      RecordType.completion,
      RecordType.adjustment,
      RecordType.reward,
      RecordType.redemption,
      RecordType.goal,
      RecordType.event,
      RecordType.eventException,
    });
    final den = app.den;
    final c = context.colors;
    final t = context.text;
    final pointsOn = den.family?.pointsEnabled ?? true;
    final jobs = kidJobs(den, app.today, kid.id);
    final reader = kid.tier == Tier.preReader;
    final width = MediaQuery.sizeOf(context).width;
    final columns = DenLayout.forWidth(width).kidColumns;
    final side = width < DenLayout.compactMax ? DenLayout.gutter : 32.0;
    final color = c.marker(kid.marker);

    final children = <Widget>[
      _Header(kid: kid, action: action),
      if (pointsOn) _StarCard(kid: kid, color: color),
      if (reader && jobs.any((j) => !j.done))
        OutlinedButton.icon(
          onPressed: () => _readAll(context, jobs),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Targets.kid)),
          icon: Icon(PhosphorIconsFill.speakerHigh, size: 28, color: c.ink),
          label: Text('Read my jobs to me', style: t.section(c.ink)),
        ),
      if (jobs.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.xxl),
          child: Column(
            children: [
              Icon(PhosphorIconsFill.sun, size: 96, color: c.ink3),
              const SizedBox(height: Sp.l),
              Text('No jobs today', style: t.section(c.ink2), textAlign: TextAlign.center),
            ],
          ),
        )
      else
        _Grid(columns: columns, children: [for (final j in jobs) _JobTile(job: j, kid: kid, color: color, pointsOn: pointsOn)]),
      if (!reader && pointsOn) _Rewards(kid: kid),
      if (!reader) _Today(kid: kid),
    ];
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(side, Sp.l, side, Sp.xxl),
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, w) in children.indexed) ...[if (i > 0) const SizedBox(height: 20), w],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _readAll(BuildContext context, List<KidJob> jobs) async {
    final words = [for (final j in jobs) if (!j.done) choreWords(j.day.chore, steps: j.steps)].join('. ');
    final problem = await speak(words);
    if (problem != null && context.mounted) showNote(context, problem);
  }
}

/// "Hi, Leo" with their picture, 68 across.
class _Header extends StatelessWidget {
  const _Header({required this.kid, this.action});
  final Member kid;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Row(
      children: [
        DenAvatar(kid, size: 68),
        const SizedBox(width: Sp.m),
        Expanded(
          child: Semantics(
            header: true,
            child: Text('Hi, ${kid.name}', style: t.screenTitle(c.ink).copyWith(fontSize: 32)),
          ),
        ),
        if (action != null) ...[const SizedBox(width: Sp.s), action!],
      ],
    );
  }
}

/// The pill at the end of a kid's header: "Done", "Grown-ups". 72 tall to tap, quiet to look at.
class KidHeaderPill extends StatelessWidget {
  const KidHeaderPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: Targets.kid,
      child: Center(
        child: DenPressable(
          onTap: onTap,
          color: c.card,
          semanticLabel: label,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l),
              child: Center(widthFactor: 1, child: Text(label, style: context.text.meta(c.ink2).bold)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Their stars, big, landing with one spring when one is earned, and the bar toward what
/// they're saving for in their own color.
class _StarCard extends StatefulWidget {
  const _StarCard({required this.kid, required this.color});
  final Member kid;
  final Color color;

  @override
  State<_StarCard> createState() => _StarCardState();
}

class _StarCardState extends State<_StarCard> with SingleTickerProviderStateMixin {
  late final AnimationController _land = AnimationController.unbounded(vsync: this, value: 1);
  int? _last;

  @override
  void dispose() {
    _land.dispose();
    super.dispose();
  }

  void _landIfMore(int stars) {
    final last = _last;
    _last = stars;
    if (last == null || stars <= last || DenMotion.reduced(context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      HapticFeedback.lightImpact();
      _land.value = 1.35;
      _land.springTo(1, spring: DenMotion.check);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final points = context.watch(const {}).den.points();
    final stars = points.available(widget.kid.id);
    _landIfMore(stars);
    final goal = kidGoal(points, widget.kid.id);
    final label = goal == null
        ? null
        : goal.$1 >= goal.$2
            ? '${goal.$3} is yours'
            : '${goal.$2 - goal.$1} more ${goal.$2 - goal.$1 == 1 ? 'star' : 'stars'} for ${goal.$3}';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(kidRadius)),
      child: Row(
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _land,
              builder: (context, star) => Transform.scale(scale: _land.value, child: star),
              child: const Star(size: 60),
            ),
          ),
          const SizedBox(width: Sp.l),
          Expanded(
            child: Semantics(
              label: '$stars ${stars == 1 ? 'star' : 'stars'}${label == null ? '' : '. $label'}',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$stars', style: t.display(c.ink).withWeight(FontWeight.w800)),
                  if (goal != null) ...[
                    const SizedBox(height: Sp.s),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        height: 12,
                        child: ColoredBox(
                          color: c.track,
                          child: FractionallySizedBox(
                            alignment: AlignmentDirectional.centerStart,
                            widthFactor: goal.$2 <= 0 ? 1 : (goal.$1 / goal.$2).clamp(0.0, 1.0),
                            child: ColoredBox(color: widget.color),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: Sp.s),
                    Text(label!, style: t.rowTitle(c.ink)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tiles [columns] across, 12 apart.
class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});
  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var j = 0; j < columns; j++) ...[
            if (j > 0) const SizedBox(width: Sp.m),
            Expanded(child: i + j < children.length ? children[i + j] : const SizedBox.shrink()),
          ],
        ],
      ));
    }
    return Column(children: [for (final (i, r) in rows.indexed) ...[if (i > 0) const SizedBox(height: Sp.m), r]]);
  }
}

/// One job as a big tile: its picture, its name, and "+1 star", or done in the kid's color. A
/// tap checks it off (or back on); a job with steps opens them.
class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.kid, required this.color, required this.pointsOn});
  final KidJob job;
  final Member kid;
  final Color color;
  final bool pointsOn;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final chore = job.day.chore;
    final done = job.done;
    final stepped = job.steps.isNotEmpty;
    final fg = done ? c.onMarker : c.ink;
    final mark = done
        ? 'Done'
        : stepped
            ? '${job.stepsDone} of ${job.steps.length}'
            : pointsOn && job.points > 0
                ? '+${job.points} ${job.points == 1 ? 'star' : 'stars'}'
                : null;
    return DenPressable(
      onTap: () => stepped ? _openSteps(context) : _toggle(context),
      haptic: !stepped,
      toggled: stepped ? null : done,
      color: done ? color : c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kidRadius)),
      semanticLabel: [chore.title, ?mark].join(', '),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 168),
        child: Padding(
          padding: const EdgeInsets.all(Sp.m),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(done ? PhosphorIconsBold.check : choreGlyph(chore.icon, chore.title), size: 44, color: fg),
              const SizedBox(height: Sp.m),
              ExcludeSemantics(
                child: Text(chore.title, textAlign: TextAlign.center, style: t.section(fg).withWeight(FontWeight.w800)),
              ),
              if (mark != null) ...[
                const SizedBox(height: Sp.xs),
                ExcludeSemantics(child: Text(mark, style: t.label(fg))),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context) async {
    final actions = context.choreActions;
    await attempt(context, () => actions.setDone(job.day, !job.day.done));
  }

  Future<void> _openSteps(BuildContext context) =>
      showDenSheet<void>(context, builder: (_) => _StepsSheet(job: job, kid: kid, color: color));
}

/// A job's steps as big tiles, each checked with a tap, and Read it to me.
class _StepsSheet extends StatelessWidget {
  const _StepsSheet({required this.job, required this.kid, required this.color});
  final KidJob job;
  final Member kid;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.chore, RecordType.completion});
    final c = context.colors;
    final t = context.text;
    // The day as it is now, so a checked step shows at once.
    final day = app.den.choresOn(job.day.date).where((d) => d.chore.id == job.day.chore.id).firstOrNull ?? job.day;
    final now = KidJob(day, job.steps, owned: job.owned);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: day.chore.title, actionLabel: 'Done', primary: now.done),
          OutlinedButton.icon(
            onPressed: () async {
              final problem = await speak(choreWords(day.chore, steps: job.steps));
              if (problem != null && context.mounted) showNote(context, problem);
            },
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Targets.kid)),
            icon: Icon(PhosphorIconsFill.speakerHigh, size: 28, color: c.ink),
            label: Text('Read it to me', style: t.section(c.ink)),
          ),
          const SizedBox(height: Sp.l),
          for (final (i, s) in job.steps.indexed) ...[
            if (i > 0) const SizedBox(height: Sp.m),
            _StepTile(n: i + 1, step: s, done: now.stepDone(s), color: color, day: day),
          ],
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.n, required this.step, required this.done, required this.color, required this.day});
  final int n;
  final ChoreStep step;
  final bool done;
  final Color color;
  final ChoreDay day;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final picture = stepPicture(step.text);
    final fg = done ? c.onMarker : c.ink;
    return DenPressable(
      onTap: () {
        final actions = context.choreActions;
        attempt(context, () => actions.setStep(day, step.id, !done));
      },
      haptic: true,
      toggled: done,
      color: done ? color : c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kidRadius)),
      semanticLabel: step.text,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 96),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.m),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 48,
                child: Center(
                  child: done
                      ? Icon(PhosphorIconsBold.check, size: 36, color: fg)
                      : picture != null
                          ? Icon(picture, size: 40, color: fg)
                          : Text('$n', style: t.display(fg).copyWith(fontSize: 36)),
                ),
              ),
              const SizedBox(width: Sp.l),
              Expanded(child: ExcludeSemantics(child: Text(step.text, style: t.section(fg)))),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a little kid can ask for with their stars: each reward, its cost, and Ask for it.
class _Rewards extends StatelessWidget {
  const _Rewards({required this.kid});
  final Member kid;

  @override
  Widget build(BuildContext context) {
    final den = context.watch(const {}).den;
    final c = context.colors;
    final t = context.text;
    final points = den.points();
    final rewards = points.rewards.where((r) => r.active).toList();
    if (rewards.isEmpty) return const SizedBox.shrink();
    final asked = {for (final r in points.pending) if (r.member == kid.id && r.status == RedemptionStatus.requested) r.reward};
    final have = points.available(kid.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: DenLayout.headingInset, bottom: DenLayout.headingGap, top: Sp.s),
          child: Semantics(header: true, child: Text('Rewards', style: t.section(c.ink).withWeight(FontWeight.w800))),
        ),
        for (final (i, r) in rewards.indexed) ...[
          if (i > 0) const SizedBox(height: Sp.m),
          Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.m),
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(kidRadius)),
            child: Row(
              children: [
                Icon(Pictograms.reward(r.icon), size: 44, color: c.ink),
                const SizedBox(width: Sp.l),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.title, style: t.section(c.ink)),
                      StarCount(r.cost, size: 20, style: t.rowTitle(c.ink2)),
                    ],
                  ),
                ),
                const SizedBox(width: Sp.s),
                if (asked.contains(r.id))
                  Text('Asked', style: t.rowTitle(c.ink2))
                else if (have >= r.cost)
                  FilledButton(
                    onPressed: () {
                      final rewardActions = context.rewardActions;
                      attempt(context, () => rewardActions.request(r, member: kid.id));
                    },
                    style: FilledButton.styleFrom(minimumSize: const Size(Targets.kid, Targets.kid)),
                    child: const Text('Ask for it'),
                  )
                else
                  Text('${r.cost - have} more', style: t.rowTitle(c.ink2)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// What's on today for a little kid: the time and what it is, big.
class _Today extends StatelessWidget {
  const _Today({required this.kid});
  final Member kid;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final today = app.today;
    final events = app.den
        .occurrences(f.startOf(today), f.startOf(f.addDays(today, 1)))
        .where((o) => o.assignees.isEmpty || o.assignees.contains(kid.id))
        .toList();
    if (events.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: DenLayout.headingInset, bottom: DenLayout.headingGap, top: Sp.s),
          child: Semantics(header: true, child: Text('Today', style: t.section(c.ink).withWeight(FontWeight.w800))),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
          decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(kidRadius)),
          child: Column(
            children: ruled([
              for (final o in events)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Targets.kid),
                  child: Row(
                    children: [
                      SizedBox(
                        width: MediaQuery.textScalerOf(context).scale(96),
                        child: Text(o.allDay ? 'All day' : f.time(o.start), style: t.rowTitle(c.ink2)),
                      ),
                      Expanded(child: Text(o.title, style: t.section(c.ink))),
                    ],
                  ),
                ),
            ]),
          ),
        ),
      ],
    );
  }
}
