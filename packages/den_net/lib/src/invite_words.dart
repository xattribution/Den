import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';

import 'spoken_code.dart' show normalizeCode;
import 'util.dart';
import 'wordlist.dart';

/// The four words of an invite that lets someone in at once (den_core's invite_keys.dart).
///
/// The parent's phone picks them, and everything else comes from them: stretched with Argon2id
/// (memory [stretchMemoryKiB], [stretchIterations] passes, one lane, 32 bytes, fixed salt
/// `den/invite-words/v1`), they give the hub's slot for the invite ([slot], HMAC-SHA256 of
/// `den/invite/v1/slot`) and the seed of the invite's key ([key], HMAC-SHA256 of
/// `den/invite/v1/key`). The link carries the words in its fragment
/// (`https://<hub>/#/join/<w>-<w>-<w>-<w>`), which browsers never send to the hub, and the hub
/// keeps the invite under the slot alone, so whoever runs it can't let someone in with it: from
/// the slot, or the key's public half in the family's log, finding the words takes one Argon2id
/// run per guess, 2^43 on average, in the invite's 24 hours. Typed words work the same as the
/// link, so the words are a fallback for a device the link can't reach, not a weaker invite.
abstract final class InviteWords {
  /// Argon2id memory, in KiB.
  static const int stretchMemoryKiB = 4 * 1024;

  /// Argon2id passes.
  static const int stretchIterations = 3;

  static final Uint8List _salt = utf8Bytes('den/invite-words/v1');
  static final Map<String, Future<Uint8List>> _stretched = {};

  /// Four new words from Den's word list (44 bits), lowercase, single spaces.
  static String generate() {
    final bytes = randomBytes(6);
    var bits = 0;
    for (final b in bytes) {
      bits = bits * 256 + b;
    }
    // Division, not shifts: in a browser, shifts work on 32 bits.
    final words = <String>[];
    for (var i = 0; i < 4; i++) {
      words.add(wordList[bits % 2048]);
      bits ~/= 2048;
    }
    return words.join(' ');
  }

  /// [code] stretched (see the class). The last few are kept, so one invite stretches once.
  static Future<Uint8List> stretch(String code) {
    final normalized = normalizeCode(code);
    if (normalized == null) throw const FormatException('Not four words from an invite');
    final known = _stretched[normalized];
    if (known != null) return known;
    while (_stretched.length >= 8) {
      _stretched.remove(_stretched.keys.first);
    }
    return _stretched[normalized] = () async {
      final kdf = Argon2id(parallelism: 1, memory: stretchMemoryKiB, iterations: stretchIterations, hashLength: 32);
      final key = await kdf.deriveKey(secretKey: SecretKey(utf8Bytes(normalized)), nonce: _salt);
      return Uint8List.fromList(await key.extractBytes());
    }();
  }

  /// The hub's slot for the invite [code] opens: hex, 64 characters.
  static Future<String> slot(String code) async =>
      hexEncode(await hmacSha256(await stretch(code), utf8Bytes('den/invite/v1/slot')));

  /// The invite's key: its public half is in the family's `inviteKey` record, named by
  /// `inviteKeyIdOf`.
  static Future<InviteKey> key(String code) async =>
      InviteKey.fromSeed(await hmacSha256(await stretch(code), utf8Bytes('den/invite/v1/key')));
}
