/// Passkeys: how a family member gets back into Den in a browser (Face ID, a fingerprint, the
/// screen lock), once Safari has cleared the Home Screen app or on a new phone. See
/// docs/hub-api.md, "Getting back in with a passkey".
///
/// A passkey belongs to a member who is already in the family: their own personal device makes
/// it (a request it signs), and the hub keeps its public key in `<data>/hub/passkeys.json`
/// (owner-only, in backups, never in the family's log). Signing in with it lets nobody in by
/// itself; it says who is back, and the hub then lets the new device ask the same way it already
/// could, under the family's trust rules:
///
/// - a parent, while the family lets the hub help ("Let the hub help us get back in",
///   `family.recovery.serverKey`): the hub signs a recovery proof (kind `hub`) for that parent and
///   the new device, exactly as `den_hub recover` does, and the device is in at once. Every device
///   shows it, and any parent can remove it.
/// - anyone else (and a parent while the hub's help is off): the new device asks to join as them,
///   and a parent lets it in with one tap, as for an invite without a key.
///
/// A passkey whose member is gone, or whose device was removed, lets nobody in and is forgotten.
/// One that isn't the family's gets "Ask someone in your family for an invite".
///
/// The relying party is the family's own address as the browser sees it ([HubContext.base]): its
/// host is the RP ID, its origin the only origin. Nothing to configure. A family on a Den host has
/// its own address, store and challenges, so a passkey for one family means nothing at another's.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';

import '../body.dart';
import '../context.dart';
import '../device_auth.dart';
import '../edge.dart';
import '../http_util.dart';
import '../push/web_push_crypto.dart' show unb64url;
import '../recovery.dart';
import '../setup.dart' show restrictToOwner;
import 'webauthn.dart';

/// The hub's state document with the family's passkeys (`<data>/hub/passkeys.json`).
const String passkeysDoc = 'passkeys';

/// A challenge the hub handed out, kept in memory until it is used once or runs out.
class _Challenge {
  _Challenge({required this.create, required this.rp, required this.origin, required this.expires, this.device, this.member});

  /// Making a passkey (`webauthn.create`), or signing in (`webauthn.get`).
  final bool create;
  final String rp;
  final String origin;
  final int expires;

  /// For making one: the device that asked and its owner.
  final String? device;
  final String? member;
}

/// The passkey routes and store for one family's hub.
class HubPasskeys {
  /// Creates the passkey endpoints for [hub]; [recovery] is its server recovery, whose key signs
  /// a parent back in.
  HubPasskeys(this.hub, this._auth, this._recovery);

  /// Shared hub context.
  final HubContext hub;
  final DeviceAuth _auth;
  final HubRecovery _recovery;

  /// How long a challenge works. The app fetches one ahead, so the tap that uses it can start
  /// the browser's passkey sheet at once (Safari allows that only inside the tap), and fetches a
  /// new one before this runs out.
  static const Duration challengeLife = Duration(minutes: 5);

  /// How long the browser's sheet may stay up.
  static const Duration ceremonyTimeout = Duration(minutes: 2);

  /// How long the proof and the invite a sign-in hands out work: the device joins right away.
  static const Duration joinLife = Duration(minutes: 10);

  /// Most challenges waiting at once; past it the oldest goes.
  static const int maxChallenges = 1000;

  /// Most passkeys one person keeps.
  static const int maxPerMember = 10;

  /// Most devices one person may have waiting for a parent after signing in with a passkey.
  static const int maxWaiting = 3;

  /// The answer to a passkey that isn't for anyone here (or no longer is).
  static const String strangerMessage = 'This passkey isn\'t for anyone in this family. Ask someone in your family for an invite.';

  final Map<String, _Challenge> _challenges = {};
  final Random _random = Random.secure();

  /// Adds the passkey routes.
  void register(Routes routes) {
    routes
      ..add('POST', '/api/v1/passkeys/options', (r, _) => creationOptions(r))
      ..add('POST', '/api/v1/passkeys', (r, _) => create(r))
      ..add('GET', '/api/v1/passkeys', (r, _) => list(r))
      ..add('DELETE', '/api/v1/passkeys/<id>', (r, p) => remove(r, p['id']!))
      ..add('POST', '/api/v1/passkeys/sign-in/options', (r, _) => signInOptions(r))
      ..add('POST', '/api/v1/passkeys/sign-in', (r, _) => signIn(r));
  }

  // ------------------------------------------------------------------ the store

  Map<String, Object?> get _doc => hub.state.read(passkeysDoc);

  /// Credential id (base64url) to `{member, rp, key, made, made_by, device, sign_count, used,
  /// backed_up}`.
  Map<String, Object?> get _keys => (_doc['keys'] ??= <String, Object?>{}) as Map<String, Object?>;

  /// Member id to the WebAuthn user handle the hub made for them (16 random bytes): the same
  /// for each of their passkeys, never their member id.
  Map<String, Object?> get _handles => (_doc['handles'] ??= <String, Object?>{}) as Map<String, Object?>;

  Future<void> _save() async {
    await hub.state.save(passkeysDoc);
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$passkeysDoc.json', warn: hub.log.warn);
  }

  /// Forgets the passkeys of people no longer in the family and of devices removed from it
  /// (a passkey belongs to the device that made it or last signed in with it). Returns whether
  /// anything went.
  bool _prune() {
    if (!hub.ready) return false;
    final den = hub.den;
    final before = _keys.length + _handles.length;
    _keys.removeWhere((_, v) {
      if (v is! Map || v['member'] is! String || den.member(v['member'] as String) == null) return true;
      final device = v['device'];
      return device is String && (den.device(device)?.revoked ?? false);
    });
    _handles.removeWhere((member, _) => den.member(member) == null);
    return _keys.length + _handles.length != before;
  }

  /// [member]'s passkeys, by credential id.
  Iterable<MapEntry<String, Map<Object?, Object?>>> _of(String member) sync* {
    for (final e in _keys.entries) {
      final v = e.value;
      if (v is Map && v['member'] == member) yield MapEntry(e.key, v);
    }
  }

  /// How many passkeys [member] has here.
  int countFor(String member) {
    if (_prune()) unawaited(_save());
    return _of(member).length;
  }

  Future<String> _handle(String member) async {
    final known = _handles[member];
    if (known is String) return known;
    final made = b64e(randomBytes(16));
    _handles[member] = made;
    await _save();
    return made;
  }

  // ------------------------------------------------------------------ the relying party

  /// The family's address as [request] came to it: its origin and host (the RP ID). Passkeys
  /// need a secure page and a host name: `https`, or `localhost` while developing; never an IP
  /// address, which WebAuthn refuses as an RP ID. Throws `409 needs_https` otherwise.
  ({String origin, String rp}) _party(Request request) {
    final base = hub.base(request);
    final host = base.host.toLowerCase();
    final local = host == 'localhost';
    final ip = InternetAddress.tryParse(host) != null || host.contains(':');
    if (host.isEmpty || ip || (base.scheme != 'https' && !local)) {
      throw ApiError(409, 'needs_https', 'Passkeys work only at your family\'s https address.');
    }
    return (origin: base.origin, rp: host);
  }

  String _newChallenge(_Challenge Function() made) {
    final now = hub.now();
    _challenges.removeWhere((_, c) => c.expires <= now);
    while (_challenges.length >= maxChallenges) {
      _challenges.remove(_challenges.keys.first);
    }
    final challenge = b64e(List.generate(32, (_) => _random.nextInt(256)));
    _challenges[challenge] = made();
    return challenge;
  }

  /// The challenge [client] answered, used up whatever happens next; null when the hub never
  /// made it, it was used, or it ran out.
  _Challenge? _take(ClientData client) {
    final c = _challenges.remove(client.challenge);
    return c == null || c.expires <= hub.now() ? null : c;
  }

  static List<int> _bytes(Object? text, String field) {
    if (text is! String || text.isEmpty || text.length > 64 * 1024) throw ApiError.invalid('That passkey answer is missing $field.', field: field);
    try {
      return unb64url(text);
    } on FormatException {
      throw ApiError.invalid('That passkey answer is missing $field.', field: field);
    }
  }

  // ------------------------------------------------------------------ making one

  /// [c] when it is a person on their own personal device: never a shared screen, a hub, or a
  /// connection (those can't sign a device request). Throws `403` otherwise.
  static DeviceRequestCheck _own(DeviceRequestCheck c) {
    final actor = c.actor, device = c.device!;
    if (actor == null || device.mode != DeviceMode.personal || device.member != actor.id) {
      throw ApiError.denied('Only your own phone or computer can make your passkey.');
    }
    return c;
  }

  /// `POST /api/v1/passkeys/options`, signed by a person's own personal device: what that
  /// browser passes to `navigator.credentials.create`, with a fresh challenge for this device.
  Future<Response> creationOptions(Request request) async {
    final c = _own((await _auth.withBody(request, limit: 1024)).check);
    final party = _party(request);
    final member = c.actor!;
    if (_prune()) await _save();
    final mine = _of(member.id).toList();
    final expires = hub.now() + challengeLife.inMilliseconds;
    final challenge = _newChallenge(() => _Challenge(
          create: true,
          rp: party.rp,
          origin: party.origin,
          expires: expires,
          device: c.device!.id,
          member: member.id,
        ));
    final family = hub.den.family?.name;
    return jsonResponse({
      'options': {
        'rp': {'id': party.rp, 'name': 'Den'},
        'user': {
          'id': await _handle(member.id),
          // What the phone's passkey list shows: whose, and which family.
          'name': family == null || family.isEmpty ? member.name : '${member.name} ($family)',
          'displayName': member.name,
        },
        'challenge': challenge,
        'pubKeyCredParams': [
          {'type': 'public-key', 'alg': coseEs256},
          {'type': 'public-key', 'alg': coseRs256},
        ],
        'timeout': ceremonyTimeout.inMilliseconds,
        'attestation': 'none',
        'authenticatorSelection': {'residentKey': 'required', 'requireResidentKey': true, 'userVerification': 'required'},
        'hints': ['client-device'],
        // A phone that holds one of theirs already says so instead of making another.
        'excludeCredentials': [for (final e in mine.where((e) => e.value['rp'] == party.rp)) {'type': 'public-key', 'id': e.key}],
      },
      'existing': mine.length,
      'expires_ms': expires,
    });
  }

  /// `POST /api/v1/passkeys {credential}`, signed by the device that asked for the options: the
  /// browser's answer to `navigator.credentials.create`. Keeps the passkey for its owner.
  Future<Response> create(Request request) async {
    final signed = await _auth.withBody(request, limit: 32 * 1024);
    final c = _own(signed.check);
    final party = _party(request);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    final credential = json is Map ? json['credential'] : null;
    if (credential is! Map || credential['response'] is! Map) throw ApiError.invalid('That isn\'t a passkey.', field: 'credential');
    final response = credential['response'] as Map;
    final id = credential['id'];
    if (id is! String || id.isEmpty || id.length > 1400) throw ApiError.invalid('That isn\'t a passkey.', field: 'credential');
    final clientData = _bytes(response['clientDataJSON'], 'clientDataJSON');
    final attestation = _bytes(response['attestationObject'], 'attestationObject');
    final NewPasskey made;
    try {
      final client = ClientData.parse(clientData);
      final challenge = _take(client);
      if (challenge == null || !challenge.create || challenge.device != c.device!.id || challenge.member != c.actor!.id) {
        throw const WebAuthnRefused('not a challenge this device asked for');
      }
      if (challenge.rp != party.rp || challenge.origin != party.origin) throw const WebAuthnRefused('another address');
      made = checkRegistration(
        id: id,
        clientDataJson: clientData,
        attestationObject: attestation,
        expected: Expected(origin: party.origin, rpId: party.rp, challenge: client.challenge),
      );
    } on WebAuthnRefused catch (e) {
      hub.log.warn('Refused a new passkey: ${e.reason}');
      throw ApiError.invalid('That passkey didn\'t check out. Try again.', field: 'credential');
    }
    final member = c.actor!;
    if (_prune()) await _save();
    final held = _keys[made.id];
    if (held is Map && held['member'] != member.id) {
      throw ApiError(409, 'conflict', 'That passkey is someone else\'s in this family.');
    }
    if (held == null && _of(member.id).length >= maxPerMember) {
      throw ApiError(409, 'too_many', 'You have $maxPerMember passkeys already. Remove one first.');
    }
    final now = hub.now();
    _keys[made.id] = {
      'member': member.id,
      'rp': party.rp,
      'key': made.key.toJson(),
      'made': now,
      'made_by': c.device!.id,
      'made_on': c.device!.name,
      'device': c.device!.id,
      'sign_count': made.signCount,
      'backed_up': made.backedUp,
    };
    await _save();
    hub.log.info('${member.name} made a passkey on ${c.device!.name}');
    return jsonResponse(_view(made.id, _keys[made.id]! as Map), status: 201);
  }

  Map<String, Object?> _view(String id, Map<Object?, Object?> v) => {
        'id': id,
        'member': v['member'],
        'made_ms': v['made'],
        'made_on': v['made_on'],
        'used_ms': v['used'],
        'synced': v['backed_up'] == true,
      };

  /// `GET /api/v1/passkeys`, signed: the acting person's own passkeys, or with `?member=`, a
  /// parent's own device asking about anyone.
  Future<Response> list(Request request) async {
    final c = await _auth.check(request);
    final asked = request.url.queryParameters['member'];
    final actor = c.actor;
    if (actor == null) throw ApiError.denied('Sign in on this screen first.');
    final member = asked ?? actor.id;
    if (member != actor.id) DeviceAuth.parentOf(c, message: 'Only a parent\'s own phone can see someone else\'s passkeys.');
    if (_prune()) await _save();
    return jsonResponse({
      'passkeys': [for (final e in _of(member)) _view(e.key, e.value)],
    });
  }

  /// `DELETE /api/v1/passkeys/{id}`, signed by its person on their own personal device, or by a
  /// parent's own device: it signs nobody in again.
  Future<Response> remove(Request request, String id) async {
    final c = await _auth.check(request);
    if (_prune()) await _save();
    final held = _keys[id];
    final actor = c.actor;
    if (held is! Map || actor == null) throw ApiError.notFound(type: 'passkey', message: 'That passkey is gone already.');
    if (held['member'] == actor.id) {
      _own(c);
    } else {
      DeviceAuth.parentOf(c, message: 'Only a parent\'s own phone can remove someone else\'s passkey.');
    }
    _keys.remove(id);
    await _save();
    hub.log.info('${actor.name} removed a passkey');
    return jsonResponse({'ok': true});
  }

  // ------------------------------------------------------------------ signing in

  /// `POST /api/v1/passkeys/sign-in/options`, from anyone: a challenge for
  /// `navigator.credentials.get`. No credential is named, so the browser offers whichever of the
  /// person's passkeys are for this address, and the hub learns nothing until they choose one.
  Future<Response> signInOptions(Request request) async {
    hub.limit(request, 'auth', Limits.auth);
    if (!hub.ready) throw ApiError.notReady();
    final party = _party(request);
    final expires = hub.now() + challengeLife.inMilliseconds;
    final challenge = _newChallenge(() => _Challenge(create: false, rp: party.rp, origin: party.origin, expires: expires));
    return jsonResponse({
      'options': {
        'challenge': challenge,
        'rpId': party.rp,
        'timeout': ceremonyTimeout.inMilliseconds,
        'userVerification': 'required',
        'allowCredentials': <Object?>[],
        'hints': ['client-device'],
      },
      'expires_ms': expires,
    });
  }

  /// `POST /api/v1/passkeys/sign-in {credential, pubkey}`: the browser's answer to
  /// `navigator.credentials.get` and the new device's key. Says who is back and hands the device
  /// what lets it join: a recovery proof for a parent while the hub may help, or an invite to ask
  /// as them. A passkey that isn't anyone's here: `403 not_in_family`.
  Future<Response> signIn(Request request) async {
    hub.checkFailures(request);
    hub.limit(request, 'auth', Limits.auth);
    if (!hub.ready) throw ApiError.notReady();
    final party = _party(request);
    final b = Body(await readJsonObject(request, required: true));
    final pubkey = b.string('pubkey', required: true, min: 20, max: 100)!;
    if (deviceIdOf(pubkey) == null) throw ApiError.invalid('That isn\'t a device key.', field: 'pubkey');
    final credential = b['credential'];
    if (credential is! Map || credential['response'] is! Map || credential['id'] is! String) {
      throw ApiError.invalid('That isn\'t a passkey.', field: 'credential');
    }
    final response = credential['response'] as Map;
    final id = (credential['id'] as String).replaceAll('=', '');
    final clientData = _bytes(response['clientDataJSON'], 'clientDataJSON');
    final authData = _bytes(response['authenticatorData'], 'authenticatorData');
    final signature = _bytes(response['signature'], 'signature');

    final ClientData client;
    try {
      client = ClientData.parse(clientData);
    } on WebAuthnRefused catch (e) {
      hub.failed(request);
      hub.log.warn('Refused a passkey sign-in: ${e.reason}');
      throw ApiError.invalid('That didn\'t work. Try again.', field: 'credential');
    }
    final challenge = _take(client);
    if (challenge == null || challenge.create || challenge.rp != party.rp || challenge.origin != party.origin) {
      hub.failed(request);
      throw ApiError.invalid('That took too long. Try again.', field: 'credential');
    }
    // Another page's answer (or a made one) is refused before anything is looked up.
    if (client.origin != party.origin || client.type != 'webauthn.get') {
      hub.failed(request);
      hub.log.warn('Refused a passkey sign-in from ${client.origin}');
      throw ApiError.invalid('That didn\'t work. Try again.', field: 'credential');
    }
    if (_prune()) await _save();
    final held = _keys[id];
    final key = held is Map ? PasskeyKey.parse(held['key']) : null;
    final member = held is Map ? hub.den.member(held['member'] as String) : null;
    if (held is! Map || key == null || member == null || held['rp'] != party.rp) {
      hub.log.info('Someone signed in with a passkey this family doesn\'t know');
      throw ApiError(403, 'not_in_family', strangerMessage);
    }
    final AuthData auth;
    try {
      auth = checkAssertion(
        clientDataJson: clientData,
        authenticatorData: authData,
        signature: signature,
        key: key,
        expected: Expected(origin: party.origin, rpId: party.rp, challenge: client.challenge),
      );
    } on WebAuthnRefused catch (e) {
      hub.failed(request);
      hub.log.warn('Refused a passkey sign-in for ${member.name}: ${e.reason}');
      throw ApiError.invalid('That didn\'t work. Try again.', field: 'credential');
    }
    if (member.accessEndedOn(hub.den.todayDate())) {
      throw ApiError(403, 'not_in_family', strangerMessage);
    }

    final now = hub.now();
    final expires = now + joinLife.inMilliseconds;
    final device = deviceIdOf(pubkey)!;
    final RecoveryProof? proof;
    if (member.isParent && _recovery.on) {
      proof = await (await _recovery.serverKey()).prove(
        family: hub.den.familyId!,
        kind: RecoveryKind.hub,
        member: member.id,
        devicePubkey: pubkey,
        expires: expires,
      );
      hub.log.warn('${member.name} signed in with a passkey; the hub let their new device in');
    } else {
      final waiting = hub.den.pendingDevices.where((d) => d.member == member.id && d.id != device).length;
      if (waiting >= maxWaiting) {
        throw ApiError(429, 'busy', 'Your last tries are still waiting for a parent. Ask a parent to open Den and let you in.');
      }
      proof = null;
      hub.log.info('${member.name} signed in with a passkey; a parent lets their new device in');
    }
    // The passkey now belongs to this device: removing it (a lost phone) turns the passkey off.
    _keys[id] = {
      ...held,
      'sign_count': auth.signCount,
      'backed_up': auth.backedUp,
      'used': now,
      'device': device,
    };
    await _save();
    final invite = Invite.create(
      familyId: hub.den.familyId!,
      founderPubkey: hub.den.founderPubkey!,
      inviterDevice: hub.den.deviceId,
      inviterPubkey: hub.den.keys.pubkey,
      validFor: joinLife,
    );
    hub.node.invites.add(invite);
    return jsonResponse({
      'invite': invite.toUrl(),
      'member': member.id,
      'member_name': member.name,
      'member_marker': member.marker.name,
      'member_picture': member.picture,
      'family': hub.den.family?.name,
      'proof': proof?.toJson(),
      'lets_in': proof != null,
      'expires_ms': expires,
    });
  }
}
