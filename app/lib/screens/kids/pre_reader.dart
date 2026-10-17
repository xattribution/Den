import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/family_glyphs.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'kid_parts.dart';

/// The pre-reader's app: pictures only. Each of today's jobs is a big card with its pictogram,
/// its step pictures and a huge check; a speaker reads it aloud. "My stars" is the sticker chart.
class PreReaderApp extends StatefulWidget {
  const PreReaderApp({super.key, required this.kid, required this.header, this.initialTab = 0});

  final Member kid;
  final Widget header;
  final int initialTab;

  @override
  State<PreReaderApp> createState() => _PreReaderAppState();
}

class _PreReaderAppState extends State<PreReaderApp> {
  late int _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final points = den.family?.pointsEnabled ?? true;
    final tab = points ? _tab : 0;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.header,
            Expanded(
              child: tab == 0 ? _Jobs(kid: widget.kid) : _Stars(kid: widget.kid),
            ),
          ],
        ),
      ),
      bottomNavigationBar: points
          ? KidTabs(
              tabs: const [KidTab(PhosphorIconsFill.checkCircle, null), KidTab(PhosphorIconsFill.star, null)],
              semantics: const ['My jobs', 'My stars'],
              index: tab,
              onChanged: (i) => setState(() => _tab = i),
            )
          : null,
    );
  }
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
      return Center(
        child: Semantics(
          label: 'No jobs today',
          child: Icon(PhosphorIconsFill.sun, size: 160, color: c.rule),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 900 ? 2 : 1;
        final width = (box.maxWidth - Sp.l * 2 - Sp.l * (columns - 1)) / columns;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.xl),
          child: Wrap(
            spacing: Sp.l,
            runSpacing: Sp.l,
            children: [
              for (final j in jobs)
                SizedBox(
                  width: width,
                  child: _PictureJob(job: j),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PictureJob extends StatelessWidget {
  const _PictureJob({required this.job});
  final KidJob job;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final day = job.day;
    final chore = day.chore;
    final steps = job.steps;
    return KidCard(
      done: job.done,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Semantics(
                label: chore.title,
                child: Icon(choreGlyph(chore.icon, chore.title), size: 96, color: job.done ? c.ink3 : c.ink),
              ),
              const Spacer(),
              SizedBox.square(
                dimension: Targets.kid,
                child: IconButton(
                  tooltip: 'Read it to me',
                  onPressed: () => speakChore(context, chore, steps: steps),
                  icon: Icon(PhosphorIconsFill.speakerHigh, size: 36, color: c.ink2),
                ),
              ),
              if (job.owned) ...[
                const SizedBox(width: Sp.s),
                BigCheck(
                  done: day.done,
                  size: 104,
                  label: chore.title,
                  onChanged: (v) => attempt(context, () => den.setChoreDone(chore.id, day.date, v)),
                ),
              ],
            ],
          ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: Sp.l),
            Wrap(
              spacing: Sp.s,
              runSpacing: Sp.s,
              children: [
                for (var i = 0; i < steps.length; i++)
                  _StepPicture(
                    n: i + 1,
                    size: job.owned ? 80 : 104,
                    step: steps[i],
                    checked: job.stepDone(steps[i]),
                    onTap: () =>
                        attempt(context, () => den.setStep(chore.id, day.date, steps[i].id, !job.stepDone(steps[i]))),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StepPicture extends StatelessWidget {
  const _StepPicture({required this.n, required this.step, required this.checked, required this.onTap, this.size = 80});
  final int n;
  final double size;
  final ChoreStep step;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final picture = stepPicture(step.text);
    final fg = checked ? c.onInk : c.ink;
    return Semantics(
      button: true,
      checked: checked,
      label: step.text,
      excludeSemantics: true,
      child: Material(
        color: checked ? c.ink : c.paper,
        borderRadius: BorderRadius.circular(Radii.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.card),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.card),
              border: Border.all(color: checked ? c.ink : c.rule, width: 2),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                picture != null
                    ? Icon(picture, size: size * 0.5, color: fg)
                    : StepDots(n: n, color: fg, size: size * 0.15),
                if (checked)
                  Positioned(right: 6, top: 6, child: Icon(PhosphorIconsBold.check, size: 18, color: c.onInk)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars({required this.kid});
  final Member kid;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final (earned, slots, reward) = chartFor(den.points(), kid.id);
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return Padding(
      padding: const EdgeInsets.all(Sp.xl),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: StickerChart(kidId: kid.id, earned: earned, slots: slots, reward: reward, star: wide ? 72 : 56),
        ),
      ),
    );
  }
}
