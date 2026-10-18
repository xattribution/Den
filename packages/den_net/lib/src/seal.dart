import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';

import 'util.dart';

/// Sealing that failed: bad signature, wrong recipient, or damaged ciphertext.
class SealException implements Exception {
  /// Creates the exception.
  SealException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'SealException: $message';
}

final X25519 _x25519 = X25519();
final Xchacha20 _cipher = Xchacha20.poly1305Aead();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// Encrypts [payload] to one device's X25519 key and signs the result with the sender's
/// Ed25519 key, for delivery through an untrusted relay.
///
/// An ephemeral X25519 key agrees a secret with [recipientXpub]; HKDF-SHA256 (salt: ephemeral
/// public key then recipient key; info: label, sender, recipient) gives the XChaCha20-Poly1305
/// key. The envelope `{v, from, to, eph, nonce, ct, sig}` is signed over its canonical JSON.
Future<Map<String, Object?>> sealToDevice({
  required DeviceKeys sender,
  required String recipientDevice,
  required String recipientXpub,
  required Map<String, Object?> payload,
}) async {
  final from = await sender.deviceId();
  final recipient = tryB64d(recipientXpub);
  if (recipient == null || recipient.length != 32) throw ArgumentError('bad recipient key');
  final eph = await _x25519.newKeyPair();
  final ephPublic = (await eph.extractPublicKey()).bytes;
  final key = await _key(eph, recipient, ephPublic, from, recipientDevice);
  final nonce = randomBytes(24);
  final box = await _cipher.encrypt(
    utf8Bytes(jsonEncode(payload)),
    secretKey: key,
    nonce: nonce,
    aad: utf8Bytes('$from|$recipientDevice'),
  );
  final envelope = <String, Object?>{
    'v': 1,
    'from': from,
    'to': recipientDevice,
    'eph': b64e(ephPublic),
    'nonce': b64e(nonce),
    'ct': b64e(concatBytes([box.cipherText, box.mac.bytes])),
  };
  envelope['sig'] = await sender.sign(_signedBytes(envelope));
  return envelope;
}

/// The sender device id an envelope claims, before it is verified.
String? sealedSender(Map<String, Object?> envelope) => envelope['from'] as String?;

/// Verifies [envelope] against [senderPubkey] and decrypts it with [recipient]'s X25519 key.
Future<Map<String, Object?>> openSealed(
  Map<String, Object?> envelope, {
  required DeviceKeys recipient,
  required String senderPubkey,
}) async {
  final from = envelope['from'];
  final to = envelope['to'];
  final sig = envelope['sig'];
  final eph = tryB64d(envelope['eph']);
  final nonce = tryB64d(envelope['nonce']);
  final ct = tryB64d(envelope['ct']);
  if (envelope['v'] != 1 || from is! String || to is! String || sig is! String) {
    throw SealException('malformed envelope');
  }
  if (eph == null || eph.length != 32 || nonce == null || nonce.length != 24 || ct == null || ct.length < 16) {
    throw SealException('malformed envelope');
  }
  if (to != await recipient.deviceId()) throw SealException('sealed to another device');
  if (await deviceIdFor(b64d(senderPubkey)) != from) throw SealException('sender key does not match');
  if (!await verifySignature(_signedBytes(envelope), sig, senderPubkey)) {
    throw SealException('bad sender signature');
  }
  final shared = await _x25519.sharedSecretKey(
    keyPair: recipient.agreement,
    remotePublicKey: SimplePublicKey(eph, type: KeyPairType.x25519),
  );
  final key = await _hkdfKey(await shared.extractBytes(), eph, recipient.agreementPublic.bytes, from, to);
  try {
    final plain = await _cipher.decrypt(
      SecretBox(ct.sublist(0, ct.length - 16), nonce: nonce, mac: Mac(ct.sublist(ct.length - 16))),
      secretKey: key,
      aad: utf8Bytes('$from|$to'),
    );
    final decoded = asJsonObject(jsonDecode(utf8.decode(plain)));
    if (decoded == null) throw SealException('payload is not an object');
    return decoded;
  } on SecretBoxAuthenticationError {
    throw SealException('ciphertext failed authentication');
  } on FormatException {
    throw SealException('payload is not JSON');
  }
}

/// A space key granted to a device: what a `keys` message carries. [by], [revoked] and [sig]
/// are the maker's statement (see den_core's [SpaceKey]); receivers keep only keys whose
/// statement verifies.
class SpaceKeyGrant {
  /// Creates a grant.
  const SpaceKeyGrant({
    required this.space,
    required this.epoch,
    required this.key,
    this.by,
    this.revoked = const [],
    this.sig,
  });

  /// The grant for a key and its maker's statement.
  factory SpaceKeyGrant.of(SpaceKey key) => SpaceKeyGrant(
        space: key.space,
        epoch: key.epoch,
        key: key.key,
        by: key.by,
        revoked: key.revoked,
        sig: key.sig,
      );

  /// Space id.
  final String space;

  /// Key epoch; mailbox ids are derived per epoch.
  final int epoch;

  /// The 32-byte key.
  final Uint8List key;

  /// The device that made the key.
  final String? by;

  /// Approved devices that were revoked when [by] made it, sorted.
  final List<String> revoked;

  /// [by]'s signature over the statement.
  final String? sig;

  /// The key with its statement, for `Den.addSpaceKey`.
  SpaceKey get spaceKey => SpaceKey(space: space, epoch: epoch, key: key, by: by, revoked: revoked, sig: sig);

  /// The `keys` message body: `{t: keys, space, epoch, key, by, revoked, sig}`.
  Map<String, Object?> toJson() => {'t': 'keys', ...spaceKey.toJson()};

  /// Parses a `keys` message body; null when malformed.
  static SpaceKeyGrant? fromJson(Map<String, Object?> json) {
    final key = SpaceKey.fromJson(json);
    return key == null ? null : SpaceKeyGrant.of(key);
  }
}

/// Seals a space key grant to a device (see [sealToDevice]).
Future<Map<String, Object?>> sealSpaceKey({
  required DeviceKeys sender,
  required String recipientDevice,
  required String recipientXpub,
  required SpaceKeyGrant grant,
}) =>
    sealToDevice(
      sender: sender,
      recipientDevice: recipientDevice,
      recipientXpub: recipientXpub,
      payload: grant.toJson(),
    );

/// Opens a sealed space key grant (see [openSealed]).
Future<SpaceKeyGrant> openSpaceKey(
  Map<String, Object?> envelope, {
  required DeviceKeys recipient,
  required String senderPubkey,
}) async {
  final payload = await openSealed(envelope, recipient: recipient, senderPubkey: senderPubkey);
  final grant = payload['t'] == 'keys' ? SpaceKeyGrant.fromJson(payload) : null;
  if (grant == null) throw SealException('not a space key grant');
  return grant;
}

Uint8List _signedBytes(Map<String, Object?> envelope) => concatBytes([
      utf8Bytes('den/seal/v1'),
      [0],
      utf8Bytes(canonicalJson([
        envelope['v'],
        envelope['from'],
        envelope['to'],
        envelope['eph'],
        envelope['nonce'],
        envelope['ct'],
      ])),
    ]);

Future<SecretKey> _key(SimpleKeyPair eph, List<int> recipient, List<int> ephPublic, String from, String to) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(recipient, type: KeyPairType.x25519),
  );
  return _hkdfKey(await shared.extractBytes(), ephPublic, recipient, from, to);
}

Future<SecretKey> _hkdfKey(List<int> shared, List<int> ephPublic, List<int> recipient, String from, String to) async {
  if (shared.every((b) => b == 0)) throw SealException('weak key');
  final derived = await _hkdf.deriveKey(
    secretKey: SecretKey(shared),
    nonce: concatBytes([ephPublic, recipient]),
    info: utf8Bytes('den/seal/v1|$from|$to'),
  );
  return SecretKey(await derived.extractBytes());
}
