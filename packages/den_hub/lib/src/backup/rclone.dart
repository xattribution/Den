/// Copying backups to a NAS's shared folder (or, as it falls out, a computer over SFTP) with
/// rclone, which the hub's image carries and the hub runs as a subprocess ([Rclone]); tests fake
/// it. Nothing is kept in an rclone config file: each run gets its remote from environment
/// variables (`RCLONE_CONFIG_DEN_*`), so the NAS's password is never on a command line, in a
/// file other than the hub's own owner-only settings, or in a log.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What one rclone run did.
class RcloneResult {
  /// A run that ended with [exitCode], having written [stdout] and [stderr].
  const RcloneResult(this.exitCode, this.stdout, this.stderr);

  /// 0 when it worked.
  final int exitCode;

  /// What it printed.
  final String stdout;

  /// What it complained about.
  final String stderr;

  /// Whether it worked.
  bool get ok => exitCode == 0;
}

/// Runs rclone: the real one ([ProcessRclone]), or a fake in tests.
abstract interface class Rclone {
  /// Runs `rclone` with [args], with [env] added to its environment and [stdin] as its input.
  Future<RcloneResult> run(List<String> args, {Map<String, String> env = const {}, List<int>? stdin, Duration? timeout});
}

/// The `rclone` binary on the PATH (or at [binary]).
class ProcessRclone implements Rclone {
  /// rclone at [binary].
  const ProcessRclone({this.binary = 'rclone'});

  /// The program to run.
  final String binary;

  @override
  Future<RcloneResult> run(List<String> args, {Map<String, String> env = const {}, List<int>? stdin, Duration? timeout}) async {
    final Process process;
    try {
      process = await Process.start(binary, args, environment: env);
    } on ProcessException {
      return const RcloneResult(127, '', 'rclone is not installed on this server');
    }
    if (stdin != null) process.stdin.add(stdin);
    unawaited(process.stdin.close().then((_) {}, onError: (Object _) {}));
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(timeout ?? const Duration(minutes: 30), onTimeout: () {
      process.kill();
      return 124;
    });
    return RcloneResult(code, await out, code == 124 ? 'timed out' : await err);
  }
}

/// Where backups go besides the server's own disk.
class BackupPlace {
  /// A NAS's shared folder ([kind] `nas`: SMB), or a computer over SFTP ([kind] `sftp`).
  const BackupPlace({
    required this.kind,
    required this.host,
    this.share = '',
    this.folder = defaultFolder,
    this.user = '',
    this.password = '',
    this.port,
    this.name,
  });

  /// The folder Den makes on the share when nobody names another.
  static const String defaultFolder = 'Den backups';

  /// `nas` or `sftp`.
  final String kind;

  /// The NAS's name or address (`nas.local`, `192.168.1.40`).
  final String host;

  /// The shared folder on it (`backups`); none for SFTP.
  final String share;

  /// The folder inside the share (or, over SFTP, on the computer) that backups go in.
  final String folder;

  /// The NAS's username, and its password.
  final String user;

  /// The password. Never in an answer or a log.
  final String password;

  /// A port other than the usual one.
  final int? port;

  /// What the NAS calls itself, as it was found ("Family NAS").
  final String? name;

  /// The place as the settings file keeps it (with the password).
  Map<String, Object?> toJson() => {
        'kind': kind,
        'host': host,
        if (share.isNotEmpty) 'share': share,
        'folder': folder,
        if (user.isNotEmpty) 'user': user,
        if (password.isNotEmpty) 'password': password,
        'port': ?port,
        'name': ?name,
      };

  /// The place as an answer says it: no password.
  Map<String, Object?> describe() => {...toJson()..remove('password'), 'has_password': password.isNotEmpty};

  /// Reads [toJson]'s output, or a request's body; null when it isn't a place.
  static BackupPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    String text(String k) => json[k] is String ? (json[k] as String).trim() : '';
    final kind = text('kind').isEmpty ? 'nas' : text('kind');
    if (kind != 'nas' && kind != 'sftp') return null;
    final host = text('host');
    if (host.isEmpty) return null;
    final port = json['port'];
    return BackupPlace(
      kind: kind,
      host: host,
      share: text('share'),
      folder: text('folder').isEmpty ? defaultFolder : text('folder'),
      user: text('user'),
      password: json['password'] is String ? json['password'] as String : '',
      port: port is int && port > 0 && port < 65536 ? port : null,
      name: text('name').isEmpty ? null : text('name'),
    );
  }

  /// This place with [password] instead (one kept from before, when the request didn't repeat it).
  BackupPlace withPassword(String password) =>
      BackupPlace(kind: kind, host: host, share: share, folder: folder, user: user, password: password, port: port, name: name);

  /// The folder backups go in, as rclone names it on the `den` remote.
  String get path {
    final inner = folder.split('/').where((s) => s.isNotEmpty).join('/');
    if (kind == 'sftp') return 'den:$inner';
    return inner.isEmpty ? 'den:$share' : 'den:$share/$inner';
  }

  /// The same place, the server alone ([share] and folder dropped): where the shares are listed.
  String get root => 'den:';
}

/// Why a NAS wouldn't take a backup, in kinds the app words for people.
enum PlaceProblem {
  /// Nothing answered at that name or address.
  unreachable,

  /// The username or password is wrong.
  login,

  /// No such shared folder.
  missing,

  /// It can be read but not written.
  readOnly,

  /// rclone isn't on this server.
  noTool,

  /// Anything else.
  other,
}

/// What a [PlaceProblem] says to a parent.
String placeProblemWords(PlaceProblem p, {String? host}) => switch (p) {
      PlaceProblem.unreachable => 'Couldn\'t reach ${host ?? 'the NAS'}. Check that it\'s on and on the same network as the server.',
      PlaceProblem.login => 'The NAS didn\'t accept that username and password.',
      PlaceProblem.missing => 'That shared folder isn\'t on the NAS.',
      PlaceProblem.readOnly => 'The NAS lets Den read that folder but not save to it. Pick another, or give that user write access.',
      PlaceProblem.noTool => 'This server can\'t copy to a NAS yet. Update Den on the server.',
      PlaceProblem.other => 'The NAS didn\'t take the backup. Try again, or pick another folder.',
    };

/// The kind of problem rclone's complaint [stderr] (exit code [code]) is.
PlaceProblem placeProblemOf(int code, String stderr) {
  final e = stderr.toLowerCase();
  if (code == 127) return PlaceProblem.noTool;
  if (e.contains('logon_failure') ||
      e.contains('logon failure') ||
      e.contains('authentication') ||
      e.contains('unable to authenticate') ||
      e.contains('permission denied (publickey') ||
      e.contains('password')) {
    return PlaceProblem.login;
  }
  if (e.contains('bad_network_name') || e.contains('object_name_not_found') || e.contains('directory not found') ||
      e.contains('not found')) {
    return PlaceProblem.missing;
  }
  if (e.contains('access_denied') || e.contains('access denied') || e.contains('read-only') || e.contains('permission denied')) {
    return PlaceProblem.readOnly;
  }
  if (e.contains('no route') ||
      e.contains('connection refused') ||
      e.contains('i/o timeout') ||
      e.contains('timed out') ||
      e.contains('no such host') ||
      e.contains('host is down') ||
      e.contains('network is unreachable') ||
      e.contains('dial tcp')) {
    return PlaceProblem.unreachable;
  }
  return PlaceProblem.other;
}

/// A problem with a [BackupPlace].
class PlaceException implements Exception {
  /// [problem], at [host].
  PlaceException(this.problem, {this.host});

  /// What kind.
  final PlaceProblem problem;

  /// The NAS's name or address.
  final String? host;

  /// What it says to a parent.
  String get words => placeProblemWords(problem, host: host);

  @override
  String toString() => 'PlaceException: ${problem.name}';
}

/// One file in a backup place.
class PlaceFile {
  /// [name], [size] bytes, last changed at [modified] (UTC ms).
  const PlaceFile(this.name, this.size, this.modified);

  /// The file's name.
  final String name;

  /// Its size in bytes.
  final int size;

  /// When it last changed (UTC ms), or 0 when unknown.
  final int modified;
}

/// Backups in a [BackupPlace] through [rclone].
class PlaceClient {
  /// Reaches places with [rclone].
  PlaceClient(this.rclone);

  /// rclone, real or fake.
  final Rclone rclone;

  static const List<String> _flags = ['--contimeout', '10s', '--timeout', '60s', '--low-level-retries', '2', '--retries', '1'];

  /// rclone's own form of [password] (`rclone obscure`, read from its input, so it is never on a
  /// command line).
  Future<String> _obscure(String password) async {
    final r = await rclone.run(['obscure', '-'], stdin: utf8.encode(password), timeout: const Duration(seconds: 20));
    if (!r.ok) throw PlaceException(placeProblemOf(r.exitCode, r.stderr));
    return r.stdout.trim();
  }

  Future<Map<String, String>> _env(BackupPlace p) async => {
        'RCLONE_CONFIG_DEN_TYPE': p.kind == 'sftp' ? 'sftp' : 'smb',
        'RCLONE_CONFIG_DEN_HOST': p.host,
        if (p.user.isNotEmpty) 'RCLONE_CONFIG_DEN_USER': p.user,
        if (p.password.isNotEmpty) 'RCLONE_CONFIG_DEN_PASS': await _obscure(p.password),
        if (p.port != null) 'RCLONE_CONFIG_DEN_PORT': '${p.port}',
        // Spares rclone asking the computer what shell it runs.
        if (p.kind == 'sftp') 'RCLONE_CONFIG_DEN_SHELL_TYPE': 'unix',
      };

  Future<RcloneResult> _run(BackupPlace p, List<String> args, {List<int>? stdin, Duration? timeout}) async {
    final r = await rclone.run([...args, ..._flags], env: await _env(p), stdin: stdin, timeout: timeout);
    if (!r.ok) throw PlaceException(placeProblemOf(r.exitCode, r.stderr), host: p.name ?? p.host);
    return r;
  }

  List<Map<String, Object?>> _entries(String stdout) {
    try {
      final json = jsonDecode(stdout);
      if (json is List) return [for (final e in json) if (e is Map) e.cast<String, Object?>()];
    } on FormatException {
      // None.
    }
    return const [];
  }

  /// The shared folders on the NAS [p] names (its share and folder ignored).
  Future<List<String>> shares(BackupPlace p) async {
    final r = await _run(p, ['lsjson', '--dirs-only', p.root], timeout: const Duration(seconds: 40));
    return [
      for (final e in _entries(r.stdout))
        if (e['Name'] case final String name)
          if (!name.endsWith(r'$')) name,
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Checks that backups can be saved in [p]: makes its folder, writes a small file there and
  /// takes it away again.
  Future<void> test(BackupPlace p) async {
    await _run(p, ['mkdir', p.path], timeout: const Duration(seconds: 40));
    final probe = '${p.path}/.den-check';
    await _run(p, ['rcat', probe], stdin: utf8.encode('Den checks it can save backups here.\n'), timeout: const Duration(seconds: 40));
    await _run(p, ['deletefile', probe], timeout: const Duration(seconds: 40));
  }

  /// The backups in [p] (and [sub] inside it), newest first.
  Future<List<PlaceFile>> list(BackupPlace p, {String sub = ''}) async {
    final where = sub.isEmpty ? p.path : '${p.path}/$sub';
    final r = await _run(p, ['lsjson', '--files-only', where], timeout: const Duration(seconds: 60));
    final out = <PlaceFile>[];
    for (final e in _entries(r.stdout)) {
      final name = e['Name'];
      if (name is! String || !name.endsWith('.denbackup')) continue;
      final size = e['Size'] is int ? e['Size'] as int : 0;
      final modified = DateTime.tryParse(e['ModTime'] is String ? e['ModTime'] as String : '')?.millisecondsSinceEpoch ?? 0;
      out.add(PlaceFile(name, size, modified));
    }
    return out..sort((a, b) => b.name.compareTo(a.name));
  }

  /// Copies the local file [local] into [p] as [name] (in [sub] inside it).
  Future<void> upload(BackupPlace p, String local, String name, {String sub = ''}) async {
    final where = sub.isEmpty ? p.path : '${p.path}/$sub';
    await _run(p, ['copyto', local, '$where/$name'], timeout: const Duration(minutes: 30));
  }

  /// Copies [name] (in [sub]) from [p] to the local file [local].
  Future<void> download(BackupPlace p, String name, String local, {String sub = ''}) async {
    final where = sub.isEmpty ? p.path : '${p.path}/$sub';
    await _run(p, ['copyto', '$where/$name', local], timeout: const Duration(minutes: 30));
  }

  /// Removes [name] (in [sub]) from [p].
  Future<void> delete(BackupPlace p, String name, {String sub = ''}) async {
    final where = sub.isEmpty ? p.path : '${p.path}/$sub';
    await _run(p, ['deletefile', '$where/$name'], timeout: const Duration(seconds: 60));
  }
}
