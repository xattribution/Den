import 'change.dart';
import 'hlc.dart';
import 'model.dart';

/// One record's merged state inside a space. Records are keyed by `(space, type, id)` so that a
/// change's validity depends only on the spaces a replica holds.
class Entry {
  Entry(this.type, this.id, this.space, this.created, this.createdBy, this.createdDevice)
      : updated = created,
        updatedBy = createdBy;

  final String type;
  final String id;
  final String space;
  final Hlc created;
  final String? createdBy;
  final String createdDevice;
  final Map<String, Object?> fields = {};
  final Map<String, Hlc> times = {};
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

/// The materialized records of every space this replica holds.
class RecordStore {
  final Map<String, Entry> _byKey = {};
  final Map<String, Map<String, List<Entry>>> _byType = {};

  /// Bumped on every applied change; caches key off it.
  int version = 0;

  static String _key(String space, String type, String id) => '$space\u0000$type\u0000$id';

  Entry? at(String space, String type, String id) => _byKey[_key(space, type, id)];

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

  Iterable<Entry> ofType(String type) sync* {
    final byId = _byType[type];
    if (byId == null) return;
    for (final list in byId.values) {
      yield* list;
    }
  }

  Iterable<Entry> liveOfType(String type) => ofType(type).where((e) => !e.deleted);

  /// Applies a valid change; returns the entry, the previous values of the fields it set, whether
  /// it created the record, and which of those fields had never been set before.
  (Entry, Map<String, Object?>, bool, Set<String>) apply(Change c) {
    final key = _key(c.space, c.type, c.rid);
    var entry = _byKey[key];
    final creating = entry == null;
    if (entry == null) {
      entry = Entry(c.type, c.rid, c.space, c.hlc, c.actor, c.device);
      _byKey[key] = entry;
      ((_byType[c.type] ??= {})[c.rid] ??= []).add(entry);
    }
    final before = <String, Object?>{};
    final absent = <String>{};
    for (final f in c.fields.entries) {
      final name = f.key;
      if (!entry.has(name)) absent.add(name);
      before[name] = entry.valueOf(name);
      final dot = name.indexOf('.');
      if (dot > 0 && !name.startsWith('_')) {
        final head = name.substring(0, dot);
        final current = entry.fields[head];
        final map = current is Map ? Map<String, Object?>.from(current) : <String, Object?>{};
        map[name.substring(dot + 1)] = copyJson(f.value);
        entry.fields[head] = map;
      } else {
        entry.fields[name] = copyJson(f.value);
        entry.times.removeWhere((k, _) => k.startsWith('$name.'));
      }
      entry.times[name] = c.hlc;
    }
    entry.updated = c.hlc;
    entry.updatedBy = c.actor;
    entry._rec = null;
    version++;
    return (entry, before, creating, absent);
  }

  void clear() {
    _byKey.clear();
    _byType.clear();
    version++;
  }
}
