import 'dart:convert';

import 'change.dart';
import 'hlc.dart';
import 'model.dart';
import 'invite_keys.dart' show retiresInviteKey;
import 'recovery.dart';
import 'snapshot.dart';
import 'store.dart';
import 'validity.dart';

/// A valid change as it was applied: what each field held before, and how people would say it.
class Applied {
  const Applied(this.change, this.before, this.created, this.verb, this.title, {this.absent = const {}});
  final Change change;
  final Map<String, Object?> before;
  final bool created;
  final String verb;
  final String title;

  /// Fields of [change] (or `"<field>.<key>"` entries) the record had never had: [before] holds
  /// null for them, which an undo can't always write back.
  final Set<String> absent;
}

/// HLC order with the change id as the last tiebreak, so the order is total.
int changeOrder(Change a, Change b) {
  final byClock = a.hlc.compareTo(b.hlc);
  return byClock != 0 ? byClock : a.id.compareTo(b.id);
}

/// What a log position holds for a change that didn't count: nothing to take back.
const Object _rejectedStep = Object();

/// The change log and the state it materializes to. Every change is validated against the state
/// built from the valid changes before it in HLC order, so every replica holding the same changes
/// agrees on both the state and which changes were rejected.
///
/// A change that arrives older than the newest one applied doesn't replay the log from scratch:
/// each applied change keeps what it overwrote (an [Undo]), so the materializer takes back the
/// changes after the newcomer's place, newest first, and applies from there. Positions before
/// [windowStart] (a log opened from a snapshot keeps only a recent window) have nothing to take
/// back with, and a change landing there replays everything.
///
/// A device's clock is its own to set, so a revoked device could sign new changes with clocks
/// from before its revocation. A revocation therefore names the last change the revoking device
/// held from it (`revokedAfter`), and a replay from scratch settles which cutoffs (see [Cutoff])
/// are in effect, applying them from the start: only those of revocations that count with the
/// others applied ([replay]). A replaced recovery key works the same way
/// ([RetiredRecoveryKeys]). All of it depends only on the log, so every replica still agrees.
/// Which revocations and replacements count can turn on any change before them, so a change
/// landing at or before one (or making one) replays everything too.
class Materializer {
  Materializer(TrustRoot Function() root) {
    validator = Validator(store, root)..createdCounter = _createdCounter;
  }

  final RecordStore store = RecordStore();
  late final Validator validator;
  final List<Change> _log = [];
  final Map<String, Change> _byId = {};
  final Map<String, Set<int>> _counters = {};

  /// Per log position: the [Undo] of a change applied there, or [_rejectedStep]. Positions before
  /// [_windowStart] hold null: there is nothing to rewind them with.
  final List<Object?> _steps = [];
  int _windowStart = 0;

  /// Change id -> why it doesn't count.
  final Map<String, String> rejected = {};

  /// Valid changes in HLC order. After a restore, those before the window are read from the
  /// snapshot only when first asked for ([_lazyApplied]).
  final List<Applied> _applied = [];
  List<Applied> Function()? _lazyApplied;
  Hlc? _lazyNewest;

  /// Times applied changes were taken back and applied again, from scratch or from a point.
  int replays = 0;

  /// Of [replays], those that started from scratch.
  int fullReplays = 0;

  List<Change> get log => _log;
  bool contains(String id) => _byId.containsKey(id);
  Change? byId(String id) => _byId[id];
  Map<String, Set<int>> get counters => _counters;

  /// The first log position a late change can rewind to without replaying everything.
  int get windowStart => _windowStart;

  /// Valid changes in HLC order.
  List<Applied> get applied {
    final lazy = _lazyApplied;
    if (lazy != null) {
      _lazyApplied = null;
      _lazyNewest = null;
      _familyBefore = const [];
      List<Applied>? before;
      try {
        before = lazy();
      } on Object {
        before = null;
      }
      if (before == null) {
        // The snapshot's history didn't read back: build it again from the log.
        replay();
      } else {
        _applied.insertAll(0, before);
      }
    }
    return _applied;
  }

  /// The clock of the newest valid change, without reading a snapshot's history.
  Hlc? get newestApplied => _applied.isNotEmpty ? _applied.last.change.hlc : _lazyNewest;

  /// The valid changes to the family record, in HLC order, without reading a snapshot's history
  /// (Today reads them, for privacy notices, right after opening).
  List<Applied> get appliedToFamily => [
        if (_lazyApplied != null) ..._familyBefore,
        for (final a in _applied)
          if (a.change.type == RecordType.family) a,
      ];

  /// While the history is unread: the valid changes to the family record before the window.
  List<Applied> _familyBefore = const [];

  /// Validates a change as the next one after everything applied.
  Rejection? check(Change c) => validator.check(c);

  bool _register(Change c) {
    if (_byId.containsKey(c.id)) return false;
    _byId[c.id] = c;
    final n = _counterIn(c.id);
    if (n != null) (_counters[c.id.substring(0, c.id.lastIndexOf(':'))] ??= {}).add(n);
    return true;
  }

  void _unregister(String id) {
    if (_byId.remove(id) == null) return;
    final n = _counterIn(id);
    if (n != null) _counters[id.substring(0, id.lastIndexOf(':'))]?.remove(n);
  }

  /// Adds changes not already held; returns the ones that turned out invalid, with reasons.
  Map<String, String> add(Iterable<Change> changes) {
    final fresh = <Change>[];
    for (final c in changes) {
      if (_register(c)) fresh.add(c);
    }
    if (fresh.isEmpty) return const {};
    fresh.sort(changeOrder);
    final at = _positionOf(fresh.first);
    if (_canRewindTo(at) && !fresh.any(_decidesVerdicts)) {
      if (at < _log.length) {
        replays++;
        _rewindTo(at);
        final tail = _log.sublist(at);
        _log
          ..length = at
          ..addAll(_merge(tail, fresh));
      } else {
        _log.addAll(fresh);
      }
      _applyFrom(at);
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

  /// Drops changes that were never stored (a local write that failed part way), or that turned
  /// out not to be what their author signed.
  void remove(Iterable<String> ids) {
    final drop = {for (final id in ids) if (_byId.containsKey(id)) id};
    if (drop.isEmpty) return;
    var at = _log.length, found = 0;
    for (var i = _log.length - 1; i >= 0 && found < drop.length; i--) {
      if (drop.contains(_log[i].id)) {
        at = i;
        found++;
      }
    }
    for (final id in drop) {
      _unregister(id);
    }
    if (_canRewindTo(at)) {
      replays++;
      _rewindTo(at);
      final tail = [for (final c in _log.sublist(at)) if (!drop.contains(c.id)) c];
      _log
        ..length = at
        ..addAll(tail);
      _applyFrom(at);
    } else {
      _log.removeWhere((c) => drop.contains(c.id));
      replay();
    }
  }

  /// Becomes a copy of [other], which holds the same log: for an engine that tries changes out
  /// (a preview). It keeps nothing to rewind with, so a late change to it replays from scratch.
  void copyFrom(Materializer other) {
    store.clear();
    for (final e in other.store.all) {
      store.put(Entry(e.type, e.id, e.space, e.created, e.createdBy, e.createdDevice,
          fields: Map.of(e.fields), times: Map.of(e.times))
        ..updated = e.updated
        ..updatedBy = e.updatedBy);
    }
    rejected
      ..clear()
      ..addAll(other.rejected);
    validator.cutoffs
      ..clear()
      ..addAll({for (final e in other.validator.cutoffs.entries) e.key: List.of(e.value)});
    validator.retiredRecoveryKeys
      ..clear()
      ..addAll(other.validator.retiredRecoveryKeys);
    _log
      ..clear()
      ..addAll(other._log);
    _byId
      ..clear()
      ..addAll(other._byId);
    _counters
      ..clear()
      ..addAll({for (final e in other._counters.entries) e.key: Set.of(e.value)});
    _applied
      ..clear()
      ..addAll(other.applied);
    _lazyApplied = null;
    _lazyNewest = null;
    _familyBefore = const [];
    _steps
      ..clear()
      ..addAll(List<Object?>.filled(_log.length, null));
    _windowStart = _log.length;
  }

  /// Forgets every change.
  void clear() {
    _log.clear();
    _byId.clear();
    _counters.clear();
    replay();
  }

  /// Replays the whole log from scratch, then settles which revocations naming a cutoff and
  /// which replaced recovery keys are in effect, taking them in log order:
  ///
  /// - one is applied only if it counts with those already applied, so a cutoff never makes
  ///   its own revocation count;
  /// - once applied, any that no longer counts (a later removal of its author's device cut it,
  ///   say) is dropped for good, and its cutoff with it, so no cutoff stays in effect once the
  ///   revocation that named it stops counting;
  /// - after a drop the scan starts over, since what the dropped one undid may let an earlier
  ///   one count.
  ///
  /// The log is replayed only when one excludes something. Every replica does the same from the
  /// log alone, and a late change before any of them replays from scratch ([add]).
  void replay() {
    replays++;
    fullReplays++;
    validator.cutoffs.clear();
    validator.retiredRecoveryKeys.clear();
    _replayOnce();
    final deciding = [for (final c in _log) if (_decidesVerdicts(c)) c];
    final applied = <String>[];
    final dropped = <String>{};
    for (var i = 0; i < deciding.length; i++) {
      final c = deciding[i];
      if (applied.contains(c.id) || dropped.contains(c.id) || rejected.containsKey(c.id)) continue;
      applied.add(c.id);
      _applyEffects(applied);
      // Nothing that counts now is cut: the state is already what a replay would give.
      if (!_applied.any((a) => _excluded(a.change))) continue;
      var shrank = false;
      while (true) {
        _replayOnce();
        final gone = [for (final id in applied) if (rejected.containsKey(id)) id];
        if (gone.isEmpty) break;
        applied.removeWhere(gone.contains);
        dropped.addAll(gone);
        shrank = true;
        _applyEffects(applied);
      }
      if (shrank) i = -1;
    }
  }

  /// Whether the validator's cutoffs or replaced recovery keys make [c] count for nothing.
  bool _excluded(Change c) {
    final n = _counterIn(c.id);
    return (n != null && (validator.cutoffs[c.device]?.any((k) => k.excludes(n, c.hlc)) ?? false)) ||
        validator.retiredRecoveryKeys.excludes(c);
  }

  /// Sets the validator's cutoffs and replaced recovery keys to those of [ids], each of which
  /// counts in the state as it stands.
  void _applyEffects(List<String> ids) {
    final chosen = {...ids};
    final effects = [
      for (final a in _applied)
        if (chosen.contains(a.change.id)) a,
    ];
    validator.cutoffs.clear();
    for (final a in effects) {
      final cut = Cutoff.of(a.change);
      if (cut != null) (validator.cutoffs[a.change.rid] ??= []).add(cut);
    }
    validator.retiredRecoveryKeys
      ..clear()
      ..addAll(RetiredRecoveryKeys.of(effects));
  }

  /// The counter of [device]'s own change that made its record, clocked [created]: nearly
  /// always its first.
  int? _createdCounter(String device, Hlc created) {
    bool makes(Change? c) => c != null && c.hlc == created && c.type == RecordType.device && c.rid == device;
    if (makes(_byId['$device:1'])) return 1;
    int? best;
    for (final n in _counters[device] ?? const <int>{}) {
      if ((best == null || n < best) && makes(_byId['$device:$n'])) best = n;
    }
    return best;
  }

  void _replayOnce() {
    store.clear();
    rejected.clear();
    _applied.clear();
    _lazyApplied = null;
    _lazyNewest = null;
    _familyBefore = const [];
    _steps.clear();
    _windowStart = 0;
    _applyFrom(0);
  }

  /// Where [c] goes in the log: after every change that orders before it.
  int _positionOf(Change c) {
    var lo = 0, hi = _log.length;
    if (hi > 0 && changeOrder(_log[hi - 1], c) < 0) return hi;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (changeOrder(_log[mid], c) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Whether the state can go back to log position [at] and be applied again from there: there
  /// is something to take back each later change with, and no revocation at or after it whose
  /// cutoff a change before it could decide.
  bool _canRewindTo(int at) {
    if (at < _windowStart) return false;
    for (var i = at; i < _log.length; i++) {
      if (_decidesVerdicts(_log[i])) return false;
    }
    return true;
  }

  /// Takes back every change from log position [at] on, newest first.
  void _rewindTo(int at) {
    for (var i = _log.length - 1; i >= at; i--) {
      final step = _steps[i];
      if (step is Undo) {
        store.undo(step);
        _applied.removeLast();
      } else {
        rejected.remove(_log[i].id);
      }
    }
    _steps.length = at;
  }

  void _applyFrom(int at) {
    for (var i = at; i < _log.length; i++) {
      _applyOne(_log[i]);
    }
  }

  static List<Change> _merge(List<Change> a, List<Change> b) {
    final out = <Change>[];
    var i = 0, j = 0;
    while (i < a.length && j < b.length) {
      out.add(changeOrder(a[i], b[j]) <= 0 ? a[i++] : b[j++]);
    }
    while (i < a.length) {
      out.add(a[i++]);
    }
    while (j < b.length) {
      out.add(b[j++]);
    }
    return out;
  }

  static bool _namesCutoff(Change c) => c.type == RecordType.device && c.fields.containsKey('revokedAfter');

  /// Whether [c] can make changes before it count for nothing on a second pass: a revocation
  /// naming a cutoff, a replaced recovery key or an invite key taken away ([RetiredRecoveryKeys]).
  static bool _decidesVerdicts(Change c) => _namesCutoff(c) || setsRecoveryKey(c) || retiresInviteKey(c);

  static int? _counterIn(String id) {
    final colon = id.lastIndexOf(':');
    return colon > 0 ? int.tryParse(id.substring(colon + 1)) : null;
  }

  void _applyOne(Change c) {
    final rejection = validator.check(c);
    if (rejection != null) {
      rejected[c.id] = rejection.message;
      _steps.add(_rejectedStep);
      return;
    }
    final (entry, before, created, absent, undo) = store.apply(c);
    _applied.add(Applied(c, before, created, verbFor(c, before, created), titleOf(entry, store), absent: absent));
    _steps.add(undo);
  }

  // ---------------------------------------------------------------- snapshots

  /// Everything the state holds, copied as it is now, for [encodeSnapshot] to write out while
  /// the state moves on. Keeps the steps of the log positions from the first change clocked at
  /// or after [windowFrom] (UTC ms) on, so a late change can rewind that far after a restore.
  SnapshotCapture capture({required TrustRoot root, required int windowFrom, required List<int> digest}) {
    var w = _log.length;
    while (w > _windowStart && _log[w - 1].hlc.millis >= windowFrom) {
      w--;
    }
    final records = [
      for (final e in store.all)
        [
          e.type, e.id, e.space, e.created, e.createdBy, e.createdDevice, e.updated, e.updatedBy,
          Map<String, Object?>.of(e.fields), Map<String, Hlc>.of(e.times),
        ],
    ];
    final window = <(Change, Object, Applied?)>[];
    final appliedFrom = _applied.length - [for (var i = w; i < _log.length; i++) if (_steps[i] is Undo) i].length;
    var a = appliedFrom;
    for (var i = w; i < _log.length; i++) {
      final step = _steps[i]!;
      window.add((_log[i], step, step is Undo ? _applied[a++] : null));
    }
    return SnapshotCapture(
      familyId: root.familyId,
      founderPubkey: root.founderPubkey,
      log: List.of(_log),
      digest: digest,
      cutoffs: {for (final e in validator.cutoffs.entries) e.key: List.of(e.value)},
      retired: RetiredRecoveryKeys()..addAll(validator.retiredRecoveryKeys),
      newest: newestApplied,
      windowStart: w,
      records: records,
      rejected: Map.of(rejected),
      window: window,
      family: [
        if (_lazyApplied != null) ..._familyBefore,
        for (final a in _applied.sublist(0, appliedFrom))
          if (a.change.type == RecordType.family) a,
      ],
      history: _lazyApplied == null ? _applied.sublist(0, appliedFrom) : null,
      historyText: _lazyApplied == null ? null : _lazyHistoryText,
      historyMore: _lazyApplied == null ? const [] : _applied.sublist(0, appliedFrom),
    );
  }

  String? _lazyHistoryText;

  /// Replaces the state with what [snapshot] holds over the changes it covers, which [held]
  /// (everything the device stores) must include; returns the changes it doesn't cover, to [add]
  /// after. Returns null, leaving the materializer empty, when the snapshot can't be used: from
  /// another family or format, damaged, or covering changes [held] lacks, or when a change it
  /// doesn't cover would land before its window (a replay from scratch would follow anyway).
  List<Change>? restore(SnapshotHeader snapshot, List<Change> held, {required TrustRoot root}) {
    try {
      final rest = _restore(snapshot, held, root);
      if (rest != null) return rest;
    } on Object {
      // Damaged: replayed from the log instead.
    }
    _log.clear();
    _byId.clear();
    _counters.clear();
    validator.cutoffs.clear();
    validator.retiredRecoveryKeys.clear();
    _replayOnce();
    return null;
  }

  List<Change>? _restore(SnapshotHeader s, List<Change> held, TrustRoot root) {
    if (s.familyId != root.familyId || s.founderPubkey != root.founderPubkey) return null;
    _log.clear();
    _byId.clear();
    _counters.clear();
    final covered = <Change>[], rest = <Change>[];
    for (final c in held) {
      if (_byId.containsKey(c.id)) continue; // A second copy of one it covers.
      if (s.covers(c.id)) {
        _register(c);
        covered.add(c);
      } else {
        rest.add(c);
      }
    }
    if (covered.length != s.count) return null;
    covered.sort(changeOrder);
    final w = s.windowStart;
    if (w > covered.length) return null;
    if (w < covered.length && covered[w].id != s.windowFirst) return null;
    if (rest.isNotEmpty) {
      var first = rest.first;
      for (final c in rest) {
        if (changeOrder(c, first) < 0) first = c;
      }
      // A change it doesn't cover, older than its window: everything would be replayed anyway.
      if (w == covered.length ? (covered.isNotEmpty && changeOrder(first, covered.last) < 0) : changeOrder(first, covered[w]) < 0) {
        return null;
      }
    }
    final state = s.state;
    store.clear();
    rejected.clear();
    _applied.clear();
    _steps.clear();
    validator.cutoffs.clear();
    final devices = (state['devices']! as List).cast<String>();
    Hlc clock(List r, int at) => Hlc(r[at] as int, r[at + 1] as int, devices[r[at + 2] as int]);
    for (final row in state['records']! as List) {
      final r = row as List;
      final created = clock(r, 3), updated = clock(r, 7);
      final times = <String, Hlc>{};
      for (final g in r[12] as List) {
        final group = g as List;
        final ref = group[0];
        final at = ref == 0 ? created : (ref == 1 ? updated : clock(ref as List, 0));
        for (var k = 1; k < group.length; k++) {
          times[group[k] as String] = at;
        }
      }
      final e = Entry(r[0] as String, r[1] as String, r[2] as String, created, r[6] as String?,
          r.length > 13 ? r[13] as String : created.device,
          fields: copyJson(r[11]) as Map<String, Object?>, times: times);
      e.updated = updated;
      e.updatedBy = r[10] as String?;
      store.put(e);
    }
    for (final e in (state['rejected']! as Map).entries) {
      rejected[e.key as String] = e.value as String;
    }
    validator.retiredRecoveryKeys
      ..clear()
      ..addAll(RetiredRecoveryKeys.fromJson(state['retired']! as List));
    for (final e in (state['cutoffs']! as Map).entries) {
      validator.cutoffs[e.key as String] = [
        for (final k in e.value as List) Cutoff((k as List)[0] as int, Hlc.parse(k[1] as String)),
      ];
    }
    _log.addAll(covered);
    _steps.addAll(List<Object?>.filled(w, null));
    _windowStart = w;
    final window = state['window']! as List;
    if (window.length != covered.length - w) return null;
    for (var i = 0; i < window.length; i++) {
      final c = covered[w + i];
      final row = window[i] as List;
      if (row[0] != c.id) return null;
      if (row.length == 1) {
        if (!rejected.containsKey(c.id)) return null;
        _steps.add(_rejectedStep);
        continue;
      }
      final a = _appliedOf(row, c);
      final entry = store.at(c.space, c.type, c.rid);
      if (entry == null) return null;
      Undo undo;
      if (a.created) {
        undo = Undo(entry, true, const [], const [], const [], const [], entry.created, entry.createdBy);
      } else {
        final names = (row[6] as List).cast<String>();
        final values = List<Object?>.of(row[7] as List);
        for (final i in row[8] as List) {
          values[i as int] = absent;
        }
        final timeNames = (row[9] as List).cast<String>();
        final timeValues = [for (final t in row[10] as List) t == null ? absent : Hlc.parse(t as String)];
        undo = Undo(entry, false, names, values, timeNames, timeValues, Hlc.parse(row[11] as String), row[12] as String?);
      }
      _applied.add(a);
      _steps.add(undo);
    }
    _familyBefore = [
      for (final row in state['family']! as List)
        _appliedOf(row as List, _byId[row[0]] ?? (throw const FormatException('The family history doesn\'t match'))),
    ];
    final applyBefore = w - [for (var i = 0; i < w; i++) if (rejected.containsKey(covered[i].id)) i].length;
    final newest = state['newest'];
    _lazyNewest = newest is String ? Hlc.parse(newest) : null;
    final historyText = s.historyText;
    _lazyHistoryText = historyText;
    _lazyApplied = applyBefore == 0
        ? null
        : () {
            final rows = jsonDecode(historyText) as List;
            if (rows.length != applyBefore) throw const FormatException('History doesn\'t match the snapshot');
            final out = <Applied>[];
            var r = 0;
            for (var i = 0; i < w; i++) {
              final c = covered[i];
              if (rejected.containsKey(c.id)) continue;
              final row = rows[r++] as List;
              if (row[0] != c.id) throw const FormatException('History doesn\'t match the snapshot');
              out.add(_appliedOf(row, c));
            }
            return out;
          };
    if (_lazyApplied == null) {
      _lazyNewest = null;
      _familyBefore = const [];
    }
    return rest;
  }

  static Applied _appliedOf(List row, Change c) {
    final created = row[1] == 1;
    if (row.length == 4) {
      return Applied(c, {for (final k in c.fields.keys) k: null}, created, row[2] as String, row[3] as String,
          absent: c.fields.keys.toSet());
    }
    return Applied(c, (row[4] as Map).cast<String, Object?>(), created, row[2] as String, row[3] as String,
        absent: (row[5] as List).cast<String>().toSet());
  }
}

/// The short past-tense verb History shows for a change.
String verbFor(Change c, Map<String, Object?> before, bool created) {
  final f = c.fields;
  if (c.isDelete) return 'removed';
  if (f['_deleted'] == false) return 'restored';
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
      if (!created && f.containsKey('checked') && f.keys.every((k) => const {'checked', 'checkedBy', '_via', '_from'}.contains(k))) {
        return f['checked'] == true ? 'checked' : 'unchecked';
      }
    case RecordType.device:
      if (f['revoked'] == true) return 'removed';
      if (f['approved'] == true && before['approved'] != true) return 'approved';
      if (created && f['approved'] == false) return 'requested';
    case RecordType.signInTries:
      return 'counted';
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
      return reason.isNotEmpty ? reason : 'Stars';
    case RecordType.redemption:
      final reward = e.fields['reward'];
      return reward is String ? field(store.at(e.space, RecordType.reward, reward), 'title') : '';
    case RecordType.subscription:
    case RecordType.connection:
      return field(e, 'label');
    case RecordType.signInTries:
      final member = e.fields['member'];
      final m = member is String ? store.at(Space.family, RecordType.member, member) : null;
      final kind = (m?.fields['signIn'] as Map?)?['kind'] == 'pattern' ? 'pattern' : 'PIN';
      return '${e.fields['tries']} wrong tries at ${field(m, 'name')}\'s $kind';
    default:
      return field(e, 'title');
  }
}
