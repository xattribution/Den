import 'dart:typed_data';

import 'package:den_core/den_core.dart';

import 'util.dart';

/// Joining with an invite key (den_core's invite_keys.dart): one pairing message that any
/// device serving sessions for the family accepts (the hub, a parent's phone serving nearby, a
/// group's replica on another family's hub), with nothing kept for it beforehand but the
/// family's own `inviteKey` record.
///
/// The joiner sends `pair {kind: "key", invite: <record id>, proof}`: `invite` is
/// `inviteKeyIdOf` the key's public half (a hash, so the key itself isn't shown), and `proof`
/// the key's Ed25519 signature over `den/pair/v1/admit` 0x00 | the session's transcript hash |
/// the joiner's own key ([admissionPairProof]). The serving side finds the record, checks that
/// it can still let a device in and the signature, and answers `pair_ok` with the family, its
/// founder key, what the key admits (`admit: {mode, member, expires}`) and its own proof
/// ([admissionHostProof]): an HMAC keyed by the key's public half, which only the family's
/// devices hold, so a stranger answering can't pose as the family. The joiner then writes the
/// change that lets it in with the key's proof (`Den.requestInviteJoin`) and sends it as its
/// `join`; validity decides on every replica, as for recovery's self-admission.
///
/// Every proof that names no live key counts against the client that sent it, like wrong invite
/// words at the hub, so a key made from four words can't be found by guessing at the door.
Future<String> admissionPairProof(InviteKey key, List<int> transcriptHash, String joinerPubkey) =>
    key.sign(_pairBytes('den/pair/v1/admit', transcriptHash, joinerPubkey));

/// Checks [admissionPairProof] against the invite key [publicKey].
Future<bool> checkAdmissionPairProof(String proof, String publicKey, List<int> transcriptHash, String joinerPubkey) =>
    verifySignature(_pairBytes('den/pair/v1/admit', transcriptHash, joinerPubkey), proof, publicKey);

/// The serving side's proof that it holds the family's record of the joiner's invite key:
/// HMAC-SHA256 keyed by the key's public half over a label, the transcript hash and its own key.
Future<String> admissionHostProof(String publicKey, List<int> transcriptHash, String hostPubkey) async =>
    b64e(await hmacSha256(b64d(publicKey), _pairBytes('den/pair/v1/admit-host', transcriptHash, hostPubkey)));

Uint8List _pairBytes(String label, List<int> transcript, String pubkey) =>
    concatBytes([utf8Bytes(label), [0], transcript, b64d(pubkey)]);

/// What an invite key lets this device in as, as the family's device said once it checked the
/// key ([JoinAttempt.admittedAs] in sync.dart).
class AdmittedAs {
  /// Creates the answer.
  const AdmittedAs({
    required this.familyId,
    required this.mode,
    required this.expires,
    this.familyName,
    this.member,
    this.memberName,
    this.marker,
    this.picture,
  });

  /// The family.
  final String familyId;

  /// The family's name, when the other side said.
  final String? familyName;

  /// What this device will be.
  final DeviceMode mode;

  /// Whose own device, for a personal one.
  final String? member;

  /// Their name, to name this device and show who it's for.
  final String? memberName;

  /// Their color (den_core's `Marker`) and picture, to show their face before this device holds
  /// their record.
  final String? marker;

  /// See [marker].
  final String? picture;

  /// When the key stops working (UTC ms).
  final int expires;
}
