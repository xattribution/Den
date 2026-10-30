/// Sealing a message to one device: what a space key grant on the relay uses (den_net), and what
/// a group admission written into a family's log uses (`groupInvite`, groups.dart).
///
/// It lives here, beside [DeviceKeys], rather than in den_net, because den_core writes and opens
/// group admissions itself and den_core can't depend on den_net. den_net re-exports it, so its
/// API and the envelope's bytes are what they were.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'change.dart';
import 'ids.dart';

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
/// Ed25519 key, for delivery through an untrusted relay or a log every device of a family holds.
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
  final recipient = _tryB64d(recipientXpub);
  if (recipient == null || recipient.length != 32) throw ArgumentError('bad recipient key');
  final eph = await _x25519.newKeyPair();
  final ephPublic = (await eph.extractPublicKey()).bytes;
  final key = await _key(eph, recipient, ephPublic, from, recipientDevice);
  final nonce = randomBytes(24);
  final box = await _cipher.encrypt(
    _utf8(jsonEncode(payload)),
    secretKey: key,
    nonce: nonce,
    aad: _utf8('$from|$recipientDevice'),
  );
  final envelope = <String, Object?>{
    'v': 1,
    'from': from,
    'to': recipientDevice,
    'eph': b64e(ephPublic),
    'nonce': b64e(nonce),
    'ct': b64e(_concat([box.cipherText, box.mac.bytes])),
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
  final eph = _tryB64d(envelope['eph']);
  final nonce = _tryB64d(envelope['nonce']);
  final ct = _tryB64d(envelope['ct']);
  if (envelope['v'] != 1 || from is! String || to is! String || sig is! String) {
    throw SealException('malformed envelope');
  }
  if (eph == null || eph.length != 32 || nonce == null || nonce.length != 24 || ct == null || ct.length < 16) {
    throw SealException('malformed envelope');
  }
  if (to != await recipient.deviceId()) throw SealException('sealed to another device');
  final senderKey = _tryB64d(senderPubkey);
  if (senderKey == null || await deviceIdFor(senderKey) != from) throw SealException('sender key does not match');
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
      aad: _utf8('$from|$to'),
    );
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map) throw SealException('payload is not an object');
    return Map<String, Object?>.from(decoded);
  } on SecretBoxAuthenticationError {
    throw SealException('ciphertext failed authentication');
  } on FormatException {
    throw SealException('payload is not JSON');
  }
}

Uint8List _signedBytes(Map<String, Object?> envelope) => _concat([
      _utf8('den/seal/v1'),
      [0],
      _utf8(canonicalJson([
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
    nonce: _concat([ephPublic, recipient]),
    info: _utf8('den/seal/v1|$from|$to'),
  );
  return SecretKey(await derived.extractBytes());
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List _concat(Iterable<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Uint8List? _tryB64d(Object? text) {
  if (text is! String) return null;
  try {
    return b64d(text);
  } on FormatException {
    return null;
  }
}
