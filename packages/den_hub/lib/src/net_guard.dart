import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'edge.dart' show IpNetwork, unmapped;

/// Looks a host name up: the system's resolver, or a fake one in tests.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// The system's resolver.
Future<List<InternetAddress>> systemResolver(String host) => InternetAddress.lookup(host);

/// The hub refused to connect to an address a caller gave it: it is on this machine, the home
/// network, a carrier's private network or a cloud's metadata service, not the public internet.
class BlockedAddress implements IOException {
  /// A refusal to reach [host].
  const BlockedAddress(this.host, this.message);

  /// The name or address that was asked for.
  final String host;

  /// Why, for the log (never shown with the address it resolved to).
  final String message;

  @override
  String toString() => 'BlockedAddress: $message';
}

final List<IpNetwork> _blockedV4 = [
  for (final n in const [
    '0.0.0.0/8', // "this network"
    '10.0.0.0/8', // private
    '100.64.0.0/10', // carrier-grade NAT (and Alibaba's metadata service, 100.100.100.200)
    '127.0.0.0/8', // loopback
    '169.254.0.0/16', // link-local (and the clouds' metadata service, 169.254.169.254)
    '172.16.0.0/12', // private
    '192.0.0.0/24', // IETF protocol assignments
    '192.0.2.0/24', // documentation
    '192.88.99.0/24', // 6to4 relays
    '192.168.0.0/16', // private
    '198.18.0.0/15', // benchmarking
    '198.51.100.0/24', // documentation
    '203.0.113.0/24', // documentation
    '224.0.0.0/4', // multicast
    '240.0.0.0/4', // reserved, and broadcast
  ])
    IpNetwork.parse(n),
];

/// Global unicast IPv6; everything outside it (loopback, unspecified, link-local `fe80::/10`,
/// unique local `fc00::/7` with AWS's metadata address, multicast, discard) is refused.
final IpNetwork _globalV6 = IpNetwork.parse('2000::/3');

/// Inside [_globalV6] but not the public internet.
final List<IpNetwork> _blockedV6 = [
  for (final n in const [
    '2001::/23', // IETF protocol assignments, Teredo among them
    '2001:db8::/32', // documentation
    '3fff::/20', // documentation
  ])
    IpNetwork.parse(n),
];

/// IPv6 forms that carry an IPv4 address, which is what gets checked.
final IpNetwork _nat64 = IpNetwork.parse('64:ff9b::/96');
final IpNetwork _sixToFour = IpNetwork.parse('2002::/16');

/// Whether [address] is on the public internet: not loopback, private (RFC 1918), link-local,
/// carrier-grade NAT, unique local IPv6, a metadata service, multicast, documentation or
/// otherwise reserved. IPv4 inside IPv6 (mapped, NAT64, 6to4) is judged as the IPv4 it carries.
bool isPublicAddress(InternetAddress address) {
  if (address.type == InternetAddressType.unix) return false;
  final a = unmapped(address);
  final raw = a.rawAddress;
  if (raw.length == 4) return !_blockedV4.any((n) => n.contains(a));
  if (_nat64.contains(a)) return isPublicAddress(InternetAddress.fromRawAddress(raw.sublist(12)));
  if (_sixToFour.contains(a)) return isPublicAddress(InternetAddress.fromRawAddress(raw.sublist(2, 6)));
  if (!_globalV6.contains(a)) return false;
  return !_blockedV6.any((n) => n.contains(a));
}

/// Fetches addresses callers give the hub (calendar feeds, OAuth client metadata documents)
/// without letting them reach the hub's own machine or network.
///
/// Each connection resolves its host once, refuses it when any answer isn't public (unless the
/// operator listed that network in [allow], `DEN_FETCH_ALLOW`), and connects to the address it
/// checked, so a name that answers differently a moment later (DNS rebinding) can't slip past.
/// Redirects open new connections and are checked the same way; TLS still verifies the
/// certificate for the name. Proxies from the environment are never used.
class NetGuard {
  /// A guard resolving with [resolve] (default the system's) that also admits [allow].
  NetGuard({HostResolver? resolve, List<IpNetwork> allow = const [], this.lookupTimeout = const Duration(seconds: 10)})
      : _resolve = resolve ?? systemResolver,
        allow = List.unmodifiable(allow);

  final HostResolver _resolve;

  /// Networks the operator lets the hub fetch from although they aren't public (a calendar
  /// server on the home network).
  final List<IpNetwork> allow;

  /// How long a lookup may take.
  final Duration lookupTimeout;

  /// Whether the hub may connect to [address].
  bool permits(InternetAddress address) => isPublicAddress(address) || allow.any((n) => n.contains(address));

  /// The one address to connect to for [host]: an IP literal as it is, else the first answer of
  /// a single lookup. Throws [BlockedAddress] when any answer isn't permitted, and
  /// [SocketException] when there is none.
  Future<InternetAddress> resolve(String host) async {
    final bare = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
    final literal = InternetAddress.tryParse(bare);
    final List<InternetAddress> found;
    if (literal != null) {
      found = [literal];
    } else {
      try {
        found = await _resolve(bare).timeout(lookupTimeout);
      } on TimeoutException {
        throw SocketException('Looking up $bare took too long');
      }
    }
    if (found.isEmpty) throw SocketException('$bare has no address');
    for (final a in found) {
      if (!permits(a)) throw BlockedAddress(host, '$host isn\'t on the public internet');
    }
    return found.first;
  }

  /// A `dart:io` client whose every connection goes through [resolve]. [connectTimeout] bounds
  /// connecting (TLS included).
  HttpClient httpClient({Duration connectTimeout = const Duration(seconds: 10)}) {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = connectTimeout
      ..userAgent = 'den_hub';
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      final secure = uri.isScheme('https');
      if (!secure && !uri.isScheme('http')) throw BlockedAddress(uri.host, 'Only web addresses can be fetched');
      final address = await resolve(uri.host);
      final task = await Socket.startConnect(address, uri.port);
      if (!secure) return task;
      return ConnectionTask.fromSocket<Socket>(
        task.socket.then<Socket>((socket) => SecureSocket.secure(socket, host: uri.host)),
        task.cancel,
      );
    };
    return client;
  }

  /// [httpClient] as a `package:http` client.
  http.Client client({Duration connectTimeout = const Duration(seconds: 10)}) =>
      IOClient(httpClient(connectTimeout: connectTimeout));
}
