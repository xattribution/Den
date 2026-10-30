/// Invites that let someone in at once. See ARCHITECTURE.md, "Invite keys".
///
/// A parent's own device writes a trust record (an `inviteKey` record in the family space):
/// "the key K may let in [uses] devices as member M's own, until T", or, bound to nobody, "as a
/// shared screen or the hub". The key is a plain Ed25519 seed: the app puts it in the invite it
/// sends (den_net derives it from the invite's four words), and it can as well be sealed to a
/// device's `xpub` and handed over through a log. The new device then lets itself in with one
/// change to its own device record (`approved: true`, the mode and member the key allows)
/// carrying an [InviteProof] in its `invite` field: K's signature over the family, the record,
/// the member, the mode, the device's key, a fresh nonce and an expiry.
///
/// It follows recovery.dart's rules: the proof is checked when the change arrives; validity
/// accepts it only while the key has uses left, the parent who made it is still a parent with
/// that device still in the family, and before it expires; and a change that takes the key away
/// (the invite withdrawn, its parent removed or no longer a parent, their device removed, "That
/// wasn't Dad") lists in `kept` the devices it let in that its author holds, so a join clocked
/// before that change counts only for those.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'change.dart';
import 'ids.dart';
import 'materializer.dart' show Applied;
import 'model.dart';
import 'store.dart';
import 'validity.dart' show Rejection, RejectionKind, TrustRoot;

/// The longest an invite key may last, from the change that makes it.
const Duration inviteKeyMaxLife = Duration(days: 7);

/// How long the app's invites that let someone in at once last.
const Duration inviteKeyDefaultLife = Duration(hours: 24);

/// The most devices one invite key may let in.
const int inviteKeyMaxUses = 50;

/// Domain label for [InviteProof] signatures.
const String inviteProofLabel = 'den/invite/v1';

/// The fields a device letting itself in with an invite may write to its own record.
const Set<String> inviteJoinFields = {
  'name', 'kind', 'pubkey', 'xpub', 'member', 'mode', 'approved', 'revoked', 'display', 'invite', //
};

final Ed25519 _ed25519 = Ed25519();

/// An invite key's statement that the device with a given key may join the family as [mode]
/// (and as [member]'s own, for a personal device) until [expires]. Signed bytes:
/// `"den/invite/v1" 0x00 | canonical JSON [family, invite, member, mode, device pubkey, nonce,
/// expires]`.
class InviteProof {
  const InviteProof({
    required this.invite,
    required this.member,
    required this.mode,
    required this.key,
    required this.nonce,
    required this.expires,
    required this.sig,
  });

  /// The `inviteKey` record's id ([inviteKeyIdOf] the key).
  final String invite;

  /// Whose device it lets in; null for a shared screen or a hub.
  final String? member;

  /// What the device is for.
  final DeviceMode mode;

  /// The invite key's public half (base64url Ed25519), as the record holds it.
  final String key;

  /// 16 random bytes (base64url).
  final String nonce;

  /// UTC milliseconds after which the proof no longer works; never later than the invite's.
  final int expires;

  /// base64url Ed25519 signature by [key] over [bytes].
  final String sig;

  static Uint8List bytes({
    required String family,
    required String invite,
    required String? member,
    required DeviceMode mode,
    required String devicePubkey,
    required String nonce,
    required int expires,
  }) =>
      Uint8List.fromList([
        ...utf8.encode(inviteProofLabel),
        0,
        ...utf8.encode(canonicalJson([family, invite, member, mode.name, devicePubkey, nonce, expires])),
      ]);

  /// The `invite` field value.
  Map<String, Object?> toJson() => {
        'invite': invite,
        'member': member,
        'mode': mode.name,
        'key': key,
        'nonce': nonce,
        'expires': expires,
        'sig': sig,
      };

  /// Reads an `invite` field value; null when it isn't one.
  static InviteProof? parse(Object? raw) {
    if (raw is! Map) return null;
    final invite = raw['invite'], member = raw['member'], key = raw['key'], nonce = raw['nonce'];
    final expires = raw['expires'], sig = raw['sig'];
    final mode = DeviceMode.values.asNameMap()[raw['mode']];
    if (invite is! String || (member != null && member is! String) || mode == null || key is! String || nonce is! String) {
      return null;
    }
    if (expires is! int || sig is! String) return null;
    return InviteProof(invite: invite, member: member as String?, mode: mode, key: key, nonce: nonce, expires: expires, sig: sig);
  }

  /// Whether [sig] is [key]'s signature for the device with [devicePubkey] in [family].
  Future<bool> verifies({required String family, required String devicePubkey}) => verifySignature(
        bytes(
          family: family,
          invite: invite,
          member: member,
          mode: mode,
          devicePubkey: devicePubkey,
          nonce: nonce,
          expires: expires,
        ),
        sig,
        key,
      );
}

/// The Ed25519 key an invite carries: its public half goes in the family's `inviteKey` record,
/// its 32-byte [seed] in the invite (den_net derives it from the invite's words), or sealed to a
/// device's `xpub` (den_net's seal.dart) for a device that is told of it through a log.
class InviteKey {
  InviteKey._(this._pair, this.publicKey);

  final SimpleKeyPair _pair;

  /// base64url public key, as the `inviteKey` record holds it.
  final String publicKey;

  /// The `inviteKey` record's id for this key.
  String get id => inviteKeyIdOf(publicKey)!;

  /// The key whose private seed is [seed] (32 bytes).
  static Future<InviteKey> fromSeed(List<int> seed) async {
    if (seed.length != 32) throw ArgumentError('An invite key seed is 32 bytes');
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    return InviteKey._(pair, b64e((await pair.extractPublicKey()).bytes));
  }

  /// A new random key.
  static Future<InviteKey> generate() => fromSeed(randomBytes(32));

  /// The private seed: what an invite carries, or what is sealed to a device.
  Future<List<int>> seed() => _pair.extractPrivateKeyBytes();

  /// base64url Ed25519 signature over [bytes] (den_net's pairing proves the key with it).
  Future<String> sign(List<int> bytes) async => b64e((await _ed25519.sign(bytes, keyPair: _pair)).bytes);

  /// Signs a proof that lets the device with [devicePubkey] into [family] as [mode] (and as
  /// [member]'s own, for a personal device), good until [expires] (UTC milliseconds), with a
  /// fresh nonce.
  Future<InviteProof> prove({
    required String family,
    required String? member,
    DeviceMode mode = DeviceMode.personal,
    required String devicePubkey,
    required int expires,
  }) async {
    final nonce = b64e(randomBytes(16));
    final sig = await sign(InviteProof.bytes(
      family: family,
      invite: id,
      member: member,
      mode: mode,
      devicePubkey: devicePubkey,
      nonce: nonce,
      expires: expires,
    ));
    return InviteProof(invite: id, member: member, mode: mode, key: publicKey, nonce: nonce, expires: expires, sig: sig);
  }
}

/// An `inviteKey` record: the key that may let in [uses] devices as [modes] (and as [member]'s
/// own, for a personal device) until [expires], made by [by] on [device].
class InviteKeyRecord extends RecordView {
  const InviteKeyRecord(super.rec);

  /// Whose device it lets in; null for a key bound to no one (a shared screen, a hub).
  String? get member => rec.strOrNull('member');

  /// What the devices it lets in may be: `personal` for someone's own (the default).
  Set<DeviceMode> get modes {
    final raw = rec.fields['modes'];
    if (raw is! List) return const {DeviceMode.personal};
    return {for (final m in raw) ?DeviceMode.values.asNameMap()[m]};
  }

  /// How many devices it may let in (1 unless it says).
  int get uses => rec.integer('uses', 1);

  /// The key's public half, or null once it was taken away (withdrawn, or its parent's role or
  /// device went).
  String? get key => rec.strOrNull('key');

  /// The parent who made it.
  String get by => rec.str('by');

  /// The device it was made on.
  String get device => rec.str('device');

  /// UTC milliseconds.
  int get expires => rec.integer('expires');

  /// When it was made (UTC milliseconds).
  int get made => rec.created.millis;

  /// Whether it can still let a device in at [now]: it has its key and hasn't expired. (Whether
  /// it has uses left is [inviteUsesLeft].)
  bool liveAt(int now) => key != null && now < expires;
}

/// The id of the `inviteKey` record for the key [publicKey]: like a device's, the first 80 bits
/// of its SHA-256, so whoever holds the key names the record from the key alone.
String? inviteKeyIdOf(String publicKey) => deviceIdOf(publicKey);

/// How [d] got in, when an invite key let it in.
InviteProof? inviteOf(Device d) => InviteProof.parse(d.rec.fields['invite']);

/// How many more devices the key [key] of [record] may let in, by [store], not counting [except].
int inviteUsesLeft(RecordStore store, InviteKeyRecord record, {String? except}) {
  var used = 0;
  for (final e in store.ofType(RecordType.device)) {
    if (e.id == except || e.space != Space.family) continue;
    if (InviteProof.parse(e.fields['invite'])?.key == record.key) used++;
  }
  return record.uses - used;
}

/// Checked when a change arrives, before it is stored, like the change's own signature: an
/// invite proof must be signed by the key it names, for the device's key. Validity then decides
/// whether the family made that key. Changes that carry no proof pass.
Future<bool> inviteProofHolds(Change c, String? familyId) async {
  if (c.type != RecordType.device || !c.fields.containsKey('invite')) return true;
  final proof = InviteProof.parse(c.fields['invite']);
  final pubkey = c.fields['pubkey'];
  // A malformed one is stored and refused by validity, the same on every replica.
  if (proof == null || pubkey is! String || familyId == null) return true;
  return proof.verifies(family: familyId, devicePubkey: pubkey);
}

/// Whether [c] takes an invite key away, which can make earlier joins with it count for nothing
/// (recovery.dart's `RetiredRecoveryKeys` keeps these too). Making one never does: a late change
/// before a new key only rewinds, which matters where every device gets a key (a group's).
bool retiresInviteKey(Change c) =>
    c.type == RecordType.inviteKey && c.fields.containsKey('key') && c.fields['key'] == null;

/// The key a valid change [a] took away, when it took one: `(key, kept)`.
(String key, Set<String> kept)? retiredInviteKey(Applied a) {
  final c = a.change;
  if (!retiresInviteKey(c)) return null;
  final old = a.before['key'];
  if (old is! String || old == c.fields['key']) return null;
  final kept = c.fields['kept'];
  return (old, kept is List ? kept.whereType<String>().toSet() : <String>{});
}

/// The devices [store] holds that the invite key [key] let in: what a change taking it away
/// lists as `kept`.
List<String> inviteKeptBy(RecordStore store, String key) => [
      for (final e in store.ofType(RecordType.device))
        if (e.space == Space.family)
          if (InviteProof.parse(e.fields['invite']) case final p?)
            if (p.key == key) e.id,
    ]..sort();

Rejection _trust(String m) => Rejection(RejectionKind.trust, m);
Rejection _deny(String m) => Rejection(RejectionKind.permission, m);
Rejection _schema(String m) => Rejection(RejectionKind.schema, m);

/// Validity for a change to an `inviteKey` record. Making one is a trust decision: a parent on
/// their own device, as themselves, from that device, for at most [inviteKeyMaxLife]: bound to
/// someone in the family (their own devices only), or to no one (shared screens or a hub). The
/// only change after that takes its key away (`key: null` with `kept`), by a parent on their
/// own device; nothing brings a key back, and nothing removes the record. `home` is for groups
/// (a family within a group of families), which a family log refuses.
///
/// In a group ([group]) the key names its home, and groups.dart decides whose it may be.
Rejection? checkInviteKeyWrite(Change c, Entry? existing, RecordStore store,
    {required bool ownDevice, required Member? actor, bool group = false}) {
  const ownOnly = 'Only a parent on their own device can do that, not a shared screen or an app acting through the hub';
  if (!ownDevice) return _deny(ownOnly);
  if (actor == null || !actor.isParent) return _deny('Only a parent can invite someone in');
  if (c.isDelete) return _schema('An invite can\'t be removed, only withdrawn');
  final f = c.fields;
  if (existing == null) {
    if (f['by'] != c.actor) return _schema('An invite must name the parent who made it');
    if (f['device'] != c.device) return _schema('An invite must name the device it was made on');
    final key = f['key'];
    if (key is! String) return _schema('A new invite needs its key');
    if (inviteKeyIdOf(key) != c.rid) return _schema('An invite is named for its key');
    if (f['home'] != null && !group) return _schema('Only a group\'s invite names a home');
    final member = f['member'];
    final modes = {for (final m in (f['modes'] as List?) ?? const ['personal']) m as String};
    if (member != null) {
      if (store.liveAt(Space.family, RecordType.member, member as String) == null) {
        return _schema('That person isn\'t in the family');
      }
      if (modes.length != 1 || modes.single != DeviceMode.personal.name) {
        return _schema('An invite for someone lets in their own devices only');
      }
    } else if (modes.isEmpty || modes.contains(DeviceMode.personal.name)) {
      return _schema('An invite for no one lets in a shared screen or the hub');
    }
    final expires = f['expires'];
    if (expires is! int || expires <= c.hlc.millis) return _schema('That invite has already run out');
    if (expires - c.hlc.millis > inviteKeyMaxLife.inMilliseconds) return _schema('An invite lasts a week at most');
    return null;
  }
  if (f.keys.any((k) => k != 'key' && k != 'kept') || f['key'] != null) {
    return _schema('An invite can only be withdrawn once it\'s made');
  }
  if (existing.fields['key'] == null) return _schema('That invite was withdrawn already');
  return null;
}

/// Validity for a change that writes `invite` to a device record: the device letting itself in,
/// as the mode and person an invite key the family made allows, with that key's proof.
/// [excluded] says whether a later change took the key away without knowing of this device
/// (recovery.dart's `RetiredRecoveryKeys.excludes`). In a group ([group]) the device also writes
/// the family it joins as one of (`home`), which groups.dart checks against the key.
Rejection? checkInviteJoin(Change c, RecordStore store, TrustRoot trust, {required bool excluded, bool group = false}) {
  if (c.rid != c.device) return _trust('An invite lets in only the device that asks');
  if (c.actor != null) return _trust('A device asking to join can\'t act for anyone');
  final own = store.at(Space.family, RecordType.device, c.rid);
  if (own != null) {
    final d = Device(own.rec);
    if (own.deleted || d.revoked) return _trust('This device was removed from the family');
    if (d.approved) return _trust('An invite lets in only a new device');
  }
  final proof = InviteProof.parse(c.fields['invite']);
  if (proof == null) return _trust('That isn\'t an invite');
  final f = c.fields;
  if (f.keys.any((k) => !inviteJoinFields.contains(k) && !(group && k == 'home'))) {
    return _trust('A device let in by an invite sets only its own name, kind and keys');
  }
  if (f['approved'] != true || f['revoked'] == true) return _trust('An invite lets a device in, approved');
  if (f['mode'] != proof.mode.name) return _trust('The proof is for another kind of device');
  if (f['member'] != proof.member) return _trust('The proof is for someone else');
  final pubkey = f['pubkey'];
  if (pubkey is! String || deviceIdOf(pubkey) != c.rid) return _trust('The device key doesn\'t match its id');
  if (own != null && own.fields['pubkey'] != pubkey) return _trust('A device\'s key can\'t change');

  final entry = store.at(Space.family, RecordType.inviteKey, proof.invite);
  if (entry == null || entry.deleted) return _trust('That isn\'t an invite the family made');
  final invite = InviteKeyRecord(entry.rec);
  if (invite.key == null) return _trust('That invite was withdrawn');
  if (invite.key != proof.key) return _trust('That isn\'t the invite\'s key');
  if (invite.member != proof.member) return _trust('The invite is for someone else');
  if (!invite.modes.contains(proof.mode)) return _trust('That invite doesn\'t let in that kind of device');
  if (proof.member != null && store.liveAt(Space.family, RecordType.member, proof.member!) == null) {
    return _trust('That person isn\'t in the family');
  }
  final parent = store.liveAt(Space.family, RecordType.member, invite.by);
  if (parent == null || !Member(parent.rec).isParent) {
    return _deny('The parent who made that invite can\'t let anyone in any more');
  }
  final maker = store.at(Space.family, RecordType.device, invite.device);
  final makerDevice = maker == null ? null : Device(maker.rec);
  if (maker == null || maker.deleted || makerDevice!.revoked || !makerDevice.approved) {
    return _trust('The device that made that invite was removed');
  }
  final at = c.hlc.millis;
  if (proof.expires <= at || invite.expires <= at) return _trust('That invite has expired');
  if (proof.expires > invite.expires) return _trust('The proof outlasts its invite');
  for (final e in store.ofType(RecordType.device)) {
    if (e.id == c.rid) continue;
    if (InviteProof.parse(e.fields['invite'])?.nonce == proof.nonce) return _trust('That invite was used already');
  }
  if (inviteUsesLeft(store, invite, except: c.rid) <= 0) return _trust('That invite was used already');
  if (excluded) return _trust('That invite was withdrawn before this device joined');
  return null;
}
