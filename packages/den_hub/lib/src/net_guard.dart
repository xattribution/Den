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

/// The hubs in [text] (`DEN_PEER_HUBS`): the other families' addresses on this server, separated
/// by spaces or commas, each a name (`den-smith.example.com`, meaning `https` on 443), a name and
/// port, or an `https://` address whose path is ignored. Only names: an IP address, `http`, or
/// anything that isn't an address is a [FormatException], so a typo can't let in more than meant.
List<Uri> parsePeerHubs(String text) {
  final hubs = <Uri>[];
  for (final word in text.split(RegExp(r'[\s,]+'))) {
    if (word.isEmpty) continue;
    final Uri uri;
    try {
      uri = Uri.parse(word.contains('://') ? word : 'https://$word');
    } on FormatException {
      throw FormatException('$word isn\'t an address like den-smith.example.com');
    }
    if (uri.scheme != 'https') throw FormatException('$word: only https addresses');
    if (uri.userInfo.isNotEmpty) throw FormatException('$word: no user name or password');
    final host = uri.host.toLowerCase();
    if (!_hostName.hasMatch(host) || InternetAddress.tryParse(host) != null) {
      throw FormatException('$word isn\'t a name like den-smith.example.com');
    }
    hubs.add(Uri(scheme: 'https', host: host, port: uri.port));
  }
  return hubs;
}

final RegExp _hostName = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]([a-z0-9-]*[a-z0-9])?$');

/// Fetches addresses callers give the hub (calendar feeds, OAuth client metadata documents)
/// without letting them reach the hub's own machine or network.
///
/// Each connection resolves its host once, refuses it when any answer isn't public (unless the
/// operator listed that network in [allow], `DEN_FETCH_ALLOW`), and connects to the address it
/// checked, so a name that answers differently a moment later (DNS rebinding) can't slip past.
/// Redirects open new connections and are checked the same way; TLS still verifies the
/// certificate for the name. Proxies from the environment are never used.
///
/// One exception, for calendars shared between families on one server: the [hubs] the operator
/// configured (the hub's own `DEN_PUBLIC_URL` and `DEN_PEER_HUBS`) may also lead to this
/// machine's loopback, where the server's reverse proxy answers for every family's address. Only
/// over `https`, only on the port the address names, and only those names: any other name, or
/// one of them over `http` or on another port, is judged like everything else, and an IP address
/// never counts as a hub. TLS still checks the certificate for the name, so whatever answers has
/// to hold that family's certificate. No other private address is let through this way.
class NetGuard {
  /// A guard resolving with [resolve] (default the system's) that also admits [allow], and
  /// loopback for [hubs] and whatever [moreHubs] gives at the time (a Den host's families'
  /// addresses, which change as families are added). [tls] replaces the system's trusted
  /// certificates (tests).
  NetGuard({
    HostResolver? resolve,
    List<IpNetwork> allow = const [],
    Iterable<Uri> hubs = const [],
    Iterable<Uri> Function()? moreHubs,
    this.lookupTimeout = const Duration(seconds: 10),
    SecurityContext? tls,
  })  : _resolve = resolve ?? systemResolver,
        _tls = tls,
        _moreHubs = moreHubs,
        allow = List.unmodifiable(allow),
        hubs = Set.unmodifiable(_origins(hubs));

  final HostResolver _resolve;
  final SecurityContext? _tls;
  final Iterable<Uri> Function()? _moreHubs;

  static Set<String> _origins(Iterable<Uri> hubs) => {
        for (final h in hubs)
          if (h.isScheme('https') && h.host.isNotEmpty && InternetAddress.tryParse(h.host) == null) _origin(h),
      };

  /// Networks the operator lets the hub fetch from although they aren't public (a calendar
  /// server at home).
  final List<IpNetwork> allow;

  /// The configured hubs' origins (`https://den-smith.example.com:443`), whose names may lead to
  /// loopback.
  final Set<String> hubs;

  /// How long a lookup may take.
  final Duration lookupTimeout;

  static String _origin(Uri uri) => 'https://${uri.host.toLowerCase()}:${uri.port}';

  /// Whether the hub may connect to [address].
  bool permits(InternetAddress address) => isPublicAddress(address) || allow.any((n) => n.contains(address));

  /// Whether [uri] is one of the configured [hubs] (or the host's families now): `https`, the
  /// same name, the same port.
  bool isHub(Uri uri) {
    if (!uri.isScheme('https')) return false;
    final origin = _origin(uri);
    if (hubs.contains(origin)) return true;
    final more = _moreHubs;
    return more != null && _origins(more()).contains(origin);
  }

  /// The one address to connect to for [host]: an IP literal as it is, else the first answer of
  /// a single lookup. Throws [BlockedAddress] when any answer isn't permitted, and
  /// [SocketException] when there is none. With [hub] (the connection is to one of [hubs]),
  /// loopback answers are permitted too, never for an IP literal.
  Future<InternetAddress> resolve(String host, {bool hub = false}) async {
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
    final named = hub && literal == null;
    for (final a in found) {
      if (permits(a) || (named && unmapped(a).isLoopback)) continue;
      throw BlockedAddress(host, '$host isn\'t on the public internet');
    }
    return found.first;
  }

  /// A `dart:io` client whose every connection goes through [resolve]. [connectTimeout] bounds
  /// connecting (TLS included).
  HttpClient httpClient({Duration connectTimeout = const Duration(seconds: 10)}) {
    final client = HttpClient(context: _tls)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = connectTimeout
      ..userAgent = 'den_hub';
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      final secure = uri.isScheme('https');
      if (!secure && !uri.isScheme('http')) throw BlockedAddress(uri.host, 'Only web addresses can be fetched');
      final address = await resolve(uri.host, hub: isHub(uri));
      final task = await Socket.startConnect(address, uri.port);
      if (!secure) return task;
      return ConnectionTask.fromSocket<Socket>(
        task.socket.then<Socket>((socket) => SecureSocket.secure(socket, host: uri.host, context: _tls)),
        task.cancel,
      );
    };
    return client;
  }

  /// [httpClient] as a `package:http` client.
  http.Client client({Duration connectTimeout = const Duration(seconds: 10)}) =>
      IOClient(httpClient(connectTimeout: connectTimeout));
}
