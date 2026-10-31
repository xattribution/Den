import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/chunky.dart';
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
import '../widgets/kid_star_card.dart';
import '../widgets/kid_tiles.dart';

/// A kid's own screen (Kid.dc.html, KIDS_MODE_AND_SOFT_THEME.md), for pre-readers and little
/// kids: their picture and "Hi, Leo" with the day, their stars on a chunky card with a pip per
/// star toward what they're saving for, then today's jobs as chunky tiles that sink onto their
/// lip when pressed and that a tap checks off (a job with steps opens them; a long press reads
/// it out). Pre-readers have their jobs read to them from a bar pinned to the bottom of a
/// phone, or under the star card on a tablet. Little kids also see their rewards and what's on
/// today.
///
/// Two columns on a phone, three on a tablet (fewer when large text would wrap a title to a
/// third line). Every target is 64 or more; job tiles are 136 or taller.
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
    final layout = DenLayout.forWidth(width);
    final side = layout.isCompact ? DenLayout.gutter : 24.0;
    final color = c.marker(kid.marker);
    final readAloud = reader && jobs.any((j) => !j.done);
    final pinned = readAloud && layout.isCompact;
    final read = ReadToMeBar(onTap: () => _readAll(context, jobs));
    // Kid primaries for the discs, by chore, never the same as a neighbor's.
    final discs = context.kid.forJobs([for (final j in jobs) j.day.chore.id]);

    final stars = pointsOn ? _Stars(kid: kid) : null;
    final today = !reader && _Today.has(app, kid) ? _Today(kid: kid) : null;
    // The star card and today's events side by side from 900 wide.
    final besides = stars != null && today != null && width >= 900;

    final children = <Widget>[
      _Header(kid: kid, action: action),
      if (besides)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: stars),
            const SizedBox(width: KidLayout.gridGap),
            Expanded(child: today),
          ],
        )
      else
        ?stars,
      if (readAloud && !pinned) read,
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
        KidGrid(
          columns: layout.kidColumns.clamp(1, 3),
          titles: [for (final j in jobs) j.day.chore.title],
          children: [
            for (final (i, j) in jobs.indexed)
              _JobTile(job: j, kid: kid, color: color, disc: discs[i].face, pointsOn: pointsOn),
          ],
        ),
      if (!reader && pointsOn) _Rewards(kid: kid),
      if (today != null && !besides) today,
    ];
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                // Pinned, the bar sits below the list rather than over it, so the last tile
                // always scrolls clear of it.
                padding: EdgeInsets.fromLTRB(side, Sp.l, side, pinned ? Sp.l : Sp.xxl),
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, w) in children.indexed) ...[
                            if (i > 0) const SizedBox(height: KidLayout.sectionGap),
                            w,
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (pinned)
              Padding(
                key: const Key('read-to-me-pinned'),
                padding: EdgeInsets.fromLTRB(side, Sp.s, side, Sp.m),
                child: read,
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

/// "Hi, Leo" and the day, with their picture in their color: the kid's top bar, with Grown-ups
/// (or Done) at its end.
class _Header extends StatelessWidget {
  const _Header({required this.kid, this.action});
  final Member kid;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final day = DateFormat('EEEE').format(app.formats.dateTime(app.today));
    final hello = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text('Hi, ${kid.name}', style: t.kidHello(c.ink))),
        Text(day, style: t.body(c.ink2)),
      ],
    );
    // With large text the greeting gets the whole width, under the picture and the pill, so a
    // name never breaks inside a word.
    if (MediaQuery.textScalerOf(context).scale(1) > 1.5) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [KidAvatar(kid), const Spacer(), ?action]),
          const SizedBox(height: Sp.s),
          hello,
        ],
      );
    }
    return Row(
      children: [
        KidAvatar(kid),
        const SizedBox(width: Sp.m),
        Expanded(child: hello),
        if (action != null) ...[const SizedBox(width: Sp.s), action!],
      ],
    );
  }
}

/// The pill at the end of a kid's header: "Done", "Grown-ups". Taps anywhere in the header's
/// 72-tall strip, quiet to look at.
class KidHeaderPill extends StatelessWidget {
  const KidHeaderPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // The whole 72-tall strip takes the tap; the pill itself stays small.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onTap,
      child: SizedBox(
        height: Targets.kid,
        child: Center(
          child: DenPressable(
            onTap: onTap,
            color: c.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.input)),
            semanticLabel: label,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.l),
                child: Center(widthFactor: 1, heightFactor: 1, child: Text(label, style: context.text.meta(c.ink).bold)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The kid's star card, from the family's points: their total and what they count toward.
class _Stars extends StatelessWidget {
  const _Stars({required this.kid});
  final Member kid;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final points = app.den.points();
    final target = kidTarget(points, kid.id, app.today, app.formats);
    final reward = target?.reward;
    return KidStarCard(
      stars: points.available(kid.id),
      target: target,
      onGetIt: reward == null
          ? null
          : () {
              final rewardActions = context.rewardActions;
              attempt(context, () => rewardActions.request(reward, member: kid.id));
            },
    );
  }
}

/// One job as a chunky tile ([KidJobTile]): its disc in a kid primary picked by its chore, its
/// title, and "+1 star" or "1 of 3", or done in the kid's color. A tap checks it off (or back
/// on); a job with steps opens them. A long press reads it out.
class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.kid, required this.color, required this.disc, required this.pointsOn});
  final KidJob job;
  final Member kid;
  final Color color;

  /// The disc's kid primary ([KidColors.forJobs]).
  final Color disc;
  final bool pointsOn;

  @override
  Widget build(BuildContext context) {
    final chore = job.day.chore;
    final done = job.done;
    final stepped = job.steps.isNotEmpty;
    final points = pointsOn && job.points > 0;
    final mark = done
        ? 'Done'
        : stepped
            ? '${job.stepsDone} of ${job.steps.length}'
            : points
                ? '+${job.points} ${job.points == 1 ? 'star' : 'stars'}'
                : null;
    return KidJobTile(
      title: chore.title,
      glyph: choreGlyph(chore.icon, chore.title),
      disc: disc,
      person: color,
      done: done,
      meta: mark,
      metaStar: !stepped && points,
      onTap: () => stepped ? _openSteps(context) : _toggle(context),
      onLongPress: () => _read(context),
      toggled: stepped ? null : done,
      semanticLabel: [chore.title, ?mark].join(', '),
    );
  }

  Future<void> _toggle(BuildContext context) async {
    final actions = context.choreActions;
    await attempt(context, () => actions.setDone(job.day, !job.day.done));
  }

  Future<void> _read(BuildContext context) async {
    final problem = await speak(choreWords(job.day.chore, steps: job.steps));
    if (problem != null && context.mounted) showNote(context, problem);
  }

  Future<void> _openSteps(BuildContext context) =>
      showDenSheet<void>(context, builder: (_) => _StepsSheet(job: job, kid: kid, color: color));
}

/// A job's steps as chunky tiles with a number disc, each checked with a tap, and Read it to me.
class _StepsSheet extends StatelessWidget {
  const _StepsSheet({required this.job, required this.kid, required this.color});
  final KidJob job;
  final Member kid;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.chore, RecordType.completion});
    // The day as it is now, so a checked step shows at once.
    final day = app.den.choresOn(job.day.date).where((d) => d.chore.id == job.day.chore.id).firstOrNull ?? job.day;
    final now = KidJob(day, job.steps, owned: job.owned);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: day.chore.title, actionLabel: 'Done', primary: now.done),
          ReadToMeBar(
            label: 'Read it to me',
            onTap: () async {
              final problem = await speak(choreWords(day.chore, steps: job.steps));
              if (problem != null && context.mounted) showNote(context, problem);
            },
          ),
          const SizedBox(height: KidLayout.sectionGap),
          for (final (i, s) in job.steps.indexed) ...[
            if (i > 0) const SizedBox(height: Sp.m),
            _StepTile(n: i + 1, step: s, done: now.stepDone(s), color: color, day: day),
          ],
        ],
      ),
    );
  }
}

/// One step as a chunky tile: a number disc (or the step's picture) and its words; done in the
/// kid's color with a white disc and a check.
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
    final disc = context.kid.forJob('${day.chore.id}/${step.id}').face;
    return ChunkyPressable(
      onTap: () {
        final actions = context.choreActions;
        attempt(context, () => actions.setStep(day, step.id, !done));
      },
      face: done ? color : c.card,
      lip: done ? KidColors.lipOf(color) : c.line,
      toggled: done,
      semanticLabel: step.text,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 96),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.m),
          child: ExcludeSemantics(
            child: Row(
              children: [
                if (picture != null || done)
                  KidDisc(color: disc, glyph: picture, done: done ? 1 : 0, size: 56)
                else
                  SizedBox.square(
                    dimension: 56,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: disc, shape: BoxShape.circle),
                      child: Center(
                        child: Text(
                          '$n',
                          textScaler: TextScaler.noScaling,
                          style: t.kidCount(KidColors.navy).copyWith(fontSize: 30),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: Sp.l),
                Expanded(child: Text(step.text, style: t.kidJob(done ? c.onMarker : c.ink))),
              ],
            ),
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
            decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.kidTile)),
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

  static List<Occurrence> _events(AppState app, Member kid) {
    final f = app.formats;
    final today = app.today;
    return app.den
        .occurrences(f.startOf(today), f.startOf(f.addDays(today, 1)))
        .where((o) => o.assignees.isEmpty || o.assignees.contains(kid.id))
        .toList();
  }

  /// Whether [kid] has anything on today.
  static bool has(AppState app, Member kid) => _events(app, kid).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final events = _events(app, kid);
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
          decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.kidTile)),
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
