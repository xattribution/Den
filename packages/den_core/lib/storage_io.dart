/// File storage for devices with a file system (not the browser).
library;

import 'dart:convert';
import 'dart:io';

import 'den_core.dart';

/// Keeps a device's change log as append-only JSON lines (`changes.jsonl`), its metadata as
/// `meta.json` and the engine's snapshot as `snapshot.json` in [directoryPath]. Appends are
/// flushed to disk before returning; metadata and the snapshot are written to a temporary file
/// and renamed over the old one, so a crash leaves either the old or the new version. A last line
/// cut short by a crash is dropped and trimmed on the next load.
class FileStorage implements DenStorage, SnapshotStorage {
  FileStorage(this.directoryPath);

  final String directoryPath;
  Future<void> _tail = Future.value();

  File get _log => File('$directoryPath${Platform.pathSeparator}changes.jsonl');
  File get _meta => File('$directoryPath${Platform.pathSeparator}meta.json');
  File get _metaTemp => File('$directoryPath${Platform.pathSeparator}meta.json.tmp');
  File get _snapshot => File('$directoryPath${Platform.pathSeparator}snapshot.json');
  File get _snapshotTemp => File('$directoryPath${Platform.pathSeparator}snapshot.json.tmp');

  Future<T> _locked<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _ensureDirectory() => Directory(directoryPath).create(recursive: true);

  @override
  Future<List<Change>> loadChanges() => _locked(() async {
        final file = _log;
        if (!await file.exists()) return <Change>[];
        final bytes = await file.readAsBytes();
        final cut = bytes.lastIndexOf(0x0a) + 1;
        final changes = <Change>[];
        for (final line in utf8.decode(bytes.sublist(0, cut), allowMalformed: true).split('\n')) {
          if (line.trim().isEmpty) continue;
          final change = _parse(line);
          if (change != null) changes.add(change);
        }
        if (cut < bytes.length) {
          final tail = _parse(utf8.decode(bytes.sublist(cut), allowMalformed: true));
          if (tail != null) {
            changes.add(tail);
            final raf = await file.open(mode: FileMode.append);
            try {
              await raf.writeString('\n');
              await raf.flush();
            } finally {
              await raf.close();
            }
          } else {
            await file.writeAsBytes(bytes.sublist(0, cut), flush: true);
          }
        }
        return changes;
      });

  static Change? _parse(String line) {
    try {
      final json = jsonDecode(line);
      return json is Map ? Change.fromJson(json.cast<String, Object?>()) : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> appendChanges(List<Change> changes) => _locked(() async {
        if (changes.isEmpty) return;
        await _ensureDirectory();
        final text = StringBuffer();
        for (final c in changes) {
          text
            ..write(jsonEncode(c.toJson()))
            ..write('\n');
        }
        final raf = await _log.open(mode: FileMode.append);
        try {
          await raf.writeString(text.toString());
          await raf.flush();
        } finally {
          await raf.close();
        }
      });

  @override
  Future<Map<String, Object?>?> loadMeta() => _locked(() async {
        for (final file in [_meta, _metaTemp]) {
          if (!await file.exists()) continue;
          try {
            final json = jsonDecode(await file.readAsString());
            if (json is Map) return json.cast<String, Object?>();
          } on FormatException {
            continue;
          }
        }
        return null;
      });

  @override
  Future<void> clear() => _locked(() async {
        for (final file in [_log, _meta, _metaTemp, _snapshot, _snapshotTemp]) {
          if (await file.exists()) await file.delete();
        }
      });

  @override
  Future<void> saveMeta(Map<String, Object?> meta) => _locked(() => _replace(_metaTemp, _meta, jsonEncode(meta)));

  @override
  Future<String?> loadSnapshot() => _locked(() async {
        final file = _snapshot;
        if (!await file.exists()) return null;
        try {
          return await file.readAsString();
        } on FileSystemException {
          return null;
        } on FormatException {
          return null;
        }
      });

  @override
  Future<void> saveSnapshot(String snapshot) => _locked(() => _replace(_snapshotTemp, _snapshot, snapshot));

  /// Writes [text] to [temp], flushes it, and renames it over [target].
  Future<void> _replace(File temp, File target, String text) async {
    await _ensureDirectory();
    final raf = await temp.open(mode: FileMode.write);
    try {
      await raf.writeString(text);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await temp.rename(target.path);
  }
}
