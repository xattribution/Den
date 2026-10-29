import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:den_core/den_core.dart';

import 'util.dart';
import 'wordlist.dart';
import 'words.dart';

/// A parent's 12 recovery words: 128 random bits and a 4-bit checksum, written with the BIP-39
/// English list (see LICENSE-NOTICE) the way BIP-39 writes a 12-word phrase, so a mistyped word
/// is caught before anything is sent. They stretch with Argon2id to the parent's recovery key
/// ([key]), whose public half the family keeps in `member.recovery.key` (den_core's
/// recovery.dart). Only the parent keeps the words.
abstract final class RecoveryWords {
  /// How many words.
  static const int count = 12;

  /// Argon2id memory, in KiB, for stretching the words ([key]).
  static const int stretchMemoryKiB = 8 * 1024;

  /// Argon2id passes.
  static const int stretchIterations = 3;

  /// The fixed salt. The words carry 128 random bits, so nothing could precompute them; the
  /// stretch makes each guess at a partly known phrase costly too.
  static final Uint8List _salt = utf8Bytes('den/recovery-words/v1');

  /// Twelve new words.
  static List<String> generate() => _wordsFor(randomBytes(16));

  static List<String> _wordsFor(List<int> entropy) {
    final check = const DartSha256().hashSync(entropy).bytes.first >> 4;
    var bits = BigInt.zero;
    for (final b in entropy) {
      bits = (bits << 8) | BigInt.from(b);
    }
    bits = (bits << 4) | BigInt.from(check);
    return [
      for (var i = count - 1; i >= 0; i--) wordList[((bits >> (11 * i)) & BigInt.from(0x7ff)).toInt()],
    ];
  }

  /// Whether [words] are twelve words of the list whose checksum is right.
  static bool valid(List<String> words) {
    if (words.length != count) return false;
    var bits = BigInt.zero;
    for (final w in words) {
      final i = wordIndex(w);
      if (i < 0) return false;
      bits = (bits << 11) | BigInt.from(i);
    }
    final entropy = [for (var i = 15; i >= 0; i--) ((bits >> (4 + 8 * i)) & BigInt.from(0xff)).toInt()];
    return const DartSha256().hashSync(entropy).bytes.first >> 4 == (bits & BigInt.from(0xf)).toInt();
  }

  /// The twelve words in [text] as someone pasted or typed them from wherever they kept them:
  /// separated by spaces, new lines, dashes or commas, numbered or not ("1. maple"), in any
  /// case, each word or its first four letters, with a line of other words around them (the
  /// note's title). Null when [text] holds no twelve words with the right checksum.
  static List<String>? parse(String text) {
    final tokens = [
      for (final t in text.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
        if (t.isNotEmpty && !RegExp(r'^\d+$').hasMatch(t)) t,
    ];
    final known = [for (final t in tokens) wordIndex(t)];
    for (var start = 0; start + count <= tokens.length; start++) {
      final run = known.sublist(start, start + count);
      if (run.any((i) => i < 0)) continue;
      final words = [for (final i in run) wordList[i]];
      if (valid(words)) return words;
    }
    return null;
  }

  /// How many words [text] holds that the list knows, to say how far someone has got.
  static int countIn(String text) => [
        for (final t in text.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
          if (t.isNotEmpty && !RegExp(r'^\d+$').hasMatch(t) && wordIndex(t) >= 0) t,
      ].length;

  /// The recovery key [words] stretch to: Argon2id (memory [stretchMemoryKiB], passes
  /// [stretchIterations], one lane, 32 bytes, salt `den/recovery-words/v1`) over the words
  /// joined by single spaces, as the seed of an Ed25519 key.
  static Future<RecoveryKey> key(List<String> words) async {
    if (!valid(words)) throw const FormatException('Those aren\'t twelve recovery words');
    final normalized = [for (final w in words) wordList[wordIndex(w)]].join(' ');
    final kdf = Argon2id(
      parallelism: 1,
      memory: stretchMemoryKiB,
      iterations: stretchIterations,
      hashLength: 32,
    );
    final seed = await kdf.deriveKey(secretKey: SecretKey(utf8Bytes(normalized)), nonce: _salt);
    return RecoveryKey.fromSeed(await seed.extractBytes());
  }
}

/// What the joiner sends to name a recovery key without showing it: hex SHA-256 of its public
/// half. The side answering finds the parent whose `member.recovery.key` hashes to it.
Future<String> recoveryKeyHash(String publicKey) async => hexEncode(await sha256(b64d(publicKey)));

/// The joiner's proof, in one session, that it holds a parent's recovery key: the key's
/// signature over a label, the session's transcript hash and the joiner's Ed25519 key.
Future<String> recoveryPairProof(RecoveryKey key, List<int> transcriptHash, String joinerPubkey) =>
    key.sign(_pairBytes('den/pair/v1/recovery', transcriptHash, joinerPubkey));

/// Checks [recoveryPairProof] against the parent's recovery key [publicKey].
Future<bool> checkRecoveryPairProof(String proof, String publicKey, List<int> transcriptHash, String joinerPubkey) =>
    verifySignature(_pairBytes('den/pair/v1/recovery', transcriptHash, joinerPubkey), proof, publicKey);

/// The answering side's proof that it holds the family's record of the joiner's recovery key
/// (every device of the family does; a stranger that only saw [recoveryKeyHash] doesn't):
/// HMAC-SHA256 keyed by the key's public half over a label, the transcript hash and its own key.
Future<String> recoveryHostProof(String publicKey, List<int> transcriptHash, String hostPubkey) async =>
    b64e(await hmacSha256(b64d(publicKey), _pairBytes('den/pair/v1/recovery-host', transcriptHash, hostPubkey)));

Uint8List _pairBytes(String label, List<int> transcript, String pubkey) =>
    concatBytes([utf8Bytes(label), [0], transcript, b64d(pubkey)]);
