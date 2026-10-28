import 'package:den_core/den_core.dart';

/// One person's (or nobody's) chores.
class ChoreGroup {
  const ChoreGroup(this.member, this.days);

  /// Whose they are; null for chores anyone can do.
  final Member? member;
  final List<ChoreDay> days;

  int get left => days.where((d) => !d.done).length;
  String get leftWords => days.isEmpty ? 'Nothing' : (left == 0 ? 'All done' : '$left left');
}

/// [days] grouped by whose they are: [me] first, then the rest of the family in [members]'
/// order, then chores anyone can do (with those of anyone no longer in the family). Each group
/// keeps the order [days] came in.
List<ChoreGroup> choreGroups(List<Member> members, Iterable<ChoreDay> days, {String? me}) {
  final known = {for (final m in members) m.id: m};
  final byOwner = <String?, List<ChoreDay>>{};
  for (final d in days) {
    final owner = known.containsKey(d.owner) ? d.owner : null;
    byOwner.putIfAbsent(owner, () => []).add(d);
  }
  return [
    if (me != null && byOwner.containsKey(me)) ChoreGroup(known[me], byOwner[me]!),
    for (final m in members)
      if (m.id != me && byOwner.containsKey(m.id)) ChoreGroup(m, byOwner[m.id]!),
    if (byOwner.containsKey(null)) ChoreGroup(null, byOwner[null]!),
  ];
}
