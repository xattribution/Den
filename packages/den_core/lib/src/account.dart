import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKeyData;
import 'package:cryptography/dart.dart' show DartHmac, DartSha256;

/// The accounts a person can sign in to Den with: Google and Apple (OpenID Connect). There is no
/// email link or password: someone with neither signs in on a device a parent set up.
const Set<String> accountProviders = {'google', 'apple'};

/// Which Google or Apple account signs in as a member (`member.account`): the provider, and
/// [accountHash] of the account's subject (`sub`, the provider's own id for the person). Never
/// the email: an address can be given up and handed to someone else, a `sub` can't.
class AccountRef {
  const AccountRef(this.provider, this.hash);

  /// `google` or `apple` ([accountProviders]).
  final String provider;

  /// [accountHash] of the account in this family: 64 hex digits.
  final String hash;

  /// The `member.account` field value.
  Map<String, Object?> toJson() => {'provider': provider, 'hash': hash};

  /// [value] as a reference, or null when it isn't one (no account, or a malformed value).
  static AccountRef? fromJson(Object? value) {
    if (value is! Map) return null;
    final provider = value['provider'], hash = value['hash'];
    if (provider is! String || !accountProviders.contains(provider) || hash is! String) return null;
    return AccountRef(provider, hash);
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
/// already has it: it only keeps families from being joined up by their records.
String accountHash(String familyId, String provider, String sub) {
  final mac = const DartHmac(DartSha256()).calculateMacSync(
    [...utf8.encode('den/account/v1'), 0, ...utf8.encode(provider), 0, ...utf8.encode(sub)],
    secretKeyData: SecretKeyData(utf8.encode(familyId)),
    nonce: const [],
  );
  return [for (final b in mac.bytes) b.toRadixString(16).padLeft(2, '0')].join();
}
