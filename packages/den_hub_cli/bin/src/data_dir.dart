import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_core/storage_io.dart';
import 'package:den_hub/den_hub.dart';

/// The hub's data directory: `keys.json` (device keys, owner-only), `log/` (the change log),
/// `hub/` (the hub's own state), `notify.json` (reminder targets, optional) and `hub.lock`
/// (held while a process uses it).
class DataDir {
  /// Wraps the directory at [path].
  DataDir(this.path);

  /// The directory.
  final String path;

  RandomAccessFile? _lock;

  /// Lock files this process holds. POSIX file locks belong to the process, so on Linux and
  /// macOS a second [lock] from the same process would succeed, and closing it would release the
  /// first; Windows locks per handle. This keeps both the same.
  static final _held = <String>{};

  String get _lockPath => File(_join('hub.lock')).absolute.path;

  String _join(String name) => '$path${Platform.pathSeparator}$name';

  /// `keys.json`.
  File get keysFile => File(_join('keys.json'));

  /// The change log's directory.
  String get logDir => _join('log');

  /// Takes the lock, or throws [StateError] when another process holds it.
  Future<void> lock() async {
    final busy = StateError('Another den_hub is using $path. Stop it first.');
    if (_held.contains(_lockPath)) throw busy;
    await Directory(path).create(recursive: true);
    final file = await File(_lockPath).open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      throw busy;
    }
    _held.add(_lockPath);
    _lock = file;
  }

  /// Releases the lock.
  Future<void> unlock() async {
    final file = _lock;
    _lock = null;
    if (file == null) return;
    _held.remove(_lockPath);
    await file.unlock();
    await file.close();
  }

  /// The device keys, made and saved (owner-only) on first use.
  Future<DeviceKeys> keys() async {
    final file = keysFile;
    if (await file.exists()) {
      return DeviceKeys.fromJson((jsonDecode(await file.readAsString()) as Map).cast<String, Object?>());
    }
    final keys = await DeviceKeys.generate();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(await keys.toJson()), flush: true);
    restrictToOwner(file.path);
    return keys;
  }

  /// Opens the hub's engine over `log/` with [keys].
  Future<Den> open() async => Den.open(storage: FileStorage(logDir), keys: await keys());

  /// Whether the directory holds a hub already.
  bool get exists => keysFile.existsSync();

  /// Whether [relative] is a path a backup may hold: `keys.json`, `notify.json`, or a file
  /// directly in `log/` or `hub/`. A restore writes nothing else.
  static bool backupPath(String relative) => RegExp(r'^(keys\.json|notify\.json|(log|hub)/[A-Za-z0-9._-]+)$').hasMatch(relative) &&
      !relative.contains('..');

  /// Everything a backup holds, relative to [path]: keys, `notify.json`, the change log and the
  /// hub's own state (OAuth clients and refresh tokens, the capture reader, feeds, reminders
  /// sent). Read so the copy is consistent even while a hub runs and writes, without its lock:
  /// the log's metadata before the log (what the metadata says the hub holds, the log copied
  /// after it holds too), the log cut after its last complete line (a change being appended
  /// right now waits for the next backup), and every other file whole, since each is replaced
  /// by renaming a finished file over it.
  Future<Map<String, List<int>>> readBackup() async {
    final out = <String, List<int>>{};
    Future<void> whole(String relative) async {
      final f = file(relative);
      if (await f.exists()) out[relative] = await f.readAsBytes();
    }

    await whole('keys.json');
    await whole('notify.json');
    final log = Directory(logDir);
    if (await log.exists()) {
      await whole('log/meta.json');
      if (!out.containsKey('log/meta.json')) await whole('log/meta.json.tmp');
      for (final f in await _filesIn(log)) {
        final name = f.uri.pathSegments.last;
        if (name.startsWith('meta.json') || name.endsWith('.tmp')) continue;
        final bytes = await f.readAsBytes();
        out['log/$name'] = name.endsWith('.jsonl') ? bytes.sublist(0, bytes.lastIndexOf(0x0a) + 1) : bytes;
      }
    }
    final hub = Directory(_join('hub'));
    if (await hub.exists()) {
      for (final f in await _filesIn(hub)) {
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.tmp') || name == 'setup-code' || name == linkOpenFile) continue;
        out['hub/$name'] = await f.readAsBytes();
      }
    }
    return out;
  }

  static Future<List<File>> _filesIn(Directory dir) async {
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File) files.add(e);
    }
    return files..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Removes what a restore replaces (keys, `notify.json`, the change log and the hub's own
  /// state), so nothing of the hub that was here mixes with the one restored.
  Future<void> clearForRestore() async {
    for (final name in ['keys.json', 'notify.json']) {
      final f = File(_join(name));
      if (await f.exists()) await f.delete();
    }
    for (final sub in ['log', 'hub']) {
      final d = Directory(_join(sub));
      if (await d.exists()) await d.delete(recursive: true);
    }
  }

  /// The file at [relative] (forward slashes).
  File file(String relative) => File(_join(relative.split('/').join(Platform.pathSeparator)));
}
