/// Narrowing den_core's derived views to what a caller may read.
///
/// The hub holds every space. A token with a member reads with that member acting, so
/// den_core's own views already hold only their spaces. A member-less token (Home Assistant,
/// claude.ai, scripts) is parent level: it reads with nobody acting, so den_core's views
/// (points lines, the Today gaps, store names) cover every space the hub holds, including a
/// member's "Just me" space the family's oversight policy closes to parents
/// (`oversight.parentsSeePrivate: false`). These functions take out what such a caller can't
/// read, so no title from a closed space reaches it. `readable` is the caller's readable
/// spaces (`Access.readable`).
library;

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

/// Whether [den]'s current view (whoever is acting) holds only spaces in [readable], so
/// nothing needs taking out.
bool viewWithin(Den den, Set<String> readable) => den.readableSpaces.every(readable.contains);

/// [summary] without the chore and step lines from chores in spaces outside [readable]: their
/// reasons are the chores' titles and step texts. Lines of chores that no longer exist are left
/// out too, since their space can't be told. Totals and goal standings stay as they are; they
/// are each member's balance, not what the chore was.
PointsSummary visiblePoints(Den den, PointsSummary summary, Set<String> readable) {
  if (viewWithin(den, readable)) return summary;
  final spaces = <String, String?>{};
  bool visible(PointsLine line) {
    if (line.source != PointsSource.chore && line.source != PointsSource.step) return true;
    final ref = line.ref;
    final at = ref?.indexOf('@') ?? -1;
    if (ref == null || at <= 0) return false;
    final chore = ref.substring(0, at);
    final space = spaces.putIfAbsent(chore, () => den.chore(chore)?.space);
    return space != null && readable.contains(space);
  }

  return PointsSummary(
    totals: summary.totals,
    goals: summary.goals,
    recent: [for (final line in summary.recent) if (visible(line)) line],
    rewards: summary.rewards,
    pending: summary.pending,
  );
}

/// The [gaps] a caller may see: a missing driver or an overlap only when every event in it is in
/// [readable], and an "up for grabs" chore only when the caller can see an unowned chore of
/// today with that title (den_core names the chore only in the gap's message, so anything that
/// doesn't match a visible chore is left out).
List<Gap> visibleGaps(Den den, List<Gap> gaps, Set<String> readable) {
  if (viewWithin(den, readable)) return gaps;
  final today = den.todayDate();
  final grabs = <String, int>{};
  for (final cd in den.choresOn(today)) {
    if (cd.date != today || cd.owner != null || cd.done || !readable.contains(cd.chore.space)) continue;
    grabs.update('${cd.chore.title} is up for grabs', (n) => n + 1, ifAbsent: () => 1);
  }
  final out = <Gap>[];
  for (final g in gaps) {
    if (g.kind == GapKind.unowned) {
      final left = grabs[g.message] ?? 0;
      if (left == 0) continue;
      grabs[g.message] = left - 1;
      out.add(g);
    } else if (g.occurrences.every((o) => readable.contains(o.event.space))) {
      out.add(g);
    }
  }
  return out;
}

/// Store names used on the items of [lists], most used first (as den_core's `Den.stores`
/// counts them), so a caller sees only stores from lists it can read.
List<String> storesOf(Iterable<ListState> lists) {
  final counts = <String, int>{};
  for (final l in lists) {
    for (final item in l.items) {
      final store = item.store?.trim();
      if (store != null && store.isNotEmpty) counts.update(store, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  return counts.keys.sorted((a, b) {
    final n = counts[b]!.compareTo(counts[a]!);
    return n != 0 ? n : a.compareTo(b);
  });
}
