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

import 'cli.dart';
import 'data_dir.dart';

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
    if (accessForToken(den, token) == null) throw StateError('That token doesn\'t work. Make one in the Den app.');
    await serveMcpStdio(McpServer(ctx), () => accessForToken(den, token), io.input, io.out.writeln);
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
    final r = await client.post(
      hub.resolve('/mcp'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        'mcp-session-id': ?session,
      },
      body: line,
    );
    session = r.headers['mcp-session-id'] ?? session;
    if (r.statusCode == 202 || r.body.isEmpty) continue;
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

/// `den_hub setup-code`.
Future<int> setupCode(DataDir data, int port, CliIo io) async {
  final status = await _getJson(Uri.parse('http://127.0.0.1:$port/api/v1/hub/status'));
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

/// `den_hub status`.
Future<int> status(DataDir data, int port, CliIo io) async {
  final base = Uri.parse('http://127.0.0.1:$port');
  final health = await _getJson(base.resolve('/health'));
  if (health != null) {
    final setup = await _getJson(base.resolve('/api/v1/hub/status'));
    io.out.writeln('Running: ${health['name']} (${health['device']}), den_hub ${health['version']}');
    io.out.writeln(health['ready'] == true ? 'In a family and serving.' : 'Setup: ${setup?['stage'] ?? 'unknown'}');
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
    io.out.writeln(den.isApproved
        ? 'In a family: ${den.members.length} people, ${den.changesSince(const {}).length} changes.'
        : den.hasFamily
            ? 'Asked to join a family; not approved yet.'
            : 'Not in a family yet.');
    return 0;
  });
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
/// lock, so none starts halfway through.
Future<int> backup(ArgResults a, DataDir data, CliIo io) async {
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
const String restoreAdvice = 'Before anyone changes anything, start the hub and let the family\'s phones and tablets '
    'connect to it. What the hub wrote after this backup is still on them; the hub takes it back as they sync and '
    'carries on after it, instead of writing over it.';

/// `den_hub restore --in FILE --passphrase-env VAR [--force]`. Refuses while a hub runs on the
/// directory (stop it, then `docker compose run --rm hub restore ...`); with `--force` it first
/// removes the hub that is there, so nothing of it mixes with the one restored.
Future<int> restore(ArgResults a, DataDir data, CliIo io) async {
  final input = _required(a, 'in');
  final passphrase = _passphrase(a, io);
  if (data.exists && a['force'] != true) throw StateError('${data.path} already holds a hub. Use --force to replace it.');
  final Map<String, Object?> json;
  try {
    json = (jsonDecode(utf8.decode(await decryptBackup(await File(input).readAsBytes(), passphrase))) as Map).cast<String, Object?>();
  } on BackupException {
    throw StateError('That backup doesn\'t open with that passphrase.');
  }
  if (json['kind'] != 'den_hub') throw StateError('That isn\'t a den_hub backup.');
  try {
    await data.lock();
  } on StateError {
    throw StateError('A hub is running on ${data.path}. Stop it first (docker compose stop hub), then restore '
        '(docker compose run --rm hub restore ...).');
  }
  try {
    final files = (json['files'] as Map).cast<String, String>();
    if (data.exists) await data.clearForRestore();
    var written = 0;
    for (final e in files.entries) {
      if (!DataDir.backupPath(e.key)) continue;
      final f = data.file(e.key);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(base64.decode(e.value), flush: true);
      if (e.key == 'keys.json' || e.key.startsWith('hub/')) restrictToOwner(f.path);
      written++;
    }
    io.out.writeln('Restored $written files into ${data.path}.');
    io.out.writeln(restoreAdvice);
    return 0;
  } finally {
    await data.unlock();
  }
}
