import 'package:cryptography/cryptography.dart';

import 'change.dart';
import 'ids.dart';

/// PBKDF2 rounds for shared-screen sign-in. The secret only gates who acts on a shared screen in
/// the home; the device's own keys protect everything else.
const int signInIterations = 20000;

final RegExp _pin = RegExp(r'^\d{4}$');
final RegExp _pattern = RegExp(r'^[0-8]{4}$');

/// Whether [secret] fits the sign-in kind: a 4-digit PIN, or a picture pattern of four
/// animals written as digits 0-8.
bool signInSecretValid(String kind, String? secret) => switch (kind) {
      'pin' => secret != null && _pin.hasMatch(secret),
      'pattern' => secret != null && _pattern.hasMatch(secret),
      'none' => true,
      _ => false,
    };

Future<String> _derive(String secret, List<int> salt) async {
  final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: signInIterations, bits: 256)
      .deriveKeyFromPassword(password: secret, nonce: salt);
  return b64e(await key.extractBytes());
}

/// The `signIn` field value for a new secret, with a fresh random salt.
Future<Map<String, Object?>> hashSignIn(String kind, String? secret) async {
  if (kind == 'none') return {'kind': 'none', 'salt': null, 'hash': null};
  final salt = randomBytes(16);
  return {'kind': kind, 'salt': b64e(salt), 'hash': await _derive(secret!, salt)};
}

/// Checks [secret] against a stored salt and hash in constant time.
Future<bool> verifySignInHash(String secret, String salt, String hash) async {
  final derived = await _derive(secret, b64d(salt));
  if (derived.length != hash.length) return false;
  var diff = 0;
  for (var i = 0; i < derived.length; i++) {
    diff |= derived.codeUnitAt(i) ^ hash.codeUnitAt(i);
  }
  return diff == 0;
}

/// A new bearer token: `den_` and 32 random bytes in base64url.
String newBearerToken() => 'den_${b64e(randomBytes(32))}';

/// How bearer tokens are stored and looked up: lowercase hex SHA-256 of the token's UTF-8 bytes.
String hashToken(String token) => sha256Hex(token);
