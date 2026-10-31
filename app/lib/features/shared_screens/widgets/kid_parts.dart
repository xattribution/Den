import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../../app/format.dart';
import '../../../design/glyphs.dart';
import '../../rewards/rewards.dart' show currentGoal, goalLine;

/// A picture for a chore step, from its words (steps have no pictogram of their own), or null
/// to show the step's number instead.
IconData? stepPicture(String text) => pictureForWords(text);

FlutterTts? _tts;

/// Reads [text] aloud, slowly, for a kid who doesn't read yet. Returns why it couldn't, or null.
Future<String?> speak(String text) async {
  try {
    final tts = _tts ??= FlutterTts();
    await tts.stop();
    await tts.setSpeechRate(0.42);
    await tts.speak(text);
    return null;
  } on Object {
    return "This device can't read aloud right now. Check its text-to-speech settings.";
  }
}

/// A chore read aloud: its title, then each step.
String choreWords(Chore chore, {List<ChoreStep>? steps}) =>
    [chore.title, ...(steps ?? chore.steps).map((s) => s.text)].where((t) => t.trim().isNotEmpty).join('. ');

/// One of a kid's jobs today: a chore they own, with every step, or just their own steps in
/// someone else's chore (helping clean the kitchen), which they finish step by step.
class KidJob {
  const KidJob(this.day, this.steps, {required this.owned});

  final ChoreDay day;
  final List<ChoreStep> steps;

  /// Whether the kid owns the chore itself, so a tap checks it off.
  final bool owned;

  bool stepDone(ChoreStep s) => day.steps[s.id] != null;
  bool get done => owned ? day.done : steps.every(stepDone);
  int get points => owned ? day.pointsAvailable : steps.fold(0, (sum, s) => sum + s.points);
  int get stepsDone => steps.where(stepDone).length;
}

/// A kid's jobs on [date], in the chore order (a tile doesn't jump when it's checked).
List<KidJob> kidJobs(Den den, String date, String kidId) => [
      for (final d in den.choresOn(date))
        if (d.owner == kidId)
          KidJob(d, d.chore.steps, owned: true)
        else if (d.chore.steps.any((s) => s.owner == kidId))
          KidJob(d, [
            for (final s in d.chore.steps)
              if (s.owner == kidId) s,
          ], owned: false),
    ];

/// What a kid's star card counts toward: a goal running now, or the next reward.
class KidTarget {
  const KidTarget({required this.name, required this.have, required this.need, required this.words, this.reward});

  /// "Park trip", "First to 25 stars".
  final String name;

  /// Stars toward it so far, and how many it takes: the pips.
  final int have;
  final int need;

  /// What the card says: "3 more stars for Park trip", "Park trip is ready".
  final String words;

  /// The reward, when the target is one; a kid can ask for it once [ready].
  final Reward? reward;

  /// A reward the kid has enough stars for.
  bool get ready => reward != null && have >= need;
}

/// What a kid's star card counts toward: the goal running now for them, in the same words as
/// Chores; or else the cheapest active reward they haven't asked for yet, which is ready once
/// they have the stars ("Park trip is ready") and gives way to the next one once they ask.
/// Null when there's nothing to aim for.
KidTarget? kidTarget(PointsSummary points, String kidId, String today, Formats f) {
  final goal = currentGoal(points, kidId, today);
  if (goal != null) {
    final (g, s) = goal;
    return KidTarget(
      name: g.goal.title,
      have: s.earned,
      need: g.goal.target < 1 ? 1 : g.goal.target,
      words: goalLine(g, s, today, f),
    );
  }
  final have = points.available(kidId);
  final asked = {
    for (final r in points.pending)
      if (r.member == kidId && r.status == RedemptionStatus.requested) r.reward,
  };
  final next = [for (final r in points.rewards) if (r.active && !asked.contains(r.id)) r]..sort((a, b) => a.cost - b.cost);
  if (next.isEmpty) return null;
  final reward = next.first;
  final left = reward.cost - have;
  return KidTarget(
    name: reward.title,
    have: have,
    need: reward.cost,
    words: left <= 0 ? '${reward.title} is ready' : '$left more ${left == 1 ? 'star' : 'stars'} for ${reward.title}',
    reward: reward,
  );
}
