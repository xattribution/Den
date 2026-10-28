import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';

import 'util.dart';
import 'wordlist.dart';
import 'words.dart';

/// A code read aloud over the phone: four words from the 2048-word list (44 bits).
///
/// Valid for [CodeBook.validity] (10 minutes by default) and burned after [CodeBook.maxFailures]
/// wrong attempts. Wrong attempts count against the code, not against a caller's address: a
/// wrong guess doesn't say which code it was aimed at, so it counts against every live code.
class SpokenCode {
  SpokenCode._(this.words, this.expires);

  /// The four words, lowercase.
  final List<String> words;

  /// When the code stops working.
  final DateTime expires;

  int _failures = 0;
  bool _used = false;

  /// Wrong attempts made while this code was live.
  int get failures => _failures;

  /// Whether the code was redeemed.
  bool get used => _used;

  /// The words separated by single spaces, as shown and spoken.
  String get text => words.join(' ');

  @override
  String toString() => text;
}

/// Number of words in a spoken code.
const int spokenCodeWords = 4;

/// Canonical form of a typed code: four known words, lowercase, single spaces. Each word may be
/// typed as its unique first four letters. Returns null when it isn't a valid code.
String? normalizeCode(String input) {
  final parts = input.trim().toLowerCase().split(RegExp(r'[\s,.\-_]+')).where((p) => p.isNotEmpty).toList();
  if (parts.length != spokenCodeWords) return null;
  final words = <String>[];
  for (final part in parts) {
    final index = wordIndex(part);
    if (index < 0) return null;
    words.add(wordList[index]);
  }
  return words.join(' ');
}

/// Argon2id memory, in KiB, for stretching a spoken code ([stretchCode]).
const int codeStretchMemoryKiB = 4 * 1024;

/// Argon2id passes for stretching a spoken code.
const int codeStretchIterations = 3;

/// The fixed Argon2id salt for spoken codes. Both sides know only the code, so nothing else can
/// go in; a table of every code's stretch would still cost 2^44 Argon2id runs.
final Uint8List _codeSalt = utf8Bytes('den/spoken-code/v2');

final Map<String, Future<Uint8List>> _stretched = {};

/// [code] stretched with Argon2id (memory [codeStretchMemoryKiB], [codeStretchIterations]
/// passes, one lane, 32 bytes): the key the rendezvous slot and both session proofs are made
/// with. A code has only 44 bits, so every guess at it, by a relay holding the slot or a device
/// holding a proof, costs a memory-hard computation, which keeps a search far beyond reach in the
/// code's ten minutes; on a phone or in a browser it is one short wait per join. The last few
/// codes are kept in memory, so one join stretches its code once.
Future<Uint8List> stretchCode(String code) {
  final normalized = normalizeCode(code) ?? code;
  final known = _stretched[normalized];
  if (known != null) return known;
  while (_stretched.length >= 16) {
    _stretched.remove(_stretched.keys.first);
  }
  return _stretched[normalized] = _stretch(normalized);
}

Future<Uint8List> _stretch(String normalized) async {
  final kdf = Argon2id(
    parallelism: 1,
    memory: codeStretchMemoryKiB,
    iterations: codeStretchIterations,
    hashLength: 32,
  );
  final key = await kdf.deriveKey(secretKey: SecretKey(utf8Bytes(normalized)), nonce: _codeSalt);
  return Uint8List.fromList(await key.extractBytes());
}

/// The joiner's proof of knowing [code] in one session: HMAC-SHA256 keyed by the stretched code
/// ([stretchCode]) over a label, the session's transcript hash and the joiner's Ed25519 key.
/// Binding it to the transcript means it can't be replayed into another session.
Future<String> joinerCodeProof(String code, List<int> transcriptHash, String joinerPubkey) =>
    _codeProof('den/pair/v2/joiner', code, transcriptHash, joinerPubkey);

/// The inviting side's proof that it knows [code] too, so a joiner never pairs with a device
/// that merely answered at the rendezvous point.
Future<String> hostCodeProof(String code, List<int> transcriptHash, String hostPubkey) =>
    _codeProof('den/pair/v2/host', code, transcriptHash, hostPubkey);

Future<String> _codeProof(String label, String code, List<int> transcript, String pubkey) async {
  return b64e(await hmacSha256(
    await stretchCode(code),
    concatBytes([utf8Bytes(label), [0], transcript, b64d(pubkey)]),
  ));
}

/// The relay rendezvous slot for a spoken code: hex HMAC-SHA256 of a label under the stretched
/// code ([stretchCode]).
Future<String> codeRendezvousSlot(String code) async {
  final normalized = normalizeCode(code);
  if (normalized == null) throw const FormatException('Not a spoken code');
  return hexEncode(await hmacSha256(await stretchCode(normalized), utf8Bytes('den/rendezvous/v2/code')));
}

/// The inviting side's live spoken codes.
class CodeBook {
  /// Creates an empty book. [now] is injectable for tests.
  CodeBook({
    DateTime Function()? now,
    this.validity = const Duration(minutes: 10),
    this.maxFailures = 5,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// How long a new code stays valid.
  final Duration validity;

  /// Wrong attempts after which a code is burned.
  final int maxFailures;

  final List<SpokenCode> _codes = [];

  /// Codes that can still be redeemed.
  List<SpokenCode> get live {
    _prune();
    return List.unmodifiable(_codes);
  }

  /// A new random code.
  SpokenCode issue() {
    _prune();
    final bytes = randomBytes(6);
    var bits = 0;
    for (final b in bytes) {
      bits = bits * 256 + b;
    }
    final words = <String>[];
    for (var i = 0; i < spokenCodeWords; i++) {
      words.add(wordList[bits % 2048]);
      bits ~/= 2048;
    }
    final code = SpokenCode._(List.unmodifiable(words), _now().add(validity));
    _codes.add(code);
    return code;
  }

  /// Stops accepting [code].
  void cancel(SpokenCode code) => _codes.remove(code);

  /// Checks a typed code. On a match the code is used up and returned; otherwise every live code
  /// records a failure and those at [maxFailures] are burned.
  SpokenCode? redeemTyped(String typed) {
    _prune();
    final normalized = normalizeCode(typed);
    final match = normalized == null ? null : _codes.where((c) => c.text == normalized).firstOrNull;
    return _settle(match);
  }

  /// Checks a joiner's session proof (see [joinerCodeProof]) against every live code, with the
  /// same use-up and failure rules as [redeemTyped].
  Future<SpokenCode?> redeemProof(String proof, List<int> transcriptHash, String joinerPubkey) async {
    _prune();
    final given = tryB64d(proof);
    SpokenCode? match;
    if (given != null) {
      for (final code in _codes) {
        final expected = tryB64d(await joinerCodeProof(code.text, transcriptHash, joinerPubkey))!;
        if (constantTimeEquals(given, expected)) {
          match = code;
          break;
        }
      }
    }
    _prune();
    return _settle(match != null && _codes.contains(match) ? match : null);
  }

  SpokenCode? _settle(SpokenCode? match) {
    if (match != null) {
      match._used = true;
      _codes.remove(match);
      return match;
    }
    for (final code in _codes) {
      code._failures++;
    }
    _codes.removeWhere((c) => c._failures >= maxFailures);
    return null;
  }

  void _prune() {
    final now = _now();
    _codes.removeWhere((c) => !now.isBefore(c.expires));
  }
}
