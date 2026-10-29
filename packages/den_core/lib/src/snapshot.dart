import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import 'change.dart';
import 'hlc.dart';
import 'materializer.dart';
import 'store.dart';
import 'validity.dart';

/// The snapshot format this engine writes and reads. A snapshot records what validation and
/// merging made of the log, so bump this whenever either changes (the rules in validity.dart,
/// how [RecordStore.apply] merges fields, the verbs and titles History shows): snapshots in any
/// other format are discarded and the log is replayed from scratch.
const int snapshotFormat = 1;

/// The digest hash of one change: SHA-256 over the bytes its author signed and the signature.
Uint8List changeHash(Change c, [List<int>? signedBytes]) {
  final sink = const DartSha256().newHashSink()
    ..add(signedBytes ?? c.signedBytes)
    ..add(const [0])
    ..add(utf8.encode(c.sig))
    ..close();
  return Uint8List.fromList(sink.hashSync().bytes);
}

/// What a snapshot's digest is: SHA-256 over the [changeHash]es of the changes it covers, in log
/// order. Stored changes that no longer give the same digest aren't what the snapshot saw.
Uint8List digestOf(Iterable<List<int>> hashes) {
  final sink = const DartSha256().newHashSink();
  for (final h in hashes) {
    sink.add(h);
  }
  sink.close();
  return Uint8List.fromList(sink.hashSync().bytes);
}

/// The state [Materializer.capture] copied out, ready to encode.
class SnapshotCapture {
  SnapshotCapture({
    required this.familyId,
    required this.founderPubkey,
    required this.log,
    required this.digest,
    required this.cutoffs,
    required this.newest,
    required this.windowStart,
    required this.records,
    required this.rejected,
    required this.window,
    required this.family,
    required this.history,
    required this.historyText,
    required this.historyMore,
  });

  final String? familyId;
  final String? founderPubkey;

  /// The changes it covers, in log order.
  final List<Change> log;
  final List<int> digest;
  final Map<String, List<Cutoff>> cutoffs;
  final Hlc? newest;
  final int windowStart;

  /// `[type, id, space, created, createdBy, createdDevice, updated, updatedBy, fields, times]`.
  final List<List<Object?>> records;
  final Map<String, String> rejected;

  /// From [windowStart] on: each change with its [Undo] (or the rejected marker) and, when it
  /// counted, how it was applied.
  final List<(Change, Object, Applied?)> window;

  /// The valid changes to the family record before [windowStart], kept with the state so they
  /// can be read without the history.
  final List<Applied> family;

  /// How the valid changes before [windowStart] were applied; null when they are still in
  /// [historyText], a previous snapshot's history not yet read, followed by [historyMore].
  final List<Applied>? history;
  final String? historyText;
  final List<Applied> historyMore;

  /// The first change of the window, or the last change when the window is empty: an uncovered
  /// change ordered before it makes the next open replay from scratch.
  Change? get boundary => windowStart < log.length ? log[windowStart] : (log.isEmpty ? null : log.last);

  /// The snapshot as text: a header line, the state, and the history, which [SnapshotHeader]
  /// reads only when asked. Yields to the event loop between slices so a browser keeps drawing.
  Future<String> encode({Future<void> Function()? breathe}) async {
    final pause = breathe ?? () => Future<void>.delayed(Duration.zero);
    final out = StringBuffer();
    final cover = <String, List<int>>{};
    final other = <String>[];
    for (final c in log) {
      final colon = c.id.lastIndexOf(':');
      final n = colon > 0 ? int.tryParse(c.id.substring(colon + 1)) : null;
      if (n == null) {
        other.add(c.id);
      } else {
        (cover[c.id.substring(0, colon)] ??= []).add(n);
      }
    }
    out.write(jsonEncode({
      'v': snapshotFormat,
      'family': familyId,
      'founder': founderPubkey,
      'n': log.length,
      'cover': {for (final e in cover.entries) e.key: _ranges(e.value)},
      'other': other,
      'digest': b64e(digest),
      'w': windowStart,
      'first': windowStart < log.length ? log[windowStart].id : null,
    }));
    out
      ..write('\n')
      ..write('{"newest":')
      ..write(jsonEncode(newest?.toString()))
      ..write(',"cutoffs":')
      ..write(jsonEncode({
        for (final e in cutoffs.entries) e.key: [for (final k in e.value) [k.after, k.at.toString()]],
      }))
      ..write(',"rejected":')
      ..write(jsonEncode(rejected))
      ..write(',"records":[');
    // Clocks as [millis, counter, device], devices by their place in a table; a record's field
    // times grouped by the change that set them, most often the one that made it or the last.
    final devices = <String, int>{};
    List<int> clock(Hlc h) => [h.millis, h.counter, devices.putIfAbsent(h.device, () => devices.length)];
    for (var i = 0; i < records.length; i++) {
      if (i > 0) out.write(',');
      final r = records[i];
      final created = r[3] as Hlc, updated = r[6] as Hlc;
      final groups = <Object, List<Object?>>{};
      for (final t in (r[9] as Map<String, Hlc>).entries) {
        final h = t.value;
        final ref = h == created ? 0 : (h == updated ? 1 : h.toString());
        (groups[ref] ??= [ref == 0 || ref == 1 ? ref : clock(h)]).add(t.key);
      }
      out.write(jsonEncode([
        r[0], r[1], r[2], ...clock(created), r[4], ...clock(updated), r[7], r[8], groups.values.toList(),
        if (r[5] != created.device) r[5],
      ]));
      if (i % 500 == 499) await pause();
    }
    out
      ..write('],"devices":')
      ..write(jsonEncode(devices.keys.toList()))
      ..write(',"family":')
      ..write(jsonEncode([for (final a in family) _appliedRow(a)]));
    out.write(',"window":[');
    for (var i = 0; i < window.length; i++) {
      if (i > 0) out.write(',');
      final (change, step, applied) = window[i];
      out.write(jsonEncode(_windowRow(change, step, applied)));
      if (i % 500 == 499) await pause();
    }
    out
      ..write(']}')
      ..write('\n')
      ..write('[');
    var first = true;
    final kept = historyText;
    if (kept != null) {
      final inner = kept.trim();
      if (inner.length > 2) {
        out.write(inner.substring(1, inner.length - 1));
        first = false;
      }
    }
    final rows = history ?? historyMore;
    for (var i = 0; i < rows.length; i++) {
      if (!first) out.write(',');
      first = false;
      out.write(jsonEncode(_appliedRow(rows[i])));
      if (i % 1000 == 999) await pause();
    }
    out.write(']');
    return out.toString();
  }

  /// Sorted counters as `[from, to, from, to, ...]`, both ends included.
  static List<int> _ranges(List<int> counters) {
    counters.sort();
    final out = <int>[];
    for (final n in counters) {
      if (out.isNotEmpty && out.last == n - 1) {
        out.last = n;
      } else if (out.isEmpty || out.last != n) {
        out
          ..add(n)
          ..add(n);
      }
    }
    return out;
  }

  static List<Object?> _appliedRow(Applied a) {
    final c = a.change;
    final plain = a.before.length == c.fields.length &&
        a.absent.length == c.fields.length &&
        a.before.values.every((v) => v == null);
    if (plain) return [c.id, a.created ? 1 : 0, a.verb, a.title];
    return [c.id, a.created ? 1 : 0, a.verb, a.title, a.before, a.absent.toList()];
  }

  static List<Object?> _windowRow(Change c, Object step, Applied? applied) {
    if (applied == null || step is! Undo) return [c.id];
    final row = _appliedRow(applied);
    if (step.created) return row;
    if (row.length == 4) row.addAll([applied.before, applied.absent.toList()]);
    final values = <Object?>[], gone = <int>[];
    for (var i = 0; i < step.fieldValues.length; i++) {
      final v = step.fieldValues[i];
      if (identical(v, absent)) {
        values.add(null);
        gone.add(i);
      } else {
        values.add(v);
      }
    }
    return [
      ...row,
      step.fieldNames,
      values,
      gone,
      step.timeNames,
      [for (final t in step.timeValues) identical(t, absent) ? null : (t as Hlc).toString()],
      step.updated.toString(),
      step.updatedBy,
    ];
  }
}

/// A stored snapshot's header, read on open: what it covers and its digest. The state and the
/// history are parsed only when the snapshot is used.
class SnapshotHeader {
  SnapshotHeader._(this._header, this._stateText, this.historyText, this._cover, this._other);

  final Map<String, Object?> _header;
  final String _stateText;

  /// The valid changes before the window, as encoded; read when History is first asked for.
  final String historyText;
  final Map<String, List<int>> _cover;
  final Set<String> _other;

  /// Reads [text], or returns null for anything this engine didn't write in [snapshotFormat].
  static SnapshotHeader? parse(String text) {
    try {
      final first = text.indexOf('\n');
      final second = first < 0 ? -1 : text.indexOf('\n', first + 1);
      if (second < 0) return null;
      final header = jsonDecode(text.substring(0, first));
      if (header is! Map || header['v'] != snapshotFormat) return null;
      final h = header.cast<String, Object?>();
      if (h['n'] is! int || h['w'] is! int || h['digest'] is! String) return null;
      final cover = <String, List<int>>{};
      for (final e in (h['cover']! as Map).entries) {
        cover[e.key as String] = (e.value as List).cast<int>();
      }
      final other = (h['other']! as List).cast<String>().toSet();
      return SnapshotHeader._(h, text.substring(first + 1, second), text.substring(second + 1), cover, other);
    } on Object {
      return null;
    }
  }

  String? get familyId => _header['family'] as String?;
  String? get founderPubkey => _header['founder'] as String?;

  /// How many changes it covers.
  int get count => _header['n']! as int;
  int get windowStart => _header['w']! as int;
  String? get windowFirst => _header['first'] as String?;
  Uint8List get digest => b64d(_header['digest']! as String);

  Map<String, Object?>? _state;

  /// The records, rejections, cutoffs and window, parsed on first use.
  Map<String, Object?> get state => _state ??= (jsonDecode(_stateText) as Map).cast<String, Object?>();

  /// Whether the change with [id] is one it covers.
  bool covers(String id) {
    final colon = id.lastIndexOf(':');
    final n = colon > 0 ? int.tryParse(id.substring(colon + 1)) : null;
    if (n == null) return _other.contains(id);
    final ranges = _cover[id.substring(0, colon)];
    if (ranges == null) return false;
    var lo = 0, hi = ranges.length ~/ 2;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ranges[mid * 2 + 1] < n) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < ranges.length ~/ 2 && ranges[lo * 2] <= n;
  }
}

/// How many changes past the stored snapshot make it due to be written again; a shorter log
/// replays quickly enough without one.
const int snapshotEvery = 256;

/// How far back a snapshot keeps what a late change needs to rewind to its place: a change older
/// than that, arriving after the snapshot was written, makes the next open replay the whole log
/// (and the snapshot is written again).
const Duration snapshotWindow = Duration(days: 30);

/// How long after [Den.open] the check of the stored log against its snapshot's digest waits, so
/// it doesn't compete with the first screens. Tests set it to zero.
Duration snapshotCheckDelay = const Duration(seconds: 2);

/// What tests can see of an engine's snapshot and replay work.
class EngineProbe {
  EngineProbe({required this.fullReplays, required this.openedFromSnapshot, required this.idle});

  /// Times the engine replayed its whole log from scratch since it opened.
  final int Function() fullReplays;

  /// Whether it opened from a stored snapshot rather than replaying the log.
  final bool Function() openedFromSnapshot;

  /// Waits for the work open left running (checking the stored log) and any snapshot being
  /// written.
  final Future<void> Function() idle;
}

/// Each open engine's [EngineProbe].
final Expando<EngineProbe> engineProbes = Expando('engine probes');
