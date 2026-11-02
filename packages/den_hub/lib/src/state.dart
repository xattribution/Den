import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The hub's state document that says it was restored from a backup and hasn't caught up yet
/// (`<dataDir>/hub/restored.json`, written by `den_hub restore`). While it is there the hub
/// writes nothing of its own to the family's log; see [HubState.restored].
const String restoreMarkerDoc = 'restored';

/// Small JSON documents the hub keeps for itself: reminders already sent, OAuth clients and
/// token hashes, calendar feed caches. Each lives in `<dataDir>/hub/<name>.json`, written to a
/// temporary file and renamed over the old one, in a directory only its owner can enter.
/// Without a directory they live in memory.
class HubState {
  /// Opens the state under [dataDir] (null: memory only).
  HubState(String? dataDir)
      : _dir = dataDir == null ? null : Directory('$dataDir${Platform.pathSeparator}hub');

  final Directory? _dir;
  final Map<String, Map<String, Object?>> _docs = {};
  Future<void> _tail = Future.value();
  bool _private = false;

  File _file(String name) => File('${_dir!.path}${Platform.pathSeparator}$name.json');

  /// The document [name], loaded on first use; empty when absent or unreadable.
  Map<String, Object?> read(String name) {
    final cached = _docs[name];
    if (cached != null) return cached;
    Map<String, Object?> doc = {};
    if (_dir != null) {
      final file = _file(name);
      try {
        if (file.existsSync()) {
          final json = jsonDecode(file.readAsStringSync());
          if (json is Map) doc = json.cast<String, Object?>();
        }
      } on Object {
        doc = {};
      }
    }
    return _docs[name] = doc;
  }

  /// Saves document [name] (after changing what [read] returned, or replacing it).
  Future<void> save(String name, [Map<String, Object?>? doc]) {
    if (doc != null) _docs[name] = doc;
    final dir = _dir;
    if (dir == null) return Future.value();
    final text = jsonEncode(_docs[name] ?? const {});
    return _queue(() async {
      await _ensureDir(dir);
      final file = _file(name);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    });
  }

  /// Removes document [name], file and all.
  Future<void> delete(String name) {
    _docs[name] = {};
    final dir = _dir;
    if (dir == null) return Future.value();
    return _queue(() async {
      final file = _file(name);
      if (await file.exists()) await file.delete();
    });
  }

  /// Whether `den_hub restore` left its marker and no device has synced since: the hub then
  /// writes nothing of its own (see `HubContext.catchingUp`).
  bool get restored => read(restoreMarkerDoc).isNotEmpty;

  Future<void> _queue(Future<void> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// Creates the directory, and makes it its owner's alone once per process: what is in it
  /// (token hashes, provider keys, the server recovery key) stays private whatever each file's
  /// own mode is.
  Future<void> _ensureDir(Directory dir) async {
    await dir.create(recursive: true);
    if (_private) return;
    _private = true;
    try {
      if (!Platform.isWindows) await Process.run('chmod', ['700', dir.path]);
    } on Object {
      // Best effort, like the files' own modes.
    }
  }

  /// Waits for pending writes.
  Future<void> flush() => _tail;
}
