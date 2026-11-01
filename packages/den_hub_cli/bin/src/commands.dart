import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_hub/cli_support.dart';
import 'package:den_net/den_net.dart';
import 'package:den_sett_import/den_sett_import.dart';
import 'package:http/http.dart' as http;
import 'package:qr/qr.dart';

import 'cli.dart';
import 'data_dir.dart';
import 'host_commands.dart';

/// A command was called wrongly.
class CliUsage implements Exception {
  /// Creates the error.
  CliUsage(this.message);

  /// What to fix.
  final String message;
}

String _required(ArgResults a, String name) {
  final v = a[name] as String?;
  if (v == null || v.isEmpty) throw CliUsage('--$name is required');
  return v;
}

Future<Map<String, Object?>?> _getJson(Uri url) async {
  try {
    final r = await http.get(url).timeout(const Duration(seconds: 2));
    if (r.statusCode != 200) return null;
    return (jsonDecode(r.body) as Map).cast<String, Object?>();
  } on Object {
    return null;
  }
}

/// Opens [data] for a one-off command, holding the lock while [body] runs.
Future<T> _withDen<T>(DataDir data, Future<T> Function(Den den) body) async {
  if (!data.exists) throw StateError('There\'s no hub in ${data.path} yet. Run den_hub serve first.');
  await data.lock();
  try {
    final den = await data.open();
    try {
      return await body(den);
    } finally {
      await den.close();
    }
  } finally {
    await data.unlock();
  }
}

/// `den_hub mcp --token T`: bridges standard input and output to a running hub's `/mcp`, or,
/// with no hub running, serves MCP from the data directory itself.
Future<int> mcp(ArgResults a, DataDir data, int port, CliIo io) async {
  final token = a['token'] as String? ?? io.environment['DEN_TOKEN'];
  if (token == null || token.isEmpty) throw CliUsage('--token is required');
  final hub = Uri.parse(a['hub'] as String? ?? 'http://127.0.0.1:$port');
  if (await _getJson(hub.resolve('/health')) != null) return _bridge(hub, token, io);
  return _withDen(data, (den) async {
    if (!den.hasFamily || !den.isApproved) throw StateError('This hub isn\'t part of a family yet.');
    final ctx = HubContext(
      den: den,
      gate: DenGate(den),
      config: HubConfig(dataDir: data.path, mdns: false),
      log: HubLog(level: LogLevel.warn, sink: io.err.writeln),
      state: HubState(data.path),
      node: SyncNode(den),
      http: http.Client(),
    );
    if (ctx.access(token) == null) throw StateError('That token doesn\'t work. Make one in the Den app.');
    await serveMcpStdio(McpServer(ctx), () => ctx.access(token), io.input, io.out.writeln);
    await ctx.node.close();
    ctx.http.close();
    return 0;
  });
}

Future<int> _bridge(Uri hub, String token, CliIo io) async {
  final client = http.Client();
  String? session;
  await for (final line in io.input.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      message = null;
    }
    // A 2026-07-28 request names itself in headers too; an earlier one rides its session.
    final modern = mcpRequestHeaders(message);
    if (modern['mcp-method'] == 'subscriptions/listen' && message is Map) {
      // The bridge handles one request at a time, so it can't hold a stream open: acknowledge
      // nothing and end the subscription, as the hub's own stdio server does.
      final id = message['id'];
      io.out.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/subscriptions/acknowledged',
        'params': {
          '_meta': {McpMeta.subscriptionId: id},
          'notifications': <String, Object?>{},
        },
      }));
      io.out.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'resultType': 'complete',
          '_meta': {McpMeta.subscriptionId: id},
        },
      }));
      continue;
    }
    final r = await client.post(
      hub.resolve('/mcp'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        ...modern,
        if (modern.isEmpty) 'mcp-session-id': ?session,
      },
      body: line,
    );
    if (modern.isEmpty) session = r.headers['mcp-session-id'] ?? session;
    if (r.statusCode == 202 || r.body.isEmpty) continue;
    if ((r.headers['content-type'] ?? '').startsWith('text/event-stream')) {
      // A stream's messages, one per event, as stdio carries them.
      for (final l in const LineSplitter().convert(r.body)) {
        if (l.startsWith('data:')) io.out.writeln(l.substring(5).trim());
      }
      continue;
    }
    io.out.writeln(r.body.trim());
  }
  client.close();
  return 0;
}

/// `den_hub import-sett <coord.db> --as <parent>`.
Future<int> importSett(ArgResults a, DataDir data, CliIo io) async {
  if (a.rest.length != 1) throw CliUsage('Give the path to Sett\'s coord.db');
  final path = a.rest.single;
  if (!File(path).existsSync()) throw StateError('There\'s no file at $path');
  final name = _required(a, 'as');
  if (data.file('hub/$restoreMarkerDoc.json').existsSync()) {
    throw StateError('$catchingUpStatus Then stop the hub and import.');
  }
  return _withDen(data, (den) async {
    if (!den.isApproved) throw StateError('This hub isn\'t part of a family yet.');
    final parent = den.members.where((m) => m.name.toLowerCase() == name.toLowerCase()).firstOrNull;
    if (parent == null || !parent.isParent) {
      final parents = den.members.where((m) => m.isParent).map((m) => m.name).join(', ');
      throw StateError('"$name" isn\'t a parent in this family. Parents: $parents');
    }
    den.actAs(parent.id, via: 'Sett import', window: const Duration(hours: 2));
    try {
      final report = await importSettDatabase(path, den);
      io.out.writeln(report);
    } finally {
      den.actAs(null);
    }
    return 0;
  });
}

/// `den_hub setup-code [--family ADDRESS]`.
Future<int> setupCode(FamilyTarget target, int port, CliIo io) async {
  final data = target.data;
  final status = await getJsonAt(Uri.parse('http://127.0.0.1:$port/api/v1/hub/status'), target.hostname);
  if (status != null && status['paired'] == true) {
    io.out.writeln('This hub is already part of a family.');
    return 0;
  }
  final file = File('${data.path}${Platform.pathSeparator}hub${Platform.pathSeparator}setup-code');
  if (status == null || !file.existsSync()) {
    io.err.writeln('No fresh hub is running here. Start it with den_hub serve; it prints its setup code.');
    return 1;
  }
  io.out.writeln(file.readAsStringSync().trim());
  return 0;
}

/// `den_hub setup-link [--url U]`: for a fresh hub, the one-time link that starts the family on
/// the first parent's phone with nothing to type and no words to compare, as text and as a QR
/// code to scan with the phone's camera, with the setup code to type when the link can't be
/// used. The link carries the setup code (the hub knows the phone by it) and the hub's device
/// id (the phone knows the hub by it), in the fragment, which browsers never send. Its address
/// is `--url` or `DEN_PUBLIC_URL`, which the compose files set; on a Den host, `--family` names
/// another family by its address.
///
/// With `--bare` (what `deploy/install.sh` runs) it prints only the link, on the first line, and
/// its QR code under it, so the installer can say the rest in its own words; it exits 3 for a
/// hub that is already in a family and 1 when there is no link to print.
Future<int> setupLinkCommand(ArgResults a, FamilyTarget target, int port, CliIo io) async {
  final data = target.data;
  final bare = a['bare'] as bool? ?? false;
  final status = await getJsonAt(Uri.parse('http://127.0.0.1:$port/api/v1/hub/status'), target.hostname);
  if (status != null && status['paired'] == true) {
    if (bare) return 3;
    io.out.writeln('This hub is already part of a family. Invite people from the Den app.');
    return 0;
  }
  final file = File('${data.path}${Platform.pathSeparator}hub${Platform.pathSeparator}setup-code');
  final device = status?['device'];
  if (status == null || device is! String || !file.existsSync()) {
    io.err.writeln('No fresh hub is running here. Start it with den_hub serve; it prints its setup code.');
    return 1;
  }
  final code = file.readAsStringSync().trim();
  final url = a['url'] as String? ?? (target.first ? io.environment['DEN_PUBLIC_URL'] : target.publicUrl?.toString());
  final base = url == null || url.isEmpty ? null : Uri.tryParse(url);
  if (base == null || !base.hasScheme || base.host.isEmpty) {
    if (bare) {
      io.err.writeln("No address for the link: add --url (the hub's address).");
      return 1;
    }
    io.out.writeln('Setup code: $code');
    io.out.writeln("Add --url https://den.example.com (the hub's address) for a link to open on the phone.");
    return 0;
  }
  if (bare) {
    final link = setupLink(base, code, device).toString();
    io.out
      ..writeln(link)
      ..writeln(terminalQr(link));
    return 0;
  }
  printSetupLink(io, base, code, device);
  return 0;
}

/// [text] as a QR code for a terminal: two rows of modules per line in half blocks, black on
/// white whatever the terminal's colors, with a quiet zone around it.
String terminalQr(String text) {
  final qr = QrImage(QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.L));
  const quiet = 2;
  final size = qr.moduleCount;
  bool dark(int x, int y) => x >= 0 && y >= 0 && x < size && y < size && qr.isDark(y, x);
  final out = StringBuffer();
  for (var y = -quiet; y < size + quiet; y += 2) {
    out.write('  \x1b[30;47m');
    for (var x = -quiet; x < size + quiet; x++) {
      final top = dark(x, y), bottom = dark(x, y + 1);
      out.write(top && bottom ? '█' : top ? '▀' : bottom ? '▄' : ' ');
    }
    out.writeln('\x1b[0m');
  }
  return out.toString().trimRight();
}

/// `den_hub open-linking [--minutes N]`: in the public posture, browsers may ask the hub for a
/// link code only while a parent has "Add a device" open; this opens it from the server itself
/// (`docker compose exec hub /app/bin/den_hub open-linking`), for N minutes (default 10, at
/// most 60). The running hub reads `hub/link-open`; nothing else changes.
Future<int> openLinking(ArgResults a, FamilyTarget target, CliIo io) async {
  final data = target.data;
  if (!data.exists) throw StateError('There\'s no hub in ${data.path} yet. Run den_hub serve first.');
  final minutes = int.tryParse(a['minutes'] as String? ?? '10');
  if (minutes == null || minutes < 1 || minutes > 60) throw CliUsage('--minutes must be from 1 to 60');
  final until = DateTime.now().toUtc().add(Duration(minutes: minutes));
  final file = data.file('hub/$linkOpenFile');
  await file.parent.create(recursive: true);
  await file.writeAsString('${until.millisecondsSinceEpoch}\n', flush: true);
  restrictToOwner(file.path);
  io.out.writeln('Browsers can ask to link to this hub until ${until.toIso8601String()} (UTC). '
      'Open the hub\'s address on the phone, choose Link this browser, and scan its code from a parent\'s phone.');
  return 0;
}

/// What `den_hub status` adds while the hub waits for a device after a restore.
const String catchingUpStatus = 'Catching up after a restore: the hub writes nothing of its own until a phone or '
    'tablet in the family has synced with it. Open Den on one.';

/// `den_hub status [--family ADDRESS]`.
Future<int> status(FamilyTarget target, int port, CliIo io) async {
  final data = target.data;
  final base = Uri.parse('http://127.0.0.1:$port');
  final probe = await probeAt(base.resolve('/health'), target.hostname);
  final catchingUp = data.file('hub/$restoreMarkerDoc.json').existsSync();
  if (probe != null && probe.status == 503) {
    // A host still opening this family (or every family, at no family's address).
    final waiting = await waitingOn(target, port);
    io.out.writeln(waiting?.error != null
        ? 'Running, but ${target.label} isn\'t open: ${waiting!.error} The host tries it again every ${waiting.retry}s.'
        : 'Running, but ${target.label} isn\'t open yet: the host is starting it, or tries it again shortly. '
            'docker compose logs hub says why.');
    return 0;
  }
  final health = probe?.json;
  if (health != null) {
    final setup = await getJsonAt(base.resolve('/api/v1/hub/status'), target.hostname);
    // In the public posture /health leaves out the name, device and version, and a hub in a
    // family says even less in its status: print what it does say.
    final name = health['name'] ?? setup?['name'];
    final device = health['device'] ?? setup?['device'];
    final who = [if (name != null) '$name', if (device != null) '($device)'].join(' ');
    io.out.writeln('Running: ${who.isEmpty ? '' : '$who, '}den_hub ${health['version'] ?? setup?['version'] ?? hubVersion}');
    io.out.writeln(switch (setup?['stage']) {
      _ when health['ready'] == true => 'In a family and serving.',
      'removed' => '${setup?['removed'] ?? 'This hub was removed from the family; reset it to add it again'}.',
      final stage => 'Setup: ${stage ?? 'unknown'}',
    });
    if (catchingUp) io.out.writeln(catchingUpStatus);
    final words = setup?['matching_words'];
    if (words is List && words.isNotEmpty) {
      io.out.writeln('Matching words: ${words.join(' ')} (approve this hub in the Den app only if it shows the same three)');
    }
    return 0;
  }
  if (!data.exists) {
    io.out.writeln('Not running, and there\'s no hub in ${data.path} yet.');
    return 1;
  }
  return _withDen(data, (den) async {
    io.out.writeln('Not running. Device ${den.deviceId}, den_hub $hubVersion.');
    final removed = removedNotice(den);
    io.out.writeln(den.isApproved
        ? 'In a family: ${den.members.length} people, ${den.changesSince(const {}).length} changes.'
        : removed != null
            ? '$removed.'
            : den.hasFamily
                ? 'Asked to join a family; not approved yet.'
                : 'Not in a family yet.');
    if (catchingUp) io.out.writeln(catchingUpStatus);
    return 0;
  });
}

/// `den_hub recover --person NAME`: a parent lost their phone and no other parent device is
/// left to let a new one in. Prints a one-time link and four words, good for one phone for 30
/// minutes, that let the new phone in as that parent, but only if the family turned on "Let
/// the hub help us get back in"; otherwise it says how. With Docker:
/// `docker compose exec hub /app/bin/den_hub recover --person "Alex"`. A running hub makes the
/// code (the command shows it the secret the hub left in `hub/recovery-cli`); with none running
/// the command makes it in the data directory, for the hub to honor when it starts.
Future<int> recover(ArgResults a, FamilyTarget target, int port, CliIo io) async {
  final data = target.data;
  final person = _required(a, 'person');
  if (!data.exists) throw StateError('There\'s no hub in ${data.path} yet. Run den_hub serve first.');
  final base = Uri.parse('http://127.0.0.1:$port');
  final Map<String, Object?> ticket;
  if (await probeAt(base.resolve('/health'), null) != null) {
    final file = data.file('hub/$recoveryCliFile');
    if (!file.existsSync()) {
      throw StateError('The hub running on port $port didn\'t leave its recovery secret in ${data.path}. '
          'Is --data the hub\'s data directory? An older hub needs updating and restarting first.');
    }
    final http.Response r;
    try {
      r = await http
          .post(
            base.resolve('/api/v1/recovery/tickets'),
            headers: {'content-type': 'application/json', 'x-den-recovery-secret': file.readAsStringSync().trim()},
            body: jsonEncode({'person': person}),
          )
          .timeout(const Duration(seconds: 10));
    } on Object {
      throw StateError('Couldn\'t reach the hub on port $port. Is it still starting?');
    }
    final json = _object(r.body);
    if (r.statusCode != 201) {
      final error = json?['error'];
      final message = error is Map ? error['message'] : null;
      throw StateError(message is String ? message : 'The hub said no (HTTP ${r.statusCode}).');
    }
    ticket = json!;
  } else {
    ticket = await _withDen(data, (den) async {
      final public = target.first ? io.environment['DEN_PUBLIC_URL'] : target.publicUrl?.toString();
      final ctx = HubContext(
        den: den,
        gate: DenGate(den),
        config: HubConfig(
          dataDir: data.path,
          mdns: false,
          publicUrl: public == null || public.isEmpty ? null : Uri.parse(public),
        ),
        log: HubLog(level: LogLevel.error, sink: io.err.writeln),
        state: HubState(data.path),
        node: SyncNode(den),
        http: http.Client(),
      );
      try {
        return (await HubRecovery.offline(ctx).issue(person)).toJson();
      } on RecoveryRefused catch (e) {
        throw StateError(e.message);
      } finally {
        await ctx.state.flush();
        await ctx.node.close();
        ctx.http.close();
      }
    });
  }
  final name = ticket['member_name'];
  final words = ((ticket['words'] as List?) ?? const []).join(' ');
  final link = ticket['link'];
  final until = DateTime.tryParse('${ticket['expires']}')?.toUtc();
  final at = until == null ? '' : ' (until ${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')} UTC)';
  io.out.writeln('A recovery code for $name is ready. It lets in one phone, for the next 30 minutes$at.');
  io.out.writeln();
  if (link is String) {
    io.out.writeln('Send $name this link to open on the new phone:');
    io.out.writeln('  $link');
    io.out.writeln();
    io.out.writeln('Or, in Den on the new phone, choose "I lost my phone" and type these four words:');
  } else {
    io.out.writeln('On the new phone, open Den at the hub\'s address, choose "I lost my phone" and type these four words:');
  }
  io.out.writeln('  $words');
  io.out.writeln();
  io.out.writeln('Every device in the family will show that $name\'s new phone was let in by the hub.');
  return 0;
}

Map<String, Object?>? _object(String text) {
  try {
    final json = jsonDecode(text);
    return json is Map ? json.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

String _passphrase(ArgResults a, CliIo io) {
  final variable = _required(a, 'passphrase-env');
  final value = io.environment[variable];
  if (value == null || value.length < 8) throw StateError('Set $variable to a passphrase of 8 characters or more.');
  return value;
}

/// `den_hub backup --out FILE --passphrase-env VAR`: keys, the change log, the hub's own state
/// and `notify.json`, sealed. Works while the hub runs (`docker compose exec hub
/// /app/bin/den_hub backup ...`): [DataDir.readBackup] reads in an order that is consistent
/// while the hub writes, so it doesn't need the hub's lock. With no hub running it holds the
/// lock, so none starts halfway through. On a Den host, `--family ADDRESS` backs up that family
/// alone, from its own directory; without it, the first family.
Future<int> backup(ArgResults a, FamilyTarget target, CliIo io) async {
  final data = target.data;
  final out = _required(a, 'out');
  final passphrase = _passphrase(a, io);
  if (!data.exists) throw StateError('There\'s no hub in ${data.path} to back up.');
  var locked = false;
  try {
    await data.lock();
    locked = true;
  } on StateError {
    io.err.writeln('The hub is running; backing it up as it runs.');
  }
  try {
    final files = await data.readBackup();
    final sealed = await encryptBackup(
      utf8.encode(jsonEncode({
        'v': 1,
        'kind': 'den_hub',
        'files': {for (final e in files.entries) e.key: base64.encode(e.value)},
      })),
      passphrase,
    );
    await File(out).writeAsBytes(sealed, flush: true);
    restrictToOwner(out);
    io.out.writeln('Backed up ${files.length} files to $out. Keep a copy somewhere other than this machine.');
    return 0;
  } finally {
    if (locked) await data.unlock();
  }
}

/// What a restore says once it has written the files.
const String restoreAdvice = 'Start the hub, then open Den on a phone or tablet in the family. What the hub wrote '
    'after this backup is still on the family\'s devices, so until one of them has synced with it the hub writes '
    'nothing of its own: calendar feeds wait, and apps and assistants are told to try again shortly. '
    '`den_hub status` says when it has caught up.';

/// `den_hub restore --in FILE --passphrase-env VAR [--force]`. Refuses while a hub runs on the
/// directory (stop it, then `docker compose run --rm hub restore ...`); with `--force` it first
/// removes the hub that is there, so nothing of it mixes with the one restored. On a Den host,
/// `--family ADDRESS` restores that family alone, into its own directory (a family the host
/// doesn't know yet, as on a new server, is added at that address); the host must be stopped,
/// since it holds every family's data.
Future<int> restore(ArgResults a, DataDir root, CliIo io) async {
  final input = _required(a, 'in');
  final passphrase = _passphrase(a, io);
  final family = a['family'] as String?;
  final known = family == null ? familyTarget(root, null, io.environment) : null;
  if (known != null && known.data.exists && a['force'] != true) {
    throw StateError('${known.data.path} already holds a hub. Use --force to replace it.');
  }
  final Map<String, Object?> json;
  try {
    json = (jsonDecode(utf8.decode(await decryptBackup(await File(input).readAsBytes(), passphrase))) as Map).cast<String, Object?>();
  } on BackupException {
    throw StateError('That backup doesn\'t open with that passphrase.');
  }
  if (json['kind'] != 'den_hub') throw StateError('That isn\'t a den_hub backup.');
  try {
    await root.lock();
  } on StateError {
    throw StateError('A hub is running on ${root.path}. Stop it first (docker compose stop hub), then restore '
        '(docker compose run --rm hub restore ...).');
  }
  final DataDir data;
  try {
    data = (known ?? familyTarget(root, family, io.environment, register: true)).data;
    if (known == null && data.exists && a['force'] != true) {
      throw StateError('${data.path} already holds a hub. Use --force to replace it.');
    }
  } catch (_) {
    await root.unlock();
    rethrow;
  }
  try {
    final files = (json['files'] as Map).cast<String, String>();
    // A backup goes back to its own family: never over another family's place on this host, with
    // that family's hub still in its own.
    final keys = files['keys.json'];
    final device = keys == null ? null : await deviceInKeys(base64.decode(keys));
    final elsewhere = device == null ? null : await hubElsewhere(root, data, device, primaryUrl(root, io.environment));
    if (elsewhere != null) {
      throw StateError('That backup is of the hub of $elsewhere on this host, not of the family it would replace. '
          'Restore it with --family set to that family\'s address.');
    }
    if (data.exists) await data.clearForRestore();
    final written = await data.writeFiles({for (final e in files.entries) e.key: base64.decode(e.value)});
    // The hub writes nothing of its own until a device of the family has synced with it.
    final marker = data.file('hub/$restoreMarkerDoc.json');
    await marker.parent.create(recursive: true);
    await marker.writeAsString(
      jsonEncode({'at': DateTime.now().toUtc().millisecondsSinceEpoch, 'from': File(input).uri.pathSegments.last}),
      flush: true,
    );
    restrictToOwner(marker.path);
    io.out.writeln('Restored $written files into ${data.path}.');
    io.out.writeln(restoreAdvice);
    return 0;
  } finally {
    await root.unlock();
  }
}
