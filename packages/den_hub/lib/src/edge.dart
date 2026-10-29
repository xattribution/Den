/// What the hub knows and enforces about where a request came from: the client's address
/// (through trusted reverse proxies only) and per-client rate limits for everything a stranger
/// can reach. (WebSocket messages are bounded by den_net's `boundedWebSocketHandler`.)
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

/// An IP network in CIDR notation (`172.30.73.0/24`, `fd00::/8`), or one address.
class IpNetwork {
  /// A network of [address] bytes (4 or 16) and a [prefix] length in bits.
  IpNetwork(List<int> address, this.prefix) : address = Uint8List.fromList(address);

  /// Reads `10.0.0.0/8`, `::1` or `192.168.1.5`. Throws [FormatException].
  factory IpNetwork.parse(String text) {
    final t = text.trim();
    final slash = t.indexOf('/');
    final host = slash < 0 ? t : t.substring(0, slash);
    final a = InternetAddress.tryParse(host);
    if (a == null) throw FormatException('"$text" isn\'t an IP address or network');
    final bits = a.rawAddress.length * 8;
    final prefix = slash < 0 ? bits : int.tryParse(t.substring(slash + 1));
    if (prefix == null || prefix < 0 || prefix > bits) throw FormatException('"$text" has a bad prefix length');
    return IpNetwork(a.rawAddress, prefix);
  }

  /// Reads a comma- or space-separated list (`DEN_TRUSTED_PROXIES`). Throws [FormatException].
  static List<IpNetwork> parseList(String text) =>
      [for (final part in text.split(RegExp(r'[\s,]+'))) if (part.isNotEmpty) IpNetwork.parse(part)];

  /// The network's address bytes.
  final Uint8List address;

  /// How many leading bits must match.
  final int prefix;

  /// Whether [a] is in this network. IPv4-mapped IPv6 addresses (`::ffff:10.0.0.1`) count as
  /// IPv4.
  bool contains(InternetAddress a) {
    final raw = unmapped(a).rawAddress;
    if (raw.length != address.length) return false;
    var left = prefix;
    for (var i = 0; i < raw.length && left > 0; i++) {
      final take = left >= 8 ? 8 : left;
      final mask = (0xff << (8 - take)) & 0xff;
      if ((raw[i] & mask) != (address[i] & mask)) return false;
      left -= take;
    }
    return true;
  }

  @override
  String toString() => '${InternetAddress.fromRawAddress(address).address}/$prefix';
}

/// [a] as IPv4 when it is an IPv4-mapped IPv6 address, else [a].
InternetAddress unmapped(InternetAddress a) {
  final raw = a.rawAddress;
  if (raw.length != 16) return a;
  for (var i = 0; i < 10; i++) {
    if (raw[i] != 0) return a;
  }
  if (raw[10] != 0xff || raw[11] != 0xff) return a;
  return InternetAddress.fromRawAddress(raw.sublist(12));
}

/// The address of the peer that opened [request]'s connection (the proxy, behind one), or null
/// when the server can't tell (requests made in tests without a socket).
InternetAddress? peerAddress(Request request) {
  final info = request.context['shelf.io.connection_info'];
  return info is HttpConnectionInfo ? unmapped(info.remoteAddress) : null;
}

/// Whether [request] came through one of the [trusted] reverse proxies, so its `X-Forwarded-*`
/// headers say where it really came from.
bool viaTrustedProxy(Request request, List<IpNetwork> trusted) {
  if (trusted.isEmpty) return false;
  final peer = peerAddress(request);
  return peer != null && trusted.any((n) => n.contains(peer));
}

/// The client [request] came from: the peer, or, when the peer is a [trusted] proxy, the
/// right-most `X-Forwarded-For` hop that isn't itself a trusted proxy. Headers from anyone else
/// are ignored, so a client can't pick its own address to dodge a limit.
InternetAddress? clientAddress(Request request, List<IpNetwork> trusted) {
  final peer = peerAddress(request);
  if (peer == null || !viaTrustedProxy(request, trusted)) return peer;
  final forwarded = request.headers['x-forwarded-for'];
  if (forwarded == null) return peer;
  var client = peer;
  for (final hop in forwarded.split(',').reversed) {
    final a = _hopAddress(hop.trim());
    if (a == null) break;
    client = a;
    if (!trusted.any((n) => n.contains(a))) break;
  }
  return client;
}

InternetAddress? _hopAddress(String hop) {
  final direct = InternetAddress.tryParse(hop);
  if (direct != null) return unmapped(direct);
  // `[2001:db8::1]:443` or `203.0.113.7:51234`.
  final bracket = RegExp(r'^\[([^\]]+)\](?::\d+)?$').firstMatch(hop);
  if (bracket != null) {
    final a = InternetAddress.tryParse(bracket[1]!);
    return a == null ? null : unmapped(a);
  }
  final colon = hop.lastIndexOf(':');
  if (colon > 0 && hop.indexOf(':') == colon) {
    final a = InternetAddress.tryParse(hop.substring(0, colon));
    return a == null ? null : unmapped(a);
  }
  return null;
}

/// The key a client's limits are counted under: its IPv4 address, or its IPv6 /64 (one home or
/// one phone network hands out a whole /64). `unknown` when there is no address.
String clientKey(InternetAddress? a) {
  if (a == null) return 'unknown';
  final raw = a.rawAddress;
  if (raw.length == 4) return a.address;
  final b = StringBuffer();
  for (var i = 0; i < 8; i++) {
    b.write(raw[i].toRadixString(16).padLeft(2, '0'));
    if (i.isOdd && i < 7) b.write(':');
  }
  return '$b::/64';
}

/// A budget: up to [burst] at once, refilled at [burst] per [per].
class Rate {
  /// Creates a rate.
  const Rate(this.burst, this.per);

  /// Most allowed in a burst.
  final int burst;

  /// How long the bucket takes to refill completely.
  final Duration per;
}

/// The limits on what a stranger can do, per client (see [clientKey]).
abstract final class Limits {
  /// Every request without a token or a device signature: health, status, the web app's files,
  /// OAuth metadata and polling.
  static const Rate anonymous = Rate(600, Duration(minutes: 1));

  /// Requests with a token or signature that didn't check out; past this the client gets 429.
  static const Rate failures = Rate(30, Duration(minutes: 5));

  /// Browser link slots and grants.
  static const Rate pairing = Rate(20, Duration(minutes: 10));

  /// New OAuth client registrations.
  static const Rate oauthRegister = Rate(10, Duration(hours: 1));

  /// New OAuth sign-in requests.
  static const Rate oauthAuthorize = Rate(10, Duration(minutes: 15));

  /// OAuth token requests.
  static const Rate oauthToken = Rate(60, Duration(minutes: 5));

  /// New WebSocket connections (device sync).
  static const Rate sockets = Rate(120, Duration(minutes: 1));

  /// WebSocket connections open at once from one client.
  static const int openSockets = 64;
}

/// Wrong guesses at a short code (an invite's four words, a recovery code), counted per client
/// (see [clientKey]) and for everyone together. Each client gets [perClient] in [window]; all
/// clients together get [ceiling], far more than one client's share, so no one address can use
/// up the guesses and keep the family from joining or getting back in, while the codes' 44 bits
/// stay out of reach of everyone at once.
class WrongGuesses {
  /// Counts wrong guesses.
  WrongGuesses({required this.perClient, required this.ceiling, required this.window, this.maxClients = 10000});

  /// Wrong guesses one client may make in [window].
  final int perClient;

  /// Wrong guesses all clients together may make in [window].
  final int ceiling;

  /// How long a wrong guess counts.
  final Duration window;

  /// Most clients remembered; past it, the quietest are forgotten first.
  final int maxClients;

  final Map<String, List<int>> _byClient = {};
  final List<int> _all = [];

  void _prune(int now) {
    final horizon = now - window.inMilliseconds;
    _all.removeWhere((at) => at <= horizon);
    _byClient.removeWhere((_, times) {
      times.removeWhere((at) => at <= horizon);
      return times.isEmpty;
    });
    while (_byClient.length > maxClients) {
      _byClient.remove(_byClient.keys.first);
    }
  }

  int _seconds(int until, int now) => max(1, ((until - now) / 1000).ceil());

  /// Seconds [client] must wait before guessing again, and whether that is everyone's wait
  /// (`all`); null when it may guess now.
  ({int seconds, bool all})? wait(String client, int now) {
    _prune(now);
    final mine = _byClient[client];
    if (mine != null && mine.length >= perClient) {
      return (seconds: _seconds(mine.first + window.inMilliseconds, now), all: false);
    }
    if (_all.length >= ceiling) return (seconds: _seconds(_all.first + window.inMilliseconds, now), all: true);
    return null;
  }

  /// Counts a wrong guess from [client].
  void add(String client, int now) {
    _prune(now);
    // Taken out and put back, so the clients heard from longest ago come first.
    final times = _byClient.remove(client) ?? <int>[];
    _byClient[client] = times..add(now);
    _all.add(now);
  }
}

class _Bucket {
  _Bucket(this.tokens, this.at);
  double tokens;
  int at;
}

/// Token buckets per client and purpose. Memory is bounded: past [maxKeys] buckets, full ones
/// (clients that went quiet) are dropped first, then the oldest.
class RateLimiter {
  /// Creates a limiter; [now] is for tests.
  RateLimiter({int Function()? now, this.maxKeys = 20000}) : _now = now ?? _wall;

  static int _wall() => DateTime.now().millisecondsSinceEpoch;

  final int Function() _now;

  /// Most buckets kept.
  final int maxKeys;

  final Map<String, _Bucket> _buckets = {};

  _Bucket _bucket(String name, String key, Rate rate) {
    final id = '$name|$key';
    final now = _now();
    final b = _buckets.remove(id) ?? _Bucket(rate.burst.toDouble(), now);
    final refill = (now - b.at) * rate.burst / rate.per.inMilliseconds;
    b
      ..tokens = min(rate.burst.toDouble(), b.tokens + refill)
      ..at = now;
    _buckets[id] = b;
    if (_buckets.length > maxKeys) _prune();
    return b;
  }

  void _prune() {
    final now = _now();
    _buckets.removeWhere((_, b) => now - b.at > const Duration(hours: 2).inMilliseconds);
    while (_buckets.length > maxKeys) {
      _buckets.remove(_buckets.keys.first);
    }
  }

  /// Takes one from [key]'s [name] bucket; false when it is empty.
  bool allow(String name, String key, Rate rate) {
    final b = _bucket(name, key, rate);
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }

  /// Whether [key]'s [name] bucket is empty, without taking from it.
  bool exhausted(String name, String key, Rate rate) => _bucket(name, key, rate).tokens < 1;

  /// Seconds until [key]'s [name] bucket has one again (at least 1).
  int retryAfter(String name, String key, Rate rate) {
    final b = _bucket(name, key, rate);
    if (b.tokens >= 1) return 1;
    final ms = (1 - b.tokens) * rate.per.inMilliseconds / rate.burst;
    return max(1, (ms / 1000).ceil());
  }
}
