/// Getting a parent back in when their phone is lost and no other parent device remains to
/// approve a new one. See ARCHITECTURE.md, "Recovery".
///
/// A new device lets itself in as a parent's personal device with one change to its own device
/// record (`approved: true`, `mode: personal`, `member`) carrying a [RecoveryProof] in its
/// `recovery` field. The proof is signed by one of two keys:
///
/// - [RecoveryKind.words]: the parent's own recovery key, stretched from the 12 words they saved
///   (den_net's `RecoveryWords`); its public half is `member.recovery.key`.
/// - [RecoveryKind.hub]: the hub's server recovery key, which the family trusts only while
///   `family.recovery.serverKey` names it (a parent turns that on, on their own device).
///
/// This is the one place a device approves itself, and only as a parent who already is one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'change.dart';
import 'groups.dart' show WindowClosure;
import 'hlc.dart';
import 'ids.dart';
import 'invite_keys.dart' show InviteProof, retiredInviteKey;
import 'materializer.dart' show Applied;
import 'model.dart';
import 'store.dart';
import 'validity.dart';

/// Which key signed a recovery proof.
enum RecoveryKind {
  /// The parent's own recovery words.
  words,

  /// The hub's server recovery key, which the family opted in to.
  hub,
}

/// The longest a recovery proof may be good for, counted from the change that uses it.
const Duration recoveryProofMaxLife = Duration(hours: 1);

/// Domain label for [RecoveryProof] signatures.
const String recoveryProofLabel = 'den/recovery/v1';

/// The fields a recovery change may write to the device's own record.
const Set<String> recoveryChangeFields = {
  'name', 'kind', 'pubkey', 'xpub', 'member', 'mode', 'approved', 'revoked', 'recovery', //
};

final Ed25519 _ed25519 = Ed25519();

/// A recovery key's statement that the device with a given key may join [familyId] as
/// [member]'s own device until [expires]. Signed bytes: `"den/recovery/v1" 0x00 | canonical
/// JSON [family, kind, member, device pubkey, nonce, expires]`.
class RecoveryProof {
  const RecoveryProof({
    required this.kind,
    required this.member,
    required this.key,
    required this.nonce,
    required this.expires,
    required this.sig,
  });

  final RecoveryKind kind;

  /// The parent the device joins as.
  final String member;

  /// The signing key's public half (base64url Ed25519): `member.recovery.key` for words, the
  /// family's `recovery.serverKey` for the hub.
  final String key;

  /// 16 random bytes (base64url). A proof is used once: validity refuses a nonce any device
  /// record already carries.
  final String nonce;

  /// UTC milliseconds after which the proof no longer works.
  final int expires;

  /// base64url Ed25519 signature by [key] over [bytes].
  final String sig;

  /// What the proof's key signs.
  static Uint8List bytes({
    required String family,
    required RecoveryKind kind,
    required String member,
    required String devicePubkey,
    required String nonce,
    required int expires,
  }) =>
      Uint8List.fromList([
        ...utf8.encode(recoveryProofLabel),
        0,
        ...utf8.encode(canonicalJson([family, kind.name, member, devicePubkey, nonce, expires])),
      ]);

  /// The `recovery` field value.
  Map<String, Object?> toJson() =>
      {'kind': kind.name, 'member': member, 'key': key, 'nonce': nonce, 'expires': expires, 'sig': sig};

  /// Reads a `recovery` field value; null when it isn't one.
  static RecoveryProof? parse(Object? raw) {
    if (raw is! Map) return null;
    final kind = RecoveryKind.values.asNameMap()[raw['kind']];
    final member = raw['member'], key = raw['key'], nonce = raw['nonce'], expires = raw['expires'], sig = raw['sig'];
    if (kind == null || member is! String || key is! String || nonce is! String || expires is! int || sig is! String) {
      return null;
    }
    return RecoveryProof(kind: kind, member: member, key: key, nonce: nonce, expires: expires, sig: sig);
  }

  /// Whether [sig] is [key]'s signature for the device with [devicePubkey] in [family].
  Future<bool> verifies({required String family, required String devicePubkey}) => verifySignature(
        bytes(family: family, kind: kind, member: member, devicePubkey: devicePubkey, nonce: nonce, expires: expires),
        sig,
        key,
      );
}

/// An Ed25519 key that signs recovery proofs: a parent's, stretched from their recovery words,
/// or the hub's server recovery key.
class RecoveryKey {
  RecoveryKey._(this._pair, this.publicKey);

  final SimpleKeyPair _pair;

  /// base64url public key, as `member.recovery.key` or `family.recovery.serverKey` holds it.
  final String publicKey;

  /// The key whose private seed is [seed] (32 bytes).
  static Future<RecoveryKey> fromSeed(List<int> seed) async {
    if (seed.length != 32) throw ArgumentError('A recovery key seed is 32 bytes');
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    return RecoveryKey._(pair, b64e((await pair.extractPublicKey()).bytes));
  }

  /// A new random key (the hub's).
  static Future<RecoveryKey> generate() => fromSeed(randomBytes(32));

  /// The private seed, for keeping the key (the hub keeps its own in its data directory).
  Future<List<int>> seed() => _pair.extractPrivateKeyBytes();

  /// base64url Ed25519 signature over [bytes].
  Future<String> sign(List<int> bytes) async => b64e((await _ed25519.sign(bytes, keyPair: _pair)).bytes);

  /// Signs a proof that lets the device with [devicePubkey] into [family] as [member]'s own,
  /// good until [expires] (UTC milliseconds), with a fresh nonce.
  Future<RecoveryProof> prove({
    required String family,
    required RecoveryKind kind,
    required String member,
    required String devicePubkey,
    required int expires,
  }) async {
    final nonce = b64e(randomBytes(16));
    final sig = await sign(RecoveryProof.bytes(
      family: family,
      kind: kind,
      member: member,
      devicePubkey: devicePubkey,
      nonce: nonce,
      expires: expires,
    ));
    return RecoveryProof(kind: kind, member: member, key: publicKey, nonce: nonce, expires: expires, sig: sig);
  }
}

/// A parent's current recovery key (`member.recovery.key`), or null.
String? recoveryKeyOf(Member m) {
  final raw = m.rec.fields['recovery'];
  return raw is Map && raw['key'] is String ? raw['key'] as String : null;
}

/// The hub key the family lets help (`family.recovery.serverKey`), or null while it is off.
String? serverRecoveryKeyOf(Family f) {
  final raw = f.rec.fields['recovery'];
  return raw is Map && raw['serverKey'] is String ? raw['serverKey'] as String : null;
}

/// How [d] was let in, when recovery let it in.
RecoveryProof? recoveryOf(Device d) => RecoveryProof.parse(d.rec.fields['recovery']);

/// Whether [c] sets a parent's recovery key or the family's server key, which can make earlier
/// recovery changes count for nothing (see [RetiredRecoveryKeys]).
bool setsRecoveryKey(Change c) =>
    (c.type == RecordType.member || c.type == RecordType.family) && c.fields.containsKey('recovery');

/// Checked when a change arrives, before it is stored, like the change's own signature: a
/// recovery proof must be signed by the key it names, for the device's key. Validity then
/// decides whether that key is the one the family trusts. Changes that carry no proof pass.
Future<bool> recoveryProofHolds(Change c, String? familyId) async {
  if (c.type != RecordType.device || !c.fields.containsKey('recovery')) return true;
  final proof = RecoveryProof.parse(c.fields['recovery']);
  final pubkey = c.fields['pubkey'];
  // A malformed one, or one without the device's own key beside it, is refused on arrival too:
  // only the device letting itself in writes `recovery`.
  if (proof == null || pubkey is! String || c.rid != c.device || deviceIdOf(pubkey) != c.device) return false;
  if (familyId == null) return true;
  return proof.verifies(family: familyId, devicePubkey: pubkey);
}

/// One recovery key replaced or removed: from its clock on, changes signed earlier that use it
/// count only for the devices the replacing device knew it had let in ([kept]).
class _Retired {
  const _Retired(this.scope, this.key, this.at, this.kept);

  /// The member whose words it was, or '' for the hub's key.
  final String scope;
  final String key;
  final Hlc at;
  final Set<String> kept;
}

/// Recovery keys that were replaced, found in the log the way revocation cutoffs are.
///
/// A device sets its own clock, so whoever still held old words (or a hub's key after the
/// family turned it off) could sign a recovery change dated before the key changed. So the
/// change that replaces a key lists the devices the old key let in that its author held
/// (`kept`), and a recovery change made with the old key and clocked before the replacement
/// counts only for those. The materializer finds these in a first pass and applies them in a
/// second, both from the log alone.
class RetiredRecoveryKeys {
  final List<_Retired> _retired = [];

  /// Windows of invited families in groups closed by their own parents (groups.dart), settled
  /// with these and kept with them.
  final List<WindowClosure> closures = [];

  bool get isEmpty => _retired.isEmpty && closures.isEmpty;

  void clear() {
    _retired.clear();
    closures.clear();
  }

  void addAll(RetiredRecoveryKeys other) {
    _retired.addAll(other._retired);
    closures.addAll(other.closures);
  }

  /// As a snapshot keeps them: `[[scope, key, clock, [kept...]], ...]`, then each closed window
  /// as `["window", change, home, clock, author, [heard...]]`.
  List<Object?> toJson() => [
        for (final r in _retired) [r.scope, r.key, r.at.toString(), r.kept.toList()..sort()],
        for (final w in closures) w.toJson(),
      ];

  /// Reads [toJson]'s output.
  static RetiredRecoveryKeys fromJson(List<Object?> json) {
    final out = RetiredRecoveryKeys();
    for (final row in json) {
      final r = row! as List;
      if (r.length == 6 && r[0] == 'window') {
        out.closures.add(WindowClosure.fromJson(r));
        continue;
      }
      out._retired.add(_Retired(r[0]! as String, r[1]! as String, Hlc.parse(r[2]! as String), (r[3]! as List).cast<String>().toSet()));
    }
    return out;
  }

  /// The scope an invite key taken away is kept under (invite_keys.dart), beside parents' words
  /// and the hub's key: a join with it clocked before that counts only for the devices kept.
  static const String _invites = 'invite';

  /// The keys valid changes in [applied] replaced, and the invite keys they took away.
  static RetiredRecoveryKeys of(Iterable<Applied> applied) {
    final out = RetiredRecoveryKeys();
    for (final a in applied) {
      final c = a.change;
      if (retiredInviteKey(a) case (final key, final kept)) {
        out._retired.add(_Retired(_invites, key, c.hlc, kept));
        continue;
      }
      if (!setsRecoveryKey(c)) continue;
      final member = c.type == RecordType.member;
      final name = member ? 'key' : 'serverKey';
      final before = a.before['recovery'];
      final after = c.fields['recovery'];
      final old = before is Map ? before[name] : null;
      final now = after is Map ? after[name] : null;
      if (old is! String || old == now) continue;
      final kept = after is Map && after['kept'] is List ? (after['kept'] as List).whereType<String>().toSet() : <String>{};
      out._retired.add(_Retired(member ? c.rid : '', old, c.hlc, kept));
    }
    return out;
  }

  /// Whether recovery change [c] used a key that a later change replaced without knowing of it,
  /// or a join with an invite key that a later change took away.
  bool excludes(Change c) {
    if (c.type != RecordType.device || _retired.isEmpty) return false;
    if (InviteProof.parse(c.fields['invite']) case final invite?) {
      return _retired.any((r) => r.scope == _invites && r.key == invite.key && c.hlc < r.at && !r.kept.contains(c.rid));
    }
    final proof = RecoveryProof.parse(c.fields['recovery']);
    if (proof == null) return false;
    final scope = proof.kind == RecoveryKind.hub ? '' : proof.member;
    return _retired.any((r) => r.scope == scope && r.key == proof.key && c.hlc < r.at && !r.kept.contains(c.rid));
  }
}

/// The devices [store] holds that [key] let in for [scope] (a member's words, or the hub's key
/// with [hub]): what a change replacing that key lists as `kept`.
List<String> keptBy(RecordStore store, {required String key, String? member, bool hub = false}) => [
      for (final e in store.ofType(RecordType.device))
        if (e.space == Space.family)
          if (RecoveryProof.parse(e.fields['recovery']) case final p?)
            if (p.key == key && (hub ? p.kind == RecoveryKind.hub : p.kind == RecoveryKind.words && p.member == member))
              e.id,
    ]..sort();

Rejection _trust(String m) => Rejection(RejectionKind.trust, m);
Rejection _deny(String m) => Rejection(RejectionKind.permission, m);

/// Validity for a change that writes `recovery` to a device record: the device letting itself
/// in as an existing parent's own device with a proof from that parent's recovery key or the
/// hub's key the family opted in to. [retired] holds the keys later changes replaced. In a group
/// ([group]) the device also writes the family it joins as one of (`home`; groups.dart).
Rejection? checkRecovery(Change c, RecordStore store, TrustRoot trust, RetiredRecoveryKeys retired, {bool group = false}) {
  if (c.rid != c.device) return _trust('Recovery lets in only the device that asks');
  if (c.actor != null) return _trust('A device asking to join can\'t act for anyone');
  final own = store.at(Space.family, RecordType.device, c.rid);
  if (own != null) {
    final d = Device(own.rec);
    if (own.deleted || d.revoked) return _trust('This device was removed from the family');
    if (d.approved) return _trust('Recovery lets in only a new device');
  }
  final proof = RecoveryProof.parse(c.fields['recovery']);
  if (proof == null) return _trust('That isn\'t a recovery proof');
  final f = c.fields;
  if (f.keys.any((k) => !recoveryChangeFields.contains(k) && !(group && k == 'home'))) {
    return _trust('A device let in by recovery sets only its own name, kind and keys');
  }
  if (f['approved'] != true || f['mode'] != DeviceMode.personal.name || f['revoked'] == true) {
    return _trust('Recovery lets in a parent\'s own device, approved');
  }
  if (f['member'] != proof.member) return _trust('The proof is for someone else');
  final pubkey = f['pubkey'];
  if (pubkey is! String || deviceIdOf(pubkey) != c.rid) return _trust('The device key doesn\'t match its id');
  if (own != null && own.fields['pubkey'] != pubkey) return _trust('A device\'s key can\'t change');

  final m = store.liveAt(Space.family, RecordType.member, proof.member);
  if (m == null) return _trust('That person isn\'t in the family');
  final member = Member(m.rec);
  if (!member.isParent) return _deny('Recovery lets in a phone only for a parent');
  switch (proof.kind) {
    case RecoveryKind.words:
      final key = recoveryKeyOf(member);
      if (key == null) return _trust('${member.name} has no recovery words');
      if (key != proof.key) return _trust('Those aren\'t ${member.name}\'s recovery words');
    case RecoveryKind.hub:
      final fam = trust.familyId == null ? null : store.liveAt(Space.family, RecordType.family, trust.familyId!);
      final key = fam == null ? null : serverRecoveryKeyOf(Family(fam.rec));
      if (key == null) return _deny('The family hasn\'t let the hub help get back in');
      if (key != proof.key) return _trust('That isn\'t the hub key the family trusts');
  }
  final at = c.hlc.millis;
  if (proof.expires <= at) return _trust('That recovery proof has expired');
  if (proof.expires - at > recoveryProofMaxLife.inMilliseconds) {
    return _trust('A recovery proof lasts an hour at most');
  }
  for (final e in store.ofType(RecordType.device)) {
    if (e.id == c.rid) continue;
    final used = e.fields['recovery'];
    if (used is Map && used['nonce'] == proof.nonce) return _trust('That recovery proof was already used');
  }
  if (retired.excludes(c)) return _trust('That recovery key was replaced before this device was let in');
  return null;
}

/// Validity for a change that writes `member.recovery`: someone's recovery key is a trust
/// decision. Only the parent themselves sets theirs, on their own device; any parent on their
/// own device may remove one. [ownDevice] and [actor] come from the validator.
Rejection? checkRecoveryKey(Change c, {required bool ownDevice, required Member? actor, required bool creating}) {
  if (creating) return _deny('Recovery words are set up by the parent themselves, once they\'re in the family');
  if (!ownDevice) {
    return _deny('Only a parent on their own device can do that, not a shared screen or an app acting through the hub');
  }
  if (actor == null || !actor.isParent) return _deny('Only parents keep recovery words');
  final value = c.fields['recovery'];
  if (value is Map && value['key'] != null && c.actor != c.rid) {
    return _deny('Each parent sets up their own recovery words, on their own phone');
  }
  return null;
}
