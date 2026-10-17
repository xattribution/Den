import 'package:den_core/den_core.dart';

import 'util.dart';

/// Which counters of one author a device holds in one space, kept sorted.
class CounterSet {
  final List<int> _sorted = [];

  /// Highest counter held, or 0.
  int get max => _sorted.isEmpty ? 0 : _sorted.last;

  /// Number of counters held.
  int get length => _sorted.length;

  /// Whether [counter] is held.
  bool contains(int counter) => _search(counter) >= 0;

  /// Adds [counter]; false when it was already there.
  bool add(int counter) {
    if (_sorted.isEmpty || counter > _sorted.last) {
      _sorted.add(counter);
      return true;
    }
    final at = _search(counter);
    if (at >= 0) return false;
    _sorted.insert(-at - 1, counter);
    return true;
  }

  /// Count and order-independent digest of the counters up to and including [limit].
  ({int count, int digest}) summaryUpTo(int limit) {
    var count = 0;
    var digest = 0;
    for (final c in _sorted) {
      if (c > limit) break;
      count++;
      digest = (digest + mix32(c)) % 0x100000000;
    }
    return (count: count, digest: digest);
  }

  int _search(int counter) {
    var lo = 0;
    var hi = _sorted.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = _sorted[mid];
      if (v == counter) return mid;
      if (v < counter) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -lo - 1;
  }
}

/// What this device holds, by space and author: the basis of `have` summaries and of telling
/// new changes from ones already held.
class ChangeIndex {
  final Map<String, Map<String, CounterSet>> _spaces = {};
  final Map<String, int> _maxByAuthor = {};
  final Set<String> _ids = {};

  /// Every space with at least one change.
  Iterable<String> get spaces => _spaces.keys;

  /// Highest counter held per author, across spaces.
  Map<String, int> get maxByAuthor => Map.unmodifiable(_maxByAuthor);

  /// Number of changes indexed.
  int get length => _ids.length;

  /// Whether a change with [change]'s id is held.
  bool contains(Change change) => _ids.contains(change.id);

  /// Records [change]; false when it was already held.
  bool add(Change change) {
    if (!_ids.add(change.id)) return false;
    final counter = change.counter;
    (_spaces[change.space] ??= {}).putIfAbsent(change.device, CounterSet.new).add(counter);
    final max = _maxByAuthor[change.device] ?? 0;
    if (counter > max) _maxByAuthor[change.device] = counter;
    return true;
  }

  /// Authors and their counters in [space].
  Map<String, CounterSet> space(String space) => _spaces[space] ?? const {};

  /// The `have` summary of [space]: author -> `[max, count, digest]`.
  Map<String, List<int>> summary(String space) => {
        for (final entry in this.space(space).entries)
          entry.key: () {
            final s = entry.value.summaryUpTo(entry.value.max);
            return [entry.value.max, s.count, s.digest];
          }(),
      };

  /// Forgets everything.
  void clear() {
    _spaces.clear();
    _maxByAuthor.clear();
    _ids.clear();
  }
}
