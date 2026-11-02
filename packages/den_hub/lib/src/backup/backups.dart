/// The server's own backups (docs/hub-api.md, "Backups"): every night, each family on the server
/// is backed up to the server's own disk (the newest 14 kept), sealed to its parents' recovery
/// words, and copied to a NAS's shared folder when a parent of the server's own family set one
/// up. Nothing to set up for the nightly copy on the disk; nothing kept in a file anyone edits.
///
/// What the parent set up, the NAS's password with it, is in the server's own family's data
/// (`hub/backup-settings.json`, owner-only, never in a backup, never in an answer or a log), and
/// how the last runs went in `hub/backup-status.json`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_actions/times.dart' show wallOf;

import '../host_state.dart' show HostState, normalizeHostname;
import '../hub.dart' show DenHub;
import '../log.dart';
import '../setup.dart' show restrictToOwner;
import 'backup_files.dart';
import 'nas_finder.dart';
import 'rclone.dart';
import 'sealed_backup.dart';

/// How many backups are kept, on the disk and on the NAS, when nobody says otherwise.
const int defaultBackupKeep = 14;

/// A backup's file name for [utcMillis]: `den-2026-10-28-0317.denbackup` (UTC), so names sort by
/// date.
String backupName(int utcMillis) {
  final t = DateTime.fromMillisecondsSinceEpoch(utcMillis, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return 'den-${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}${two(t.minute)}.denbackup';
}

/// When the backup named [name] ([backupName]) was made (UTC ms), or null for another name.
int? backupNameTime(String name) {
  final m = RegExp(r'^den-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})\.denbackup$').firstMatch(name);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i)!);
  return DateTime.utc(g(1), g(2), g(3), g(4), g(5)).millisecondsSinceEpoch;
}

/// Why the last backup didn't happen, or didn't reach the NAS.
class BackupProblem {
  /// [kind] at [at] (UTC ms); [place] when it was the NAS that failed (the copy on the disk is
  /// there).
  const BackupProblem({required this.kind, required this.at, this.place = false});

  /// `no_words` (no parent has saved recovery words, so nobody could open one), `disk` (the
  /// server couldn't write it), or a [PlaceProblem]'s name (`unreachable`, `login`, ...).
  final String kind;

  /// When.
  final int at;

  /// Whether the backup is on the disk and only the NAS's copy failed.
  final bool place;

  /// As kept and as answers say it.
  Map<String, Object?> toJson() => {'kind': kind, 'at': at, 'place': place};

  /// Reads [toJson]'s output.
  static BackupProblem? fromJson(Object? json) {
    if (json is! Map || json['kind'] is! String || json['at'] is! int) return null;
    return BackupProblem(kind: json['kind'] as String, at: json['at'] as int, place: json['place'] == true);
  }
}

/// How the server's backups stand.
class BackupStatus {
  /// The status.
  const BackupStatus({this.lastAt, this.lastSize, this.placeLastAt, this.attemptAt, this.problem});

  /// When the last backup was saved on the disk (UTC ms).
  final int? lastAt;

  /// Its size in bytes (the server's own family's).
  final int? lastSize;

  /// When one last reached the NAS.
  final int? placeLastAt;

  /// When the last try was, whether it worked or not.
  final int? attemptAt;

  /// What went wrong the last time, or null.
  final BackupProblem? problem;

  /// As the status file keeps it.
  Map<String, Object?> toJson() => {
        'last_at': ?lastAt,
        'last_size': ?lastSize,
        'place_last_at': ?placeLastAt,
        'attempt_at': ?attemptAt,
        if (problem != null) 'problem': problem!.toJson(),
      };

  /// Reads [toJson]'s output.
  static BackupStatus fromJson(Map<String, Object?> j) => BackupStatus(
        lastAt: j['last_at'] is int ? j['last_at'] as int : null,
        lastSize: j['last_size'] is int ? j['last_size'] as int : null,
        placeLastAt: j['place_last_at'] is int ? j['place_last_at'] as int : null,
        attemptAt: j['attempt_at'] is int ? j['attempt_at'] as int : null,
        problem: BackupProblem.fromJson(j['problem']),
      );
}

/// A backup on the server's disk or in the backup place.
class BackupEntry {
  /// [name], [size] bytes, made at [at] (UTC ms).
  const BackupEntry(this.name, this.size, this.at);

  /// The file's name.
  final String name;

  /// Its size.
  final int size;

  /// When it was made.
  final int at;

  /// As answers say it.
  Map<String, Object?> toJson() => {'name': name, 'size': size, 'at': at};
}

/// The server's backups: settings, the nightly run, and the backup place.
class HostBackups {
  /// Backups into [dir] (a directory on the server's disk; null keeps none, for hosts in memory),
  /// copied to a place with [rclone], NASes found by [finder]. [now] is the clock (tests move it).
  HostBackups({
    this.dir,
    Rclone rclone = const ProcessRclone(),
    this.finder = const MdnsNasFinder(),
    int Function()? now,
    this.checkEvery = const Duration(minutes: 15),
  })  : places = PlaceClient(rclone),
        _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  /// Where the backups go on the server's disk: one folder per family, the server's own family's
  /// at the top.
  final String? dir;

  /// The backup place, through rclone.
  final PlaceClient places;

  /// NASes on the network.
  final NasFinder finder;

  /// How often the nightly run looks whether it is due.
  final Duration checkEvery;

  final int Function() _now;
  DenHub? _own;
  List<DenHub> Function() _families = () => const [];
  HubLog? _log;
  Timer? _timer;
  Future<BackupStatus>? _running;
  int _startedAt = 0;

  /// The server's own family, while it is attached.
  DenHub? get own => _own;

  /// Whether a backup is running now.
  bool get running => _running != null;

  String? get _hubDir {
    final d = _own?.config.dataDir;
    return d == null ? null : [d, 'hub'].join(Platform.pathSeparator);
  }

  File? _file(String name) => _hubDir == null ? null : File([_hubDir!, name].join(Platform.pathSeparator));

  /// Starts with the server's own family [own], backing up each of [families] (the host's
  /// families, the own one among them).
  void attach(DenHub own, {required List<DenHub> Function() families, required HubLog log}) {
    _own = own;
    _families = families;
    _log = log;
    _startedAt = _now();
    _timer?.cancel();
    if (dir != null && own.config.dataDir != null) {
      _timer = Timer.periodic(checkEvery, (_) => unawaited(tick()));
    }
  }

  /// The server's own family stopped.
  void detach(DenHub own) {
    if (!identical(_own, own)) return;
    _own = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Stops the nightly run for good.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Map<String, Object?> _readJson(String name) {
    final f = _file(name);
    if (f == null || !f.existsSync()) return const {};
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map) return j.cast<String, Object?>();
    } on Object {
      _log?.warn('${f.path} can\'t be read; backups go on with what they had.');
    }
    return const {};
  }

  void _writeJson(String name, Map<String, Object?> doc) {
    final f = _file(name);
    if (f == null) return;
    HostState.ownerOnlyDir(f.parent);
    final temp = File('${f.path}.tmp');
    if (temp.existsSync()) temp.deleteSync();
    temp.createSync(exclusive: true);
    HostState.ownerOnlyFile(temp.path);
    temp.writeAsStringSync(jsonEncode(doc), flush: true);
    temp.renameSync(f.path);
  }

  /// How many backups are kept.
  int get keep {
    final k = _readJson(backupSettingsFile)['keep'];
    return k is int && k > 0 && k <= 365 ? k : defaultBackupKeep;
  }

  /// Where backups go besides the disk, with its password; null for the disk alone.
  BackupPlace? get place => BackupPlace.fromJson(_readJson(backupSettingsFile)['place']);

  /// Sets where backups go besides the disk ([place] null: the disk alone).
  void setPlace(BackupPlace? place) {
    final doc = {..._readJson(backupSettingsFile)}..remove('place');
    _writeJson(backupSettingsFile, {...doc, 'v': 1, 'place': ?place?.toJson()});
    if (place == null) {
      final s = status;
      if (s.problem?.place ?? false) _writeStatus(BackupStatus(lastAt: s.lastAt, lastSize: s.lastSize, attemptAt: s.attemptAt));
    }
  }

  /// How the backups stand.
  BackupStatus get status => BackupStatus.fromJson(_readJson(backupStatusFile));

  void _writeStatus(BackupStatus s) => _writeJson(backupStatusFile, s.toJson());

  /// When the nightly run will look next: the coming night between 2 and 5 in the family's time
  /// zone, or now when the last backup is more than 30 hours old.
  bool due() {
    final own = _own;
    if (own == null || !own.ready) return false;
    final now = _now();
    final last = status.attemptAt ?? _startedAt;
    if (now - last >= const Duration(hours: 30).inMilliseconds) return true;
    if (now - last < const Duration(hours: 20).inMilliseconds) return false;
    final hour = wallOf(own.context.zone, now).hour;
    return hour >= 2 && hour < 5;
  }

  /// Runs the nightly backup when it is due.
  Future<void> tick() async {
    if (running || !due()) return;
    await runNow();
  }

  /// The folder a family's backups go in, under [dir] and in the place: none for the server's
  /// own family; another family's address (or its log's id).
  String subOf(DenHub family) {
    if (identical(family, _own)) return '';
    return normalizeHostname(family.config.publicUrl?.host) ?? family.host.idOf(family) ?? family.den.deviceId;
  }

  String _dirOf(String sub) => sub.isEmpty ? dir! : [dir!, sub].join(Platform.pathSeparator);

  /// The server's own family's backups on the disk, newest first.
  List<BackupEntry> onDisk() {
    final d = dir == null ? null : Directory(dir!);
    if (d == null || !d.existsSync()) return const [];
    return [
      for (final f in d.listSync().whereType<File>())
        if (backupNameTime(f.uri.pathSegments.last) case final at?) BackupEntry(f.uri.pathSegments.last, f.lengthSync(), at),
    ]..sort((a, b) => b.name.compareTo(a.name));
  }

  /// Backs every family on the server up now (once at a time: a second call waits for the run
  /// going on), and copies the backups to the place. Never throws; [status] says how it went.
  Future<BackupStatus> runNow() => _running ??= _run().whenComplete(() => _running = null);

  Future<BackupStatus> _run() async {
    final own = _own;
    final before = status;
    final now = _now();
    if (own == null || dir == null) return before;
    final place = this.place;
    final keep = this.keep;
    int? size;
    var lastAt = before.lastAt;
    var placeLastAt = before.placeLastAt;
    BackupProblem? problem;
    for (final family in _families()) {
      final data = family.config.dataDir;
      if (data == null || !family.ready) continue;
      final mine = identical(family, own);
      final sub = subOf(family);
      final to = backupRecipientsOf(family.den);
      if (to.isEmpty) {
        if (mine) problem = BackupProblem(kind: 'no_words', at: now);
        _log?.warn('${mine ? 'No' : 'For ${family.config.publicUrl?.host ?? sub}, no'} parent has saved recovery words, so '
            'no backup was made: nobody could open it.');
        continue;
      }
      final name = backupName(now);
      final File file;
      try {
        final files = await readBackupFiles(data);
        final sealed = await sealBackup(backupPlaintext(files),
            to: to, madeAt: now, familyName: family.den.family?.name, familyId: family.den.familyId);
        final folder = Directory(_dirOf(sub));
        HostState.ownerOnlyDir(folder);
        file = File([folder.path, name].join(Platform.pathSeparator));
        final temp = File('${file.path}.tmp');
        if (temp.existsSync()) temp.deleteSync();
        temp.createSync(exclusive: true);
        restrictToOwner(temp.path, warn: _log?.warn);
        await temp.writeAsBytes(sealed, flush: true);
        await temp.rename(file.path);
        _prune(folder, keep);
        if (mine) {
          size = sealed.length;
          lastAt = now;
        }
      } on Object catch (e) {
        _log?.error('The backup${mine ? '' : ' of ${family.config.publicUrl?.host ?? sub}'} couldn\'t be saved: ${e.runtimeType}');
        if (mine) problem = BackupProblem(kind: 'disk', at: now);
        continue;
      }
      if (place == null) continue;
      try {
        await places.upload(place, file.path, name, sub: sub);
        if (mine) placeLastAt = now;
        await _prunePlace(place, keep, sub);
      } on PlaceException catch (e) {
        _log?.warn('The backup didn\'t reach the NAS: ${e.problem.name}');
        if (mine) problem ??= BackupProblem(kind: e.problem.name, at: now, place: true);
      }
    }
    final next = BackupStatus(
      lastAt: lastAt,
      lastSize: size ?? before.lastSize,
      placeLastAt: placeLastAt,
      attemptAt: now,
      problem: problem,
    );
    _writeStatus(next);
    if (problem == null) _log?.info('Backed up${place == null ? '' : ', and copied to the NAS'}');
    return next;
  }

  void _prune(Directory folder, int keep) {
    final names = [
      for (final f in folder.listSync().whereType<File>())
        if (backupNameTime(f.uri.pathSegments.last) != null) f,
    ]..sort((a, b) => b.path.compareTo(a.path));
    for (final f in names.skip(keep)) {
      try {
        f.deleteSync();
      } on FileSystemException {
        _log?.debug('Couldn\'t remove an old backup');
      }
    }
  }

  Future<void> _prunePlace(BackupPlace place, int keep, String sub) async {
    try {
      final there = await places.list(place, sub: sub);
      for (final f in there.where((f) => backupNameTime(f.name) != null).skip(keep)) {
        await places.delete(place, f.name, sub: sub);
      }
    } on PlaceException {
      _log?.debug('Couldn\'t tidy the old backups on the NAS');
    }
  }
}
