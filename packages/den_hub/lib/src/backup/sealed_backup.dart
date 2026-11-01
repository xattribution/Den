/// Backups that open with a parent's recovery words: no separate passphrase to keep.
///
/// Each backup is sealed with its own random 32-byte key, and that key is wrapped once for every
/// parent who has saved recovery words. A parent's words already stretch to an Ed25519 key whose
/// public half is in the family's log (`member.recovery.key`, den_core's recovery.dart), so the
/// hub, which never sees the words, can wrap to it: the Ed25519 public key is turned into its
/// X25519 twin (the birational map every Ed25519 key has, as libsodium's
/// `crypto_sign_ed25519_pk_to_curve25519`), an ephemeral X25519 key agrees a secret with it, and
/// HKDF-SHA256 makes the key that seals the backup's key with XChaCha20-Poly1305. To open, the
/// words stretch to the Ed25519 seed again (den_net's [RecoveryWords.key]), whose X25519 twin is
/// the first half of its SHA-512, clamped (as the Ed25519 secret scalar itself is).
///
/// Nothing new is kept anywhere: changing one's words changes the key that later backups are
/// wrapped to, and older backups still open with the words that were current when they were made.
///
/// Layout: `"DENB"`, version 2, a big-endian u32 header length, the header (UTF-8 JSON), a
/// 24-byte nonce, then the XChaCha20-Poly1305 ciphertext and tag of the backup under its key,
/// with everything before the ciphertext as associated data. The header says when the backup was
/// made, the family's name, and holds the wraps: `{kind: words, member, name, key, epk, nonce,
/// box}` per parent, and `{kind: passphrase, m, t, p, salt, nonce, box}` when a passphrase was
/// given too (`den_hub backup --passphrase-env`, for installs whose scripts set one).
///
/// Version 1 (den_net's [encryptBackup], sealed with `DEN_BACKUP_PASSPHRASE` alone) still opens
/// with that passphrase.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';

const List<int> _magic = [0x44, 0x45, 0x4e, 0x42]; // "DENB"
const int _v2 = 2;
const String _wrapLabel = 'den/backup-wrap/v2';
const int _maxHeader = 256 * 1024;

final Xchacha20 _cipher = Xchacha20.poly1305Aead();
final X25519 _x25519 = X25519();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// A parent whose recovery words open a backup: their member id, name, and the public half of
/// the key their words stretch to (`member.recovery.key`).
class BackupRecipient {
  /// The parent [member] called [name], whose recovery key is [key].
  const BackupRecipient({required this.member, required this.name, required this.key});

  /// Member id.
  final String member;

  /// Their name, so a restore can say whose words open it.
  final String name;

  /// base64url Ed25519 public key.
  final String key;
}

/// The parents of [den]'s family who have saved recovery words.
List<BackupRecipient> backupRecipientsOf(Den den) => [
      for (final m in den.members)
        if (m.isParent)
          if (recoveryKeyOf(m) case final key?) BackupRecipient(member: m.id, name: m.name, key: key),
    ];

/// What a backup says about itself before it is opened.
class BackupInfo {
  const BackupInfo._({required this.version, this.madeAt, this.familyName, this.familyId, this.names = const [], this.passphrase = false});

  /// 1: sealed with a passphrase alone (older Den); 2: with recovery words.
  final int version;

  /// When it was made (UTC ms), when it says.
  final int? madeAt;

  /// The family's name, when it says.
  final String? familyName;

  /// The family's id, when it says.
  final String? familyId;

  /// The parents whose recovery words open it.
  final List<String> names;

  /// Whether a passphrase opens it (every version 1 backup, and a version 2 one made with one).
  final bool passphrase;

  /// Whether recovery words open it.
  bool get words => names.isNotEmpty;
}

/// Reads what [sealed] says about itself; throws [BackupException] when it isn't a Den backup.
BackupInfo readBackupInfo(List<int> sealed) {
  if (sealed.length < 6) throw BackupException('not a Den backup');
  for (var i = 0; i < _magic.length; i++) {
    if (sealed[i] != _magic[i]) throw BackupException('not a Den backup');
  }
  if (sealed[4] == 1) return const BackupInfo._(version: 1, passphrase: true);
  if (sealed[4] != _v2) throw BackupException('unsupported backup version ${sealed[4]}');
  final (header, _) = _header(sealed);
  final wraps = _wraps(header);
  return BackupInfo._(
    version: 2,
    madeAt: header['made_at'] is int ? header['made_at'] as int : null,
    familyName: header['family_name'] is String ? header['family_name'] as String : null,
    familyId: header['family'] is String ? header['family'] as String : null,
    names: [for (final w in wraps) if (w['kind'] == 'words' && w['name'] is String) w['name'] as String],
    passphrase: wraps.any((w) => w['kind'] == 'passphrase'),
  );
}

(Map<String, Object?>, int) _header(List<int> sealed) {
  if (sealed.length < 9) throw BackupException('not a Den backup');
  final length = (sealed[5] << 24) | (sealed[6] << 16) | (sealed[7] << 8) | sealed[8];
  if (length <= 0 || length > _maxHeader || sealed.length < 9 + length + 24 + 16) throw BackupException('damaged backup');
  try {
    final json = jsonDecode(utf8.decode(sealed.sublist(9, 9 + length)));
    if (json is Map) return (json.cast<String, Object?>(), 9 + length);
  } on FormatException {
    // Said below.
  }
  throw BackupException('damaged backup');
}

List<Map<String, Object?>> _wraps(Map<String, Object?> header) => [
      if (header['wraps'] case final List<Object?> list)
        for (final w in list)
          if (w is Map) w.cast<String, Object?>(),
    ];

/// The X25519 public key that is the twin of the Ed25519 public key [ed] (32 bytes): Montgomery
/// u = (1 + y) / (1 - y) mod 2^255 - 19, from the Edwards y in [ed].
Uint8List x25519PublicOfEd25519(List<int> ed) {
  if (ed.length != 32) throw ArgumentError('An Ed25519 public key is 32 bytes');
  final p = (BigInt.one << 255) - BigInt.from(19);
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(i == 31 ? ed[i] & 0x7f : ed[i]);
  }
  final one = BigInt.one;
  final denominator = (one - y) % p;
  if (denominator == BigInt.zero) throw ArgumentError('Not a usable Ed25519 public key');
  final u = ((one + y) * denominator.modInverse(p)) % p;
  final out = Uint8List(32);
  var rest = u;
  for (var i = 0; i < 32; i++) {
    out[i] = (rest & BigInt.from(0xff)).toInt();
    rest = rest >> 8;
  }
  return out;
}

/// The X25519 key pair that is the twin of the Ed25519 key whose seed is [seed]: the first 32
/// bytes of SHA-512(seed), which X25519 clamps as Ed25519 does its secret scalar.
Future<SimpleKeyPair> x25519OfEd25519Seed(List<int> seed) async {
  final hash = await Sha512().hash(seed);
  return _x25519.newKeyPairFromSeed(hash.bytes.sublist(0, 32));
}

Future<SecretKey> _wrapKey(List<int> shared, List<int> epk, List<int> recipient) =>
    _hkdf.deriveKey(secretKey: SecretKey(shared), nonce: [...epk, ...recipient], info: utf8.encode(_wrapLabel));

/// Seals [plaintext] so the recovery words of each of [to] open it, and [passphrase] too when
/// given. [madeAt] (UTC ms), [familyName] and [familyId] go in the header, readable before it is
/// opened. Throws [ArgumentError] with nobody to open it.
Future<Uint8List> sealBackup(
  List<int> plaintext, {
  required List<BackupRecipient> to,
  String? passphrase,
  int? madeAt,
  String? familyName,
  String? familyId,
  BackupParams params = BackupParams.standard,
}) async {
  if (to.isEmpty && (passphrase == null || passphrase.isEmpty)) {
    throw ArgumentError('Nobody could open this backup: no parent has saved recovery words');
  }
  final key = randomBytes(32);
  final wraps = <Map<String, Object?>>[];
  for (final r in to) {
    final recipient = x25519PublicOfEd25519(b64d(r.key));
    final eph = await _x25519.newKeyPair();
    final epk = (await eph.extractPublicKey()).bytes;
    final shared = await _x25519.sharedSecretKey(keyPair: eph, remotePublicKey: SimplePublicKey(recipient, type: KeyPairType.x25519));
    final kek = await _wrapKey(await shared.extractBytes(), epk, recipient);
    final nonce = randomBytes(24);
    final box = await _cipher.encrypt(key, secretKey: kek, nonce: nonce, aad: utf8.encode(r.key));
    wraps.add({
      'kind': 'words',
      'member': r.member,
      'name': r.name,
      'key': r.key,
      'epk': b64e(epk),
      'nonce': b64e(nonce),
      'box': b64e([...box.cipherText, ...box.mac.bytes]),
    });
  }
  if (passphrase != null && passphrase.isNotEmpty) {
    final salt = randomBytes(16);
    final kek = await _passphraseKey(passphrase, salt, params);
    final nonce = randomBytes(24);
    final box = await _cipher.encrypt(key, secretKey: kek, nonce: nonce, aad: utf8.encode('passphrase'));
    wraps.add({
      'kind': 'passphrase',
      'm': params.memoryKiB,
      't': params.iterations,
      'p': params.parallelism,
      'salt': b64e(salt),
      'nonce': b64e(nonce),
      'box': b64e([...box.cipherText, ...box.mac.bytes]),
    });
  }
  final header = utf8.encode(jsonEncode({
    'v': _v2,
    'kind': 'den_hub',
    'made_at': ?madeAt,
    'family': ?familyId,
    'family_name': ?familyName,
    'wraps': wraps,
  }));
  final nonce = randomBytes(24);
  final aad = Uint8List.fromList([
    ..._magic,
    _v2,
    (header.length >> 24) & 0xff,
    (header.length >> 16) & 0xff,
    (header.length >> 8) & 0xff,
    header.length & 0xff,
    ...header,
    ...nonce,
  ]);
  final box = await _cipher.encrypt(plaintext, secretKey: SecretKey(key), nonce: nonce, aad: aad);
  return Uint8List.fromList([...aad, ...box.cipherText, ...box.mac.bytes]);
}

Future<SecretKey> _passphraseKey(String passphrase, List<int> salt, BackupParams params) async {
  final kdf = Argon2id(parallelism: params.parallelism, memory: params.memoryKiB, iterations: params.iterations, hashLength: 32);
  final derived = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
  return SecretKey(await derived.extractBytes());
}

/// Why a backup didn't open with what was given.
enum BackupRefusal {
  /// The words are someone's, but not of anyone this backup was sealed for.
  wrongWords,

  /// The passphrase doesn't open it.
  wrongPassphrase,

  /// It opens only with a passphrase (an older backup), and none was given.
  needsPassphrase,

  /// It opens only with recovery words, and none were given.
  needsWords,

  /// Not a Den backup, or damaged.
  damaged,
}

/// A backup that didn't open: [reason] says why.
class BackupOpenException implements Exception {
  /// Refused for [reason].
  BackupOpenException(this.reason);

  /// Why.
  final BackupRefusal reason;

  @override
  String toString() => 'BackupOpenException: ${reason.name}';
}

/// Opens [sealed] with recovery [words] (twelve, as [RecoveryWords.parse] gives them) or a
/// [passphrase], whichever opens it. Throws [BackupOpenException].
Future<Uint8List> openBackup(List<int> sealed, {List<String>? words, String? passphrase}) async {
  final BackupInfo info;
  try {
    info = readBackupInfo(sealed);
  } on BackupException {
    throw BackupOpenException(BackupRefusal.damaged);
  }
  if (info.version == 1) {
    if (passphrase == null || passphrase.isEmpty) throw BackupOpenException(BackupRefusal.needsPassphrase);
    try {
      return await decryptBackup(sealed, passphrase);
    } on BackupException {
      throw BackupOpenException(BackupRefusal.wrongPassphrase);
    }
  }
  final (header, end) = _header(sealed);
  final wraps = _wraps(header);
  List<int>? key;
  if (words != null) {
    final RecoveryKey recovery;
    try {
      recovery = await RecoveryWords.key(words);
    } on FormatException {
      throw BackupOpenException(BackupRefusal.wrongWords);
    }
    for (final w in wraps) {
      if (w['kind'] != 'words' || w['key'] != recovery.publicKey) continue;
      key = await _unwrapWords(w, await recovery.seed(), recovery.publicKey);
      if (key != null) break;
    }
  }
  if (key == null && passphrase != null && passphrase.isNotEmpty) {
    for (final w in wraps) {
      if (w['kind'] != 'passphrase') continue;
      key = await _unwrapPassphrase(w, passphrase);
      if (key != null) break;
    }
  }
  if (key == null) {
    if (words != null) throw BackupOpenException(BackupRefusal.wrongWords);
    if (passphrase != null && passphrase.isNotEmpty) {
      throw BackupOpenException(info.passphrase ? BackupRefusal.wrongPassphrase : BackupRefusal.needsWords);
    }
    throw BackupOpenException(info.words ? BackupRefusal.needsWords : BackupRefusal.needsPassphrase);
  }
  final nonce = sealed.sublist(end, end + 24);
  final aad = sealed.sublist(0, end + 24);
  try {
    final plain = await _cipher.decrypt(
      SecretBox(sealed.sublist(end + 24, sealed.length - 16), nonce: nonce, mac: Mac(sealed.sublist(sealed.length - 16))),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw BackupOpenException(BackupRefusal.damaged);
  }
}

List<int>? _boxParts(Map<String, Object?> w, String name) {
  final v = w[name];
  if (v is! String) return null;
  try {
    return b64d(v);
  } on FormatException {
    return null;
  }
}

Future<List<int>?> _unwrapWords(Map<String, Object?> w, List<int> seed, String publicKey) async {
  final epk = _boxParts(w, 'epk'), nonce = _boxParts(w, 'nonce'), box = _boxParts(w, 'box');
  if (epk == null || epk.length != 32 || nonce == null || nonce.length != 24 || box == null || box.length != 48) return null;
  final mine = await x25519OfEd25519Seed(seed);
  final recipient = (await mine.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(keyPair: mine, remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519));
  final kek = await _wrapKey(await shared.extractBytes(), epk, recipient);
  try {
    return await _cipher.decrypt(SecretBox(box.sublist(0, 32), nonce: nonce, mac: Mac(box.sublist(32))),
        secretKey: kek, aad: utf8.encode(publicKey));
  } on SecretBoxAuthenticationError {
    return null;
  }
}

Future<List<int>?> _unwrapPassphrase(Map<String, Object?> w, String passphrase) async {
  final salt = _boxParts(w, 'salt'), nonce = _boxParts(w, 'nonce'), box = _boxParts(w, 'box');
  final m = w['m'], t = w['t'], p = w['p'];
  if (salt == null || nonce == null || nonce.length != 24 || box == null || box.length != 48) return null;
  if (m is! int || t is! int || p is! int || m < 8 * p || m > 1024 * 1024 || t < 1 || t > 64 || p < 1 || p > 16) return null;
  final kek = await _passphraseKey(passphrase, salt, BackupParams(memoryKiB: m, iterations: t, parallelism: p));
  try {
    return await _cipher.decrypt(SecretBox(box.sublist(0, 32), nonce: nonce, mac: Mac(box.sublist(32))),
        secretKey: kek, aad: utf8.encode('passphrase'));
  } on SecretBoxAuthenticationError {
    return null;
  }
}
