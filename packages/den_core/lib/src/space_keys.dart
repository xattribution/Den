import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import 'change.dart';

/// A space's key for one epoch, bound to the device that made it.
///
/// The maker signs `"den/space-key/v1" 0x00 | canonical JSON [family, space, epoch, hash, by,
/// revoked]` ([statementBytes]), where `hash` is [spaceKeyHash] of the key and `revoked` lists,
/// sorted, every approved device that was revoked when the maker made it: the devices the maker
/// knew not to give it to. Any device can pass a key on; receivers check the signature against
/// the maker's device record, so only a parent's device or a hub can mint one.
///
/// Two parents who revoke devices while out of touch each make a key for the same epoch. Every
/// replica keeps both and picks the same one ([pickSpaceKey]), so the family's mailbox for that
/// epoch can't split; a parent's device or hub that then sees a revoked device listed by one
/// candidate but not by the winner rotates again, because the winner may have reached it.
///
/// A key stored without a statement ([Den.setSpaceKey], or kept from before keys were bound) has
/// a null [by] and [sig]. It is trusted on this device only, loses to any bound key at its
/// epoch, and a parent's device or hub signs it as its own before passing it on.
class SpaceKey {
  /// Creates a key; [revoked] is sorted and deduplicated.
  SpaceKey({
    required this.space,
    required this.epoch,
    required List<int> key,
    this.by,
    Iterable<String> revoked = const [],
    this.sig,
  })  : key = Uint8List.fromList(key),
        revoked = List.unmodifiable(revoked.toSet().toList()..sort());

  /// The space id.
  final String space;

  /// The key epoch; mailbox ids are derived per epoch.
  final int epoch;

  /// The 32-byte key.
  final Uint8List key;

  /// The device that made the key, or null for a key stored without a statement.
  final String? by;

  /// Approved devices that were revoked when [by] made the key, sorted.
  final List<String> revoked;

  /// base64url Ed25519 signature by [by] over [statementBytes], or null.
  final String? sig;

  /// Whether the key carries its maker's statement.
  bool get bound => by != null && sig != null;

  /// [spaceKeyHash] of [key]: how candidates are told apart and ordered.
  String get hash => spaceKeyHash(key);

  /// The bytes [by] signs, for [family].
  Uint8List statementBytes(String family) => Uint8List.fromList([
        ...utf8.encode('den/space-key/v1'),
        0,
        ...utf8.encode(canonicalJson([family, space, epoch, hash, by, revoked])),
      ]);

  /// The same key with [by]'s statement.
  SpaceKey signed({required String by, required Iterable<String> revoked, required String sig}) =>
      SpaceKey(space: space, epoch: epoch, key: key, by: by, revoked: revoked, sig: sig);

  /// `{space, epoch, key, by, revoked, sig}`, the last three only when bound.
  Map<String, Object?> toJson() => {
        'space': space,
        'epoch': epoch,
        'key': b64e(key),
        if (bound) ...{'by': by, 'revoked': revoked, 'sig': sig},
      };

  /// Parses [toJson] output (and the same fields inside a `keys` message); null when malformed.
  /// A `revoked` list that isn't sorted and unique is malformed, since the signature covers it
  /// as sent.
  static SpaceKey? fromJson(Map<String, Object?> json) {
    final space = json['space'];
    final epoch = json['epoch'];
    final by = json['by'];
    final sig = json['sig'];
    final rawRevoked = json['revoked'] ?? const <Object?>[];
    Uint8List? key;
    try {
      final k = json['key'];
      if (k is String) key = b64d(k);
    } on FormatException {
      key = null;
    }
    if (space is! String || space.isEmpty || epoch is! int || epoch < 0 || key == null || key.length != 32) return null;
    if (by is! String? || sig is! String? || (by == null) != (sig == null)) return null;
    if (rawRevoked is! List || rawRevoked.any((d) => d is! String)) return null;
    final revoked = rawRevoked.cast<String>();
    for (var i = 1; i < revoked.length; i++) {
      if (revoked[i - 1].compareTo(revoked[i]) >= 0) return null;
    }
    return SpaceKey(space: space, epoch: epoch, key: key, by: by, revoked: revoked, sig: sig);
  }

  @override
  String toString() => 'SpaceKey($space@$epoch ${hash.substring(0, 8)} by ${by ?? 'nobody'})';
}

/// Lowercase hex SHA-256 of `"den/space-key/v1/hash" 0x00 | key`.
String spaceKeyHash(List<int> key) => const DartSha256()
    .hashSync([...utf8.encode('den/space-key/v1/hash'), 0, ...key])
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// The key every replica picks among [candidates] for one epoch: a bound key whose maker is
/// still in good standing ([valid]) with the lowest hash, else a key stored without a statement,
/// else any bound key with the lowest hash. Null for no candidates.
SpaceKey? pickSpaceKey(Iterable<SpaceKey> candidates, bool Function(SpaceKey key) valid) {
  SpaceKey? best;
  var bestRank = 3;
  for (final c in candidates) {
    final rank = c.bound ? (valid(c) ? 0 : 2) : 1;
    if (rank < bestRank || (rank == bestRank && c.hash.compareTo(best!.hash) < 0)) {
      best = c;
      bestRank = rank;
    }
  }
  return best;
}

/// What [Den.addSpaceKey] did with a key.
enum SpaceKeyOutcome {
  /// Kept as a candidate for its epoch (or it upgraded the same key stored without a statement).
  stored,

  /// This device already holds that key for that epoch.
  duplicate,

  /// The maker's device record hasn't arrived yet; the key waits in memory and is checked again
  /// after the next ingest.
  waiting,

  /// Not signed, signed by a device that may not make keys, or the signature doesn't verify.
  refused,
}
