import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';

import 'util.dart';

/// Argon2id cost parameters stored in every backup header.
class BackupParams {
  /// Creates parameters; [memoryKiB] is in 1 KiB blocks.
  const BackupParams({required this.memoryKiB, required this.iterations, required this.parallelism});

  /// OWASP's minimum Argon2id configuration (19 MiB, t=2, p=1), usable in pure Dart on phones.
  static const BackupParams standard = BackupParams(memoryKiB: 19 * 1024, iterations: 2, parallelism: 1);

  /// Memory in KiB.
  final int memoryKiB;

  /// Passes over memory.
  final int iterations;

  /// Lanes.
  final int parallelism;
}

/// A backup that can't be opened: wrong passphrase, damaged, or not a Den backup.
class BackupException implements Exception {
  /// Creates the exception.
  BackupException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'BackupException: $message';
}

const List<int> _magic = [0x44, 0x45, 0x4e, 0x42]; // "DENB"
const int _version = 1;
const int _kdfArgon2id = 1;
const int _saltLength = 16;
const int _nonceLength = 24;
const int _headerLength = 4 + 1 + 1 + 4 + 4 + 1 + _saltLength + _nonceLength;

// Ceilings on what a header may ask for, so a crafted file can't exhaust memory or time.
const int _maxMemoryKiB = 1024 * 1024;
const int _maxIterations = 64;
const int _maxParallelism = 16;

final Xchacha20 _cipher = Xchacha20.poly1305Aead();

/// Seals [plaintext] with a key derived from [passphrase].
///
/// Layout: `"DENB"`, version (1), KDF id (1 = Argon2id), memory KiB (u32), iterations (u32),
/// parallelism (u8), salt (16), nonce (24), then XChaCha20-Poly1305 ciphertext and tag. The
/// whole header is authenticated as associated data.
Future<Uint8List> encryptBackup(
  List<int> plaintext,
  String passphrase, {
  BackupParams params = BackupParams.standard,
}) async {
  if (passphrase.isEmpty) throw ArgumentError('passphrase must not be empty');
  final salt = randomBytes(_saltLength);
  final nonce = randomBytes(_nonceLength);
  final header = concatBytes([
    _magic,
    [_version, _kdfArgon2id],
    u32be(params.memoryKiB),
    u32be(params.iterations),
    [params.parallelism],
    salt,
    nonce,
  ]);
  final key = await _deriveKey(passphrase, salt, params);
  final box = await _cipher.encrypt(plaintext, secretKey: key, nonce: nonce, aad: header);
  return concatBytes([header, box.cipherText, box.mac.bytes]);
}

/// Opens a backup made by [encryptBackup]. Throws [BackupException] on a wrong passphrase or
/// any damage.
Future<Uint8List> decryptBackup(List<int> sealed, String passphrase) async {
  if (sealed.length < _headerLength + 16) throw BackupException('not a Den backup');
  for (var i = 0; i < _magic.length; i++) {
    if (sealed[i] != _magic[i]) throw BackupException('not a Den backup');
  }
  if (sealed[4] != _version) throw BackupException('unsupported backup version ${sealed[4]}');
  if (sealed[5] != _kdfArgon2id) throw BackupException('unsupported key derivation');
  final params = BackupParams(
    memoryKiB: readU32be(sealed, 6),
    iterations: readU32be(sealed, 10),
    parallelism: sealed[14],
  );
  if (params.memoryKiB < 8 * params.parallelism ||
      params.memoryKiB > _maxMemoryKiB ||
      params.iterations < 1 ||
      params.iterations > _maxIterations ||
      params.parallelism < 1 ||
      params.parallelism > _maxParallelism) {
    throw BackupException('backup asks for unreasonable key derivation costs');
  }
  final salt = sealed.sublist(15, 15 + _saltLength);
  final nonce = sealed.sublist(15 + _saltLength, _headerLength);
  final header = sealed.sublist(0, _headerLength);
  final key = await _deriveKey(passphrase, salt, params);
  try {
    final plain = await _cipher.decrypt(
      SecretBox(
        sealed.sublist(_headerLength, sealed.length - 16),
        nonce: nonce,
        mac: Mac(sealed.sublist(sealed.length - 16)),
      ),
      secretKey: key,
      aad: header,
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw BackupException('wrong passphrase or damaged backup');
  }
}

Future<SecretKey> _deriveKey(String passphrase, List<int> salt, BackupParams params) async {
  final kdf = Argon2id(
    parallelism: params.parallelism,
    memory: params.memoryKiB,
    iterations: params.iterations,
    hashLength: 32,
  );
  final derived = await kdf.deriveKey(secretKey: SecretKey(utf8Bytes(passphrase)), nonce: salt);
  return SecretKey(await derived.extractBytes());
}
