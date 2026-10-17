/// Helpers for platforms with `dart:io`: LAN discovery of hubs over mDNS and serving the sync
/// protocol over WebSockets with shelf.
library;

import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'src/relay_protocol.dart';
import 'src/sync.dart';

/// The mDNS service type hubs advertise.
const String denServiceType = '_den._tcp';

/// A hub found on the local network.
class DiscoveredHub {
  /// Creates a record of one discovered hub.
  const DiscoveredHub({
    required this.instance,
    required this.host,
    required this.port,
    required this.addresses,
    this.deviceId,
    this.familyId,
    this.txt = const {},
  });

  /// The mDNS service instance name.
  final String instance;

  /// The SRV target host name.
  final String host;

  /// The SRV port (47733 by default).
  final int port;

  /// IPv4 addresses the host name resolved to.
  final List<InternetAddress> addresses;

  /// The hub's device id from the TXT record `id=`; pin it when connecting.
  final String? deviceId;

  /// The family id from the TXT record `f=`.
  final String? familyId;

  /// Every TXT key and value.
  final Map<String, String> txt;

  /// The hub's sync endpoint, `ws://<address>:<port>/ws`.
  Uri get syncUri => Uri(
        scheme: 'ws',
        host: addresses.isEmpty ? host : addresses.first.address,
        port: port,
        path: '/ws',
      );

  @override
  String toString() => 'DiscoveredHub($instance $host:$port id=$deviceId)';
}

/// Parses TXT record text (one `key=value` per line, as package:multicast_dns returns it).
/// Keys are lowercased; a key without `=` maps to an empty string.
Map<String, String> parseServiceTxt(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final eq = trimmed.indexOf('=');
    if (eq < 0) {
      out[trimmed.toLowerCase()] = '';
    } else if (eq > 0) {
      out[trimmed.substring(0, eq).toLowerCase()] = trimmed.substring(eq + 1);
    }
  }
  return out;
}

/// Looks for `_den._tcp` hubs on the LAN. Hubs advertise TXT keys `id` (device id), `f` (family
/// id) and `v` (protocol version). Returns what answered within roughly [timeout].
Future<List<DiscoveredHub>> discoverHubs({
  Duration timeout = const Duration(seconds: 3),
  MDnsClient? client,
}) async {
  final mdns = client ?? MDnsClient();
  await mdns.start();
  final found = <String, DiscoveredHub>{};
  try {
    final inner = timeout ~/ 2;
    await for (final ptr in mdns.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$denServiceType.local'),
      timeout: timeout,
    )) {
      final instance = ptr.domainName;
      if (found.containsKey(instance)) continue;
      final srvs = await mdns
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(instance), timeout: inner)
          .toList();
      if (srvs.isEmpty) continue;
      final srv = srvs.first;
      final txts = await mdns
          .lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance), timeout: inner)
          .toList();
      final txt = txts.isEmpty ? <String, String>{} : parseServiceTxt(txts.map((t) => t.text).join('\n'));
      final addresses = await mdns
          .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: inner)
          .map((r) => r.address)
          .toList();
      found[instance] = DiscoveredHub(
        instance: instance,
        host: srv.target,
        port: srv.port,
        addresses: addresses,
        deviceId: txt['id'],
        familyId: txt['f'],
        txt: txt,
      );
    }
  } finally {
    mdns.stop();
  }
  return found.values.toList();
}

/// A shelf handler that upgrades to a WebSocket and serves [node]'s sync protocol on it; mount
/// it at `/ws`.
Handler syncWebSocketHandler(SyncNode node, {Duration? pingInterval = const Duration(seconds: 30)}) =>
    webSocketHandler(
      (WebSocketChannel socket, String? _) => unawaited(node.serve(socket)),
      pingInterval: pingInterval,
    );

/// Serves [node] at `ws://<address>:<port>/ws` (port 0 picks a free one). For hubs that need
/// nothing else on the port, and for tests.
Future<HttpServer> serveSync(
  SyncNode node, {
  Object? address,
  int port = hubPort,
}) {
  final ws = syncWebSocketHandler(node);
  return shelf_io.serve(
    (Request request) {
      if (request.url.path == 'ws') return ws(request);
      if (request.url.path == 'health') return Response.ok('{"ok":true}', headers: {'content-type': 'application/json'});
      return Response.notFound('not found');
    },
    address ?? InternetAddress.anyIPv4,
    port,
  );
}
