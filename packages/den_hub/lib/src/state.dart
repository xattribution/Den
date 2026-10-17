import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Small JSON documents the hub keeps for itself: reminders already sent, OAuth clients and
/// refresh-token hashes, calendar feed caches. Each lives in `<dataDir>/hub/<name>.json`, written
/// to a temporary file and renamed over the old one. Without a directory they live in memory.
class HubState {
  /// Opens the state under [dataDir] (null: memory only).
  HubState(String? dataDir)
      : _dir = dataDir == null ? null : Directory('$dataDir${Platform.pathSeparator}hub');

  final Directory? _dir;
  final Map<String, Map<String, Object?>> _docs = {};
  Future<void> _tail = Future.value();

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
    final run = _tail.then((_) async {
      await dir.create(recursive: true);
      final file = _file(name);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    });
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// Waits for pending writes.
  Future<void> flush() => _tail;
}
