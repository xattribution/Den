/// Checking what a browser's passkey answers (WebAuthn Level 2/3, as a relying party), the
/// proportionate way: a challenge the hub made, used once; the family's own origin and RP ID;
/// the person really there and verified (Face ID, a fingerprint, the screen lock); and the
/// signature. Attestation is never asked for (`"none"`) and never read, whatever an
/// authenticator sends: Den doesn't care which brand of phone holds the key. The sign counter
/// and the backup flags are kept for information only, since synced passkeys (iCloud Keychain,
/// Google Password Manager) report 0 forever.
///
/// ES256 (P-256, every Apple and Google passkey) and RS256 (Windows Hello). Nothing else.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:pointycastle/export.dart';

import '../oidc.dart' show RsaPublicKey, bytesEqual, rsaVerifySha256;
import '../push/web_push_crypto.dart' show p256Domain, p256Point, unb64url, b64url;
import 'cbor.dart';

/// COSE's number for ES256 (RFC 9053).
const int coseEs256 = -7;

/// COSE's number for RS256 (RFC 8812).
const int coseRs256 = -257;

/// Why a passkey's answer was refused, for the hub's log (never shown as is).
class WebAuthnRefused implements Exception {
  /// Refuses for [reason].
  const WebAuthnRefused(this.reason);

  /// What didn't check out.
  final String reason;

  @override
  String toString() => 'WebAuthnRefused: $reason';
}

/// SHA-256 of [bytes].
Uint8List sha256(List<int> bytes) => Uint8List.fromList(const DartSha256().hashSync(bytes).bytes);

/// A passkey's public key: ES256 (`x`, `y`) or RS256 (`n`, `e`), as the hub keeps it.
class PasskeyKey {
  /// A P-256 key with coordinates [x] and [y] (32 bytes each).
  PasskeyKey.es256(List<int> x, List<int> y)
      : alg = 'ES256',
        _a = Uint8List.fromList(x),
        _b = Uint8List.fromList(y);

  /// An RSA key with modulus [n] and exponent [e].
  PasskeyKey.rs256(List<int> n, List<int> e)
      : alg = 'RS256',
        _a = Uint8List.fromList(n),
        _b = Uint8List.fromList(e);

  /// `ES256` or `RS256`.
  final String alg;
  final Uint8List _a;
  final Uint8List _b;

  /// The key from a COSE_Key map (WebAuthn's credential public key). Throws [WebAuthnRefused]
  /// for any other kind of key, or a P-256 point that isn't on the curve.
  factory PasskeyKey.fromCose(Object? cose) {
    if (cose is! Map) throw const WebAuthnRefused('key isn\'t a COSE map');
    final kty = cose[1], alg = cose[3];
    if (kty == 2 && alg == coseEs256) {
      final crv = cose[-1], x = cose[-2], y = cose[-3];
      if (crv != 1 || x is! Uint8List || y is! Uint8List || x.length != 32 || y.length != 32) {
        throw const WebAuthnRefused('not a P-256 key');
      }
      final key = PasskeyKey.es256(x, y);
      try {
        p256Point([4, ...x, ...y]);
      } on FormatException {
        throw const WebAuthnRefused('point not on P-256');
      }
      return key;
    }
    if (kty == 3 && alg == coseRs256) {
      final n = cose[-1], e = cose[-2];
      if (n is! Uint8List || e is! Uint8List || n.length < 256 || n.length > 512 || e.isEmpty || e.length > 8) {
        throw const WebAuthnRefused('not a usable RSA key');
      }
      return PasskeyKey.rs256(n, e);
    }
    throw const WebAuthnRefused('only ES256 and RS256 passkeys');
  }

  /// As the hub keeps it.
  Map<String, Object?> toJson() =>
      alg == 'ES256' ? {'alg': alg, 'x': b64url(_a), 'y': b64url(_b)} : {'alg': alg, 'n': b64url(_a), 'e': b64url(_b)};

  /// From [toJson]; null when it isn't one.
  static PasskeyKey? parse(Object? json) {
    if (json is! Map) return null;
    try {
      return switch (json['alg']) {
        'ES256' => PasskeyKey.es256(unb64url(json['x'] as String), unb64url(json['y'] as String)),
        'RS256' => PasskeyKey.rs256(unb64url(json['n'] as String), unb64url(json['e'] as String)),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  /// Whether [signature] is this key's over [message]: ES256 as WebAuthn sends it (an ASN.1 DER
  /// `SEQUENCE { r, s }`), RS256 as PKCS #1 v1.5 with SHA-256.
  bool verify(List<int> message, List<int> signature) {
    if (alg == 'RS256') {
      return rsaVerifySha256(RsaPublicKey(_unsigned(_a), _unsigned(_b)), message, signature);
    }
    final rs = _derSignature(signature);
    if (rs == null) return false;
    final n = p256Domain.n;
    if (rs.r <= BigInt.zero || rs.s <= BigInt.zero || rs.r >= n || rs.s >= n) return false;
    try {
      final verifier = ECDSASigner(SHA256Digest())
        ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(p256Point([4, ..._a, ..._b]), p256Domain)));
      return verifier.verifySignature(Uint8List.fromList(message), ECSignature(rs.r, rs.s));
    } on Object {
      return false;
    }
  }
}

BigInt _unsigned(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// `SEQUENCE { INTEGER r, INTEGER s }`, strictly: short lengths, nothing after it.
({BigInt r, BigInt s})? _derSignature(List<int> der) {
  if (der.length < 8 || der.length > 72 || der[0] != 0x30 || der[1] != der.length - 2) return null;
  var at = 2;
  BigInt? integer() {
    if (at + 2 > der.length || der[at] != 0x02) return null;
    final length = der[at + 1];
    if (length < 1 || length > 33 || at + 2 + length > der.length) return null;
    final value = der.sublist(at + 2, at + 2 + length);
    at += 2 + length;
    if (value[0] & 0x80 != 0) return null;
    return _unsigned(value);
  }

  final r = integer(), s = integer();
  if (r == null || s == null || at != der.length) return null;
  return (r: r, s: s);
}

/// What the browser says it signed (`clientDataJSON`).
class ClientData {
  /// What [parse] read.
  const ClientData({required this.type, required this.challenge, required this.origin, required this.crossOrigin});

  /// `webauthn.create` or `webauthn.get`.
  final String type;

  /// base64url, as the hub gave it.
  final String challenge;
  /// The page's origin, as the browser saw it.
  final String origin;

  /// The page was framed by another origin.
  final bool crossOrigin;

  /// Reads `clientDataJSON`; throws [WebAuthnRefused].
  static ClientData parse(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const WebAuthnRefused('clientDataJSON isn\'t JSON');
    }
    if (json is! Map) throw const WebAuthnRefused('clientDataJSON isn\'t an object');
    final type = json['type'], challenge = json['challenge'], origin = json['origin'], cross = json['crossOrigin'];
    if (type is! String || challenge is! String || origin is! String) throw const WebAuthnRefused('clientDataJSON is missing something');
    // A page framed by another site (topOrigin) never gets a passkey of the family's.
    if (json['topOrigin'] != null) throw const WebAuthnRefused('framed by another page');
    return ClientData(type: type, challenge: challenge, origin: origin, crossOrigin: cross == true);
  }
}

/// The authenticator's own statement (`authenticatorData`).
class AuthData {
  AuthData._(this.rpIdHash, this.flags, this.signCount, this.credentialId, this.key);

  /// SHA-256 of the RP ID the authenticator signed for.
  final Uint8List rpIdHash;

  /// UP, UV, BE, BS, AT and ED.
  final int flags;

  /// The signature counter: information only (synced passkeys keep 0).
  final int signCount;

  /// With attested credential data (registration): the new passkey's id.
  final Uint8List? credentialId;

  /// With attested credential data: the new passkey's public key.
  final PasskeyKey? key;

  /// The person touched or looked (UP).
  bool get present => flags & 0x01 != 0;

  /// The person was verified: Face ID, a fingerprint, the screen lock (UV).
  bool get verified => flags & 0x04 != 0;

  /// The passkey may be synced to the person's other devices (BE), and is (BS). Kept for
  /// information only.
  bool get backupEligible => flags & 0x08 != 0;

  /// See [backupEligible].
  bool get backedUp => flags & 0x10 != 0;

  /// Reads `authenticatorData`, with the new passkey when [attested]; throws [WebAuthnRefused].
  static AuthData parse(List<int> bytes, {bool attested = false}) {
    if (bytes.length < 37) throw const WebAuthnRefused('authenticatorData too short');
    final rpIdHash = Uint8List.fromList(bytes.sublist(0, 32));
    final flags = bytes[32];
    final count = (bytes[33] << 24) | (bytes[34] << 16) | (bytes[35] << 8) | bytes[36];
    if (!attested) return AuthData._(rpIdHash, flags, count, null, null);
    if (flags & 0x40 == 0) throw const WebAuthnRefused('no attested credential data');
    if (bytes.length < 37 + 18) throw const WebAuthnRefused('attested credential data too short');
    final idLength = (bytes[53] << 8) | bytes[54];
    if (idLength < 16 || idLength > 1023 || 55 + idLength > bytes.length) throw const WebAuthnRefused('bad credential id');
    final id = Uint8List.fromList(bytes.sublist(55, 55 + idLength));
    final ({Object? value, int end}) cose;
    try {
      cose = readCbor(bytes, 55 + idLength);
    } on FormatException {
      throw const WebAuthnRefused('credential public key isn\'t CBOR');
    }
    // Extensions (ED) may follow; Den asks for none and reads none.
    if (cose.end != bytes.length && flags & 0x80 == 0) throw const WebAuthnRefused('bytes after the credential key');
    return AuthData._(rpIdHash, flags, count, id, PasskeyKey.fromCose(cose.value));
  }
}

/// What a check expects: the family's own origin (`https://den.example.com`) and RP ID (its
/// host name, `den.example.com`), and the challenge the hub handed out.
class Expected {
  /// What to expect.
  const Expected({required this.origin, required this.rpId, required this.challenge});

  /// `https://den.example.com`.
  final String origin;

  /// `den.example.com`.
  final String rpId;

  /// The challenge, base64url.
  final String challenge;
}

void _checkClient(ClientData client, String type, Expected expected) {
  if (client.type != type) throw WebAuthnRefused('type ${client.type}');
  if (!bytesEqual(utf8.encode(client.challenge), utf8.encode(expected.challenge))) throw const WebAuthnRefused('another challenge');
  if (client.origin != expected.origin) throw WebAuthnRefused('origin ${client.origin}');
  if (client.crossOrigin) throw const WebAuthnRefused('cross-origin');
}

void _checkAuth(AuthData auth, Expected expected) {
  if (!bytesEqual(auth.rpIdHash, sha256(utf8.encode(expected.rpId)))) throw const WebAuthnRefused('another RP ID');
  if (!auth.present) throw const WebAuthnRefused('nobody was there (UP)');
  if (!auth.verified) throw const WebAuthnRefused('not verified (UV)');
}

/// A new passkey, checked.
class NewPasskey {
  /// What [checkRegistration] found.
  const NewPasskey({required this.id, required this.key, required this.signCount, required this.backedUp});

  /// The credential id, base64url.
  final String id;

  /// Its public key.
  final PasskeyKey key;

  /// Its sign counter, for information.
  final int signCount;

  /// Synced to the person's other devices, for information.
  final bool backedUp;
}

/// Checks a registration (`navigator.credentials.create`): [id] is the credential's id as the
/// browser reported it (base64url), [clientDataJson] and [attestationObject] its response.
NewPasskey checkRegistration({
  required String id,
  required List<int> clientDataJson,
  required List<int> attestationObject,
  required Expected expected,
}) {
  _checkClient(ClientData.parse(clientDataJson), 'webauthn.create', expected);
  final Object? attestation;
  try {
    attestation = decodeCbor(attestationObject);
  } on FormatException {
    throw const WebAuthnRefused('attestationObject isn\'t CBOR');
  }
  if (attestation is! Map || attestation['authData'] is! Uint8List) throw const WebAuthnRefused('no authData');
  // `fmt` and `attStmt` are the authenticator's word for what it is; Den asked for none and
  // reads none.
  final auth = AuthData.parse(attestation['authData'] as Uint8List, attested: true);
  _checkAuth(auth, expected);
  final credential = b64url(auth.credentialId!);
  if (credential != id.replaceAll('=', '')) throw const WebAuthnRefused('credential id doesn\'t match');
  return NewPasskey(id: credential, key: auth.key!, signCount: auth.signCount, backedUp: auth.backedUp);
}

/// Checks a sign-in (`navigator.credentials.get`) with the passkey's [key].
AuthData checkAssertion({
  required List<int> clientDataJson,
  required List<int> authenticatorData,
  required List<int> signature,
  required PasskeyKey key,
  required Expected expected,
}) {
  _checkClient(ClientData.parse(clientDataJson), 'webauthn.get', expected);
  final auth = AuthData.parse(authenticatorData);
  _checkAuth(auth, expected);
  if (!key.verify([...authenticatorData, ...sha256(clientDataJson)], signature)) throw const WebAuthnRefused('bad signature');
  return auth;
}
