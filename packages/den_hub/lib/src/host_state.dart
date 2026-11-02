import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart' show b64e;
import 'package:http/http.dart' as http_client;
import 'package:shelf/shelf.dart';

import 'edge.dart';
import 'push/web_push_crypto.dart';
import 'setup.dart' show restrictToOwner;
import 'sign_in_setup.dart';

/// The directory under a host's data directory that holds each log besides the first:
/// `<data>/logs/<id>/`, each in the same layout as `<data>/` itself (`keys.json`, `log/`, `hub/`,
/// `notify.json`).
const String hostLogsDir = 'logs';

/// The directory under a host's data directory with the host's own state: `host.json` (the logs
/// it serves and their addresses), `cli-secret`, and `push.json`, the host's own push key
/// ([hostPushFile]). No family's keys are kept there: each family's Web Push key is in its own
/// data, and goes with it.
const String hostStateDir = 'host';

/// The file in [hostStateDir] with the host's own Web Push key: the one key families on the host
/// that opt in ([HubConfig.hostPush]) hand out besides their own, so one web app holding several
/// of them gets all their pushes through one subscription. It is no family's key.
const String hostPushFile = 'push.json';

/// The file in [hostStateDir] holding the secret `den_hub add-family`, `adopt` and
/// `remove-family` show the running host, as `den_hub recover` shows a hub its own. Made again
/// each time the host starts; backups leave it out.
const String hostCliFile = 'cli-secret';

/// One log a Den host serves besides the first (the one in `<data>/` itself), as `host.json`
/// keeps it.
class HostedLog {
  /// Creates the record.
  const HostedLog({required this.id, this.publicUrl, required this.added, this.adoptedFrom, this.removed = false});

  /// Reads a record from `host.json`; null when it isn't one.
  static HostedLog? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], url = json['public_url'], added = json['added'];
    if (id is! String || !validId(id) || added is! int) return null;
    final from = json['adopted_from'];
    return HostedLog(
      id: id,
      publicUrl: url is String && url.isNotEmpty ? Uri.tryParse(url) : null,
      added: added,
      adoptedFrom: from is String ? from : null,
      removed: json['removed'] == true,
    );
  }

  /// The log's directory name under `<data>/logs/`: its family's id for a hub that was adopted,
  /// a random id for a family added fresh (it has no family until a parent sets it up).
  final String id;

  /// The family's own address (`https://den-smith.example.com`): requests to its name go to it,
  /// and its links, sign-in pages and OAuth name it, as `DEN_PUBLIC_URL` does for the first.
  final Uri? publicUrl;

  /// When the host took it on (UTC ms).
  final int added;

  /// The data directory it was adopted from (`den_hub adopt`), for the record.
  final String? adoptedFrom;

  /// Taken off the host (`den_hub remove-family`): no longer served, its data still there, so
  /// adding the same address again brings the same family back.
  final bool removed;

  /// The name requests come to it by: [publicUrl]'s host, lower case.
  String? get hostname => publicUrl == null ? null : normalizeHostname(publicUrl!.host);

  /// A copy with [removed] (and [publicUrl]) changed.
  HostedLog copyWith({bool? removed, Uri? publicUrl}) => HostedLog(
        id: id,
        publicUrl: publicUrl ?? this.publicUrl,
        added: added,
        adoptedFrom: adoptedFrom,
        removed: removed ?? this.removed,
      );

  /// As `host.json` keeps it.
  Map<String, Object?> toJson() => {
        'id': id,
        'public_url': ?publicUrl?.toString(),
        'added': added,
        'adopted_from': ?adoptedFrom,
        if (removed) 'removed': true,
      };

  /// Whether [id] is a directory name the host makes: letters, digits, `-` and `_`, 1 to 64.
  static bool validId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) && id != '.' && id != '..';

  /// A fresh random id: 16 base32 letters.
  static String newId() {
    const letters = 'abcdefghijklmnopqrstuvwxyz234567';
    final random = Random.secure();
    return List.generate(16, (_) => letters[random.nextInt(letters.length)]).join();
  }
}

/// [name] as the host compares addresses: lower case, without a trailing dot, an IPv6 literal
/// without its brackets. Null for an empty name.
String? normalizeHostname(String? name) {
  if (name == null) return null;
  var n = name.trim().toLowerCase();
  if (n.startsWith('[') && n.endsWith(']')) n = n.substring(1, n.length - 1);
  if (n.endsWith('.')) n = n.substring(0, n.length - 1);
  return n.isEmpty ? null : n;
}

/// The name [request] was made to: a trusted proxy's `X-Forwarded-Host`, else the `Host`
/// header, without its port; null without either. Anyone can send any `Host`, so this only picks
/// which family's public face answers a request that carries nothing else: every credential is
/// still checked by the family it belongs to.
String? requestHostname(Request request, List<IpNetwork> trusted) {
  final proxied = viaTrustedProxy(request, trusted);
  final forwarded = proxied ? request.headers['x-forwarded-host']?.split(',').first.trim() : null;
  final host = (forwarded == null || forwarded.isEmpty) ? request.headers['host'] : forwarded;
  if (host == null || host.isEmpty) return null;
  // `[::1]:47733`, `den.example.com:443`, `den.example.com`.
  if (host.startsWith('[')) {
    final end = host.indexOf(']');
    return normalizeHostname(end < 0 ? host : host.substring(0, end + 1));
  }
  final colon = host.lastIndexOf(':');
  return normalizeHostname(colon > 0 && host.indexOf(':') == colon ? host.substring(0, colon) : host);
}

/// A Den host's own state, under `<data>/host/` ([hostStateDir]): which logs it serves besides
/// the first, at which addresses (`host.json`), and the command line's secret ([hostCliFile]).
/// Without a data directory everything is in memory.
class HostState {
  /// Opens the state of the host whose data directory is [dataDir].
  HostState(this.dataDir) {
    _load();
  }

  /// The host's data directory, or null.
  final String? dataDir;

  final List<HostedLog> _logs = [];
  Uri? _primaryUrl;
  bool _several = false;

  VapidKeys? _pushKey;

  /// Reads the host's push key ([hostPushFile]) as the host starts, when it has one. A file that
  /// can't be read stops the host ([StateError]) rather than a new key quietly taking its place:
  /// every browser that turned reminders on with the old one would stop getting them.
  void loadPushKey() {
    final dir = dataDir;
    if (dir == null || _pushKey != null) return;
    final file = File(_path(dir, hostPushFile));
    if (file.existsSync()) _pushKey = _readPushKey(file);
  }

  /// The host's own Web Push key ([hostPushFile]), made on first use; in memory without a data
  /// directory. It is written owner-only from the start (`host/` 0700, the file 0600 before the
  /// key goes in, then renamed into place), and a host that can't make it so ([FileSystemException])
  /// or can't read the one it has ([StateError]) says so instead of serving with another.
  VapidKeys pushKey() {
    final have = _pushKey;
    if (have != null) return have;
    final dir = dataDir;
    if (dir == null) return _pushKey = VapidKeys.generate();
    final file = File(_path(dir, hostPushFile));
    if (file.existsSync()) return _pushKey = _readPushKey(file);
    final made = VapidKeys.generate();
    ownerOnlyDir(file.parent);
    final temp = File('${file.path}.tmp');
    if (temp.existsSync()) temp.deleteSync();
    temp.createSync(exclusive: true);
    ownerOnlyFile(temp.path);
    temp.writeAsStringSync(jsonEncode({'v': 1, 'vapid': b64url(made.privateKey)}), flush: true);
    temp.renameSync(file.path);
    return _pushKey = made;
  }

  static VapidKeys _readPushKey(File file) {
    Object? problem;
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map && json['vapid'] is String) return VapidKeys.fromPrivate(unb64url(json['vapid'] as String));
    } on Object catch (e) {
      problem = e;
    }
    throw StateError(
      "The host's push key (${file.path}) can't be read${problem == null ? '' : ' ($problem)'}. Restore it from a backup. "
      'To make a new one instead, move the file away: every browser that turned reminders on with it then turns them on again.',
    );
  }

  /// Makes [dir] (and what leads to it) and leaves it to its owner alone: `chmod 700`, or on
  /// Windows the owner's access only (best effort there). Throws when `chmod` fails.
  static void ownerOnlyDir(Directory dir) {
    dir.createSync(recursive: true);
    _chmod(dir.path, '700');
  }

  /// Leaves the file at [path] to its owner alone: `chmod 600`; on Windows, best effort.
  static void ownerOnlyFile(String path) => _chmod(path, '600');

  static void _chmod(String path, String mode) {
    if (Platform.isWindows) {
      restrictToOwner(path);
      return;
    }
    final done = Process.runSync('chmod', [mode, path]);
    if (done.exitCode != 0) {
      throw FileSystemException("Couldn't leave it to its owner alone (chmod $mode: ${'${done.stderr}'.trim()})", path);
    }
  }

  /// Deletes `vapid.json`, which earlier builds of the host kept every family's Web Push key in
  /// (each family's own data has its key). Best effort.
  void dropKeyring() {
    final dir = dataDir;
    if (dir == null) return;
    try {
      final old = File(_path(dir, 'vapid.json'));
      if (old.existsSync()) old.deleteSync();
    } on Object {
      // Nothing reads it.
    }
  }

  static String _path(String dataDir, String name) =>
      [dataDir, hostStateDir, name].join(Platform.pathSeparator);

  File? get _registry => dataDir == null ? null : File(_path(dataDir!, 'host.json'));

  void _load() {
    final file = _registry;
    if (file == null || !file.existsSync()) return;
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on Object {
      throw StateError('${file.path} is unreadable. Fix it, or restore it from a backup, before the host starts.');
    }
    if (json is! Map) return;
    _several = json['several'] == true;
    final primary = json['primary'];
    if (primary is Map && primary['public_url'] is String) _primaryUrl = Uri.tryParse(primary['public_url'] as String);
    for (final l in (json['logs'] as List?) ?? const []) {
      final log = HostedLog.fromJson(l);
      if (log != null && !_logs.any((x) => x.id == log.id)) _logs.add(log);
    }
    if (_logs.isNotEmpty) _several = true;
  }

  /// Whether the host has ever had a family besides the first (one it serves, one taken off, or
  /// one whose data was deleted since). Once it has, it never answers as one family at any
  /// address again ([HostConfig.single]): an address a family had stays no one else's.
  bool get several => _several;

  /// Every log in `host.json`, removed ones included.
  List<HostedLog> get all => List.unmodifiable(_logs);

  /// The logs the host serves besides the first.
  List<HostedLog> get logs => [for (final l in _logs) if (!l.removed) l];

  /// The log with [id], removed or not.
  HostedLog? log(String id) => _logs.where((l) => l.id == id).firstOrNull;

  /// The log with the id [hostnameOrId], or the one at that address: the one served there,
  /// else the one taken off it; null when none is, or when more than one was taken off it and
  /// none is served (say which by its id).
  HostedLog? find(String hostnameOrId) {
    final byId = log(hostnameOrId);
    if (byId != null) return byId;
    final want = normalizeHostname(hostnameOrId);
    if (want == null) return null;
    final served = [for (final l in _logs) if (!l.removed && l.hostname == want) l];
    if (served.isNotEmpty) return served.length == 1 ? served.single : null;
    final gone = removedAt(want);
    return gone.length == 1 ? gone.single : null;
  }

  /// The logs taken off [hostname] (its data still there), oldest first.
  List<HostedLog> removedAt(String hostname) {
    final want = normalizeHostname(hostname);
    return [for (final l in _logs) if (l.removed && want != null && l.hostname == want) l];
  }

  /// The first family's address, as the host last saw it (`DEN_PUBLIC_URL`).
  Uri? get primaryUrl => _primaryUrl;

  /// The directory of log [id].
  String? dirOf(String id) => dataDir == null ? null : [dataDir!, hostLogsDir, id].join(Platform.pathSeparator);

  /// Adds [log], or replaces the one with its id, and saves.
  void put(HostedLog log) {
    _logs
      ..removeWhere((l) => l.id == log.id)
      ..add(log);
    _several = true;
    save();
  }

  /// Drops the record of log [id] (its data deleted), and saves. The host still remembers it had
  /// other families ([several]).
  void forget(String id) {
    final before = _logs.length;
    _logs.removeWhere((l) => l.id == id);
    if (_logs.length != before) save();
  }

  /// Notes the first family's address, saving when it changed.
  void notePrimary(Uri? url) {
    if (url?.toString() == _primaryUrl?.toString()) return;
    _primaryUrl = url;
    save();
  }

  /// Writes `host.json` (owner-only), by a temporary file renamed over it.
  void save() {
    final file = _registry;
    if (file == null) return;
    ownerOnlyDir(file.parent);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'v': 1,
        if (_primaryUrl != null) 'primary': {'public_url': _primaryUrl.toString()},
        if (_several) 'several': true,
        'logs': [for (final l in _logs) l.toJson()],
      }),
      flush: true,
    );
    restrictToOwner(temp.path);
    temp.renameSync(file.path);
  }

  /// Makes a new secret for the command line and writes it to [hostCliFile]; null without a data
  /// directory, or when it can't be written.
  String? writeCliSecret() {
    final dir = dataDir;
    if (dir == null) return null;
    final random = Random.secure();
    final secret = b64e(List.generate(32, (_) => random.nextInt(256)));
    try {
      final file = File(_path(dir, hostCliFile));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$secret\n', flush: true);
      restrictToOwner(file.path);
      return secret;
    } on Object {
      return null;
    }
  }

  /// The secret the running host left for the command line, read from [dataDir]; null when there
  /// is none.
  static String? readCliSecret(String dataDir) {
    try {
      return File(_path(dataDir, hostCliFile)).readAsStringSync().trim();
    } on FileSystemException {
      return null;
    }
  }
}

/// What a family's hub (a tenant) gets from the Den host it runs in: the host-wide limits and
/// clients, and the lookups that keep codes unique across the host's books.
abstract interface class HostLink {
  /// Per-client budgets, shared by every family on the host, so spreading tries across
  /// families' addresses buys no more of them.
  RateLimiter get limits;

  /// Wrong invite words, counted for the whole host.
  WrongGuesses get inviteGuesses;

  /// Wrong recovery codes, counted for the whole host.
  WrongGuesses get recoveryGuesses;

  /// Whether any family on the host keeps an invite under [key] (four words, or `slot:<hex>`).
  bool inviteTaken(String key);

  /// Whether any family on the host keeps a recovery code with [hash].
  bool recoveryCodeTaken(String hash);

  /// Whether any family on the host waits for setup with [code].
  bool setupCodeTaken(String code);

  /// Whether a hub on the host other than [hubDevice] holds the family [familyId]: a fresh hub
  /// is never set up into a family the host serves already, so no two of its logs hold one.
  bool familyElsewhere(String familyId, String hubDevice);

  /// Admits a WebSocket upgrade from [request]'s client within the host's budgets, and returns
  /// the client's key.
  String admitSocket(Request request);

  /// Outgoing HTTP to what the operator configured.
  http_client.Client get http;

  /// Outgoing HTTP to addresses callers gave a hub, through the host's NetGuard.
  http_client.Client get fetch;

  /// The host's own Web Push key ([hostPushFile]), which a family hands out and signs with only
  /// when it opted in ([HubConfig.hostPush]), and only for subscriptions made with it.
  VapidKeys get pushKey;

  /// Signing in with Google and Apple, one set for every family on the host, kept in the host's
  /// own family's data and changed only by its parents ([HubSignInSetup]).
  HostSignIn get signIn;

  /// Every family's address the host knows (its own family's first): those it serves now and
  /// those `host.json` lists, attached or not. Each needs its own way back registered with
  /// Google and Apple.
  List<Uri> get familyAddresses;
}
