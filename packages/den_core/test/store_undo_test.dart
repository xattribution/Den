import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/store.dart';
import 'package:test/test.dart';

/// How a record merged before undo existed: every field write, entry writes of map fields, and
/// whole writes clearing the entries' times.
class NaiveRecord {
  final Map<String, Object?> fields = {};
  final Map<String, Hlc> times = {};

  void apply(Change c) {
    for (final f in c.fields.entries) {
      final name = f.key;
      final dot = name.indexOf('.');
      if (dot > 0 && !name.startsWith('_')) {
        final head = name.substring(0, dot);
        final current = fields[head];
        final map = current is Map ? Map<String, Object?>.from(current) : <String, Object?>{};
        map[name.substring(dot + 1)] = copyJson(f.value);
        fields[head] = map;
      } else {
        fields[name] = copyJson(f.value);
        times.removeWhere((k, _) => k.startsWith('$name.'));
      }
      times[name] = c.hlc;
    }
  }
}

String show(Map<String, Object?> fields, Map<String, Hlc> times, Hlc updated, String? updatedBy) =>
    canonicalJson({'fields': fields, 'times': {for (final t in times.entries) t.key: '${t.value}'}, 'updated': '$updated', 'by': updatedBy});

void main() {
  test('applying merges as before, and undoing restores exactly what was there', () {
    final random = Random(5);
    const names = ['steps', 'patch', 'title', '_from', '_x', 'done'];
    for (var trial = 0; trial < 300; trial++) {
      final store = RecordStore();
      final naive = NaiveRecord();
      final undos = <(Undo, String)>[];
      for (var i = 0; i < 12; i++) {
        final fields = <String, Object?>{};
        for (var k = 0; k < 1 + random.nextInt(3); k++) {
          final name = names[random.nextInt(names.length)];
          switch (random.nextInt(4)) {
            case 0:
              fields['$name.${'abc'[random.nextInt(3)]}'] = random.nextBool() ? null : random.nextInt(9);
            case 1:
              fields[name] = {'a': random.nextInt(9), if (random.nextBool()) 'b': [random.nextInt(9)]};
            case 2:
              fields[name] = random.nextBool() ? null : 'v${random.nextInt(9)}';
            default:
              fields['$name.${'ab'[random.nextInt(2)]}'] = {'deep': random.nextInt(9)};
          }
        }
        final c = Change(
          id: 'd:${i + 1}',
          space: Space.family,
          hlc: Hlc(1000 + i, 0, 'd'),
          type: RecordType.category,
          rid: 'r',
          fields: fields,
          device: 'd',
          actor: random.nextBool() ? 'm${random.nextInt(3)}' : null,
          sig: '',
        );
        final before = store.at(Space.family, RecordType.category, 'r');
        final was = before == null ? null : show(before.fields, before.times, before.updated, before.updatedBy);
        final (entry, _, created, _, undo) = store.apply(c);
        naive.apply(c);
        expect(created, before == null);
        expect(show(entry.fields, entry.times, entry.updated, entry.updatedBy), show(naive.fields, naive.times, c.hlc, c.actor),
            reason: 'trial $trial, change $i: $fields');
        undos.add((undo, was ?? ''));
      }
      // Newest first, each undo leaves the record as it was before that change.
      for (final (undo, was) in undos.reversed) {
        store.undo(undo);
        final e = store.at(Space.family, RecordType.category, 'r');
        if (undo.created) {
          expect(e, isNull);
        } else {
          expect(show(e!.fields, e.times, e.updated, e.updatedBy), was, reason: 'trial $trial');
        }
      }
    }
  });
}
