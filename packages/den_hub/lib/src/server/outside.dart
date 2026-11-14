/// The outside world and the home network (docs/hub-api.md, "Inside and outside").
///
/// Inside the home (this machine, the home network, the family's tailnet, or a proxy on this
/// machine that forwards one of those) everything works as it always did. From outside (a
/// Cloudflare tunnel, a relay, a public address) the hub answers only devices of the family: a
/// request signed by one, a connection's token, a calendar link's secret, device sync, and what a
/// device needs to join with an invite. Everyone else gets an empty `404`: no app, no welcome
/// screen, nothing that says a Den is here.
///
/// A browser loads the app from outside only with a door pass: a cookie the hub gives a browser
/// that opened a working invite or setup link (for a day), and renews for a device of the family
/// that asks with a signed request (for [DoorPass.deviceLife]).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:den_net/den_net.dart' show DeviceRequest;
import 'package:shelf/shelf.dart';

import '../access.dart' show bearerToken;
import '../edge.dart';
import '../host.dart' show DenHost;
import '../host_state.dart';
import '../net_guard.dart' show isPublicAddress;
import '../setup.dart' show restrictToOwner;
import 'server_access.dart' show fromHomeNetwork;

/// Whether [request] came from inside the home: this machine, the home network or the family's
/// tailnet, directly or through a proxy on this machine (Tailscale Serve) or one the server
/// trusts, that forwards a home address. Anything a Cloudflare tunnel carries is outside, and so
/// is a request with no address at all (the relay's tunnel, another family's calendar link).
bool fromInside(Request request, List<IpNetwork> trusted) {
  if (request.context[inProcessClient] != null) return false;
  for (final name in request.headers.keys) {
    final n = name.toLowerCase();
    if (n.startsWith('cf-') || n == 'cdn-loop') return false;
  }
  if (DenHost.local(request) || fromHomeNetwork(request)) return true;
  final peer = peerAddress(request);
  if (peer == null) return false;
  if (!peer.isLoopback && !viaTrustedProxy(request, trusted)) return false;
  // The proxy's own hop is the right-most: whatever a client put before it is the client's word.
  final forwarded = request.headers['x-forwarded-for'];
  if (forwarded == null) return false;
  final hops = forwarded.split(',');
  final last = InternetAddress.tryParse(hops.last.trim());
  return last != null && !isPublicAddress(last);
}

/// What a request from outside may reach without a door pass: device sync, anything signed by a
/// device or carrying a connection's token (the family checks either), a calendar link, and what
/// a device needs to join, recover or sign in. [segments] is the path.
bool outsideMayAsk(Request request, List<String> segments) {
  final headers = request.headers;
  if (headers[DeviceRequest.device] != null && headers[DeviceRequest.signature] != null) return true;
  if (bearerToken(headers['authorization']) != null) return true;
  if (segments.isEmpty) return false;
  final first = segments.first;
  final path = segments.join('/');
  final method = request.method;
  if (path == 'ws') return true;
  if (first == 'ics' && segments.length == 3) return true;
  // Connecting an assistant (MCP with OAuth): a parent approves it on their phone.
  if (first == '.well-known' || first == 'oauth' || first == 'mcp') return true;
  // Signing in with Google or Apple, or a passkey: each proves who it is.
  if (first == 'auth') return true;
  if (path == 'api/v1/account/providers' || path.startsWith('api/v1/passkeys/sign-in')) return true;
  // Joining and recovering: each needs its words or code, and is counted when they are wrong.
  if (method == 'POST' && (path == 'api/v1/invites' || path == 'api/v1/invites/redeem' || path == 'api/v1/recovery/redeem')) {
    return true;
  }
  if (path.startsWith('api/v1/link/') || path == 'api/v1/link') return true;
  return false;
}

/// What a browser holding a door pass may load from outside besides [outsideMayAsk]: the app
/// itself, the hub's status the app asks for before it knows the family, and a fresh hub's setup
/// (which still needs its setup code from outside).
bool passMayLoad(Request request, List<String> segments) {
  if (segments.isEmpty) return true;
  if (!DenHost.reserved.contains(segments.first)) return true;
  final path = segments.join('/');
  if (request.method == 'GET' && path == 'api/v1/hub/status') return true;
  return path == 'api/v1/hub/setup' || path == 'api/v1/hub/setup/ws' || path.startsWith('api/v1/hub/first-boot');
}

/// What anyone may load from outside at an address a family lives at: the app itself and the
/// hub's status the app asks for before it knows the family. Joining, signing in and every bit
/// of the family's data still need their words, a device of the family or a token.
bool appForAnyone(Request request, List<String> segments) {
  if (segments.isEmpty) return true;
  if (!DenHost.reserved.contains(segments.first)) return true;
  return request.method == 'GET' && segments.join('/') == 'api/v1/hub/status';
}

/// What anyone may load from outside: the Home Screen icon and its manifest, which iOS and
/// Android fetch without cookies when someone adds Den to their Home Screen.
bool anyoneMayLoad(List<String> segments) {
  if (segments.isEmpty) return false;
  final first = segments.first;
  return segments.length == 1 && (first == 'manifest.json' || first == 'favicon.png') || first == 'icons';
}

/// The empty answer the outside gets for everything else.
Response nothingHere() => Response.notFound('', headers: {'cache-control': 'no-store', 'content-type': 'text/plain'});

/// The door pass: a cookie, signed with the host's own key, that lets a browser load the app
/// from outside until it expires. It proves nothing about who holds it; the family's data still
/// needs a device's signature.
class DoorPass {
  DoorPass._(this._key);

  /// The cookie.
  static const String cookieName = '__Host-den_pass';

  /// For a browser that opened a working invite or setup link: long enough to add Den to the
  /// Home Screen and join.
  static const Duration linkLife = Duration(days: 1);

  /// For a device of the family, renewed each time Den opens.
  static const Duration deviceLife = Duration(days: 90);

  static const String _file = 'door.key';

  final SecretKey _key;
  final Hmac _hmac = Hmac.sha256();

  /// The pass key in `<data>/host/door.key`, made the first time; with no data directory, one
  /// that lasts while the hub runs.
  static DoorPass open(String? dataDir) {
    final random = Random.secure();
    List<int> fresh() => List.generate(32, (_) => random.nextInt(256));
    if (dataDir == null) return DoorPass._(SecretKey(fresh()));
    final file = File([dataDir, 'host', _file].join(Platform.pathSeparator));
    if (file.existsSync()) {
      final bytes = base64Url.decode(file.readAsStringSync().trim());
      if (bytes.length == 32) return DoorPass._(SecretKey(bytes));
    }
    HostState.ownerOnlyDir(file.parent);
    final key = fresh();
    file.writeAsStringSync('${base64Url.encode(key)}\n', flush: true);
    restrictToOwner(file.path);
    return DoorPass._(SecretKey(key));
  }

  /// A `set-cookie` value for a pass that lasts [life] from [now] (UTC milliseconds).
  Future<String> cookie(Duration life, int now) async {
    final until = now + life.inMilliseconds;
    final body = until.toString();
    final mac = await _hmac.calculateMac(utf8.encode(body), secretKey: _key);
    final value = '$body.${base64Url.encode(mac.bytes).replaceAll('=', '')}';
    return '$cookieName=$value; Path=/; Max-Age=${life.inSeconds}; Secure; HttpOnly; SameSite=Lax';
  }

  /// Whether [request] carries a pass that is ours and hasn't expired at [now].
  Future<bool> admits(Request request, int now) async {
    final value = cookieValue(request, cookieName);
    if (value == null) return false;
    final dot = value.indexOf('.');
    if (dot <= 0) return false;
    final body = value.substring(0, dot);
    final until = int.tryParse(body);
    if (until == null || until <= now) return false;
    final mac = await _hmac.calculateMac(utf8.encode(body), secretKey: _key);
    final want = base64Url.encode(mac.bytes).replaceAll('=', '');
    final given = value.substring(dot + 1);
    if (given.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= want.codeUnitAt(i) ^ given.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// The value of the cookie [name] in [request], or null.
String? cookieValue(Request request, String name) {
  final header = request.headers['cookie'];
  if (header == null) return null;
  for (final part in header.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    if (part.substring(0, eq).trim() == name) return part.substring(eq + 1).trim();
  }
  return null;
}
