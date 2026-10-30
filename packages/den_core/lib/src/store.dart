import 'change.dart';
import 'hlc.dart';
import 'model.dart';

/// One record's merged state inside a space. Records are keyed by `(space, type, id)` so that a
/// change's validity depends only on the spaces a replica holds.
class Entry {
  Entry(this.type, this.id, this.space, this.created, this.createdBy, this.createdDevice,
      {Map<String, Object?>? fields, Map<String, Hlc>? times})
      : updated = created,
        updatedBy = createdBy,
        fields = fields ?? {},
        times = times ?? {};

  final String type;
  final String id;
  final String space;
  final Hlc created;
  final String? createdBy;
  final String createdDevice;
  final Map<String, Object?> fields;
  final Map<String, Hlc> times;
  Hlc updated;
  String? updatedBy;
  Rec? _rec;

  bool get deleted => fields['_deleted'] == true;

  Rec get rec => _rec ??= Rec(
        type: type,
        id: id,
        space: space,
        fields: Map.unmodifiable(fields),
        created: created,
        updated: updated,
        createdBy: createdBy,
        updatedBy: updatedBy,
        fieldTimes: Map.unmodifiable(times),
      );

  /// The value a field (or `"<field>.<key>"` entry) holds now.
  Object? valueOf(String name) {
    final dot = name.indexOf('.');
    if (dot > 0 && !name.startsWith('_')) {
      final head = fields[name.substring(0, dot)];
      return head is Map ? head[name.substring(dot + 1)] : null;
    }
    return fields[name];
  }

  /// Whether a field (or `"<field>.<key>"` entry) has been set at all, even to null. A swap to
  /// anyone stores a null owner, so a null value and no value can mean different things.
  bool has(String name) {
    final dot = name.indexOf('.');
    if (dot > 0 && !name.startsWith('_')) {
      final head = fields[name.substring(0, dot)];
      return head is Map && head.containsKey(name.substring(dot + 1));
    }
    return fields.containsKey(name);
  }
}

/// Deep copy of a JSON value so state never aliases a change's maps and lists.
Object? copyJson(Object? value) {
  if (value is Map) return {for (final e in value.entries) e.key.toString(): copyJson(e.value)};
  if (value is List) return [for (final v in value) copyJson(v)];
  return value;
}

/// What a field or field time held before a change: [absent] when it wasn't there at all.
const Object absent = _Absent();

class _Absent {
  const _Absent();
}

/// Everything a change altered in one record, so it can be taken back exactly: the record it
/// created, or the earlier values of the fields and field times it touched. The materializer
/// keeps one per applied change to rewind to an earlier position in the log.
class Undo {
  Undo(this.entry, this.created, this.fieldNames, this.fieldValues, this.timeNames, this.timeValues, this.updated,
      this.updatedBy);

  final Entry entry;
  final bool created;

  /// Top-level fields of [entry] the change touched, with what each held ([absent] when unset).
  final List<String> fieldNames;
  final List<Object?> fieldValues;

  /// Field times the change set or cleared, with what each held ([absent] when unset).
  final List<String> timeNames;
  final List<Object?> timeValues;
  final Hlc updated;
  final String? updatedBy;
}

/// The materialized records of every space this replica holds.
class RecordStore {
  /// type -> record id -> the entries with that id, one per space (nearly always one).
  final Map<String, Map<String, List<Entry>>> _byType = {};

  /// Bumped on every applied or undone change; caches key off it.
  int version = 0;

  /// Bumped when the whole store is replaced (cleared, replayed or restored), which no per-type
  /// count can tell apart from what it held before.
  int epoch = 0;

  /// type -> space -> changes applied to or undone from records of that type in that space.
  final Map<String, Map<String, int>> _versions = {};

  /// In a group: the homes whose place ended (groups.dart, `HomeEnd`), from when, why
  /// (`contested` or `disowned`) and, when disowned, by which change. Settled by the
  /// materializer from the log alone; kept through [clear], which a replay does.
  Map<String, ({Hlc at, String why, String? by})> endedHomes = const {};

  /// While validity judges a change: its clock, so a home that ended later reads as it was then.
  Hlc? judging;

  /// A number that changes whenever a record of one of [types] in one of [spaces] does; equal
  /// numbers within one [epoch] mean nothing those views read has changed.
  int versionOf(Iterable<String> types, Iterable<String> spaces) {
    var n = 0;
    for (final t in types) {
      final bySpace = _versions[t];
      if (bySpace == null) continue;
      for (final s in spaces) {
        n += bySpace[s] ?? 0;
      }
    }
    return n;
  }

  /// [versionOf] over every space.
  int versionOfType(String type) {
    var n = 0;
    for (final v in (_versions[type] ?? const <String, int>{}).values) {
      n += v;
    }
    return n;
  }

  void _touched(String type, String space) {
    final bySpace = _versions[type] ??= {};
    bySpace[space] = (bySpace[space] ?? 0) + 1;
    version++;
  }

  Entry? at(String space, String type, String id) {
    final list = _byType[type]?[id];
    if (list == null) return null;
    for (final e in list) {
      if (e.space == space) return e;
    }
    return null;
  }

  /// The live entry at `(space, type, id)`, or null.
  Entry? liveAt(String space, String type, String id) {
    final e = at(space, type, id);
    return e == null || e.deleted ? null : e;
  }

  /// The record with this id in any space: a live one if there is one (the most recently
  /// created when several), else the most recently created deleted one.
  Entry? find(String type, String id) {
    final list = _byType[type]?[id];
    if (list == null || list.isEmpty) return null;
    Entry? best;
    for (final e in list) {
      if (best == null ||
          (best.deleted && !e.deleted) ||
          (best.deleted == e.deleted && e.created > best.created)) {
        best = e;
      }
    }
    return best;
  }

  Iterable<Entry> ofType(String type) {
    final byId = _byType[type];
    if (byId == null) return const [];
    return byId.values.expand(_same);
  }

  static List<Entry> _same(List<Entry> list) => list;

  Iterable<Entry> liveOfType(String type) => ofType(type).where((e) => !e.deleted);

  /// Every entry, in the order [ofType] gives them type by type.
  Iterable<Entry> get all => _byType.values.expand((byId) => byId.values).expand(_same);

  /// Applies a valid change; returns the entry, the previous values of the fields it set, whether
  /// it created the record, which of those fields had never been set before, and how to take it
  /// back.
  (Entry, Map<String, Object?>, bool, Set<String>, Undo) apply(Change c) {
    var entry = at(c.space, c.type, c.rid);
    final creating = entry == null;
    final fieldNames = <String>[], timeNames = <String>[];
    final fieldValues = <Object?>[], timeValues = <Object?>[];
    if (entry == null) {
      entry = Entry(c.type, c.rid, c.space, c.hlc, c.actor, c.device);
      ((_byType[c.type] ??= {})[c.rid] ??= []).add(entry);
    } else {
      // What the change will touch, as it was before any of it: the top-level fields, the times
      // it sets, and the entry times a whole-field write clears.
      final fields = entry.fields, times = entry.times;
      void field(String name) {
        if (fieldNames.contains(name)) return;
        fieldNames.add(name);
        fieldValues.add(fields.containsKey(name) ? fields[name] : absent);
      }

      void time(String name) {
        if (timeNames.contains(name)) return;
        timeNames.add(name);
        timeValues.add(times.containsKey(name) ? times[name] : absent);
      }

      for (final name in c.fields.keys) {
        final dot = name.indexOf('.');
        if (dot > 0 && !name.startsWith('_')) {
          field(name.substring(0, dot));
        } else {
          field(name);
          if (_mayHaveEntryTimes(entry, name)) {
            for (final k in times.keys) {
              if (k.startsWith('$name.')) time(k);
            }
          }
        }
        time(name);
      }
    }
    final undo = Undo(entry, creating, fieldNames, fieldValues, timeNames, timeValues, entry.updated, entry.updatedBy);
    final before = <String, Object?>{};
    final absentBefore = <String>{};
    for (final f in c.fields.entries) {
      final name = f.key;
      if (!entry.has(name)) absentBefore.add(name);
      before[name] = entry.valueOf(name);
      final dot = name.indexOf('.');
      if (dot > 0 && !name.startsWith('_')) {
        final head = name.substring(0, dot);
        final current = entry.fields[head];
        final map = current is Map ? Map<String, Object?>.from(current) : <String, Object?>{};
        map[name.substring(dot + 1)] = copyJson(f.value);
        entry.fields[head] = map;
      } else {
        if (_mayHaveEntryTimes(entry, name)) entry.times.removeWhere((k, _) => k.startsWith('$name.'));
        entry.fields[name] = copyJson(f.value);
      }
      entry.times[name] = c.hlc;
    }
    entry.updated = c.hlc;
    entry.updatedBy = c.actor;
    entry._rec = null;
    _touched(c.type, c.space);
    return (entry, before, creating, absentBefore, undo);
  }

  /// Whether `"<name>.<key>"` field times may exist on [entry]: only entry writes make them, and
  /// those leave a map in the field, so any other value means there are none to clear.
  static bool _mayHaveEntryTimes(Entry entry, String name) => name.startsWith('_') || entry.fields[name] is Map;

  /// Takes back a change [apply] made, the newest first.
  void undo(Undo u) {
    final entry = u.entry;
    if (u.created) {
      final byId = _byType[entry.type]!;
      final list = byId[entry.id]!..remove(entry);
      if (list.isEmpty) byId.remove(entry.id);
      if (byId.isEmpty) _byType.remove(entry.type);
    } else {
      for (var i = 0; i < u.fieldNames.length; i++) {
        final v = u.fieldValues[i];
        if (identical(v, absent)) {
          entry.fields.remove(u.fieldNames[i]);
        } else {
          entry.fields[u.fieldNames[i]] = v;
        }
      }
      for (var i = 0; i < u.timeNames.length; i++) {
        final v = u.timeValues[i];
        if (identical(v, absent)) {
          entry.times.remove(u.timeNames[i]);
        } else {
          entry.times[u.timeNames[i]] = v as Hlc;
        }
      }
      entry.updated = u.updated;
      entry.updatedBy = u.updatedBy;
      entry._rec = null;
    }
    _touched(entry.type, entry.space);
  }

  /// Adds an entry as a snapshot recorded it.
  void put(Entry e) => ((_byType[e.type] ??= {})[e.id] ??= []).add(e);

  void clear() {
    _byType.clear();
    _versions.clear();
    version++;
    epoch++;
  }
}
