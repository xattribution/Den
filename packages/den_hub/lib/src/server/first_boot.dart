/// The server's first boot, in a browser (docs/hub-api.md, "First boot"): before the server has
/// a family, whoever holds its one-time setup code (the link the installer printed) connects it
/// to the internet with a Cloudflare tunnel token, and then makes the family on their phone or
/// restores one from a backup. Every endpoint here needs the setup code ([HubSetup.requireCode]);
/// once the family exists none of them answers, and the server's settings are a parent's, from
/// Settings on their own phone (server_api.dart).
library;

import 'dart:async';
import 'dart:io';

import 'package:den_net/den_net.dart' show RecoveryWords;
import 'package:shelf/shelf.dart';

import '../backup/backup_files.dart';
import '../backup/backups.dart';
import '../backup/rclone.dart';
import '../backup/sealed_backup.dart';
import '../body.dart';
import '../context.dart';
import '../edge.dart' show Rate;
import '../host.dart' show DenHost;
import '../host_state.dart' show HostState;
import '../http_util.dart';
import '../setup.dart';
import 'connector.dart';
import 'server_access.dart';

/// The largest backup a browser may upload: far more than a family's log.
const int maxBackupUpload = 256 * 1024 * 1024;

/// The family's address as typed or found (`den.example.com`, `https://den.example.com/`):
/// `https://den.example.com`, or null when it isn't one.
Uri? familyAddressOf(String text) {
  var t = text.trim().toLowerCase();
  if (t.isEmpty) return null;
  if (!t.contains('://')) t = 'https://$t';
  final u = Uri.tryParse(t);
  if (u == null || u.host.isEmpty || !u.host.contains('.') || u.scheme != 'https') return null;
  if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$').hasMatch(u.host)) return null;
  return Uri(scheme: 'https', host: u.host, port: u.hasPort && u.port != 443 ? u.port : null);
}

/// The first-boot endpoints of the server's own family's hub, while it has no family.
class FirstBoot {
  /// For the hub of [hub] in [host], whose setup is [setup]; [setAddress] gives the hub its
  /// address once the server has one.
  FirstBoot(this.hub, this.setup, this.host, {required this.setAddress, required this.isOwn});

  /// Shared hub context.
  final HubContext hub;

  /// The hub's setup, which holds the code.
  final HubSetup setup;

  /// The host.
  final DenHost host;

  /// Gives the hub its address.
  final void Function(Uri address) setAddress;

  /// Whether this hub is the server's own family's (first-boot is for that one only).
  final bool Function() isOwn;

  /// Made the family on a phone ("Make your family"), so the setup link there goes straight to
  /// making it.
  bool _chosen = false;

  TunnelConnector? get _connector => host.connector;
  HostBackups get _backups => host.backups;

  /// Whether the first-boot pages are for this server: a connector to set up, and the server's
  /// own family still to make.
  bool get offered => (_connector?.available ?? false) && isOwn() && !hub.ready;

  /// What `GET /api/v1/hub/status` says while it has no family: `{next: "start" | "family"}`.
  Map<String, Object?>? statusPart() => offered ? {'next': _chosen ? 'family' : 'start'} : null;

  /// Adds the routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/hub/first-boot', (r, _) => _state(r))
      ..add('PUT', '/api/v1/hub/first-boot/internet', (r, _) => _token(r))
      ..add('PUT', '/api/v1/hub/first-boot/address', (r, _) => _address(r))
      ..add('POST', '/api/v1/hub/first-boot/choice', (r, _) => _choice(r))
      ..add('POST', '/api/v1/hub/first-boot/nas/find', (r, _) => _find(r))
      ..add('POST', '/api/v1/hub/first-boot/nas/shares', (r, _) => _shares(r))
      ..add('POST', '/api/v1/hub/first-boot/backups', (r, _) => _list(r))
      ..add('POST', '/api/v1/hub/first-boot/upload', (r, _) => _upload(r))
      ..add('POST', '/api/v1/hub/first-boot/restore', (r, _) => _restore(r));
  }

  void _check(Request r) {
    if (!isOwn()) throw ApiError.notFound();
    setup.requireCode(r);
  }

  Future<Map<String, Object?>> _describe(Request r) async {
    final connector = _connector;
    final tunnel = connector == null ? const CloudflareStatus(token: false) : await connector.state();
    var address = hub.config.publicUrl;
    // The address, learned from the tunnel itself: nobody types it.
    if (address == null && tunnel.connected && tunnel.hostnames.isNotEmpty) {
      final found = familyAddressOf(tunnel.hostnames.first);
      if (found != null) {
        _saveAddress(found);
        address = found;
      }
    }
    final code = setup.code;
    final base = address ?? hub.base(r);
    return {
      'internet': {
        'available': connector?.available ?? false,
        'token': tunnel.token,
        'connected': tunnel.connected,
        'reachable': tunnel.reachable,
        if (tunnel.hostnames.isNotEmpty) 'found': tunnel.hostnames,
        'problem': ?tunnel.message,
      },
      if (address != null) 'address': address.toString(),
      if (code != null) 'setup_link': setupLink(base, HubSetup.display(code), hub.den.deviceId).toString(),
      'restore': {'passphrase_known': host.config.backupPassphrase != null},
    };
  }

  void _saveAddress(Uri address) {
    final dir = hub.config.dataDir;
    if (dir != null) {
      final file = File([dir, 'hub', addressFile].join(Platform.pathSeparator));
      HostState.ownerOnlyDir(file.parent);
      file.writeAsStringSync('$address\n', flush: true);
    }
    setAddress(address);
    hub.log.info('The family\'s address is $address');
  }

  Future<Response> _state(Request r) async {
    _check(r);
    return jsonResponse(await _describe(r));
  }

  /// `PUT /api/v1/hub/first-boot/internet {token}`: saves the tunnel token (never said back) and
  /// starts the tunnel.
  Future<Response> _token(Request r) async {
    _check(r);
    requireSecretsSafe(hub, r);
    final connector = _connector;
    if (connector == null || !connector.available) {
      throw ApiError(409, 'no_connector', 'This server can\'t connect to Cloudflare by itself. Update Den on the server.');
    }
    final b = Body(await readJsonObject(r, required: true));
    final token = tunnelTokenOf(b.string('token', required: true, min: 1, max: 8000)!);
    if (token == null) {
      throw ApiError.invalid('That isn\'t a tunnel token. Copy the long one Cloudflare shows for the tunnel (it starts with eyJ).',
          field: 'token');
    }
    await connector.setToken(token);
    hub.log.info('Saved the Cloudflare tunnel token for tunnel ${tunnelIdOf(token) ?? '(unnamed)'}; connecting');
    return jsonResponse(await _describe(r), status: 202);
  }

  /// `PUT /api/v1/hub/first-boot/address {address}`: the family's address, when the tunnel
  /// doesn't say it.
  Future<Response> _address(Request r) async {
    _check(r);
    final b = Body(await readJsonObject(r, required: true));
    final address = familyAddressOf(b.string('address', required: true, min: 1, max: 300)!);
    if (address == null) {
      throw ApiError.invalid('That isn\'t an address. It looks like den.yourfamily.com.', field: 'address');
    }
    _saveAddress(address);
    return jsonResponse(await _describe(r));
  }

  /// `POST /api/v1/hub/first-boot/choice {choice: "family"}`: the family is made on a phone next.
  Future<Response> _choice(Request r) async {
    _check(r);
    final b = Body(await readJsonObject(r, required: true));
    if (b.string('choice', required: true) != 'family') throw ApiError.invalid('"choice" must be "family".', field: 'choice');
    _chosen = true;
    return jsonResponse(await _describe(r));
  }

  Future<Response> _find(Request r) async {
    _check(r);
    final found = await _backups.finder.find();
    return jsonResponse({'found': [for (final f in found) f.toJson()]});
  }

  /// The place in a request body ([BackupPlace.fromJson]), or `400`.
  static BackupPlace placeIn(Map<String, Object?> json) {
    final place = BackupPlace.fromJson(json['place']);
    if (place == null) throw ApiError.invalid('Say which NAS: its name or address.', field: 'place');
    return place;
  }

  /// [PlaceException] as an answer: `422 place_problem` with its kind and words.
  static ApiError placeError(PlaceException e) =>
      ApiError(422, 'place_problem', e.words, details: {'problem': e.problem.name});

  Future<Response> _shares(Request r) async {
    _check(r);
    requireSecretsSafe(hub, r);
    final place = placeIn(await readJsonObject(r, required: true));
    try {
      return jsonResponse({'shares': await _backups.places.shares(place)});
    } on PlaceException catch (e) {
      throw placeError(e);
    }
  }

  /// `POST /api/v1/hub/first-boot/backups {place?}`: the backups on the NAS [place] (newest
  /// first), or without one those on this server's disk.
  Future<Response> _list(Request r) async {
    _check(r);
    requireSecretsSafe(hub, r);
    final json = await readJsonObject(r);
    if (json['place'] == null) return jsonResponse({'backups': [for (final b in _backups.onDisk()) b.toJson()]});
    final place = placeIn(json);
    try {
      final files = await _backups.places.list(place);
      return jsonResponse({
        'backups': [
          for (final f in files) {'name': f.name, 'size': f.size, 'at': backupNameTime(f.name) ?? f.modified},
        ],
      });
    } on PlaceException catch (e) {
      throw placeError(e);
    }
  }

  File get _uploaded => File([host.config.dataDir ?? Directory.systemTemp.path, 'restore-upload.denbackup'].join(Platform.pathSeparator));

  Map<String, Object?> _infoOf(BackupInfo info) => {
        'version': info.version,
        'made_at': ?info.madeAt,
        'family_name': ?info.familyName,
        'names': info.names,
        'passphrase': info.passphrase,
      };

  /// `POST /api/v1/hub/first-boot/upload` (the backup file itself as the body): keeps it until it
  /// is restored, and says what it is.
  Future<Response> _upload(Request r) async {
    _check(r);
    final bytes = await readBodyBytes(r, limit: maxBackupUpload, deadline: const Duration(minutes: 10));
    final BackupInfo info;
    try {
      info = readBackupInfo(bytes);
    } on Object {
      throw ApiError.invalid('That isn\'t a Den backup. Pick the file whose name ends in .denbackup.', field: 'file');
    }
    final file = _uploaded;
    final temp = File('${file.path}.tmp');
    if (temp.existsSync()) temp.deleteSync();
    temp.createSync(recursive: true, exclusive: true);
    HostState.ownerOnlyFile(temp.path);
    await temp.writeAsBytes(bytes, flush: true);
    temp.renameSync(file.path);
    return jsonResponse({'backup': _infoOf(info)});
  }

  /// `POST /api/v1/hub/first-boot/restore {from: upload | disk | nas, name?, place?, words?,
  /// passphrase?}`: opens the backup with a parent's recovery words (or, for an older one, its
  /// passphrase), puts the family in place of this empty hub, and answers once it serves.
  Future<Response> _restore(Request r) async {
    _check(r);
    requireSecretsSafe(hub, r);
    final json = await readJsonObject(r, required: true);
    final b = Body(json);
    final from = b.string('from', required: true);
    final name = b.string('name', max: 200);
    final List<int> bytes;
    BackupPlace? place;
    switch (from) {
      case 'upload':
        if (!_uploaded.existsSync()) throw ApiError.invalid('Pick the backup file again.', field: 'file');
        bytes = await _uploaded.readAsBytes();
      case 'disk':
        final pick = name ?? (_backups.onDisk().firstOrNull?.name);
        if (pick == null || backupNameTime(pick) == null || _backups.dir == null) {
          throw ApiError.invalid('There\'s no backup on this server.', field: 'name');
        }
        final file = File([_backups.dir!, pick].join(Platform.pathSeparator));
        if (!file.existsSync()) throw ApiError.invalid('That backup isn\'t on this server.', field: 'name');
        bytes = await file.readAsBytes();
      case 'nas':
        place = placeIn(json);
        try {
          final pick = name ?? (await _backups.places.list(place)).firstOrNull?.name;
          if (pick == null || backupNameTime(pick) == null) throw ApiError.invalid('There\'s no backup in that folder.', field: 'name');
          final temp = File('${_uploaded.path}.nas.tmp');
          if (temp.existsSync()) temp.deleteSync();
          await _backups.places.download(place, pick, temp.path);
          bytes = await temp.readAsBytes();
          temp.deleteSync();
        } on PlaceException catch (e) {
          throw placeError(e);
        }
      default:
        throw ApiError.invalid('"from" must be upload, disk or nas.', field: 'from');
    }
    final wordsText = b.string('words', max: 1000);
    final words = wordsText == null || wordsText.trim().isEmpty ? null : RecoveryWords.parse(wordsText);
    if (wordsText != null && wordsText.trim().isNotEmpty && words == null) {
      throw ApiError.invalid('Those aren\'t twelve recovery words. Check each one.', field: 'words');
    }
    final passphrase = b.string('passphrase', max: 500) ?? host.config.backupPassphrase;
    final BackupInfo info;
    final Map<String, List<int>> files;
    try {
      info = readBackupInfo(bytes);
      files = backupFilesOf(await openBackup(bytes, words: words, passphrase: passphrase));
    } on BackupOpenException catch (e) {
      hub.limit(r, 'restore', const Rate(10, Duration(minutes: 10)), message: 'Too many tries. Wait a few minutes, then try again.');
      throw ApiError(422, 'backup_refused', _refusedWords(e.reason, bytes), details: {'reason': e.reason.name});
    } on Object {
      throw ApiError.invalid('That backup is damaged.', field: 'file');
    }
    if (files['keys.json'] == null) throw ApiError.invalid('That backup is damaged.', field: 'file');
    hub.log.info('Restoring ${info.familyName ?? 'the family'} from a backup');
    await host.restoreOwn(files, from: name ?? from!);
    if (_uploaded.existsSync()) _uploaded.deleteSync();
    // A family brought back from a NAS keeps backing up there.
    if (place != null) _backups.setPlace(place);
    return jsonResponse({'ok': true, 'family_name': ?info.familyName});
  }

  static String _refusedWords(BackupRefusal reason, List<int> bytes) {
    final names = (() {
      try {
        return readBackupInfo(bytes).names;
      } on Object {
        return const <String>[];
      }
    })();
    final whose = names.isEmpty ? 'a parent' : names.join(' or ');
    return switch (reason) {
      BackupRefusal.wrongWords => 'Those words don\'t open this backup. It opens with the recovery words of $whose.',
      BackupRefusal.needsWords => 'This backup opens with the recovery words of $whose.',
      BackupRefusal.wrongPassphrase => 'That passphrase doesn\'t open this backup.',
      BackupRefusal.needsPassphrase => 'This backup was made by an older Den, and opens with the passphrase it was made with.',
      BackupRefusal.damaged => 'That backup is damaged.',
    };
  }
}
