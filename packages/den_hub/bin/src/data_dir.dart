import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_core/storage_io.dart';
import 'package:den_hub/den_hub.dart';

/// The hub's data directory: `keys.json` (device keys, owner-only), `log/` (the change log),
/// `hub/` (the hub's own state) and `hub.lock` (held while a process uses it).
class DataDir {
  /// Wraps the directory at [path].
  DataDir(this.path);

  /// The directory.
  final String path;

  RandomAccessFile? _lock;

  String _join(String name) => '$path${Platform.pathSeparator}$name';

  /// `keys.json`.
  File get keysFile => File(_join('keys.json'));

  /// The change log's directory.
  String get logDir => _join('log');

  /// Takes the lock, or throws [StateError] when another process holds it.
  Future<void> lock() async {
    await Directory(path).create(recursive: true);
    final file = await File(_join('hub.lock')).open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      throw StateError('Another den_hub is using $path. Stop it first.');
    }
    _lock = file;
  }

  /// Releases the lock.
  Future<void> unlock() async {
    final file = _lock;
    _lock = null;
    if (file == null) return;
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

  /// Every file a backup holds, relative to [path].
  List<String> backupFiles() {
    final out = <String>[];
    if (keysFile.existsSync()) out.add('keys.json');
    for (final sub in ['log', 'hub']) {
      final dir = Directory(_join(sub));
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.tmp') || name == 'setup-code') continue;
        out.add('$sub/$name');
      }
    }
    return out;
  }

  /// The file at [relative] (forward slashes).
  File file(String relative) => File(_join(relative.split('/').join(Platform.pathSeparator)));
}
