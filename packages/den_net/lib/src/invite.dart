import 'dart:typed_data';

import 'package:den_core/den_core.dart';

import 'util.dart';

/// A QR invite: `den://join?f=&fk=&d=&k=&s=&h=&r=&x=`. See ARCHITECTURE.md, "Pairing".
///
/// `f` family id, `fk` founder's Ed25519 key, `d` and `k` the inviting device and its key, `s`
/// the 128-bit secret (base64url), `h` hub URLs (comma-separated, each percent-encoded), `r` the
/// relay URL, `x` expiry in Unix seconds. The joiner pins `d`/`k`, so nothing between the two
/// devices can substitute its own key, and proves it scanned the code with
/// HMAC-SHA256(secret, its raw Ed25519 public key).
class Invite {
  /// Creates an invite; prefer [Invite.create] for a fresh secret.
  Invite({
    required this.familyId,
    required this.founderPubkey,
    required this.inviterDevice,
    required this.inviterPubkey,
    required List<int> secret,
    required this.expires,
    this.hubs = const [],
    this.relay,
  }) : secret = Uint8List.fromList(secret) {
    if (this.secret.length != secretLength) throw ArgumentError('secret must be $secretLength bytes');
  }

  /// A new invite with a random secret.
  factory Invite.create({
    required String familyId,
    required String founderPubkey,
    required String inviterDevice,
    required String inviterPubkey,
    List<Uri> hubs = const [],
    Uri? relay,
    Duration validFor = const Duration(hours: 1),
    DateTime? now,
  }) =>
      Invite(
        familyId: familyId,
        founderPubkey: founderPubkey,
        inviterDevice: inviterDevice,
        inviterPubkey: inviterPubkey,
        secret: randomBytes(secretLength),
        expires: _wholeSeconds((now ?? DateTime.now()).toUtc().add(validFor)),
        hubs: hubs,
        relay: relay,
      );

  /// Secret length in bytes (128 bits).
  static const int secretLength = 16;

  /// The family being joined.
  final String familyId;

  /// The founding device's Ed25519 key, which roots the joiner's trust in the family's log.
  final String founderPubkey;

  /// The device that showed the code and will accept the joiner's session.
  final String inviterDevice;

  /// The inviting device's Ed25519 key, pinned during the session handshake.
  final String inviterPubkey;

  /// The 128-bit invite secret.
  final Uint8List secret;

  /// When the invite stops working (whole seconds, UTC).
  final DateTime expires;

  /// WebSocket URLs where the inviting device can be reached directly.
  final List<Uri> hubs;

  /// The relay for a tunnel or rendezvous when the inviter can't be reached directly.
  final Uri? relay;

  /// Whether the invite has expired at [now].
  bool isExpired([DateTime? now]) => !(now ?? DateTime.now()).toUtc().isBefore(expires);

  /// The `den://join?...` URL for the QR code.
  String toUrl() {
    final params = <String>[
      'f=${_enc(familyId)}',
      'fk=${_enc(founderPubkey)}',
      'd=${_enc(inviterDevice)}',
      'k=${_enc(inviterPubkey)}',
      's=${b64e(secret)}',
      if (hubs.isNotEmpty) 'h=${hubs.map((u) => _enc(u.toString())).join(',')}',
      if (relay != null) 'r=${_enc(relay.toString())}',
      'x=${expires.millisecondsSinceEpoch ~/ 1000}',
    ];
    return 'den://join?${params.join('&')}';
  }

  @override
  String toString() => toUrl();

  /// Parses and checks a scanned invite: format, that `d` is the id of `k`, and expiry.
  ///
  /// Throws [FormatException] for anything malformed, forged or expired.
  static Future<Invite> parse(String url, {DateTime? now, bool allowExpired = false}) async {
    final invite = decode(url);
    if (await deviceIdFor(b64d(invite.inviterPubkey)) != invite.inviterDevice) {
      throw const FormatException('Invite device does not match its key');
    }
    if (!allowExpired && invite.isExpired(now)) throw const FormatException('Invite has expired');
    return invite;
  }

  /// Decodes the URL's fields without the checks [parse] makes.
  static Invite decode(String url) {
    final trimmed = url.trim();
    const prefix = 'den://join?';
    if (!trimmed.startsWith(prefix)) throw const FormatException('Not a Den invite');
    final raw = <String, String>{};
    for (final pair in trimmed.substring(prefix.length).split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq <= 0) throw FormatException('Bad invite parameter', pair);
      raw[pair.substring(0, eq)] = pair.substring(eq + 1);
    }
    String required(String key) {
      final value = raw[key];
      if (value == null || value.isEmpty) throw FormatException('Invite is missing "$key"');
      return Uri.decodeQueryComponent(value);
    }

    final founderPubkey = required('fk');
    final inviterPubkey = required('k');
    for (final key in [founderPubkey, inviterPubkey]) {
      if (tryB64d(key)?.length != 32) throw const FormatException('Bad key in invite');
    }
    final secret = tryB64d(required('s'));
    if (secret == null || secret.length != secretLength) throw const FormatException('Bad invite secret');
    final seconds = int.tryParse(required('x'));
    if (seconds == null || seconds <= 0) throw const FormatException('Bad invite expiry');
    final hubs = <Uri>[];
    final hubParam = raw['h'];
    if (hubParam != null && hubParam.isNotEmpty) {
      for (final part in hubParam.split(',')) {
        hubs.add(_uri(Uri.decodeQueryComponent(part)));
      }
    }
    final relayParam = raw['r'];
    return Invite(
      familyId: required('f'),
      founderPubkey: founderPubkey,
      inviterDevice: required('d'),
      inviterPubkey: inviterPubkey,
      secret: secret,
      expires: DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
      hubs: hubs,
      relay: relayParam == null || relayParam.isEmpty ? null : _uri(Uri.decodeQueryComponent(relayParam)),
    );
  }

  /// The joiner's proof of having scanned this invite: base64url HMAC-SHA256(secret, pubkey).
  Future<String> proofFor(String joinerPubkey) async => b64e(await hmacSha256(secret, b64d(joinerPubkey)));

  /// Whether [proof] is this invite's proof for [joinerPubkey].
  Future<bool> checkProof(String joinerPubkey, String proof) async {
    final given = tryB64d(proof);
    final key = tryB64d(joinerPubkey);
    if (given == null || key == null) return false;
    return constantTimeEquals(given, await hmacSha256(secret, key));
  }

  /// The relay rendezvous slot for this invite: hex SHA-256 of a label and the secret.
  Future<String> rendezvousSlot() async =>
      hexEncode(await sha256(concatBytes([utf8Bytes('den/rendezvous/v1/qr|'), secret])));
}

/// A QR invite that an approved parent device hands to the family's hub, so the hub admits the
/// joiner on its behalf (a browser linking through the hub, say). The invite names the hub as
/// the inviting device, so the joiner pins the hub's key; the grant is the parent device's
/// Ed25519 signature over the invite and a [context] the hub checks (such as a link slot), so
/// nobody else can make the hub accept invites.
///
/// Signed bytes: `"den/invite-grant/v1" 0x00 | canonical JSON [invite URL, grantor, context]`.
class InviteGrant {
  /// Creates a grant; prefer [InviteGrant.sign].
  const InviteGrant({required this.invite, required this.grantor, required this.context, required this.sig});

  /// Signs [invite] for [context] with the granting device's [keys].
  static Future<InviteGrant> sign(Invite invite, {required DeviceKeys keys, required String context}) async {
    final grantor = await keys.deviceId();
    return InviteGrant(
      invite: invite,
      grantor: grantor,
      context: context,
      sig: await keys.sign(_grantBytes(invite.toUrl(), grantor, context)),
    );
  }

  /// The invite, naming the hub as the inviting device.
  final Invite invite;

  /// The parent device that signed the grant.
  final String grantor;

  /// What the grant is for, chosen by the hub (for example `link:<slot>`).
  final String context;

  /// base64url Ed25519 signature by [grantor].
  final String sig;

  /// `{invite, device, context, sig}`.
  Map<String, Object?> toJson() => {'invite': invite.toUrl(), 'device': grantor, 'context': context, 'sig': sig};

  /// Reads [toJson] output; throws [FormatException] when it is malformed.
  static InviteGrant fromJson(Map<String, Object?> json) {
    final url = json['invite'], device = json['device'], context = json['context'], sig = json['sig'];
    if (url is! String || device is! String || context is! String || sig is! String) {
      throw const FormatException('Not an invite grant');
    }
    return InviteGrant(invite: Invite.decode(url), grantor: device, context: context, sig: sig);
  }

  /// Why [den] (the hub the invite names) must refuse this grant for [expectedContext], or
  /// null when it is good: signed by an approved, unrevoked personal device whose owner is a
  /// parent, for this family, naming this device and its key, unexpired.
  Future<String?> problem(Den den, {required String expectedContext, DateTime? now}) async {
    if (context != expectedContext) return 'wrong-context';
    if (invite.isExpired(now)) return 'expired';
    if (!den.hasFamily || invite.familyId != den.familyId || invite.founderPubkey != den.founderPubkey) {
      return 'wrong-family';
    }
    if (invite.inviterDevice != den.deviceId || invite.inviterPubkey != den.keys.pubkey) return 'wrong-device';
    final device = den.device(grantor);
    if (device == null || !device.approved || device.revoked || device.mode != DeviceMode.personal) {
      return 'not-a-parent-device';
    }
    final owner = device.member == null ? null : den.member(device.member!);
    if (owner == null || !owner.isParent) return 'not-a-parent-device';
    final ok = await verifySignature(_grantBytes(invite.toUrl(), grantor, context), sig, device.pubkey);
    return ok ? null : 'bad-signature';
  }
}

Uint8List _grantBytes(String inviteUrl, String grantor, String context) => concatBytes([
      utf8Bytes('den/invite-grant/v1'),
      [0],
      utf8Bytes(canonicalJson([inviteUrl, grantor, context])),
    ]);

/// The inviting side's live QR invites. Each works once and only until it expires.
class InviteBook {
  /// Creates an empty book; [now] is injectable for tests.
  InviteBook({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<Invite> _invites = [];

  /// Invites that can still be redeemed.
  List<Invite> get live {
    _prune();
    return List.unmodifiable(_invites);
  }

  /// Starts accepting [invite].
  void add(Invite invite) {
    _prune();
    _invites.add(invite);
  }

  /// Stops accepting [invite].
  void revoke(Invite invite) => _invites.remove(invite);

  /// Finds the live invite [proof] was made with and uses it up; null when none matches.
  Future<Invite?> redeem(String joinerPubkey, String proof) async {
    _prune();
    for (final invite in List.of(_invites)) {
      if (await invite.checkProof(joinerPubkey, proof)) {
        _invites.remove(invite);
        return invite;
      }
    }
    return null;
  }

  void _prune() {
    final now = _now();
    _invites.removeWhere((i) => i.isExpired(now));
  }
}

String _enc(String value) => Uri.encodeQueryComponent(value);

Uri _uri(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) throw FormatException('Bad URL in invite', text);
  return uri;
}

DateTime _wholeSeconds(DateTime t) =>
    DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch ~/ 1000 * 1000, isUtc: true);
