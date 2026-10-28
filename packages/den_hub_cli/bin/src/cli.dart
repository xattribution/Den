import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:den_hub/den_hub.dart';

import 'commands.dart';
import 'data_dir.dart';

/// Where a command writes, and what it reads (tests pass their own).
class CliIo {
  /// Creates the streams; defaults are the process's own.
  CliIo({Stream<List<int>>? input, StringSink? out, StringSink? err, Map<String, String>? environment})
      : input = input ?? stdin,
        out = out ?? stdout,
        err = err ?? stderr,
        environment = environment ?? Platform.environment;

  /// Standard input.
  final Stream<List<int>> input;

  /// Standard output.
  final StringSink out;

  /// Standard error, where logs go.
  final StringSink err;

  /// Environment variables.
  final Map<String, String> environment;
}

ArgParser _common(ArgParser p) => p
  ..addOption('data', help: 'Data directory (env DEN_DATA, default ./den-data)')
  ..addOption('port', help: 'Port (env DEN_PORT, default 47733)');

/// The argument parser for every command.
ArgParser cliParser() {
  final root = ArgParser()..addFlag('help', abbr: 'h', negatable: false);
  _common(root.addCommand('serve'))
    ..addOption('host', help: 'Address to bind (env DEN_HOST, default 0.0.0.0)')
    ..addOption('web', help: 'Static web build to serve at / (env DEN_WEB)')
    ..addOption('relay', help: 'Relay URL for a tunnel (env DEN_RELAY)')
    ..addOption('name', help: 'Hub name before it joins a family (env DEN_NAME)')
    ..addOption('ha-url', help: 'Home Assistant URL for notifications (env DEN_HA_URL)')
    ..addOption('ha-token', help: 'Home Assistant long-lived token (env DEN_HA_TOKEN)')
    ..addOption('public-url', help: 'Public base URL for OAuth and link codes (env DEN_PUBLIC_URL)')
    ..addOption('trusted-proxies',
        help: 'Reverse proxies whose X-Forwarded-* headers to believe, addresses or CIDRs (env DEN_TRUSTED_PROXIES)')
    ..addOption('csp', help: 'Replace the web app\'s Content-Security-Policy (env DEN_CSP)')
    ..addOption('log-level', help: 'debug, info, warn or error (env DEN_LOG)')
    ..addFlag('public',
        help: 'Reachable from the internet: minimal unauthenticated answers, mDNS off (env DEN_PUBLIC=1; '
            'default on for an https public URL)',
        defaultsTo: null)
    ..addFlag('mailbox', help: 'Also sync through the relay mailbox (env DEN_MAILBOX=1)', defaultsTo: null)
    ..addFlag('mdns', help: 'Advertise on the LAN (env DEN_MDNS=0 turns it off; off by default when public)', defaultsTo: null);
  _common(root.addCommand('mcp'))
    ..addOption('token', help: 'A token from the Den app (env DEN_TOKEN)')
    ..addOption('hub', help: 'A running hub to bridge to (default http://127.0.0.1:<port>)');
  _common(root.addCommand('import-sett')).addOption('as', help: 'The parent the import acts as (by name)');
  _common(root.addCommand('setup-code'));
  _common(root.addCommand('status'));
  _common(root.addCommand('backup'))
    ..addOption('out', help: 'Backup file to write')
    ..addOption('passphrase-env', help: 'Environment variable holding the passphrase');
  _common(root.addCommand('restore'))
    ..addOption('in', help: 'Backup file to read')
    ..addOption('passphrase-env', help: 'Environment variable holding the passphrase')
    ..addFlag('force', help: 'Replace an existing hub in the data directory', negatable: false);
  return root;
}

/// Runs `den_hub` with [args]; returns the exit code.
Future<int> runCli(List<String> args, {CliIo? io}) async {
  final cli = io ?? CliIo();
  final parser = cliParser();
  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    cli.err.writeln('${e.message}\n\n${_usage(parser)}');
    return 64;
  }
  if (parsed['help'] == true) {
    cli.out.writeln(_usage(parser));
    return 0;
  }
  final command = parsed.command ?? parser.commands['serve']!.parse(parsed.rest);
  final name = parsed.command?.name ?? 'serve';
  final env = cli.environment;
  final data = DataDir(command['data'] as String? ?? env['DEN_DATA'] ?? 'den-data');
  final port = int.tryParse(command['port'] as String? ?? env['DEN_PORT'] ?? '') ?? defaultHubPort;
  try {
    return switch (name) {
      'serve' => await serve(command, data, port, cli),
      'mcp' => await mcp(command, data, port, cli),
      'import-sett' => await importSett(command, data, cli),
      'setup-code' => await setupCode(data, port, cli),
      'status' => await status(data, port, cli),
      'backup' => await backup(command, data, cli),
      'restore' => await restore(command, data, cli),
      _ => 64,
    };
  } on StateError catch (e) {
    cli.err.writeln(e.message);
    return 1;
  } on CliUsage catch (e) {
    cli.err.writeln(e.message);
    return 64;
  }
}

String _usage(ArgParser parser) => [
      'den_hub: the Den hub.',
      '',
      'Commands:',
      '  serve (default)   Serve sync, the API, MCP, feeds and reminders',
      '  mcp --token T     MCP over standard input and output',
      '  import-sett DB --as NAME   Import a Sett coord.db as that parent',
      '  setup-code        Print a fresh hub\'s setup code',
      '  status            Say what the hub is doing',
      '  backup --out FILE --passphrase-env VAR',
      '  restore --in FILE --passphrase-env VAR [--force]',
      '',
      for (final e in parser.commands.entries) '${e.key}:\n${e.value.usage}\n',
    ].join('\n');

LogLevel _level(String? name) => LogLevel.values.firstWhere((l) => l.name == name, orElse: () => LogLevel.info);

Map<String, MemberNotify> _notify(DataDir data, Map<String, String> env) {
  String? text = env['DEN_NOTIFY'];
  final file = File('${data.path}${Platform.pathSeparator}notify.json');
  if (text == null && file.existsSync()) text = file.readAsStringSync();
  if (text == null || text.trim().isEmpty) return const {};
  final json = (jsonDecode(text) as Map).cast<String, Object?>();
  final members = (json['members'] as Map?)?.cast<String, Object?>() ?? json;
  return {
    for (final e in members.entries)
      if (e.value is Map) e.key: MemberNotify.fromJson((e.value as Map).cast<String, Object?>()),
  };
}

bool? _envFlag(String? v) => v == null ? null : !(v == '0' || v.toLowerCase() == 'false' || v.toLowerCase() == 'no');

/// `den_hub serve`.
Future<int> serve(ArgResults a, DataDir data, int port, CliIo io) async {
  final env = io.environment;
  String? opt(String name, String envName) => a[name] as String? ?? env[envName];
  final List<IpNetwork> proxies;
  try {
    proxies = IpNetwork.parseList(opt('trusted-proxies', 'DEN_TRUSTED_PROXIES') ?? '');
  } on FormatException catch (e) {
    throw CliUsage('DEN_TRUSTED_PROXIES: ${e.message}');
  }
  final public = opt('public-url', 'DEN_PUBLIC_URL');
  final publicUrl = public == null || public.isEmpty ? null : Uri.parse(public);
  final exposed = a['public'] as bool? ?? _envFlag(env['DEN_PUBLIC']);
  final publicPosture = exposed ?? (publicUrl?.scheme == 'https');
  await data.lock();
  final log = HubLog(level: _level(opt('log-level', 'DEN_LOG')), sink: io.err.writeln);
  final den = await data.open();
  final relay = opt('relay', 'DEN_RELAY');
  final ha = opt('ha-url', 'DEN_HA_URL');
  final hub = await DenHub.start(den, HubConfig(
    port: port,
    host: opt('host', 'DEN_HOST'),
    dataDir: data.path,
    webDir: opt('web', 'DEN_WEB'),
    relay: relay == null || relay.isEmpty ? null : Uri.parse(relay),
    name: opt('name', 'DEN_NAME') ?? 'Den hub',
    homeAssistantUrl: ha == null || ha.isEmpty ? null : Uri.parse(ha),
    homeAssistantToken: opt('ha-token', 'DEN_HA_TOKEN'),
    notify: _notify(data, env),
    publicUrl: publicUrl,
    allowedOrigins: [...?env['DEN_ALLOWED_ORIGINS']?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)],
    trustedProxies: proxies,
    public: exposed,
    contentSecurityPolicy: opt('csp', 'DEN_CSP'),
    mailbox: a['mailbox'] as bool? ?? _envFlag(env['DEN_MAILBOX']) ?? false,
    mdns: a['mdns'] as bool? ?? _envFlag(env['DEN_MDNS']) ?? !publicPosture,
    log: log,
  ));
  if (publicPosture && proxies.isEmpty) {
    log.warn('Running in the public posture with no DEN_TRUSTED_PROXIES: behind a reverse proxy, list it so '
        'limits count each client and the hub knows requests came over HTTPS.');
  }
  final done = Completer<void>();
  final signals = [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm];
  final subs = [for (final s in signals) s.watch().listen((_) => done.isCompleted ? null : done.complete())];
  await done.future;
  for (final s in subs) {
    await s.cancel();
  }
  await hub.stop();
  await den.close();
  await data.unlock();
  return 0;
}
