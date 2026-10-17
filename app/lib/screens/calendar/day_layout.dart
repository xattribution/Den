import 'dart:math' as math;

/// One item placed in a day column: minutes past midnight, and where it sits among the items it
/// overlaps. [lane] of [lanes] is its slot; [span] is how many free lanes to its right it may
/// widen into.
class DaySlot<T> {
  DaySlot(this.item, this.start, this.end);

  final T item;
  final int start;
  final int end;
  int lane = 0;
  int lanes = 1;
  int span = 1;

  @override
  String toString() => 'DaySlot($item $start-$end lane $lane/$lanes span $span)';
}

/// Lays out overlapping items side by side, the way a person would draw them on a day planner:
/// items that overlap, directly or through a chain, form a cluster that shares the column's
/// width in lanes; each item takes the first lane free at its start, then widens to the right
/// over lanes nobody uses beside it. Very short items count as [minLength] minutes so their
/// labels never collide.
List<DaySlot<T>> layoutDay<T>(Iterable<DaySlot<T>> slots, {int minLength = 20}) {
  final sorted = [...slots]
    ..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : (b.end - b.start).compareTo(a.end - a.start);
    });
  int visualEnd(DaySlot<T> s) => math.max(s.end, s.start + minLength);
  bool overlaps(DaySlot<T> a, DaySlot<T> b) => a.start < visualEnd(b) && b.start < visualEnd(a);

  final out = <DaySlot<T>>[];
  var cluster = <DaySlot<T>>[];
  var laneEnds = <int>[];
  var clusterEnd = -1;

  void close() {
    final lanes = laneEnds.length;
    for (final s in cluster) {
      s.lanes = lanes;
    }
    for (final s in cluster) {
      var span = 1;
      for (var lane = s.lane + 1; lane < lanes; lane++) {
        if (cluster.any((o) => o.lane == lane && overlaps(o, s))) break;
        span++;
      }
      s.span = span;
    }
    out.addAll(cluster);
    cluster = [];
    laneEnds = [];
    clusterEnd = -1;
  }

  for (final s in sorted) {
    if (cluster.isNotEmpty && s.start >= clusterEnd) close();
    var lane = laneEnds.indexWhere((end) => end <= s.start);
    if (lane == -1) {
      lane = laneEnds.length;
      laneEnds.add(visualEnd(s));
    } else {
      laneEnds[lane] = visualEnd(s);
    }
    s.lane = lane;
    cluster.add(s);
    clusterEnd = math.max(clusterEnd, visualEnd(s));
  }
  if (cluster.isNotEmpty) close();
  return out;
}
