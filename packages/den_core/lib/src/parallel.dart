import 'dart:async';
import 'dart:typed_data';

import 'change.dart';
import 'parallel_web.dart' if (dart.library.io) 'parallel_io.dart' as platform;
import 'snapshot.dart';

/// What [checkChanges] reports for a change whose signature it didn't check.
final Uint8List unhashed = Uint8List(0);

/// Checks changes off the critical path: each one's signature against its author's key (when
/// [verify]) and its digest hash (when [hash]). Returns, in order, the hash ([unhashed] when not
/// hashing) for each change that passes, or null for one whose signature fails or whose author's
/// key in [pubkeys] is null.
///
/// On platforms with isolates, larger batches are split across worker isolates, so the calling
/// isolate (the app's UI thread) only waits. Elsewhere (browsers) the work runs in slices that
/// yield to the event loop between them, so frames keep being drawn; a browser's Web Crypto
/// checks a slice's signatures concurrently.
Future<List<Uint8List?>> checkChanges(
  List<Change> changes, {
  List<String?>? pubkeys,
  bool verify = true,
  bool hash = true,
}) async {
  if (changes.isEmpty) return const [];
  final keys = verify ? pubkeys! : List<String?>.filled(changes.length, null);
  final job = _Job(changes, keys, verify, hash);
  final workers = platform.workers;
  final big = verify ? changes.length >= 4 : changes.length >= 2000;
  if (workers > 1 && big) {
    final parts = workers < changes.length ? workers : changes.length;
    final size = (changes.length + parts - 1) ~/ parts;
    try {
      final results = await Future.wait([
        for (var start = 0; start < changes.length; start += size)
          _inWorker(job.slice(start, start + size > changes.length ? changes.length : start + size)),
      ]);
      return [for (final r in results) ...r];
    } on Object {
      // A worker that couldn't start or take the batch: check it here instead.
    }
  }
  final out = <Uint8List?>[];
  final step = verify ? 16 : 100;
  for (var start = 0; start < changes.length; start += step) {
    final end = start + step > changes.length ? changes.length : start + step;
    out.addAll(await job.slice(start, end).runAll(concurrent: true));
    if (end < changes.length) await Future<void>.delayed(Duration.zero);
  }
  return out;
}

/// Sends only [part] to the worker, not whatever else a closure here would capture.
Future<List<Uint8List?>> _inWorker(_Job part) => platform.run(part.runAll);

class _Job {
  _Job(this.changes, this.keys, this.verify, this.hash);
  final List<Change> changes;
  final List<String?> keys;
  final bool verify;
  final bool hash;

  _Job slice(int start, int end) => _Job(changes.sublist(start, end), keys.sublist(start, end), verify, hash);

  Future<List<Uint8List?>> runAll({bool concurrent = false}) async {
    if (concurrent) return Future.wait([for (var i = 0; i < changes.length; i++) one(i)]);
    return [for (var i = 0; i < changes.length; i++) await one(i)];
  }

  Future<Uint8List?> one(int i) async {
    final c = changes[i];
    final bytes = c.signedBytes;
    if (verify) {
      final key = keys[i];
      if (key == null || !await verifySignature(bytes, c.sig, key)) return null;
    }
    return hash ? changeHash(c, bytes) : unhashed;
  }
}
