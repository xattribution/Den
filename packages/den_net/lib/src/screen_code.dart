import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart'
    show Change, DeviceKind, DeviceMode, RecordType, Space, b64e, canonicalJson, deviceIdOf, randomBytes, verifySignature;

import 'util.dart';

/// The short code a kitchen screen shows so a parent can add it from their own phone
/// (ARCHITECTURE.md, "Pairing", "Kitchen screen code").
///
/// The screen picks it: [length] characters of Crockford's base32 ([alphabet], 40 bits), shown
/// in two groups (`K7QM-3RXA`). Typed, it is read without regard to case, spaces or dashes, and
/// the letters people mistake for digits (O for 0, I and L for 1) read as those digits.
///
/// Both ends stretch it with Argon2id (memory [stretchMemoryKiB], [stretchIterations] passes,
/// one lane, 32 bytes), salted with the family's address the screen opened ([origin]:
/// `den/screen-code/v2 0x00 https://den.example.com`), so a table of every code's stretch is good
/// for one family's address only, and derive from that, by HMAC-SHA256:
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
/// average, in the code's ten minutes, or a table built for that one address beforehand.
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

  static final Map<String, Future<ScreenCodeKeys>> _derived = {};

  /// The family's address as both ends write it into the stretch: scheme and host in lower
  /// case and the port only when it isn't the scheme's own (`https://den.example.com`,
  /// `http://192.168.1.20:47733`), whatever path, query or case the address came with. A sync
  /// address (`wss://.../ws`) is the same as the page's (`https://...`).
  static String origin(Uri address) {
    final scheme = switch (address.scheme.toLowerCase()) { 'wss' => 'https', 'ws' => 'http', final s => s };
    final standard = (scheme == 'https' && address.port == 443) || (scheme == 'http' && address.port == 80);
    final port = !address.hasPort || standard ? '' : ':${address.port}';
    return '$scheme://${address.host.toLowerCase()}$port';
  }

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

  /// The slot and MAC key [code] stretches to at the family's address [at] ([origin]). The last
  /// few are kept, so a code stretches once.
  static Future<ScreenCodeKeys> derive(String code, {required Uri at}) {
    final normalized = normalize(code);
    if (normalized == null) throw const FormatException("That isn't a screen's code");
    final where = origin(at);
    final cacheKey = '$normalized $where';
    final known = _derived[cacheKey];
    if (known != null) return known;
    while (_derived.length >= 8) {
      _derived.remove(_derived.keys.first);
    }
    return _derived[cacheKey] = () async {
      final kdf = Argon2id(parallelism: 1, memory: stretchMemoryKiB, iterations: stretchIterations, hashLength: 32);
      final salt = [...utf8Bytes('den/screen-code/v2'), 0, ...utf8Bytes(where)];
      final key = await kdf.deriveKey(secretKey: SecretKey(utf8Bytes(normalized)), nonce: salt);
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

  /// What a screen's QR code holds: `den://screen/K7QM3RXA`. Only Den's own scanner reads it
  /// (seeing the screen is the point); no link opens Add a screen with a code in it.
  static String qr(String code) => '$qrPrefix${normalize(code) ?? code}';

  /// What every screen's QR code starts with.
  static const String qrPrefix = 'den://screen/';

  /// The code in a screen's QR code ([qr]) or in typed text; null when there is none.
  static String? fromText(String text) {
    final t = text.trim();
    return normalize(t.startsWith(qrPrefix) ? t.substring(qrPrefix.length) : t);
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

/// Whether [change] is the join request of the screen with [pubkey] and [xpub], as a screen's
/// code may carry it: its own device record, written by itself for nobody, unapproved, as a
/// shared screen of the [kind] its code was tagged with (never a hub) and called [name] (the
/// name the parent chose), nothing else in it, and signed by that key. The hub checks it before
/// keeping it, and the parent's phone again before it writes it with its approval.
Future<bool> isScreenJoinRequest(
  Change change, {
  required String pubkey,
  required String xpub,
  required String name,
  required String kind,
}) async {
  final device = deviceIdOf(pubkey);
  final f = change.fields;
  final fits = device != null &&
      change.type == RecordType.device &&
      change.space == Space.family &&
      change.rid == device &&
      change.device == device &&
      change.actor == null &&
      f['pubkey'] == pubkey &&
      f['xpub'] == xpub &&
      f['approved'] == false &&
      f['mode'] == DeviceMode.shared.name &&
      f['member'] == null &&
      f['name'] == name &&
      f['kind'] == kind &&
      kind != DeviceKind.hub.name &&
      DeviceKind.values.any((k) => k.name == kind) &&
      f.keys.every(_screenJoinFields.contains);
  return fits && await verifySignature(change.signedBytes, change.sig, pubkey);
}

const Set<String> _screenJoinFields = {'name', 'kind', 'pubkey', 'xpub', 'member', 'mode', 'approved'};
