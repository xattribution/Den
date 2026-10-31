import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/chunky.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import 'kid_parts.dart';
import 'kid_tiles.dart';

/// A kid's stars (KIDS_MODE_AND_SOFT_THEME.md, component 2): a big star, the total, what they're
/// counting toward and a pip per star it takes, on a chunky card. When a star is earned the star
/// lands with one spring and a heavy haptic, the one celebration in kids mode. When a reward is
/// reached the last pip fills and the card says "Park trip is ready" with a navy Get it button
/// (a heavy haptic, then a light one). Under Reduce Motion the landing is a 100 ms fade; the
/// haptics stay.
class KidStarCard extends StatefulWidget {
  const KidStarCard({super.key, required this.stars, required this.target, this.onGetIt});

  final int stars;
  final KidTarget? target;

  /// Asks for a ready reward.
  final VoidCallback? onGetIt;

  @override
  State<KidStarCard> createState() => _KidStarCardState();
}

class _KidStarCardState extends State<KidStarCard> with TickerProviderStateMixin {
  late final AnimationController _land = AnimationController.unbounded(vsync: this, value: 1);
  late final AnimationController _fade = AnimationController(vsync: this, duration: DenMotion.fade, value: 1);
  Timer? _second;

  @override
  void didUpdateWidget(KidStarCard old) {
    super.didUpdateWidget(old);
    if (widget.stars > old.stars) _landStar();
    if ((widget.target?.ready ?? false) && !(old.target?.ready ?? false)) _reached();
  }

  void _landStar() {
    HapticFeedback.heavyImpact();
    if (DenMotion.reduced(context)) {
      _fade.forward(from: 0);
    } else {
      _land.value = 0;
      _land.springTo(1, spring: DenMotion.check);
    }
  }

  void _reached() {
    HapticFeedback.heavyImpact();
    _second?.cancel();
    _second = Timer(const Duration(milliseconds: 120), HapticFeedback.lightImpact);
  }

  @override
  void dispose() {
    _second?.cancel();
    _land.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final target = widget.target;
    final stars = widget.stars;
    final ready = target?.ready ?? false;
    final count = '$stars';
    final label = [
      '$stars ${stars == 1 ? 'star' : 'stars'}',
      if (target != null) target.words,
    ].join('. ');

    final star = RepaintBoundary(
      child: FadeTransition(
        opacity: _fade,
        child: AnimatedBuilder(
          animation: _land,
          builder: (context, child) => Transform.scale(scale: _land.value.clamp(0.0, 1.4), child: child),
          child: const Star(size: 64),
        ),
      ),
    );

    return ChunkySlab(
      face: c.card,
      lip: c.line,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: label,
              liveRegion: true,
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    star,
                    const SizedBox(width: Sp.l),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.end,
                            spacing: Sp.m,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(count, style: t.kidCount(c.ink)),
                                  const SizedBox(width: Sp.s),
                                  Text(stars == 1 ? 'star' : 'stars', style: t.kidMeta(c.ink2).copyWith(fontSize: 18 * t.scale)),
                                ],
                              ),
                              if (target != null && !ready)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(tidy(target.name), style: t.kidMeta(c.ink2).copyWith(fontSize: 16 * t.scale)),
                                ),
                            ],
                          ),
                          if (target != null) ...[
                            const SizedBox(height: 10),
                            StarPips(have: target.have, need: target.need),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (ready) ...[
              const SizedBox(height: Sp.l),
              Row(
                children: [
                  Expanded(child: Text(tidy(target!.words), style: t.kidJob(c.ink))),
                  const SizedBox(width: Sp.m),
                  if (widget.onGetIt != null)
                    FilledButton(
                      onPressed: widget.onGetIt,
                      style: FilledButton.styleFrom(minimumSize: const Size(96, KidLayout.minTarget)),
                      child: Text('Get it', semanticsLabel: 'Get ${target.name}', style: t.kidJob(c.onPrimary)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
