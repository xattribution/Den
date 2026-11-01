import 'dart:convert';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';

import 'body.dart';
import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'http_util.dart';

/// A kitchen screen waiting for a parent to type its code (`/api/v1/screens`).
class _Waiting {
  _Waiting({
    required this.slot,
    required this.secret,
    required this.pubkey,
    required this.xpub,
    required this.name,
    required this.kind,
    required this.tag,
    required this.client,
    required this.expires,
  });

  final String slot;

  /// What only the screen that asked knows; it asks how things stand with it.
  final String secret;

  /// The screen's device key and sealing key, bound to its code by [tag].
  final String pubkey;
  final String xpub;
  final String name;
  final String kind;
  final String tag;

  /// Whom it was made for, for the share each client has.
  final String client;

  /// UTC milliseconds.
  int expires;

  /// The parent's device that took the code, once one has: the only one that goes on with it.
  String? acceptedBy;

  /// What that phone said to join with: family, founder, hub, name and its tag.
  Map<String, Object?>? accepted;

  /// The screen's own signed join request, once it sent it, for the parent's phone to write
  /// into the family's log with its approval. The hub never writes it.
  Map<String, Object?>? change;

  String get device => deviceIdOf(pubkey)!;
}

/// Kitchen screens that join with a short code a parent types on their own phone
/// (ARCHITECTURE.md, "Pairing", "Kitchen screen code").
///
/// The hub only carries messages between the screen and the parent's phone. Nothing it keeps
/// lets anyone in: the screen writes its own join request and the parent's phone approves it,
/// as with any shared display, by den_core's rules.
///
/// 1. The screen, opened at the family's address, makes its keys, picks a code (den_net's
///    [ScreenCode]) and sends `POST /api/v1/screens/code` with the code's slot, its device key,
///    sealing key, name, kind and the code's tag over them. The hub answers a secret for it.
/// 2. A parent types the code; their phone sends the slot, signed (`POST /api/v1/screens/find`),
///    and checks the tag before it shows "Add Kitchen iPad as a kitchen screen?".
/// 3. On Add, the phone sends what the screen joins with and its own tag over it
///    (`POST /api/v1/screens/accept`); from then on only that phone goes on with the code.
/// 4. The screen reads it (`POST /api/v1/screens/code/status`), checks the tag, writes its join
///    request (unapproved, shared, nobody's) and sends it (`POST /api/v1/screens/code/join`).
/// 5. The phone fetches it (`POST /api/v1/screens/request`), checks it is the key the parent
///    saw, writes it into the family's log with its approval, and syncs both to the hub.
/// 6. The screen, waiting on the hub, syncs as a shared display.
///
/// Waiting screens live in memory only, for [lifetime], at most [maxWaiting] for the family and
/// [maxPerClient] for one client. Codes are the family's: a code is found only among the
/// screens that asked at this family's address, so a parent of another family on the same host
/// finds nothing, the same as for a wrong code. Wrong codes count, [maxWrong] per client and
/// [wrongCeiling] for the whole family in [wrongWindow], after which the hub stops looking.
/// Neither the code, nor its slot, nor the secret goes in the log.
class ScreenCodes {
  /// Creates the screen-code endpoints for [hub]; [auth] checks the parent's signed requests.
  ScreenCodes(this.hub, this.auth) : clock = hub.now;

  /// Shared hub context.
  final HubContext hub;

  /// Checks signed requests from the family's devices.
  final DeviceAuth auth;

  /// UTC milliseconds now: the hub's clock, which tests move on to see codes run out.
  int Function() clock;

  /// How long a code works.
  static const Duration lifetime = ScreenCode.life;

  /// How long the screen and the phone have to finish once a parent took the code.
  static const Duration finishing = Duration(minutes: 5);

  /// Most screens waiting for the family at once.
  static const int maxWaiting = 20;

  /// Most screens waiting from one client at once.
  static const int maxPerClient = 3;

  /// Wrong codes one client may try in [wrongWindow].
  static const int maxWrong = 10;

  /// Wrong codes everyone together may try for this family in [wrongWindow]. Against at most
  /// [maxWaiting] codes of 40 bits, that is one chance in about a billion a window.
  static const int wrongCeiling = 50;

  /// How long wrong codes count.
  static const Duration wrongWindow = Duration(minutes: 10);

  final Map<String, _Waiting> _waiting = {};
  final Random _random = Random.secure();
  final WrongGuesses _wrong = WrongGuesses(perClient: maxWrong, ceiling: wrongCeiling, window: wrongWindow);

  /// Adds the routes.
  void register(Routes routes) {
    routes
      ..add('POST', '/api/v1/screens/code', (r, _) => create(r))
      ..add('POST', '/api/v1/screens/code/status', (r, _) => status(r))
      ..add('POST', '/api/v1/screens/code/join', (r, _) => join(r))
      ..add('POST', '/api/v1/screens/find', (r, _) => find(r))
      ..add('POST', '/api/v1/screens/accept', (r, _) => accept(r))
      ..add('POST', '/api/v1/screens/request', (r, _) => requestOf(r));
  }

  /// How many screens are waiting, for tests and status.
  int get waiting {
    _prune();
    return _waiting.length;
  }

  void _prune() {
    final now = clock();
    _waiting.removeWhere((_, w) => w.expires <= now);
  }

  String _token(int bytes) => b64e(List.generate(bytes, (_) => _random.nextInt(256)));

  static ApiError _expired() =>
      ApiError.notFound(type: 'screen', message: 'This code ran out. Get a new one on the screen.');

  static ApiError _wrongCode() =>
      ApiError.notFound(type: 'screen', message: "That code isn't right, or it ran out. Check the code on the screen and try again.");

  static String _slot(Body b) {
    final slot = b.string('slot', required: true, max: 64)!;
    if (!ScreenCode.isSlot(slot)) throw ApiError.invalid("That isn't a screen code's slot.", field: 'slot');
    return slot;
  }

  /// The screen [b] names with its secret; `404` (counted as a failed try) otherwise.
  _Waiting _screenOf(Request request, Body b) {
    final slot = _slot(b);
    final secret = b.string('secret', required: true, max: 64)!;
    _prune();
    final w = _waiting[slot];
    if (w == null || !_same(secret, w.secret)) {
      hub.failed(request);
      throw _expired();
    }
    return w;
  }

  /// `POST /api/v1/screens/code {slot, pubkey, xpub, name, kind, tag}`, from a screen with no
  /// family: keeps it waiting for [lifetime]. Answers `201 {secret, expires, expires_ms}`.
  Future<Response> create(Request request) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.limit(request, 'pairing', Limits.pairing, message: 'Too many codes from here. Wait a few minutes, then try again.');
    final b = Body(await readJsonObject(request, required: true));
    final slot = _slot(b);
    final pubkey = b.string('pubkey', required: true, max: 64)!;
    final xpub = b.string('xpub', required: true, max: 64)!;
    final name = b.string('name', required: true, min: 1, max: 60)!.trim();
    final kind = b.string('kind', required: true, max: 20)!;
    final tag = b.string('tag', required: true, max: 64)!;
    final device = deviceIdOf(pubkey);
    if (device == null) throw ApiError.invalid("That isn't a device key.", field: 'pubkey');
    final known = DeviceKind.values.asNameMap()[kind];
    if (known == null || known == DeviceKind.hub) throw ApiError.invalid("That isn't a kind of screen.", field: 'kind');
    if (hub.den.device(device) != null) {
      throw ApiError(409, 'conflict', 'This screen asked to join before. Start over on it to get a new code.');
    }
    _prune();
    final client = hub.clientOf(request);
    if (_waiting.values.where((w) => w.client == client).length >= maxPerClient) {
      throw ApiError(429, 'rate_limited', 'Too many screens here are showing a code. Use one of them, or wait ten minutes.',
          details: {'retry_after': 600}, headers: {'retry-after': '600'});
    }
    if (_waiting.length >= maxWaiting) {
      throw ApiError(429, 'rate_limited', 'Too many screens are waiting to be added. Try again in a few minutes.',
          details: {'retry_after': 120}, headers: {'retry-after': '120'});
    }
    if (_waiting.containsKey(slot)) throw ApiError(409, 'conflict', 'That code is taken. Get a new one.');
    final w = _waiting[slot] = _Waiting(
      slot: slot,
      secret: _token(24),
      pubkey: pubkey,
      xpub: xpub,
      name: name,
      kind: kind,
      tag: tag,
      client: client,
      expires: clock() + lifetime.inMilliseconds,
    );
    hub.log.info('A screen is showing a code to join the family');
    return jsonResponse({
      'secret': w.secret,
      'expires': DateTime.fromMillisecondsSinceEpoch(w.expires, isUtc: true).toIso8601String(),
      'expires_ms': w.expires,
    }, status: 201);
  }

  /// How the screen stands in the family's log: `approved`, `declined` (removed), or null.
  String? _settled(_Waiting w) {
    final d = hub.den.device(w.device);
    if (d == null || d.pubkey != w.pubkey) return null;
    if (d.revoked) return 'declined';
    return d.approved && d.mode == DeviceMode.shared ? 'approved' : null;
  }

  /// `POST /api/v1/screens/code/status {slot, secret}`, from the screen: `waiting`, `accepted`
  /// (with what to join with), `requested` (its request reached the hub), or `approved` /
  /// `declined` once the family's log says so.
  Future<Response> status(Request request) async {
    hub.checkFailures(request);
    final w = _screenOf(request, Body(await readJsonObject(request, required: true)));
    final settled = _settled(w);
    if (settled != null) {
      _waiting.remove(w.slot);
      return jsonResponse({'state': settled});
    }
    final accepted = w.accepted;
    return jsonResponse({
      'state': accepted == null ? 'waiting' : (w.change == null ? 'accepted' : 'requested'),
      if (accepted != null) ...accepted,
      'expires_ms': w.expires,
    });
  }

  /// `POST /api/v1/screens/code/join {slot, secret, change}`, from the screen once a parent took
  /// its code: its own signed join request, kept for the parent's phone. Only the request the
  /// code was bound to is taken: the key the screen showed, unapproved, a shared screen that is
  /// nobody's, signed by that key.
  Future<Response> join(Request request) async {
    hub.checkFailures(request);
    final b = Body(await readJsonObject(request, required: true));
    final w = _screenOf(request, b);
    if (w.accepted == null) throw ApiError(409, 'not_accepted', 'No parent has added this screen yet.');
    final raw = b.object('change');
    final Change change;
    try {
      change = Change.fromJson(raw ?? const {});
    } on Object {
      throw ApiError.invalid("That isn't a join request.", field: 'change');
    }
    if (!await isScreenJoinRequest(change, pubkey: w.pubkey, xpub: w.xpub)) {
      hub.failed(request);
      hub.log.warn('Refused a kitchen screen\'s join request that isn\'t the one its code was for');
      throw ApiError.invalid('That join request isn\'t this screen\'s.', field: 'change');
    }
    w.change = change.toJson();
    return jsonResponse({'ok': true});
  }

  /// [request]'s signer, a parent on their own device, and its JSON body.
  Future<(DeviceRequestCheck, Body)> _parent(Request request) async {
    final signed = await auth.withBody(request, limit: 32 * 1024);
    final check = DeviceAuth.parentOf(signed.check, message: "Only a parent's own phone can add a kitchen screen.");
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    if (json is! Map) throw ApiError.invalid('The body must be a JSON object.');
    return (check, Body(json.cast<String, Object?>()));
  }

  /// Throws `429` while wrong codes from [client], or for the family, have used up their tries.
  void _checkWrong(String client) {
    final wait = _wrong.wait(client, clock());
    if (wait == null) return;
    throw ApiError.rateLimited(
      wait.seconds,
      wait.all
          ? 'Too many wrong codes were tried. Wait a few minutes, then try again.'
          : 'Too many wrong codes from here. Wait ten minutes, then try again.',
    );
  }

  /// A screen waiting under [slot] that no parent took yet; a wrong try otherwise.
  _Waiting _untaken(Request request, String slot) {
    _prune();
    final w = _waiting[slot];
    if (w == null || w.acceptedBy != null) {
      _wrong.add(hub.clientOf(request), clock());
      hub.log.warn('Someone tried a screen code that matches no screen');
      throw _wrongCode();
    }
    return w;
  }

  /// `POST /api/v1/screens/find {slot}`, signed by a parent's own device: the screen waiting
  /// under the slot of the code they typed, `{device, pubkey, xpub, name, kind, tag,
  /// expires_ms}`, for the phone to check the tag and ask. `404` for a wrong code, a used one or
  /// one that ran out, alike.
  Future<Response> find(Request request) async {
    final client = hub.clientOf(request);
    _checkWrong(client);
    final (_, b) = await _parent(request);
    final w = _untaken(request, _slot(b));
    return jsonResponse({
      'device': w.device,
      'pubkey': w.pubkey,
      'xpub': w.xpub,
      'name': w.name,
      'kind': w.kind,
      'tag': w.tag,
      'expires_ms': w.expires,
    });
  }

  /// `POST /api/v1/screens/accept {slot, family, founder, hub, name, tag}`, signed by a
  /// parent's own device, after they said Add: what the screen joins with, and the phone's tag
  /// over it. The code is then that phone's alone.
  Future<Response> accept(Request request) async {
    final client = hub.clientOf(request);
    _checkWrong(client);
    final (check, b) = await _parent(request);
    final w = _untaken(request, _slot(b));
    final family = b.string('family', required: true, max: 64);
    final founder = b.string('founder', required: true, max: 64);
    final hubDevice = b.string('hub', required: true, max: 64);
    final name = b.string('name', required: true, min: 1, max: 60)!.trim();
    final tag = b.string('tag', required: true, max: 64)!;
    if (family != hub.den.familyId || founder != hub.den.founderPubkey || hubDevice != hub.den.deviceId) {
      throw ApiError.invalid("That isn't this family's hub.");
    }
    w.acceptedBy = check.device!.id;
    w.accepted = {'family': family, 'founder': founder, 'hub': hubDevice, 'name': name, 'tag': tag};
    w.expires = max(w.expires, clock() + finishing.inMilliseconds);
    hub.log.info('${check.actor!.name} is adding a kitchen screen');
    return jsonResponse({'ok': true, 'expires_ms': w.expires});
  }

  /// `POST /api/v1/screens/request {slot}`, signed by the parent's device that took the code:
  /// `accepted` while the screen hasn't sent its join request, `requested` with it as `change`,
  /// or `approved` once the family's log holds the approval.
  Future<Response> requestOf(Request request) async {
    final (check, b) = await _parent(request);
    final slot = _slot(b);
    _prune();
    final w = _waiting[slot];
    if (w == null || w.acceptedBy != check.device!.id) throw _expired();
    final settled = _settled(w);
    if (settled != null) return jsonResponse({'state': settled});
    return jsonResponse({
      'state': w.change == null ? 'accepted' : 'requested',
      'change': ?w.change,
      'expires_ms': w.expires,
    });
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
