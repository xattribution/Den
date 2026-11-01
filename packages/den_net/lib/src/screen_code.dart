import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart' show b64e, canonicalJson, randomBytes;

import 'util.dart';

/// The short code a kitchen screen shows so a parent can add it from their own phone
/// (ARCHITECTURE.md, "Pairing", "Kitchen screen code").
///
/// The screen picks it: [length] characters of Crockford's base32 ([alphabet], 40 bits), shown
/// in two groups (`K7QM-3RXA`). Typed, it is read without regard to case, spaces or dashes, and
/// the letters people mistake for digits (O for 0, I and L for 1) read as those digits.
///
/// Both ends stretch it with Argon2id (memory [stretchMemoryKiB], [stretchIterations] passes,
/// one lane, 32 bytes, fixed salt `den/screen-code/v1`) and derive from that, by HMAC-SHA256:
///
/// - the hub's [ScreenCodeKeys.slot] (`den/screen-code/v1/slot`), the only thing the hub keeps
///   the code under, so the hub never learns the code;
/// - a MAC key (`den/screen-code/v1/mac`) for two tags: the screen's ([ScreenCodeKeys.screenTag],
///   over its keys, name and kind), which the parent's phone checks before it shows anything,
///   and the phone's ([ScreenCodeKeys.familyTag], over the family, its founder key, the hub and
///   the name the parent chose), which the screen checks before it asks to join.
///
/// So the key a parent approves is the one the screen in front of her made, even if the hub
/// in between lied: finding the code from the slot takes one Argon2id run per guess, 2^39 on
/// average, in the code's ten minutes.
abstract final class ScreenCode {
  /// Crockford's base32: digits and letters with I, L, O and U left out.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Characters in a code.
  static const int length = 8;

  /// How long a code works.
  static const Duration life = Duration(minutes: 10);

  /// Argon2id memory, in KiB.
  static const int stretchMemoryKiB = 4 * 1024;

  /// Argon2id passes.
  static const int stretchIterations = 3;

  static final Uint8List _salt = utf8Bytes('den/screen-code/v1');
  static final Map<String, Future<ScreenCodeKeys>> _derived = {};

  /// A new random code, [length] characters of [alphabet], no dash.
  static String generate() {
    final bytes = randomBytes(5);
    var bits = 0;
    for (final b in bytes) {
      bits = bits * 256 + b;
    }
    // Division, not shifts: in a browser, shifts work on 32 bits.
    final out = StringBuffer();
    for (var i = 0; i < length; i++) {
      out.write(alphabet[bits % 32]);
      bits ~/= 32;
    }
    return out.toString();
  }

  /// [typed] as a code ([length] characters of [alphabet]), or null when it isn't one: upper
  /// case, without spaces, dashes or dots, O read as 0 and I or L as 1.
  static String? normalize(String typed) {
    final out = StringBuffer();
    for (final rune in typed.toUpperCase().runes) {
      var ch = String.fromCharCode(rune);
      if (' -_.‐‑‒–—\t'.contains(ch)) continue;
      ch = switch (ch) { 'O' => '0', 'I' || 'L' => '1', _ => ch };
      if (!alphabet.contains(ch)) return null;
      out.write(ch);
    }
    final code = out.toString();
    return code.length == length ? code : null;
  }

  /// [code] in two groups for reading: `K7QM-3RXA`.
  static String format(String code) {
    final c = normalize(code) ?? code;
    return c.length == length ? '${c.substring(0, 4)}-${c.substring(4)}' : c;
  }

  /// The slot and MAC key [code] stretches to. The last few are kept, so a code stretches once.
  static Future<ScreenCodeKeys> derive(String code) {
    final normalized = normalize(code);
    if (normalized == null) throw const FormatException("That isn't a screen's code");
    final known = _derived[normalized];
    if (known != null) return known;
    while (_derived.length >= 8) {
      _derived.remove(_derived.keys.first);
    }
    return _derived[normalized] = () async {
      final kdf = Argon2id(parallelism: 1, memory: stretchMemoryKiB, iterations: stretchIterations, hashLength: 32);
      final key = await kdf.deriveKey(secretKey: SecretKey(utf8Bytes(normalized)), nonce: _salt);
      final stretched = await key.extractBytes();
      return ScreenCodeKeys._(
        hexEncode(await hmacSha256(stretched, utf8Bytes('den/screen-code/v1/slot'))),
        await hmacSha256(stretched, utf8Bytes('den/screen-code/v1/mac')),
      );
    }();
  }

  /// Whether [text] has the shape of a slot ([ScreenCodeKeys.slot]): 64 hex characters.
  static bool isSlot(Object? text) => text is String && _slotRe.hasMatch(text);

  static final RegExp _slotRe = RegExp(r'^[0-9a-f]{64}$');

  /// The code in a link or QR code (`https://<hub>/#/add-screen/K7QM3RXA`), or in typed text;
  /// null when there is none.
  static String? fromText(String text) {
    final at = text.indexOf('add-screen/');
    final rest = at < 0 ? text : text.substring(at + 'add-screen/'.length).split(RegExp(r'[?#/&]')).first;
    return normalize(Uri.decodeComponent(rest));
  }
}

/// What a screen's code stretches to ([ScreenCode.derive]).
class ScreenCodeKeys {
  ScreenCodeKeys._(this.slot, this._mac);

  /// What the hub keeps the screen's request under: hex, 64 characters.
  final String slot;
  final Uint8List _mac;

  static const String _screenLabel = 'den/screen-code/v1/screen';
  static const String _familyLabel = 'den/screen-code/v1/family';

  Future<String> _tag(String label, List<Object?> values) async =>
      b64e(await hmacSha256(_mac, [...utf8Bytes(label), 0, ...utf8Bytes(canonicalJson(values))]));

  /// The screen's tag over its device key, its sealing key, the name it suggests and its kind.
  Future<String> screenTag({required String pubkey, required String xpub, required String name, required String kind}) =>
      _tag(_screenLabel, [pubkey, xpub, name, kind]);

  /// The parent's phone's tag over what the screen joins with: the family, its founder's key,
  /// the hub to wait on, the screen's own key and the name the parent chose.
  Future<String> familyTag({
    required String family,
    required String founder,
    required String hub,
    required String pubkey,
    required String name,
  }) =>
      _tag(_familyLabel, [family, founder, hub, pubkey, name]);

  /// Whether [tag] is [expected]'s, in constant time.
  static bool same(String tag, String expected) {
    final a = tryB64d(tag), b = tryB64d(expected);
    return a != null && b != null && constantTimeEquals(a, b);
  }
}
