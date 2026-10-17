import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:den_net/relay_protocol.dart';
import 'package:den_relay/den_relay.dart';

Future<void> main(List<String> arguments) async {
  final env = Platform.environment;
  final parser = ArgParser()
    ..addOption('port', defaultsTo: env['DEN_RELAY_PORT'] ?? '$relayPort', help: 'Port to listen on (env DEN_RELAY_PORT).')
    ..addOption('host', defaultsTo: '0.0.0.0', help: 'Address to bind.')
    ..addOption('data-dir', defaultsTo: env['DEN_RELAY_DATA'] ?? 'data', help: 'Where mailboxes are stored (env DEN_RELAY_DATA).')
    ..addFlag('trust-proxy',
        negatable: false, help: 'Rate-limit by the last X-Forwarded-For entry (only behind a reverse proxy).')
    ..addFlag('healthcheck', negatable: false, help: 'Check a relay on --port at 127.0.0.1 and exit 0 if healthy.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }
  if (options.flag('help')) {
    stdout.writeln('den_relay: tunnels, mailboxes and pairing rendezvous for Den.\n');
    stdout.writeln(parser.usage);
    return;
  }
  final port = int.tryParse(options.option('port')!);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('--port must be a port number');
    exit(64);
  }
  if (options.flag('healthcheck')) {
    exit(await _healthy(port) ? 0 : 1);
  }

  final config = RelayConfig(dataDir: options.option('data-dir')!, trustProxy: options.flag('trust-proxy'));
  final relay = await RelayServer.start(config, address: options.option('host'), port: port);
  stdout.writeln('den_relay $relayVersion listening on ${options.option('host')}:${relay.port}');

  final stopping = Completer<void>();
  void stop(ProcessSignal _) {
    if (!stopping.isCompleted) stopping.complete();
  }

  final subscriptions = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen(stop),
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(stop),
  ];
  await stopping.future;
  for (final s in subscriptions) {
    await s.cancel();
  }
  await relay.close();
  stdout.writeln('den_relay stopped');
}

Future<bool> _healthy(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.get('127.0.0.1', port, '/health');
    final response = await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    return response.statusCode == 200;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}
