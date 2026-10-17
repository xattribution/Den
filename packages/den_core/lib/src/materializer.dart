import 'change.dart';
import 'model.dart';
import 'store.dart';
import 'validity.dart';

/// A valid change as it was applied: what each field held before, and how people would say it.
class Applied {
  const Applied(this.change, this.before, this.created, this.verb, this.title);
  final Change change;
  final Map<String, Object?> before;
  final bool created;
  final String verb;
  final String title;
}

/// HLC order with the change id as the last tiebreak, so the order is total.
int changeOrder(Change a, Change b) {
  final byClock = a.hlc.compareTo(b.hlc);
  return byClock != 0 ? byClock : a.id.compareTo(b.id);
}

/// The change log and the state it materializes to. Every change is validated against the state
/// built from the valid changes before it; a change that arrives older than the newest one
/// applied triggers a replay from scratch in HLC order, so every replica holding the same changes
/// agrees on both the state and which changes were rejected.
class Materializer {
  Materializer(TrustRoot Function() root) {
    validator = Validator(store, root);
  }

  final RecordStore store = RecordStore();
  late final Validator validator;
  final List<Change> _log = [];
  final Map<String, Change> _byId = {};
  final Map<String, Set<int>> _counters = {};

  /// Change id -> why it doesn't count.
  final Map<String, String> rejected = {};

  /// Valid changes in HLC order.
  final List<Applied> applied = [];

  int replays = 0;

  List<Change> get log => _log;
  bool contains(String id) => _byId.containsKey(id);
  Change? byId(String id) => _byId[id];
  Map<String, Set<int>> get counters => _counters;

  /// Validates a change as the next one after everything applied.
  Rejection? check(Change c) => validator.check(c);

  /// Adds changes not already held; returns the ones that turned out invalid, with reasons.
  Map<String, String> add(Iterable<Change> changes) {
    final fresh = <Change>[];
    for (final c in changes) {
      if (_byId.containsKey(c.id)) continue;
      _byId[c.id] = c;
      fresh.add(c);
      final colon = c.id.lastIndexOf(':');
      final n = colon > 0 ? int.tryParse(c.id.substring(colon + 1)) : null;
      if (n != null) (_counters[c.id.substring(0, colon)] ??= {}).add(n);
    }
    if (fresh.isEmpty) return const {};
    fresh.sort(changeOrder);
    if (_log.isEmpty || changeOrder(fresh.first, _log.last) > 0) {
      _log.addAll(fresh);
      fresh.forEach(_applyOne);
    } else {
      _log
        ..addAll(fresh)
        ..sort(changeOrder);
      replay();
    }
    return {
      for (final c in fresh)
        if (rejected.containsKey(c.id)) c.id: rejected[c.id]!,
    };
  }

  /// Drops changes that were never stored (a local write that failed part way).
  void remove(Iterable<String> ids) {
    final drop = ids.toSet();
    if (drop.isEmpty) return;
    _log.removeWhere((c) => drop.contains(c.id));
    for (final id in drop) {
      _byId.remove(id);
      final colon = id.lastIndexOf(':');
      final n = colon > 0 ? int.tryParse(id.substring(colon + 1)) : null;
      if (n != null) _counters[id.substring(0, colon)]?.remove(n);
    }
    replay();
  }

  void replay() {
    replays++;
    store.clear();
    rejected.clear();
    applied.clear();
    _log.forEach(_applyOne);
  }

  void _applyOne(Change c) {
    final rejection = validator.check(c);
    if (rejection != null) {
      rejected[c.id] = rejection.message;
      return;
    }
    final (entry, before, created) = store.apply(c);
    applied.add(Applied(c, before, created, verbFor(c, before, created), titleOf(entry, store)));
  }
}

/// The short past-tense verb History shows for a change.
String verbFor(Change c, Map<String, Object?> before, bool created) {
  final f = c.fields;
  if (c.isDelete) return 'removed';
  switch (c.type) {
    case RecordType.adjustment:
      return ((f['delta'] as num?) ?? 0) < 0 ? 'took' : 'gave';
    case RecordType.redemption:
      if (created && f['status'] == RedemptionStatus.requested.name) return 'requested';
      if (f['status'] == RedemptionStatus.approved.name) return created ? 'requested' : 'approved';
      if (f['status'] == RedemptionStatus.declined.name) return 'declined';
    case RecordType.completion:
      if (f.containsKey('done')) return f['done'] == true ? 'completed' : 'reopened';
      if (f.containsKey('owner')) return 'swapped';
      final steps = [
        for (final e in f.entries)
          if (e.key.startsWith('steps.')) e.value,
        ...?(f['steps'] as Map?)?.values,
      ];
      if (steps.isNotEmpty) return steps.any((v) => v != null) ? 'checked' : 'unchecked';
    case RecordType.item:
      if (!created && f.containsKey('checked') && f.keys.every((k) => const {'checked', 'checkedBy', '_via'}.contains(k))) {
        return f['checked'] == true ? 'checked' : 'unchecked';
      }
    case RecordType.device:
      if (f['revoked'] == true) return 'removed';
      if (f['approved'] == true && before['approved'] != true) return 'approved';
      if (created && f['approved'] == false) return 'requested';
    case RecordType.connection:
      if (f['status'] == ConnectionStatus.revoked.name) return 'removed';
      if (created && f['status'] == ConnectionStatus.pending.name) return 'requested';
      if (!created && f['status'] == ConnectionStatus.active.name) return 'approved';
  }
  return created ? 'added' : 'changed';
}

/// The title or text people know a record by, read from the state right after a change.
String titleOf(Entry e, RecordStore store) {
  String field(Entry? r, String name) => (r?.fields[name] as String?) ?? '';
  switch (e.type) {
    case RecordType.family:
    case RecordType.member:
    case RecordType.device:
    case RecordType.category:
      return field(e, 'name');
    case RecordType.item:
      return field(e, 'text');
    case RecordType.completion:
      final chore = e.fields['chore'];
      return chore is String ? field(store.at(e.space, RecordType.chore, chore), 'title') : '';
    case RecordType.eventException:
      final event = e.fields['event'];
      final patched = (e.fields['patch'] as Map?)?['title'];
      if (patched is String) return patched;
      return event is String ? field(store.at(e.space, RecordType.event, event), 'title') : '';
    case RecordType.adjustment:
      final reason = field(e, 'reason');
      return reason.isNotEmpty ? reason : 'Points';
    case RecordType.redemption:
      final reward = e.fields['reward'];
      return reward is String ? field(store.at(e.space, RecordType.reward, reward), 'title') : '';
    case RecordType.subscription:
    case RecordType.connection:
      return field(e, 'label');
    default:
      return field(e, 'title');
  }
}
