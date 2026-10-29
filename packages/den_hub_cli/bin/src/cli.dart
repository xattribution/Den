import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:den_hub/den_hub.dart';

import 'commands.dart';
import 'data_dir.dart';
import 'host_commands.dart';

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

ArgParser _family(ArgParser p) =>
    p..addOption('family', help: 'On a host with several families: which, by its address (den-smith.example.com)');

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
    ..addOption('fetch-allow',
        help: 'Private networks calendar feeds may be fetched from, addresses or CIDRs (env DEN_FETCH_ALLOW)')
    ..addOption('peer-hubs',
        help: 'The other families\' hubs on this server, whose shared calendars may be fetched through this '
            'machine\'s own reverse proxy: https addresses or names (env DEN_PEER_HUBS)')
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
  _family(_common(root.addCommand('setup-code')));
  _family(_common(root.addCommand('setup-link'))).addOption('url', help: "The hub's address, https://den.example.com (env DEN_PUBLIC_URL)");
  _family(_common(root.addCommand('open-linking'))).addOption('minutes', help: 'How long browsers may ask to link (default 10)');
  _family(_common(root.addCommand('status')));
  _family(_common(root.addCommand('recover')))
      .addOption('person', help: 'The parent who lost their phone, by their name in Den (in quotes if it has a space)');
  _family(_common(root.addCommand('backup')))
    ..addOption('out', help: 'Backup file to write')
    ..addOption('passphrase-env', help: 'Environment variable holding the passphrase');
  _family(_common(root.addCommand('restore')))
    ..addOption('in', help: 'Backup file to read')
    ..addOption('passphrase-env', help: 'Environment variable holding the passphrase')
    ..addFlag('force', help: 'Replace an existing hub in the data directory', negatable: false);
  _common(root.addCommand('add-family'))
    ..addOption('hostname', help: "The new family's own address, den-smith.example.com")
    ..addOption('url', help: 'Its address with a scheme and port, when not https on 443')
    ..addOption('id', help: 'Which family to bring back, when more than one was taken off the address');
  _common(root.addCommand('adopt'))
    ..addOption('hostname', help: "The family's own address, den-smith.example.com (its old DEN_PUBLIC_URL)")
    ..addOption('url', help: 'Its address with a scheme and port, when not https on 443')
    ..addFlag('dry-run', help: 'Say what it would do, and change nothing', negatable: false);
  _family(_common(root.addCommand('remove-family')))
    ..addOption('id', help: 'The family by its id (den_hub families lists them): needed to delete the data of a family still on the host')
    ..addFlag('delete-data', help: "Delete the family's data too", negatable: false);
  _common(root.addCommand('families'));
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
  FamilyTarget target() => familyTarget(data, command['family'] as String?, env);
  try {
    return switch (name) {
      'serve' => await serve(command, data, port, cli),
      'mcp' => await mcp(command, data, port, cli),
      'import-sett' => await importSett(command, data, cli),
      'setup-code' => await setupCode(target(), port, cli),
      'setup-link' => await setupLinkCommand(command, target(), port, cli),
      'open-linking' => await openLinking(command, target(), cli),
      'status' => await status(target(), port, cli),
      'recover' => await recover(command, target(), port, cli),
      'backup' => await backup(command, target(), cli),
      'restore' => await restore(command, data, cli),
      'add-family' => await addFamily(command, data, port, cli),
      'adopt' => await adopt(command, data, port, cli),
      'remove-family' => await removeFamily(command, data, port, cli),
      'families' => await families(command, data, port, cli),
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
      '  setup-link [--url U]   A link and QR code that start the family on the first parent\'s phone',
      '  open-linking      Let browsers ask to link to a public hub for 10 minutes',
      '  status            Say what the hub is doing',
      '  recover --person NAME   A one-time link and four words that let a parent\'s new phone in',
      '                    (only if the family turned on "Let the hub help us get back in")',
      '  backup --out FILE --passphrase-env VAR',
      '  restore --in FILE --passphrase-env VAR [--force]',
      '',
      'One host, several families (each at its own address, with its own keys and data):',
      '  add-family --hostname ADDRESS   Another family on this host; prints its setup link',
      '  adopt DIR --hostname ADDRESS [--dry-run]   Move a hub that ran on its own onto this host;',
      '                    it keeps its keys, so its phones keep syncing',
      '  remove-family --family ADDRESS   Take a family off this host; its data stays',
      '  remove-family --id ID --delete-data   ... and delete its data (or --family ADDRESS of one taken off)',
      '  families          The families this host serves',
      '  --family ADDRESS  on setup-code, setup-link, open-linking, status, recover, backup and',
      '                    restore: that family (the first family without it)',
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

/// `den_hub serve`: the Den host over the data directory. The first family is the one in the
/// directory itself, as a hub's always was; each other family `den_hub add-family` or `adopt`
/// put on the host is in `logs/<id>/`, at its own address, and served alongside.
Future<int> serve(ArgResults a, DataDir data, int port, CliIo io) async {
  final host = await openHost(a, data, port, io);
  final done = Completer<void>();
  final signals = [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm];
  final subs = [for (final s in signals) s.watch().listen((_) => done.isCompleted ? null : done.complete())];
  await done.future;
  for (final s in subs) {
    await s.cancel();
  }
  await host.stop();
  return 0;
}

/// Starts the Den host [serve] runs, over [data], holding its lock and each family's until the
/// host stops ([DenHost.stop] releases them). A family whose data won't open is logged and left
/// out, and the others are served.
Future<DenHost> openHost(ArgResults a, DataDir data, int port, CliIo io) async {
  final env = io.environment;
  String? opt(String name, String envName) => a[name] as String? ?? env[envName];
  final List<IpNetwork> proxies;
  try {
    proxies = IpNetwork.parseList(opt('trusted-proxies', 'DEN_TRUSTED_PROXIES') ?? '');
  } on FormatException catch (e) {
    throw CliUsage('DEN_TRUSTED_PROXIES: ${e.message}');
  }
  final List<IpNetwork> fetchAllow;
  try {
    fetchAllow = IpNetwork.parseList(opt('fetch-allow', 'DEN_FETCH_ALLOW') ?? '');
  } on FormatException catch (e) {
    throw CliUsage('DEN_FETCH_ALLOW: ${e.message}');
  }
  final List<Uri> peerHubs;
  try {
    peerHubs = parsePeerHubs(opt('peer-hubs', 'DEN_PEER_HUBS') ?? '');
  } on FormatException catch (e) {
    throw CliUsage('DEN_PEER_HUBS: ${e.message}');
  }
  final public = opt('public-url', 'DEN_PUBLIC_URL');
  final publicUrl = public == null || public.isEmpty ? null : Uri.parse(public);
  final exposed = a['public'] as bool? ?? _envFlag(env['DEN_PUBLIC']);
  final publicPosture = exposed ?? (publicUrl?.scheme == 'https');
  final relay = opt('relay', 'DEN_RELAY');
  final ha = opt('ha-url', 'DEN_HA_URL');
  final bind = opt('host', 'DEN_HOST');
  final web = opt('web', 'DEN_WEB');
  final csp = opt('csp', 'DEN_CSP');
  final mailbox = a['mailbox'] as bool? ?? _envFlag(env['DEN_MAILBOX']) ?? false;
  final allowedOrigins = [...?env['DEN_ALLOWED_ORIGINS']?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)];
  final log = HubLog(level: _level(opt('log-level', 'DEN_LOG')), sink: io.err.writeln);

  /// A family's hub: the first family's as `serve` always made it; another family's at its own
  /// address, labeled in the log, with its own notify.json, and without mDNS and Home Assistant
  /// (which are the first family's home's).
  HubConfig configFor(DataDir dir, {Uri? address, HostedLog? hosted}) => HubConfig(
        port: port,
        host: bind,
        dataDir: dir.path,
        webDir: web,
        relay: relay == null || relay.isEmpty ? null : Uri.parse(relay),
        name: opt('name', 'DEN_NAME') ?? 'Den hub',
        homeAssistantUrl: hosted != null || ha == null || ha.isEmpty ? null : Uri.parse(ha),
        homeAssistantToken: hosted == null ? opt('ha-token', 'DEN_HA_TOKEN') : null,
        notify: _notify(dir, hosted == null ? env : const {}),
        publicUrl: address,
        allowedOrigins: allowedOrigins,
        trustedProxies: proxies,
        fetchAllow: fetchAllow,
        peerHubs: peerHubs,
        public: exposed,
        contentSecurityPolicy: csp,
        mailbox: mailbox,
        mdns: hosted == null ? a['mdns'] as bool? ?? _envFlag(env['DEN_MDNS']) ?? !publicPosture : false,
        log: hosted == null ? log : log.labeled(hosted.hostname ?? hosted.id),
      );

  Future<HostedTenant> openLog(HostedLog hosted, {required bool fresh}) async {
    final dir = data.log(hosted.id);
    if (!fresh && !dir.exists) throw StateError('There\'s no hub in ${dir.path}');
    await dir.lock();
    try {
      final den = await dir.open();
      return (
        den: den,
        config: configFor(dir, address: hosted.publicUrl, hosted: hosted),
        close: () async {
          await den.close();
          await dir.unlock();
        },
      );
    } catch (_) {
      await dir.unlock();
      rethrow;
    }
  }

  await data.lock();
  var handedOver = false;
  try {
    final host = await DenHost.start(HostConfig(
      port: port,
      host: bind,
      dataDir: data.path,
      webDir: web,
      trustedProxies: proxies,
      contentSecurityPolicy: csp,
      log: log,
      fetchAllow: fetchAllow,
      peerHubs: peerHubs,
      openLog: (l) => openLog(l, fresh: false),
      createLog: (l) => openLog(l, fresh: true),
      // remove-family --delete-data, once the host has let the family go: its own lock says no
      // backup or restore has it open.
      deleteLog: (l) async {
        final dir = data.log(l.id);
        if (!Directory(dir.path).existsSync()) return;
        await dir.lock();
        try {
          await Directory(dir.path).delete(recursive: true);
        } finally {
          await dir.unlock();
        }
      },
      // One family answers at any address while host.json lists no other, as a hub always has.
      single: true,
      // Until the first family is attached, its address answers 503, never another family.
      expected: [?publicUrl?.host],
      // A family that doesn't open is tried again this often (DEN_HOST_RETRY, seconds).
      retryInterval: Duration(seconds: int.tryParse(env['DEN_HOST_RETRY'] ?? '')?.clamp(1, 3600) ?? 30),
    ));
    try {
      final den = await data.open();
      try {
        await host.add(den, configFor(data, address: publicUrl), onClosed: () async {
          await den.close();
          await data.unlock();
        });
        handedOver = true;
      } catch (_) {
        await den.close();
        rethrow;
      }
      // Every other family host.json lists; one that doesn't open is tried again, and its address
      // answers 503 until it does (den_hub families says why).
      await host.openConfigured();
    } catch (_) {
      await host.stop();
      rethrow;
    }
    if (host.tenants.length > 1) {
      log.info('Serving ${host.tenants.length} families: '
          '${[for (final t in host.tenants) t.config.publicUrl?.host ?? '(the first, with no address)'].join(', ')}');
    }
    if (publicPosture && proxies.isEmpty) {
      log.warn('Running in the public posture with no DEN_TRUSTED_PROXIES: behind a reverse proxy, list it so '
          'limits count each client and the hub knows requests came over HTTPS.');
    }
    return host;
  } finally {
    if (!handedOver) await data.unlock();
  }
}
