import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// P-256, the curve of Web Push's keys (RFC 8291) and of VAPID's ES256 (RFC 8292).
final ECDomainParameters _p256 = ECCurve_prime256v1();

final Random _random = Random.secure();

/// base64url without padding, as Web Push writes keys.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding; throws [FormatException].
Uint8List unb64url(String text) {
  final clean = text.trim();
  return base64Url.decode(clean.padRight(clean.length + (4 - clean.length % 4) % 4, '='));
}

Uint8List _randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

/// [value] as [length] big-endian bytes.
Uint8List _fixed(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

BigInt _unsigned(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

Uint8List _hmac(List<int> key, List<int> data) =>
    (HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(key)))).process(Uint8List.fromList(data));

/// A P-256 private key from 32 bytes, checked to be in range.
ECPrivateKey _privateKey(List<int> d) {
  if (d.length != 32) throw ArgumentError('a P-256 private key is 32 bytes');
  final value = _unsigned(d);
  if (value == BigInt.zero || value >= _p256.n) throw ArgumentError('not a P-256 private key');
  return ECPrivateKey(value, _p256);
}

ECPrivateKey _newPrivateKey() {
  while (true) {
    final bytes = _randomBytes(32);
    final value = _unsigned(bytes);
    if (value > BigInt.zero && value < _p256.n) return ECPrivateKey(value, _p256);
  }
}

/// The uncompressed public point (65 bytes, `0x04 | x | y`) of [key].
Uint8List _publicOf(ECPrivateKey key) => (_p256.G * key.d)!.getEncoded(false);

ECPoint _point(List<int> encoded) {
  if (encoded.length != 65 || encoded[0] != 4) throw const FormatException('not an uncompressed P-256 point');
  final point = _p256.curve.decodePoint(encoded);
  if (point == null || point.isInfinity) throw const FormatException('not a P-256 point');
  return point;
}

/// The hub's VAPID key pair (RFC 8292): push services take pushes for a subscription only from
/// the holder of the key the browser subscribed with.
class VapidKeys {
  VapidKeys._(this._private) : publicKey = _publicOf(_private);

  /// A new random key pair.
  factory VapidKeys.generate() => VapidKeys._(_newPrivateKey());

  /// The key pair whose private key is the 32 bytes [d].
  factory VapidKeys.fromPrivate(List<int> d) => VapidKeys._(_privateKey(d));

  final ECPrivateKey _private;

  /// The public key, uncompressed (65 bytes): the browser's `applicationServerKey`.
  final Uint8List publicKey;

  /// The private key's 32 bytes, for keeping in the hub's data directory.
  Uint8List get privateKey => _fixed(_private.d!, 32);

  /// ES256 over [message]: deterministic ECDSA (RFC 6979) with SHA-256, as `r | s`.
  Uint8List sign(List<int> message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(_private));
    final signature = signer.generateSignature(Uint8List.fromList(message)) as ECSignature;
    return Uint8List.fromList([..._fixed(signature.r, 32), ..._fixed(signature.s, 32)]);
  }

  /// Whether [signature] (`r | s`) is this key's ES256 signature over [message].
  bool verify(List<int> message, List<int> signature) {
    if (signature.length != 64) return false;
    final verifier = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(_point(publicKey), _p256)));
    return verifier.verifySignature(
      Uint8List.fromList(message),
      ECSignature(_unsigned(signature.sublist(0, 32)), _unsigned(signature.sublist(32))),
    );
  }

  /// The `Authorization` header for a push to [endpoint] (RFC 8292):
  /// `vapid t=<JWT>, k=<public key>`, the JWT signed with ES256 for the endpoint's origin,
  /// expiring at [expires] (at most a day ahead), naming [subject] (a `mailto:` or `https:`
  /// address push services can reach the hub's owner at).
  String authorization(Uri endpoint, {required String subject, required DateTime expires}) {
    final header = b64url(utf8.encode(jsonEncode({'typ': 'JWT', 'alg': 'ES256'})));
    final claims = b64url(utf8.encode(jsonEncode({
      'aud': '${endpoint.scheme}://${endpoint.authority}',
      'exp': expires.millisecondsSinceEpoch ~/ 1000,
      'sub': subject,
    })));
    final signed = '$header.$claims';
    return 'vapid t=$signed.${b64url(sign(ascii.encode(signed)))}, k=${b64url(publicKey)}';
  }
}

/// Encrypts [plaintext] for one browser's push subscription, as RFC 8291 says (the
/// `aes128gcm` content coding of RFC 8188, one record): a fresh P-256 key pair agrees a secret
/// with the subscription's [uaPublic] key, mixed with its [authSecret]; the body is the
/// header (salt, record size, the fresh public key) and the AES-128-GCM ciphertext.
///
/// [serverPrivate] and [salt] are for test vectors; leave them out.
Uint8List encryptForPush(
  List<int> plaintext, {
  required List<int> uaPublic,
  required List<int> authSecret,
  List<int>? serverPrivate,
  List<int>? salt,
  int recordSize = 4096,
}) {
  if (authSecret.length != 16) throw const FormatException('the auth secret is 16 bytes');
  final ua = _point(uaPublic);
  final asKey = serverPrivate == null ? _newPrivateKey() : _privateKey(serverPrivate);
  final asPublic = _publicOf(asKey);
  final useSalt = salt == null ? _randomBytes(16) : Uint8List.fromList(salt);
  if (useSalt.length != 16) throw ArgumentError('the salt is 16 bytes');
  if (plaintext.length + 17 > recordSize) throw ArgumentError('too long for one record');

  final shared = (ECDHBasicAgreement()..init(asKey)).calculateAgreement(ECPublicKey(ua, _p256));
  final ecdhSecret = _fixed(shared, 32);
  final prkKey = _hmac(authSecret, ecdhSecret);
  final keyInfo = [...utf8.encode('WebPush: info'), 0, ...uaPublic, ...asPublic];
  final ikm = _hmac(prkKey, [...keyInfo, 1]);
  final prk = _hmac(useSalt, ikm);
  final cek = _hmac(prk, [...utf8.encode('Content-Encoding: aes128gcm'), 0, 1]).sublist(0, 16);
  final nonce = _hmac(prk, [...utf8.encode('Content-Encoding: nonce'), 0, 1]).sublist(0, 12);

  final gcm = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(cek), 128, nonce, Uint8List(0)));
  // One record, so it is the last: the plaintext ends with the 0x02 delimiter.
  final ciphertext = gcm.process(Uint8List.fromList([...plaintext, 2]));

  return Uint8List.fromList([
    ...useSalt,
    ..._fixed(BigInt.from(recordSize), 4),
    asPublic.length,
    ...asPublic,
    ...ciphertext,
  ]);
}
