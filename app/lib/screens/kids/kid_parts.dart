import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/family_glyphs.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';

/// The kids' apps use only title, heading and display type, 72-dp targets and 16-radius cards.

/// A kid's card: something they act on by itself (a job, a reward). Flush well fill, no shadow.
class KidCard extends StatelessWidget {
  const KidCard({super.key, required this.child, this.done = false, this.padding = const EdgeInsets.all(Sp.l)});

  final Widget child;
  final bool done;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.state),
      curve: Motion.curve,
      padding: padding,
      decoration: BoxDecoration(
        color: done ? c.paper : c.well,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: done ? c.rule : c.well, width: 2),
      ),
      child: child,
    );
  }
}

/// The big round check: an empty ink ring, or solid ink with a check.
class BigCheck extends StatelessWidget {
  const BigCheck({super.key, required this.done, required this.onChanged, required this.label, this.size = 88});

  final bool done;
  final ValueChanged<bool>? onChanged;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = size < Targets.kid ? Targets.kid : size;
    return Semantics(
      button: true,
      checked: done,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        radius: s / 2 + 4,
        onTap: onChanged == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onChanged!(!done);
              },
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.state),
          curve: Motion.curve,
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? c.ink : Colors.transparent,
            border: Border.all(color: done ? c.ink : c.ink2, width: 4),
          ),
          child: done ? Icon(PhosphorIconsBold.check, size: s * 0.55, color: c.onInk) : null,
        ),
      ),
    );
  }
}

class KidTab {
  const KidTab(this.icon, this.label);
  final IconData icon;

  /// Shown under the icon for kids who read; always the semantics label.
  final String? label;
}

/// Big tabs along the bottom: solid ink when chosen, 80 dp tall.
class KidTabs extends StatelessWidget {
  const KidTabs({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
    this.semantics = const [],
  });

  final List<KidTab> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  /// Labels for screen readers when the tabs show pictures only.
  final List<String> semantics;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.paper,
        border: Border(top: BorderSide(color: c.rule)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Sp.s),
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                    child: Semantics(
                      selected: i == index,
                      button: true,
                      label: tabs[i].label ?? (i < semantics.length ? semantics[i] : null),
                      excludeSemantics: true,
                      child: Material(
                        color: i == index ? c.ink : c.well,
                        borderRadius: BorderRadius.circular(Radii.card),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(Radii.card),
                          onTap: () => onChanged(i),
                          child: SizedBox(
                            height: 80,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  tabs[i].icon,
                                  size: tabs[i].label == null ? 40 : 30,
                                  color: i == index ? c.onInk : c.ink,
                                ),
                                if (tabs[i].label != null) ...[
                                  const SizedBox(height: 2),
                                  Text(tabs[i].label!, style: context.type.title(i == index ? c.onInk : c.ink)),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stars already seen landing, per kid, so a star earned since the chart was last open lands
/// once and only once.
final Map<String, int> _seenStars = {};

/// The sticker chart: a grid of slots toward the next reward, each earned point a star sticker.
/// The newest stars land (200 ms) the first time the chart shows them, unless reduced motion is
/// on. It is the one celebration in Den, and it's the reward itself.
class StickerChart extends StatefulWidget {
  const StickerChart({
    super.key,
    required this.kidId,
    required this.earned,
    required this.slots,
    this.reward = true,
    this.star = 56,
  });

  final String kidId;
  final int earned;
  final int slots;

  /// Shows the gift at the end of the chart, when there is a reward to reach.
  final bool reward;
  final double star;

  @override
  State<StickerChart> createState() => _StickerChartState();
}

class _StickerChartState extends State<StickerChart> with SingleTickerProviderStateMixin {
  late final AnimationController _land;
  late int _from;

  @override
  void initState() {
    super.initState();
    _land = AnimationController(vsync: this, duration: Motion.sheet);
    _from = (_seenStars[widget.kidId] ?? widget.earned).clamp(0, widget.earned);
    _seenStars[widget.kidId] = widget.earned;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _startIfNeeded();
  }

  @override
  void didUpdateWidget(StickerChart old) {
    super.didUpdateWidget(old);
    if (widget.earned > old.earned) {
      _from = old.earned;
      _seenStars[widget.kidId] = widget.earned;
      _land.value = 0;
      _startIfNeeded();
    } else {
      _seenStars[widget.kidId] = widget.earned;
    }
  }

  void _startIfNeeded() {
    if (_from >= widget.earned) return;
    if (MediaQuery.of(context).disableAnimations) {
      _land.value = 1;
    } else {
      _land.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _land.dispose();
    super.dispose();
  }

  /// The largest sticker, up to [StickerChart.star], at which the whole chart and its reward fit.
  double _fit(BoxConstraints box) {
    final count = widget.slots + (widget.reward ? 1 : 0);
    for (var s = widget.star; s >= 28; s -= 4) {
      final cols = ((box.maxWidth + Sp.s) / (s + Sp.s)).floor().clamp(1, 1000);
      final rows = (count / cols).ceil();
      if (!box.hasBoundedHeight || rows * (s + Sp.s) <= box.maxHeight) return s;
    }
    return 28;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final filled = widget.earned.clamp(0, widget.slots);
    return LayoutBuilder(
      builder: (context, box) {
        final s = _fit(box);
        final count = widget.slots + (widget.reward ? 1 : 0);
        final cols = ((box.maxWidth + Sp.s) / (s + Sp.s)).floor().clamp(1, count);
        return Semantics(
          label: '${widget.earned} of ${widget.slots} stars',
          excludeSemantics: true,
          child: Center(
            child: SizedBox(
              width: cols * (s + Sp.s) - Sp.s,
              child: Wrap(
                spacing: Sp.s,
                runSpacing: Sp.s,
                children: [
                  for (var i = 0; i < widget.slots; i++)
                    SizedBox.square(
                      dimension: s,
                      child: i < filled
                          ? (i >= _from
                                ? AnimatedBuilder(
                                    animation: _land,
                                    builder: (context, child) {
                                      final t = Curves.easeOut.transform(_land.value);
                                      return Opacity(
                                        opacity: t,
                                        child: Transform.scale(scale: 1.6 - 0.6 * t, child: child),
                                      );
                                    },
                                    child: Star(size: s),
                                  )
                                : Star(size: s))
                          : Center(
                              child: Container(
                                width: s * 0.7,
                                height: s * 0.7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: c.rule, width: 3),
                                ),
                              ),
                            ),
                    ),
                  if (widget.reward)
                    SizedBox.square(
                      dimension: s,
                      child: Icon(
                        PhosphorIconsFill.gift,
                        size: s * 0.9,
                        color: filled >= widget.slots ? c.ink : c.ink3,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// How many slots and stars a kid's chart shows: toward their first goal when there is one,
/// else their balance in rows of ten.
(int earned, int slots, bool reward) chartFor(PointsSummary points, String kidId) {
  for (final g in points.goals) {
    final members = g.goal.members;
    if (members != null && !members.contains(kidId)) continue;
    final standing = g.standings.where((s) => s.member == kidId).firstOrNull;
    if (standing == null) continue;
    final slots = g.goal.target.clamp(5, 60);
    return (standing.earned.clamp(0, slots), slots, true);
  }
  final balance = (points.totals[kidId] ?? 0).clamp(0, 60);
  final slots = ((balance ~/ 10) + 1) * 10;
  return (balance, slots.clamp(10, 60), false);
}

/// A picture for a chore step, from its words (steps have no pictogram of their own), or null
/// to show the step's number as dots.
IconData? stepPicture(String text) => pictureForWords(text);

/// Dots for a step's number when it has no picture: pre-readers can count before they read.
class StepDots extends StatelessWidget {
  const StepDots({super.key, required this.n, required this.color, this.size = 10});
  final int n;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final count = n.clamp(1, 6);
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
      ],
    );
  }
}

FlutterTts? _tts;

/// Reads a chore aloud: its title, then each step.
Future<void> speakChore(BuildContext context, Chore chore, {List<ChoreStep>? steps}) async {
  final text = [chore.title, ...(steps ?? chore.steps).map((s) => s.text)].where((t) => t.trim().isNotEmpty).join('. ');
  try {
    final tts = _tts ??= FlutterTts();
    await tts.stop();
    await tts.setSpeechRate(0.42);
    await tts.speak(text);
  } on Object {
    if (context.mounted) {
      showNote(context, "This device can't read aloud right now. Check its text-to-speech settings.");
    }
  }
}

/// One of a kid's jobs today: a chore they own, with every step, or just their own steps in
/// someone else's chore (helping clean the kitchen), which they finish step by step.
class KidJob {
  const KidJob(this.day, this.steps, {required this.owned});

  final ChoreDay day;
  final List<ChoreStep> steps;

  /// Whether the kid owns the chore itself, and so gets the big check.
  final bool owned;

  bool stepDone(ChoreStep s) => day.steps[s.id] != null;
  bool get done => owned ? day.done : steps.every(stepDone);
  int get points => owned ? day.pointsAvailable : steps.fold(0, (sum, s) => sum + s.points);
}

/// A kid's jobs on [date], unfinished first.
List<KidJob> kidJobs(Den den, String date, String kidId) {
  final jobs = <KidJob>[
    for (final d in den.choresOn(date))
      if (d.owner == kidId)
        KidJob(d, d.chore.steps, owned: true)
      else if (d.chore.steps.any((s) => s.owner == kidId))
        KidJob(d, [
          for (final s in d.chore.steps)
            if (s.owner == kidId) s,
        ], owned: false),
  ];
  jobs.sort((a, b) => (a.done ? 1 : 0) - (b.done ? 1 : 0));
  return jobs;
}
