import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:den_core/den_core.dart' show DeviceKeys;
import 'package:den_hub/cli_support.dart' show restoreMarkerDoc;
import 'package:den_hub/den_hub.dart';
import 'package:http/http.dart' as http;

import 'cli.dart';
import 'commands.dart';
import 'data_dir.dart';

/// Which family on a Den host a command is for (`--family <address or id>`): its data directory
/// and the address requests to it name. Without `--family`, the first family, the one in the
/// data directory itself.
class FamilyTarget {
  /// Creates the target.
  FamilyTarget(this.data, {this.publicUrl, this.log, DataDir? host}) : host = host ?? data;

  /// The family's data directory: the host's own for the first family, `logs/<id>/` for others.
  final DataDir data;

  /// The host's data directory (the first family's).
  final DataDir host;

  /// The family's address, when known.
  final Uri? publicUrl;

  /// Its record in `host.json`; null for the first family.
  final HostedLog? log;

  /// The name requests to the running host give in `Host`, so they reach this family. Null for
  /// the first family with no address known: on a host with one family, any address reaches it.
  String? get hostname => publicUrl == null ? null : normalizeHostname(publicUrl!.host);

  /// Whether this is the first family.
  bool get first => log == null;

  /// How the family is named to people.
  String get label => hostname ?? (first ? 'the first family' : log!.id);
}

/// [text] (`den-smith.example.com`, or an address) as the name it stands for, lower case.
String? familyName(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final uri = Uri.tryParse(t.contains('://') ? t : 'https://$t');
  return normalizeHostname(uri?.host ?? t);
}

/// The first family's address: `DEN_PUBLIC_URL`, else what the host last noted.
Uri? primaryUrl(DataDir data, Map<String, String> env) {
  final configured = env['DEN_PUBLIC_URL'];
  if (configured != null && configured.isNotEmpty) return Uri.tryParse(configured);
  return HostState(data.path).primaryUrl;
}

/// The family [family] names on the host in [data] (its address or its log's id), or the first
/// family when null. With [register], an address the host doesn't know yet is added to
/// `host.json` (a restore onto a new server). Throws [StateError] for one it doesn't know.
FamilyTarget familyTarget(DataDir data, String? family, Map<String, String> env, {bool register = false}) {
  final first = primaryUrl(data, env);
  if (family == null || family.isEmpty) return FamilyTarget(data, publicUrl: first);
  final name = familyName(family);
  if (name == null) throw CliUsage('--family takes a family\'s address, like den-smith.example.com');
  if (first != null && normalizeHostname(first.host) == name) return FamilyTarget(data, publicUrl: first);
  final state = HostState(data.path);
  final found = state.find(family.trim()) ?? state.find(name);
  if (found != null && !found.removed) return FamilyTarget(data.log(found.id), publicUrl: found.publicUrl, log: found, host: data);
  if (register) {
    final log = found?.copyWith(removed: false) ??
        HostedLog(id: HostedLog.newId(), publicUrl: Uri.parse('https://$name'), added: DateTime.now().toUtc().millisecondsSinceEpoch);
    state.put(log);
    return FamilyTarget(data.log(log.id), publicUrl: log.publicUrl, log: log, host: data);
  }
  throw StateError('There\'s no family at $family on this host. den_hub families lists them.');
}

/// GETs [url] as if at [hostname] (null: as it is); the JSON object, or null when nothing
/// answers or the answer isn't 200.
Future<Map<String, Object?>?> getJsonAt(Uri url, String? hostname) async {
  try {
    final r = await http.get(url, headers: {'host': ?hostname}).timeout(const Duration(seconds: 2));
    if (r.statusCode != 200) return null;
    return (jsonDecode(r.body) as Map).cast<String, Object?>();
  } on Object {
    return null;
  }
}

/// GETs [url] as if at [hostname]: its status and JSON object (empty when it isn't one), for any
/// status; null when nothing answers. A host still opening a family answers `503`, and runs.
Future<({int status, Map<String, Object?> json})?> probeAt(Uri url, String? hostname) async {
  try {
    final r = await http.get(url, headers: {'host': ?hostname}).timeout(const Duration(seconds: 2));
    Object? json;
    try {
      json = jsonDecode(r.body);
    } on FormatException {
      json = null;
    }
    return (status: r.statusCode, json: json is Map ? json.cast<String, Object?>() : <String, Object?>{});
  } on Object {
    return null;
  }
}

/// Asks the host running on [port] over [data] something only `den_hub` on this machine may
/// (`/api/v1/host/...`), with the secret it left in `host/cli-secret`. Null when no host runs
/// there (or an older hub does, which has no secret).
Future<({int status, Map<String, Object?> json})?> hostCall(
    int port, DataDir data, String method, String path, {Object? body}) async {
  final base = Uri.parse('http://127.0.0.1:$port');
  if (await probeAt(base.resolve('/health'), null) == null) return null;
  final secret = HostState.readCliSecret(data.path);
  if (secret == null) return null;
  final request = http.Request(method, base.resolve(path))..headers[DenHost.secretHeader] = secret;
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode(body);
  }
  final http.Response r;
  try {
    r = await http.Response.fromStream(await request.send()).timeout(const Duration(seconds: 60));
  } on Object {
    throw StateError('The host on port $port didn\'t answer. Is it still starting?');
  }
  Object? json;
  try {
    json = jsonDecode(r.body);
  } on FormatException {
    json = null;
  }
  return (status: r.statusCode, json: json is Map ? json.cast<String, Object?>() : <String, Object?>{});
}

/// Why the running host hasn't opened [target]'s family, as it says (`error`, and how often it
/// tries again); null when it isn't waiting for it, or doesn't answer.
Future<({String? error, int retry})?> waitingOn(FamilyTarget target, int port) async {
  final id = target.log?.id;
  if (id == null) return null;
  try {
    final running = await hostCall(port, target.host, 'GET', '/api/v1/host');
    for (final w in (running?.json['waiting'] as List?) ?? const []) {
      if (w is Map && w['id'] == id) return (error: w['error'] as String?, retry: (w['retry_seconds'] as int?) ?? 30);
    }
  } on StateError {
    return null;
  }
  return null;
}

String _errorOf(Map<String, Object?> json, int status) {
  final error = json['error'];
  final message = error is Map ? error['message'] : null;
  return message is String ? message : 'The host said no (HTTP $status).';
}

/// The address `add-family` and `adopt` are given: `--url`, else `https://` and `--hostname`.
Uri _addressOf(ArgResults a) {
  final url = a['url'] as String?;
  final hostname = a['hostname'] as String?;
  final text = url != null && url.isNotEmpty ? url : hostname;
  if (text == null || text.isEmpty) throw CliUsage('--hostname is required: the family\'s own address, like den-smith.example.com');
  final List<Uri> parsed;
  try {
    parsed = parsePeerHubs(text);
  } on FormatException catch (e) {
    throw CliUsage('${e.message}. A family\'s address is a name like den-smith.example.com.');
  }
  if (parsed.length != 1) throw CliUsage('Give one address, like den-smith.example.com');
  final u = parsed.single;
  return u.port == 443 ? Uri(scheme: 'https', host: u.host) : u;
}

/// Prints [family]'s setup link and QR code, as `setup-link` does.
void printSetupLink(CliIo io, Uri base, String code, String device) {
  final link = setupLink(base, code, device).toString();
  io.out
    ..writeln("On the first parent's iPhone, scan this with the Camera, or open the link in Safari:")
    ..writeln()
    ..writeln(terminalQr(link))
    ..writeln('  $link')
    ..writeln()
    ..writeln('Then add Den to the Home Screen as it shows, and open it from there.')
    ..writeln('If Den asks for the setup code, it is: $code');
}

/// `den_hub add-family --hostname den-smith.example.com`: a new family on this host, at its own
/// address, with its own keys and data in `logs/<id>/`. With the host running it starts serving
/// at once and this prints the family's setup link and QR code; with none running it is noted
/// for the next start.
Future<int> addFamily(ArgResults a, DataDir data, int port, CliIo io) async {
  final url = _addressOf(a);
  final name = normalizeHostname(url.host)!;
  final first = primaryUrl(data, io.environment);
  if (first != null && normalizeHostname(first.host) == name) throw StateError('$name is the first family\'s address.');
  final id = a['id'] as String?;
  final running = await hostCall(port, data, 'POST', '/api/v1/host/families', body: {'public_url': '$url', 'id': ?id});
  if (running != null) {
    if (running.status != 201) throw StateError(_errorOf(running.json, running.status));
    final code = running.json['setup_code'], device = running.json['device'];
    io.out.writeln('The host now serves $name.');
    if (code is String && device is String) {
      io.out.writeln();
      printSetupLink(io, url, code, device);
    } else {
      io.out.writeln('${running.json['family_name'] ?? 'Its family'} is back, as it was.');
    }
    return 0;
  }
  if (!data.exists) throw StateError('There\'s no hub in ${data.path} yet. Run den_hub serve first.');
  try {
    await data.lock();
  } on StateError {
    throw StateError('A host is running on ${data.path} but didn\'t answer on port $port. Give --port, or stop it first.');
  }
  try {
    final state = HostState(data.path);
    if (state.logs.any((l) => l.hostname == name)) throw StateError('$name is on this host already.');
    final gone = state.removedAt(name);
    if (id != null && !gone.any((l) => l.id == id)) throw StateError('No family taken off $name has the id $id.');
    if (id == null && gone.length > 1) {
      throw StateError('More than one family was taken off $name (${gone.map((l) => l.id).join(', ')}): say which with --id.');
    }
    final previous = id == null ? gone.firstOrNull : gone.firstWhere((l) => l.id == id);
    final log = previous?.copyWith(removed: false) ??
        HostedLog(id: HostedLog.newId(), publicUrl: url, added: DateTime.now().toUtc().millisecondsSinceEpoch);
    if (previous == null) await data.log(log.id).keys();
    state.put(log);
    io.out
      ..writeln('Added $name (in ${data.log(log.id).path}). The host serves it from its next start;')
      ..writeln('then its setup link and QR code: den_hub setup-link --family $name');
    return 0;
  } finally {
    await data.unlock();
  }
}

/// [path] with `..` and symbolic links resolved, without a trailing separator.
String _real(String path) {
  String out;
  try {
    out = Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    out = Directory(path).absolute.uri.normalizePath().toFilePath();
  }
  while (out.length > 1 && out.endsWith(Platform.pathSeparator)) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// The hub device id in [dir]'s `keys.json`, or null without one.
Future<String?> _deviceOf(DataDir dir) async {
  if (!dir.exists) return null;
  try {
    return await (await DeviceKeys.fromJson((jsonDecode(await dir.keysFile.readAsString()) as Map).cast<String, Object?>())).deviceId();
  } on Object {
    return null;
  }
}

/// The hub device id in a `keys.json` file's [bytes], or null.
Future<String?> deviceInKeys(List<int> bytes) async {
  try {
    return await (await DeviceKeys.fromJson((jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>())).deviceId();
  } on Object {
    return null;
  }
}

/// The family on the host in [data] other than the one in [target] whose hub is [device] (its
/// address, or `the first family`), or null.
Future<String?> hubElsewhere(DataDir data, DataDir target, String device, Uri? first) async {
  final mine = _real(target.path);
  for (final k in await _knownHubs(data, first)) {
    final dir = k.id == null ? data : data.log(k.id!);
    if (k.device == device && _real(dir.path) != mine) return k.hostname ?? k.id ?? 'the first family';
  }
  return null;
}

/// A hub this host has had: the first family's, each family `host.json` lists (taken off or
/// not), and any copy in `logs/` it doesn't list (an adopt that stopped halfway).
typedef _Known = ({String device, String? hostname, String? id, bool removed, bool listed});

Future<List<_Known>> _knownHubs(DataDir data, Uri? first) async {
  final out = <_Known>[];
  final mine = await _deviceOf(data);
  if (mine != null) out.add((device: mine, hostname: first == null ? null : normalizeHostname(first.host), id: null, removed: false, listed: true));
  final state = HostState(data.path);
  for (final l in state.all) {
    final device = await _deviceOf(data.log(l.id));
    if (device != null) out.add((device: device, hostname: l.hostname, id: l.id, removed: l.removed, listed: true));
  }
  final logs = Directory('${data.path}${Platform.pathSeparator}$hostLogsDir');
  if (logs.existsSync()) {
    for (final e in logs.listSync()) {
      final id = e.uri.pathSegments.where((x) => x.isNotEmpty).last;
      if (e is! Directory || state.log(id) != null) continue;
      final device = await _deviceOf(data.log(id));
      if (device != null) out.add((device: device, hostname: null, id: id, removed: false, listed: false));
    }
  }
  return out;
}

/// What `adopt` learns about a hub's data directory, from the directory alone.
class _Hub {
  _Hub(this.device, this.family, this.familyName, this.changes, this.approved);
  final String device;
  final String? family;
  final String? familyName;
  final int changes;
  final bool approved;

  static Future<_Hub> of(DataDir dir) async {
    final den = await dir.open();
    try {
      return _Hub(den.deviceId, den.familyId, den.family?.name, den.changesSince(const {}).length, den.isApproved);
    } finally {
      await den.close();
    }
  }
}

/// `den_hub adopt <another hub's data directory> --hostname den-smith.example.com [--dry-run]`:
/// moves a hub that ran on its own (a family's own container, say) onto this host, at its own
/// address. Its `keys.json` moves with it, so the hub keeps its device id: its family's phones
/// keep syncing with no pairing again, its links, tokens and connections keep working, and its
/// browsers keep their reminders. The other hub must be stopped; its directory is copied, never
/// changed, except for a note that makes it wait for a phone before writing anything, should it
/// ever start again. `--dry-run` says what it would do and changes nothing.
///
/// Run again for a hub the host already serves at that address (a merge that stopped after the
/// copy), it says so and succeeds, changing nothing. A hub the host has, or had (a family taken
/// off it), is never adopted again, by whatever path it is reached (`..` and symbolic links are
/// resolved, and the host's own data directory is refused).
Future<int> adopt(ArgResults a, DataDir data, int port, CliIo io) async {
  if (a.rest.length != 1) throw CliUsage('Give the other hub\'s data directory: den_hub adopt /path/to/its/data --hostname ADDRESS');
  final source = DataDir(a.rest.single);
  final url = _addressOf(a);
  final name = normalizeHostname(url.host)!;
  final dry = a['dry-run'] == true;
  if (!source.exists) throw StateError('There\'s no hub in ${source.path} (no keys.json).');
  final from = _real(source.path);
  final into = _real(data.path);
  if (from == into || from.startsWith('$into${Platform.pathSeparator}')) {
    throw StateError('${source.path} is this host\'s own data directory, or inside it (a family on this host, or taken off it).');
  }
  final first = primaryUrl(data, io.environment);
  final device = await _deviceOf(source);
  final known = await _knownHubs(data, first);
  for (final k in known) {
    if (k.device != device) continue;
    if (k.listed && !k.removed && k.hostname == name) {
      if (!dry) _markMoved(source, data, k.id ?? '', io);
      io.out.writeln('The host serves this hub at $name already: nothing to do.');
      return 0;
    }
    if (!k.listed) {
      // A copy an adopt left without telling the host: nothing ever served it. Moved aside, never
      // deleted: whoever runs this deletes it once the family is fine.
      if (dry) {
        io.out.writeln('Would move aside ${data.log(k.id!).path}, an unfinished copy of this hub that the host doesn\'t list.');
      } else {
        final aside = await _moveAside(data, k.id!);
        io.out.writeln('Moved an unfinished copy of this hub that the host doesn\'t list from ${data.log(k.id!).path} to $aside. '
            'Delete it once the family is fine.');
      }
      continue;
    }
    throw StateError(k.removed
        ? 'This host had that hub at ${k.hostname ?? k.id}, taken off; add-family --hostname ${k.hostname ?? '<its address>'} brings it back.'
        : 'This host serves that hub already${k.hostname == null ? '' : ', at ${k.hostname}'}.');
  }
  try {
    await source.lock();
  } on StateError {
    throw StateError('A hub is running on ${source.path}. Stop it first (docker compose stop hub-<name>), then adopt it.');
  }
  try {
    final hub = await _Hub.of(source);
    if (first != null && normalizeHostname(first.host) == name) throw StateError('$name is the first family\'s address.');
    if (HostState(data.path).logs.any((l) => l.hostname == name)) throw StateError('$name is a family\'s address on this host already.');

    // What the host holds now, from the running host, else from its directories.
    final running = await hostCall(port, data, 'GET', '/api/v1/host');
    final held = <({String? device, String? family, String? hostname})>[];
    if (running != null) {
      for (final f in (running.json['families'] as List?) ?? const []) {
        if (f is! Map) continue;
        final u = f['public_url'];
        held.add((device: f['device'] as String?, family: f['family'] as String?, hostname: u is String ? normalizeHostname(Uri.parse(u).host) : null));
      }
    } else {
      if (!data.exists) await data.keys();
      try {
        await data.lock();
      } on StateError {
        throw StateError('A host is running on ${data.path} but didn\'t answer on port $port. Give --port, or stop it first.');
      }
      try {
        final mine = await _Hub.of(data);
        held.add((device: mine.device, family: mine.family, hostname: first == null ? null : normalizeHostname(first.host)));
        for (final l in HostState(data.path).logs) {
          final dir = data.log(l.id);
          if (!dir.exists) continue;
          final other = await _Hub.of(dir);
          held.add((device: other.device, family: other.family, hostname: l.hostname));
        }
      } finally {
        await data.unlock();
      }
    }
    for (final h in held) {
      if (h.device == hub.device) throw StateError('This host serves that hub already.');
      if (hub.family != null && h.family == hub.family) throw StateError('This host serves that hub\'s family already (${h.hostname ?? 'the first family'}).');
      if (h.hostname == name) throw StateError('$name is a family\'s address on this host already.');
    }
    final state = HostState(data.path);
    final reuse = state.find(name);
    var id = hub.family != null && HostedLog.validId(hub.family!) ? hub.family! : HostedLog.newId();
    if (state.log(id) != null || data.log(id).exists) id = HostedLog.newId();
    final target = data.log(id);
    final files = await source.readBackup();

    io.out
      ..writeln(dry ? 'Would adopt:' : 'Adopting:')
      ..writeln('  from      ${source.path}')
      ..writeln('  family    ${hub.familyName ?? hub.family ?? 'none yet (waiting for setup)'}${hub.approved ? '' : ', not approved yet'}')
      ..writeln('  hub       ${hub.device} (keeps its keys, so phones keep syncing)')
      ..writeln('  changes   ${hub.changes}')
      ..writeln('  into      ${target.path}')
      ..writeln('  address   $url')
      ..writeln('  files     ${files.length}');
    if (reuse != null && reuse.removed) io.out.writeln('  (replacing the family that was at $name before, whose data stays in ${data.log(reuse.id).path})');
    if (dry) {
      io.out.writeln('Nothing changed (--dry-run).');
      return 0;
    }

    await target.writeFiles(files);
    // The copy is the family's hub now: check it before anything serves it.
    final copied = await _Hub.of(target);
    if (copied.device != hub.device || copied.changes != hub.changes) {
      await Directory(target.path).delete(recursive: true);
      throw StateError('The copy in ${target.path} didn\'t match ${source.path}; it was removed and nothing changed.');
    }
    final record = HostedLog(id: id, publicUrl: url, added: DateTime.now().toUtc().millisecondsSinceEpoch, adoptedFrom: from);
    if (running != null) {
      final r = await hostCall(port, data, 'POST', '/api/v1/host/logs', body: {'id': id, 'public_url': '$url', 'adopted_from': from});
      if (r == null || r.status != 201) {
        throw StateError('Copied into ${target.path}, but the host didn\'t take it on: '
            '${r == null ? 'it stopped' : _errorOf(r.json, r.status)}. Nothing serves the copy.');
      }
    } else {
      HostState(data.path).put(record);
    }
    _markMoved(source, data, id, io);
    io.out
      ..writeln()
      ..writeln(running != null ? 'The host serves $name now.' : 'The host serves $name from its next start.')
      ..writeln('Point $name at the host (its Caddy site at the host\'s port) and never start the old hub again:')
      ..writeln('its data stays in ${source.path}, untouched but for a note that makes it wait for a phone before')
      ..writeln('writing anything, should it start by mistake.');
    return 0;
  } finally {
    await source.unlock();
  }
}

/// The directory where [_moveAside] puts copies in `logs/` the host doesn't list.
const String _asideDir = 'logs-aside';

/// Moves `logs/<id>/` (a copy of a hub the host doesn't list) to `logs-aside/<id>-<time>/` in
/// the host's data directory, holding its lock so nothing has it open; returns where it went.
Future<String> _moveAside(DataDir data, String id) async {
  final copy = data.log(id);
  try {
    await copy.lock();
  } on StateError {
    throw StateError('${copy.path} is a copy of this hub that the host doesn\'t list, and something has it open. Stop that first.');
  }
  final to = [data.path, _asideDir, '$id-${DateTime.now().toUtc().millisecondsSinceEpoch}'].join(Platform.pathSeparator);
  try {
    Directory([data.path, _asideDir].join(Platform.pathSeparator)).createSync(recursive: true);
    Directory(copy.path).renameSync(to);
  } finally {
    await copy.unlock();
  }
  return to;
}

/// Leaves a note in the adopted hub's own directory: the restore marker, so that hub, if it ever
/// starts again, writes nothing of its own until a device of the family has synced with it (the
/// changes the host writes as that same hub are on the family's devices).
void _markMoved(DataDir source, DataDir data, String id, CliIo io) {
  try {
    final marker = source.file('hub/$restoreMarkerDoc.json');
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync(
      jsonEncode({'at': DateTime.now().toUtc().millisecondsSinceEpoch, 'adopted_into': Directory(data.path).absolute.path, 'id': id}),
      flush: true,
    );
    restrictToOwner(marker.path);
  } on Object {
    io.err.writeln('Couldn\'t leave a note in ${source.path}. Never start that hub again: the host is that hub now.');
  }
}

/// `den_hub remove-family --family den-smith.example.com`: the host stops serving that family.
/// Its data stays in `logs/<id>/` (add-family with the same address brings it back).
///
/// `--delete-data` deletes it too: for a family taken off already, by its address or id; for one
/// still on the host only with `--id` (`den_hub families` lists the ids), so a mistyped name never
/// deletes a family in use. With the host running, the host itself lets the family go and deletes
/// it, so its record goes everywhere at once.
Future<int> removeFamily(ArgResults a, DataDir data, int port, CliIo io) async {
  final family = (a['family'] as String?)?.trim();
  final givenId = (a['id'] as String?)?.trim();
  if ((family == null || family.isEmpty) && (givenId == null || givenId.isEmpty)) {
    throw CliUsage('--family is required: the family\'s address (or its id, or --id)');
  }
  final first = primaryUrl(data, io.environment);
  final name = family == null || family.isEmpty ? null : familyName(family);
  if (first != null && name != null && normalizeHostname(first.host) == name) {
    throw StateError('That\'s the first family, whose data is the host\'s own directory. It can\'t be removed.');
  }
  final state = HostState(data.path);
  final HostedLog? log;
  if (givenId != null && givenId.isNotEmpty) {
    log = state.log(givenId);
    if (log == null) throw StateError('No family on this host has the id $givenId. den_hub families lists them, with their ids.');
    if (family != null && family.isNotEmpty && family != givenId && log.hostname != name) {
      throw StateError('The family with the id $givenId is at ${log.hostname ?? '(no address)'}, not $family. Nothing changed.');
    }
  } else {
    log = state.find(family!) ?? (name == null ? null : state.find(name));
    if (log == null) {
      final gone = name == null ? const <HostedLog>[] : state.removedAt(name);
      throw StateError(gone.length > 1
          ? 'More than one family was taken off $name (${gone.map((l) => l.id).join(', ')}): give --id.'
          : 'There\'s no family at $family on this host. den_hub families lists them.');
    }
  }
  final label = log.hostname ?? log.id;
  final dir = data.log(log.id);
  final delete = a['delete-data'] == true;
  final byId = (givenId != null && givenId.isNotEmpty) || family == log.id;
  if (delete && !log.removed && !byId) {
    throw StateError('$label is still on this host, so its data isn\'t deleted by its address. Take it off first '
        '(den_hub remove-family --family $label), then delete its data; or give its id, --id ${log.id}, to do both. Nothing changed.');
  }
  if (log.removed && !delete) {
    io.out.writeln('The host doesn\'t serve $label already. Its data stays in ${dir.path}.');
    return 0;
  }
  final running = await hostCall(port, data, 'DELETE', '/api/v1/host/families/${log.id}${delete ? '?delete_data=1' : ''}');
  if (running != null) {
    if (running.status != 200) throw StateError(_errorOf(running.json, running.status));
  } else {
    // No host running: this is the only one changing the host's state.
    try {
      await data.lock();
    } on StateError {
      throw StateError('A host is running on ${data.path} but didn\'t answer on port $port. Give --port, or stop it first.');
    }
    try {
      final now = HostState(data.path);
      if (!log.removed) now.put(log.copyWith(removed: true));
      if (delete) {
        // Its own lock says no backup or restore has it open.
        if (Directory(dir.path).existsSync()) {
          await dir.lock();
          try {
            await Directory(dir.path).delete(recursive: true);
          } finally {
            await dir.unlock();
          }
        }
        now.forget(log.id);
      }
    } finally {
      await data.unlock();
    }
  }
  if (delete) {
    io.out.writeln('The host no longer serves $label, and its data is deleted.');
  } else {
    io.out.writeln('The host no longer serves $label. Its data stays in ${dir.path}: '
        'den_hub add-family --hostname $label brings the family back.');
  }
  return 0;
}

/// `den_hub families`: the families this host serves, at which address, from which directory.
Future<int> families(ArgResults a, DataDir data, int port, CliIo io) async {
  final running = await hostCall(port, data, 'GET', '/api/v1/host');
  final state = HostState(data.path);
  final first = primaryUrl(data, io.environment);
  // One line a family: its address, then `first` or `id <id>`, then how it is, then the rest.
  // install.sh reads the first three words, so keep them in this order.
  if (running != null) {
    final open = <String>{};
    for (final f in (running.json['families'] as List?) ?? const []) {
      if (f is! Map) continue;
      final id = f['id'] as String?;
      if (id != null) open.add(id);
      final where = id == null ? data.path : data.log(id).path;
      final what = f['ready'] == true ? 'in a family: ${f['family_name'] ?? f['family']}' : 'setup: ${f['stage']}';
      io.out.writeln('${f['public_url'] ?? '(no address)'}  ${id == null ? 'first' : 'id $id'}  $what  hub ${f['device']}  data $where');
    }
    final why = {
      for (final w in (running.json['waiting'] as List?) ?? const [])
        if (w is Map && w['id'] is String) w['id'] as String: (error: w['error'] as String?, retry: w['retry_seconds'] as int?),
    };
    for (final l in state.all) {
      if (open.contains(l.id)) continue;
      final w = why[l.id];
      final what = l.removed
          ? 'taken off'
          : 'not open: ${w?.error ?? 'starting'} (tried again every ${w?.retry ?? 30}s)';
      io.out.writeln('${l.publicUrl ?? '(no address)'}  id ${l.id}  $what  data ${data.log(l.id).path}');
    }
    return 0;
  }
  io.out.writeln('Not running. From ${data.path}/$hostStateDir/host.json:');
  io.out.writeln('${first ?? '(the first family, no address known)'}  first  data ${data.path}');
  for (final l in state.all) {
    io.out.writeln('${l.publicUrl ?? '(no address)'}  id ${l.id}  ${l.removed ? 'taken off' : 'served from the next start'}  data ${data.log(l.id).path}');
  }
  return 0;
}
