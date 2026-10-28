import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../../design/glyphs.dart';

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

/// What a kid is saving toward: their first goal, or the cheapest reward they can't have yet.
/// (earned, target, what) or null when there's nothing to aim for.
(int, int, String)? kidGoal(PointsSummary points, String kidId) {
  for (final g in points.goals) {
    final members = g.goal.members;
    if (members != null && !members.contains(kidId)) continue;
    final standing = g.standings.where((s) => s.member == kidId).firstOrNull;
    if (standing == null) continue;
    return (standing.earned, g.goal.target, g.goal.title);
  }
  final have = points.available(kidId);
  final next = [for (final r in points.rewards) if (r.active && r.cost > have) r]..sort((a, b) => a.cost - b.cost);
  if (next.isEmpty) return null;
  return (have, next.first.cost, next.first.title);
}
