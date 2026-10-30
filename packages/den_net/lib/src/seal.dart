import 'dart:typed_data';

import 'package:den_core/den_core.dart';

// Sealing to one device moved to den_core (a group's admissions are sealed in a family's log):
// re-exported here, so den_net's API and the envelope's bytes are unchanged.
export 'package:den_core/den_core.dart' show SealException, openSealed, sealToDevice, sealedSender;

/// A space key granted to a device: what a `keys` message carries. [by], [revoked] and [sig]
/// are the maker's statement (see den_core's [SpaceKey]); receivers keep only keys whose
/// statement verifies.
class SpaceKeyGrant {
  /// Creates a grant.
  const SpaceKeyGrant({
    required this.space,
    required this.epoch,
    required this.key,
    this.by,
    this.revoked = const [],
    this.sig,
  });

  /// The grant for a key and its maker's statement.
  factory SpaceKeyGrant.of(SpaceKey key) => SpaceKeyGrant(
        space: key.space,
        epoch: key.epoch,
        key: key.key,
        by: key.by,
        revoked: key.revoked,
        sig: key.sig,
      );

  /// Space id.
  final String space;

  /// Key epoch; mailbox ids are derived per epoch.
  final int epoch;

  /// The 32-byte key.
  final Uint8List key;

  /// The device that made the key.
  final String? by;

  /// Approved devices that were revoked when [by] made it, sorted.
  final List<String> revoked;

  /// [by]'s signature over the statement.
  final String? sig;

  /// The key with its statement, for `Den.addSpaceKey`.
  SpaceKey get spaceKey => SpaceKey(space: space, epoch: epoch, key: key, by: by, revoked: revoked, sig: sig);

  /// The `keys` message body: `{t: keys, space, epoch, key, by, revoked, sig}`.
  Map<String, Object?> toJson() => {'t': 'keys', ...spaceKey.toJson()};

  /// Parses a `keys` message body; null when malformed.
  static SpaceKeyGrant? fromJson(Map<String, Object?> json) {
    final key = SpaceKey.fromJson(json);
    return key == null ? null : SpaceKeyGrant.of(key);
  }
}

/// Seals a space key grant to a device (see [sealToDevice]).
Future<Map<String, Object?>> sealSpaceKey({
  required DeviceKeys sender,
  required String recipientDevice,
  required String recipientXpub,
  required SpaceKeyGrant grant,
}) =>
    sealToDevice(
      sender: sender,
      recipientDevice: recipientDevice,
      recipientXpub: recipientXpub,
      payload: grant.toJson(),
    );

/// Opens a sealed space key grant (see [openSealed]).
Future<SpaceKeyGrant> openSpaceKey(
  Map<String, Object?> envelope, {
  required DeviceKeys recipient,
  required String senderPubkey,
}) async {
  final payload = await openSealed(envelope, recipient: recipient, senderPubkey: senderPubkey);
  final grant = payload['t'] == 'keys' ? SpaceKeyGrant.fromJson(payload) : null;
  if (grant == null) throw SealException('not a space key grant');
  return grant;
}
