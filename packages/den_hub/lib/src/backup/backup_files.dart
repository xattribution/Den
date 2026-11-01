/// What a family's backup holds, read from and written back to its data directory: the device
/// keys, the change log, the hub's own state (`hub/`) and `notify.json`. Used by the hub's own
/// nightly backups and the first-boot restore, and by `den_hub backup` and `restore`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_core/storage_io.dart';

import '../host_state.dart' show HostState;
import '../recovery.dart' show recoveryCliFile, recoveryTicketsDoc;
import '../setup.dart' show linkOpenFile, restrictToOwner;
import '../state.dart' show restoreMarkerDoc;
import 'sealed_backup.dart';

/// The file in `hub/` that holds the Cloudflare tunnel's token ([TunnelConnector]).
const String tunnelTokenFile = 'tunnel-token';

/// The file in `hub/` that says where backups go (and the NAS's sign-in), owner-only.
const String backupSettingsFile = 'backup-settings.json';

/// The file in `hub/` that says how the last backups went.
const String backupStatusFile = 'backup-status.json';

/// The file in `hub/` with the family's address as the server learned it at first boot
/// (`https://den.example.com`), for a server whose `DEN_PUBLIC_URL` isn't set.
const String addressFile = 'address';

/// What in `hub/` belongs to this server rather than to the family: how it reaches the internet
/// and where its backups go. Never in a backup, and kept as it is through a restore, so a family
/// restored onto a new server keeps that server's connection and backup place.
const Set<String> serverFiles = {tunnelTokenFile, backupSettingsFile, backupStatusFile};

String _join(String dir, String relative) => [dir, ...relative.split('/')].join(Platform.pathSeparator);

/// Whether [relative] is a path a backup may hold: `keys.json`, `notify.json`, or a file directly
/// in `log/` or `hub/`. A restore writes nothing else.
bool backupPath(String relative) =>
    RegExp(r'^(keys\.json|notify\.json|(log|hub)/[A-Za-z0-9._-]+)$').hasMatch(relative) && !relative.contains('..');

Future<List<File>> _filesIn(Directory dir) async {
  final files = <File>[];
  await for (final e in dir.list()) {
    if (e is File) files.add(e);
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

/// Everything a backup of the data directory [dir] holds, relative to it: keys, `notify.json`,
/// the change log and the hub's own state (OAuth clients and refresh tokens, the capture reader,
/// feeds, reminders sent, the server recovery key). Read so the copy is consistent even while a
/// hub runs and writes, without its lock: the log's metadata before the log (what the metadata
/// says the hub holds, the log copied after it holds too), the log cut after its last complete
/// line (a change being appended right now waits for the next backup), and every other file
/// whole, since each is replaced by renaming a finished file over it. Left out: what lasts
/// minutes or is made again at start, and [serverFiles].
Future<Map<String, List<int>>> readBackupFiles(String dir) async {
  final out = <String, List<int>>{};
  Future<void> whole(String relative) async {
    final f = File(_join(dir, relative));
    if (await f.exists()) out[relative] = await f.readAsBytes();
  }

  await whole('keys.json');
  await whole('notify.json');
  final log = Directory(_join(dir, 'log'));
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
  final hub = Directory(_join(dir, 'hub'));
  if (await hub.exists()) {
    for (final f in await _filesIn(hub)) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.tmp') ||
          name == 'setup-code' ||
          name == linkOpenFile ||
          name == recoveryCliFile ||
          name == '$recoveryTicketsDoc.json' ||
          serverFiles.contains(name)) {
        continue;
      }
      out['hub/$name'] = await f.readAsBytes();
    }
  }
  return out;
}

/// Writes [files] (a backup's, or another hub's being adopted) into [dir], relative paths with
/// forward slashes, keeping only what [backupPath] allows; keys and the hub's state owner-only
/// from the start. Returns how many it wrote.
Future<int> writeBackupFiles(String dir, Map<String, List<int>> files) async {
  await Directory(dir).create(recursive: true);
  var written = 0;
  for (final e in files.entries) {
    if (!backupPath(e.key)) continue;
    final f = File(_join(dir, e.key));
    await f.parent.create(recursive: true);
    if (e.key == 'keys.json' || e.key.startsWith('hub/')) {
      // An empty temporary file made 0600 before anything secret goes in, then renamed over the
      // old one, so the keys and the hub's secrets are never readable by others.
      final temp = File('${f.path}.restore.tmp');
      if (await temp.exists()) await temp.delete();
      await temp.create(exclusive: true);
      restrictToOwner(temp.path);
      await temp.writeAsBytes(e.value, flush: true);
      await temp.rename(f.path);
    } else {
      await f.writeAsBytes(e.value, flush: true);
    }
    written++;
  }
  return written;
}

/// Removes what a restore replaces in [dir] (keys, `notify.json`, the change log and the hub's
/// own state), so nothing of the hub that was there mixes with the one restored.
Future<void> clearForRestore(String dir) async {
  for (final name in ['keys.json', 'notify.json']) {
    final f = File(_join(dir, name));
    if (await f.exists()) await f.delete();
  }
  for (final sub in ['log', 'hub']) {
    final d = Directory(_join(dir, sub));
    if (await d.exists()) await d.delete(recursive: true);
  }
}

/// Puts the family in [files] (a backup's) into [dir] in place of what is there, and leaves the
/// restore marker, so the hub writes nothing of its own until a device of the family has synced.
/// What belongs to this server ([serverFiles]) stays as it was, and so does the address it
/// learned at first boot, when it learned one: the server keeps its connection, its backup place
/// and the address it reaches the internet at. [from] names the backup in the marker. Returns
/// how many files it wrote.
Future<int> restoreBackupFiles(String dir, Map<String, List<int>> files, {required String from, required int now}) async {
  final kept = <String, List<int>>{};
  for (final name in [...serverFiles, addressFile]) {
    final f = File(_join(dir, 'hub/$name'));
    if (await f.exists()) kept['hub/$name'] = await f.readAsBytes();
  }
  await clearForRestore(dir);
  final written = await writeBackupFiles(dir, {
    for (final e in files.entries)
      if (!serverFiles.contains(e.key.replaceFirst('hub/', ''))) e.key: e.value,
  });
  await writeBackupFiles(dir, kept);
  final marker = File(_join(dir, 'hub/$restoreMarkerDoc.json'));
  HostState.ownerOnlyDir(marker.parent);
  await marker.writeAsString(jsonEncode({'at': now, 'from': from}), flush: true);
  restrictToOwner(marker.path);
  return written;
}

/// The plaintext of a backup: `{v: 1, kind: den_hub, files: {path: base64}}`.
List<int> backupPlaintext(Map<String, List<int>> files) => utf8.encode(jsonEncode({
      'v': 1,
      'kind': 'den_hub',
      'files': {for (final e in files.entries) e.key: base64.encode(e.value)},
    }));

/// The files in a backup's plaintext; throws [FormatException] when it isn't a hub's backup.
Map<String, List<int>> backupFilesOf(List<int> plaintext) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(plaintext));
  } on FormatException {
    throw const FormatException('That isn\'t a den_hub backup.');
  }
  if (json is! Map || json['kind'] != 'den_hub' || json['files'] is! Map) {
    throw const FormatException('That isn\'t a den_hub backup.');
  }
  return {
    for (final e in (json['files'] as Map).entries)
      if (e.key is String && e.value is String) e.key as String: base64.decode(e.value as String),
  };
}

/// Who can open a backup of [files] and whose it is: the family's parents with recovery words,
/// its name and id, read from the backup's own copy of the log (opened in a temporary directory,
/// so a hub running on the data directory is never disturbed).
Future<({List<BackupRecipient> to, String? familyName, String? familyId})> backupAbout(Map<String, List<int>> files) async {
  final keys = files['keys.json'];
  if (keys == null) return (to: const <BackupRecipient>[], familyName: null, familyId: null);
  final temp = await Directory.systemTemp.createTemp('den_backup_');
  try {
    HostState.ownerOnlyDir(temp);
    await writeBackupFiles(temp.path, {for (final e in files.entries) if (e.key.startsWith('log/')) e.key: e.value});
    final den = await Den.open(
      storage: FileStorage(_join(temp.path, 'log')),
      keys: await DeviceKeys.fromJson((jsonDecode(utf8.decode(keys)) as Map).cast<String, Object?>()),
    );
    try {
      return (to: backupRecipientsOf(den), familyName: den.family?.name, familyId: den.familyId);
    } finally {
      await den.close();
    }
  } finally {
    await temp.delete(recursive: true);
  }
}
