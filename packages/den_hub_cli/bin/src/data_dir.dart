import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_core/storage_io.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/den_hub.dart' as backup_files show backupPath, clearForRestore;

/// The hub's data directory: `keys.json` (device keys, owner-only), `log/` (the change log),
/// `hub/` (the hub's own state, with what the app set up on the hub: the reader's and the AI
/// helper's keys, signing in with Google and Apple), `notify.json` (reminder targets older hubs
/// read; nothing reads it now, but backups keep it so an old backup restores whole) and
/// `hub.lock` (held while a process uses it).
///
/// On a Den host this is the first family's, unchanged, and it also holds `logs/<id>/`, each
/// other family's data directory in the same layout ([log]), and `host/`, the host's own state
/// (which logs it serves at which addresses, every Web Push key). A family's backup holds only
/// its own directory's files.
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

  /// The data directory of the host's log [id]: `logs/<id>/`.
  DataDir log(String id) => DataDir(_join('$hostLogsDir${Platform.pathSeparator}$id'));

  /// Writes [files] (a backup's, or another hub's being adopted), relative paths with forward
  /// slashes, keeping only what [backupPath] allows; keys and the hub's state owner-only.
  /// Returns how many it wrote.
  Future<int> writeFiles(Map<String, List<int>> files) => writeBackupFiles(path, files);

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

  /// Whether [relative] is a path a backup may hold ([backupPath]).
  static bool backupPath(String relative) => backup_files.backupPath(relative);

  /// Everything a backup holds, relative to [path] ([readBackupFiles]): consistent even while a
  /// hub runs and writes, without its lock.
  Future<Map<String, List<int>>> readBackup() => readBackupFiles(path);

  /// Removes what a restore replaces ([clearForRestore]).
  Future<void> clearForRestore() => backup_files.clearForRestore(path);

  /// The file at [relative] (forward slashes).
  File file(String relative) => File(_join(relative.split('/').join(Platform.pathSeparator)));
}
