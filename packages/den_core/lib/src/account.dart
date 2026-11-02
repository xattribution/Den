import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKeyData;
import 'package:cryptography/dart.dart' show DartHmac, DartSha256;

import 'change.dart';
import 'model.dart' show RecordType;

/// The accounts a person can sign in to Den with: Google and Apple (OpenID Connect). There is no
/// email link or password: someone with neither uses a device a parent set up.
const Set<String> accountProviders = {'google', 'apple'};

/// The longest a hub's [AccountProof] may claim to last.
const Duration accountProofMaxLife = Duration(days: 1);

/// How long the hub makes a proof last: the phone writes it as soon as it has read it back.
const Duration accountProofLife = Duration(hours: 1);

/// The hub's word that someone really signed in with an account, for one member of one family:
/// its device ([hub], whose key is [key]) signs `"den/account-proof/v1" 0x00 | canonical JSON
/// [family, member, provider, hash, hub, nonce, expires]`. `member.account` carries it, so a
/// parent can't bind a hash they computed (a Google `sub` can be looked up; the family id is on
/// every device) without that account's real sign-in. The signature is checked when the change
/// arrives, like the change's own ([accountProofHolds]); validity checks that [key] is the key of
/// an approved hub of the family, at the change's place in the log, and [expires].
class AccountProof {
  const AccountProof({required this.hub, required this.key, required this.nonce, required this.expires, required this.sig});

  /// The hub device that signed.
  final String hub;

  /// Its Ed25519 public key (base64url).
  final String key;

  /// The binding it is for: random, so no two proofs are alike.
  final String nonce;

  /// UTC milliseconds after which a change can't use it.
  final int expires;

  /// The signature (base64url).
  final String sig;

  /// What the hub signs for [member] of [family].
  static Uint8List signedBytes({
    required String family,
    required String member,
    required String provider,
    required String hash,
    required String hub,
    required String nonce,
    required int expires,
  }) =>
      Uint8List.fromList([
        ...utf8.encode('den/account-proof/v1'),
        0,
        ...utf8.encode(canonicalJson([family, member, provider, hash, hub, nonce, expires])),
      ]);

  /// The hub with [keys] (its device keys; its device id [hub]) vouching that [member] of
  /// [family] signed in with the [provider] account whose hash is [hash].
  static Future<AccountRef> sign({
    required DeviceKeys keys,
    required String hub,
    required String family,
    required String member,
    required String provider,
    required String hash,
    required String nonce,
    required int expires,
  }) async {
    final bytes = signedBytes(family: family, member: member, provider: provider, hash: hash, hub: hub, nonce: nonce, expires: expires);
    return AccountRef(provider, hash,
        proof: AccountProof(hub: hub, key: keys.pubkey, nonce: nonce, expires: expires, sig: await keys.sign(bytes)));
  }

  /// Whether [sig] is [key]'s over this proof for [member] of [family] and [account].
  Future<bool> verifies({required String family, required String member, required AccountRef account}) => verifySignature(
        signedBytes(
            family: family, member: member, provider: account.provider, hash: account.hash, hub: hub, nonce: nonce, expires: expires),
        sig,
        key,
      );
}

/// Which Google or Apple account signs in as a member (`member.account`): the provider, and
/// [accountHash] of the account's subject (`sub`, the provider's own id for the person), with the
/// hub's [proof] that it signed in. Never the email: an address can be given up and handed to
/// someone else, a `sub` can't. Two references are the same account when provider and hash are.
class AccountRef {
  const AccountRef(this.provider, this.hash, {this.proof});

  /// `google` or `apple` ([accountProviders]).
  final String provider;

  /// [accountHash] of the account in this family: 64 hex digits.
  final String hash;

  /// The hub's word that this account signed in for the member; what binding needs.
  final AccountProof? proof;

  /// The `member.account` field value.
  Map<String, Object?> toJson() => {
        'provider': provider,
        'hash': hash,
        if (proof case final p?) ...{'hub': p.hub, 'key': p.key, 'nonce': p.nonce, 'expires': p.expires, 'sig': p.sig},
      };

  /// [value] as a reference, or null when it isn't one (no account, or a malformed value). A
  /// value without a whole proof reads with none.
  static AccountRef? fromJson(Object? value) {
    if (value is! Map) return null;
    final provider = value['provider'], hash = value['hash'];
    if (provider is! String || !accountProviders.contains(provider) || hash is! String) return null;
    final hub = value['hub'], key = value['key'], nonce = value['nonce'], expires = value['expires'], sig = value['sig'];
    final proof = hub is String && key is String && nonce is String && expires is int && sig is String
        ? AccountProof(hub: hub, key: key, nonce: nonce, expires: expires, sig: sig)
        : null;
    return AccountRef(provider, hash, proof: proof);
  }

  @override
  bool operator ==(Object other) => other is AccountRef && other.provider == provider && other.hash == hash;

  @override
  int get hashCode => Object.hash(provider, hash);
}

/// The hash `member.account` holds for the [provider] account whose subject is [sub], in the
/// family [familyId]: lowercase hex of HMAC-SHA256 keyed by the family id's UTF-8 bytes, over
/// `"den/account/v1" 0x00 provider 0x00 sub`.
///
/// Keyed by the family id, so the same person in two families has two unrelated hashes: whoever
/// holds both families' logs (a Den host, a backup, a device in both) can't tell from them that
/// it is one person. The family id never changes, so a binding survives the hub moving, being
/// restored from a backup, or the family getting another hub; and every replica can compute it,
/// so nothing about it depends on a key one machine holds. It hides the `sub` from nobody who
/// already has it, which is why binding also takes the hub's [AccountProof].
String accountHash(String familyId, String provider, String sub) {
  final mac = const DartHmac(DartSha256()).calculateMacSync(
    [...utf8.encode('den/account/v1'), 0, ...utf8.encode(provider), 0, ...utf8.encode(sub)],
    secretKeyData: SecretKeyData(utf8.encode(familyId)),
    nonce: const [],
  );
  return [for (final b in mac.bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

/// Checked when a change arrives, before it is stored, like the change's own signature: an
/// account a change binds must carry a proof signed by the key it names, for this member of this
/// family. Validity then decides whether that key is one of the family's hubs. Changes that bind
/// nothing pass; a malformed one is stored and refused by validity, the same on every replica.
Future<bool> accountProofHolds(Change c, String? familyId) async {
  if (c.type != RecordType.member || !c.fields.containsKey('account')) return true;
  final account = AccountRef.fromJson(c.fields['account']);
  final proof = account?.proof;
  if (account == null || proof == null || familyId == null) return true;
  return proof.verifies(family: familyId, member: c.rid, account: account);
}
