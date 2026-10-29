import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'change.dart';
import 'ids.dart';
import 'model.dart';

/// PBKDF2-SHA256 rounds of a shared-screen sign-in hashed before [SignInKdf.argon2id]. Such a
/// hash (a `signIn` with no `kdf`) still verifies until it is set again; nothing new uses it.
const int signInIterations = 20000;

/// How a shared-screen PIN or picture pattern is stretched before it is stored, as `signIn.kdf`
/// names it. The hash sits in the family space, so every family device holds it: the stretch
/// is what an offline guess costs.
abstract final class SignInKdf {
  /// Argon2id (RFC 9106, version 0x13, one 32-byte output) over the secret's UTF-8 bytes, with
  /// the record's 16-byte salt and the `memoryKiB`, `iterations` and `parallelism` stored beside
  /// it.
  static const String argon2id = 'argon2id-v1';

  /// Memory for new sign-ins: 6 MiB, with [iterations] passes and one lane. In a browser this is
  /// pure Dart compiled to JavaScript, about 0.25 s on a recent phone and 0.5 s on a slower one,
  /// which is all a sign-in at a shared screen can wait; natively it takes about 0.1 s.
  static const int memoryKiB = 6 * 1024;

  /// Passes over memory for new sign-ins.
  static const int iterations = 2;

  /// Lanes for new sign-ins.
  static const int parallelism = 1;

  /// Argon2id blocks between yields to the event loop, so a browser page can draw while it runs.
  static const int _chunk = 1000;
}

final RegExp _pin = RegExp(r'^(\d{4}|\d{6})$');
final RegExp _pattern = RegExp(r'^[0-8]{4}$');

/// Whether [secret] fits the sign-in kind: a PIN of 4 or 6 digits, or a picture pattern of four
/// animals written as digits 0-8.
bool signInSecretValid(String kind, String? secret) => switch (kind) {
      'pin' => secret != null && _pin.hasMatch(secret),
      'pattern' => secret != null && _pattern.hasMatch(secret),
      'none' => true,
      _ => false,
    };

Future<String> _pbkdf2(String secret, List<int> salt) async {
  final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: signInIterations, bits: 256)
      .deriveKeyFromPassword(password: secret, nonce: salt);
  return b64e(await key.extractBytes());
}

Future<String> _argon2id(String secret, List<int> salt, int memoryKiB, int iterations, int parallelism) async {
  final kdf = DartArgon2id(
    parallelism: parallelism,
    memory: memoryKiB,
    iterations: iterations,
    hashLength: 32,
    blocksPerProcessingChunk: SignInKdf._chunk,
  );
  final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(secret)), nonce: salt);
  return b64e(await key.extractBytes());
}

/// The `signIn` field value for a new secret: a fresh random salt and an Argon2id hash
/// ([SignInKdf]) with its parameters, and for a PIN how many digits it has.
Future<Map<String, Object?>> hashSignIn(String kind, String? secret) async {
  if (kind == 'none') return {'kind': 'none', 'salt': null, 'hash': null};
  final salt = randomBytes(16);
  return {
    'kind': kind,
    'salt': b64e(salt),
    'hash': await _argon2id(secret!, salt, SignInKdf.memoryKiB, SignInKdf.iterations, SignInKdf.parallelism),
    'kdf': SignInKdf.argon2id,
    'memoryKiB': SignInKdf.memoryKiB,
    'iterations': SignInKdf.iterations,
    'parallelism': SignInKdf.parallelism,
    if (kind == 'pin') 'digits': secret.length,
  };
}

/// Checks [secret] against a stored sign-in, stretched the way it says ([SignIn.kdf]), in
/// constant time. False for a sign-in it can't read.
Future<bool> verifySignInHash(String secret, SignIn signIn) async {
  final salt = signIn.salt;
  final hash = signIn.hash;
  if (salt == null || hash == null) return false;
  final String derived;
  try {
    switch (signIn.kdf) {
      case null:
        derived = await _pbkdf2(secret, b64d(salt));
      case SignInKdf.argon2id:
        final m = signIn.memoryKiB, t = signIn.iterations, p = signIn.parallelism;
        if (m == null || t == null || p == null || m < 8 * p) return false;
        derived = await _argon2id(secret, b64d(salt), m, t, p);
      default:
        return false;
    }
  } on FormatException {
    return false;
  }
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
