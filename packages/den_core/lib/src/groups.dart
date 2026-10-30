/// Groups of families: a Den log of its own (`family.kind: group`) whose people and devices
/// come from several families. See ARCHITECTURE.md, "Groups of families".
///
/// Every family in a group is a `home` record. Every person carries their home (`member.home`)
/// and every device carries its family's (`device.home`); neither ever changes. The trust rules
/// live here, as one hook in validity.dart ([checkGroupRules]), the same pattern as recovery.dart:
///
/// - **G1** a person's home is required and fixed; a device's is its owner's, and fixed.
/// - **G2** every trust decision about a person or a device (adding, role, grants, removing,
///   approving, revoking, mode) comes from a parent's own device, and a parent of the same home.
///   The one exception is an invited home's window: while none of its parents is in, the home
///   that invited it may add its first parent and one-use keys for that parent and its hub.
/// - **G3** a `home` record changes only by that home's parents (or, while nobody of it is in,
///   is taken back by the home that invited it), and leaving is final.
/// - **G4** a hub acts only for people of its own home, never for nobody; shared screens only
///   show a group.
/// - **G5** `m:X` is X's alone (no parent of any home reads or writes it); `p` is every parent's.
/// - **G6** a device lets itself in with an invite key of its own home (or its home's window key),
///   or a parent's recovery words copied into the group, and joins as a device of that home.
/// - **G7** chores, stars, feeds, connections and sign-in records stay in each family's own log.
/// - **G8** every home keeps a parent until it leaves; leaving is one commit by its own parent,
///   after which nothing of that home counts.
///
/// A family's log refuses everything here that only a group holds, so a family behaves exactly
/// as it did; and a group refuses `groupLink` and `groupInvite`, which only a family holds.
library;

import 'change.dart';
import 'hlc.dart';
import 'invite_keys.dart';
import 'model.dart';
import 'permissions.dart';
import 'recovery.dart';
import 'store.dart';
import 'validity.dart' show Rejection, RejectionKind, TrustRoot;

/// Record types a group never holds (G7): each family's own chores and stars, its calendar feeds,
/// its AI connections and its shared screens' sign-in records; and the records about groups that
/// only a family's own log holds.
const Set<String> groupRefusedTypes = {
  RecordType.chore,
  RecordType.completion,
  RecordType.adjustment,
  RecordType.goal,
  RecordType.reward,
  RecordType.redemption,
  RecordType.subscription,
  RecordType.connection,
  RecordType.signInTries,
  RecordType.groupLink,
  RecordType.groupInvite,
};

/// Label of a sealed group admission's payload (`groupInvite.sealed`, [GroupAdmission]).
const String groupInviteKind = 'groupInvite';

Rejection _trust(String m) => Rejection(RejectionKind.trust, m);
Rejection _deny(String m) => Rejection(RejectionKind.permission, m);
Rejection _schema(String m) => Rejection(RejectionKind.schema, m);

const String _ownDeviceOnly =
    'Only a parent on their own device can do that, not a shared screen or an app acting through the hub';

/// Whether the log [trust] roots is a group: its family record says so. Read even when removed,
/// which a group's record never is, so a group can't turn back into a family.
bool isGroupLog(RecordStore store, TrustRoot trust) {
  final id = trust.familyId;
  if (id == null) return false;
  return store.at(Space.family, RecordType.family, id)?.fields['kind'] == LogKind.group;
}

/// The home [id], removed or not; null when the group has none.
Home? homeAt(RecordStore store, Object? id) {
  if (id is! String) return null;
  final e = store.at(Space.family, RecordType.home, id);
  return e == null ? null : Home(e.rec);
}

/// Whether the home [id] left the group (or never was in it).
bool homeLeft(RecordStore store, Object? id) => homeAt(store, id)?.left ?? true;

/// The home of the person [memberId], removed or not.
String? homeOfMember(RecordStore store, Object? memberId) {
  if (memberId is! String) return null;
  final home = store.at(Space.family, RecordType.member, memberId)?.fields['home'];
  return home is String ? home : null;
}

/// The home of [d]: its own, else its owner's.
String? homeOfDevice(RecordStore store, Device d) => d.home ?? homeOfMember(store, d.member);

/// Whether [d] no longer counts in the group: removed, or its family left.
bool deviceOutOfGroup(RecordStore store, Device d) => d.revoked || homeLeft(store, homeOfDevice(store, d));

/// The live people of the home [homeId].
Iterable<Member> membersOfHome(RecordStore store, String homeId) => [
      for (final e in store.liveOfType(RecordType.member))
        if (e.space == Space.family && e.fields['home'] == homeId) Member(e.rec),
    ];

/// The devices of the home [homeId] that are in: approved and not removed.
Iterable<Device> devicesOfHome(RecordStore store, String homeId) => [
      for (final e in store.liveOfType(RecordType.device))
        if (e.space == Space.family && e.fields['approved'] == true && e.fields['revoked'] != true)
          if (homeOfDevice(store, Device(e.rec)) == homeId) Device(e.rec),
    ];

/// Whether the invited home [homeId] is in its window: it is still `invited`, so none of its own
/// parents has said it is in. While it is, the home that invited it stands in for it (G2): it adds
/// its first parent and the keys that let that parent's phone and its hub in, and may take the
/// invitation back or say "That wasn't them". The invited family's own parent closes the window
/// when they say it is in ([WindowClosure]), and nothing the inviting family does after, or
/// dates before without the invited family having held it, counts.
bool inviteWindowOpen(RecordStore store, String homeId) => homeAt(store, homeId)?.status == HomeStatus.invited;

/// Whether a parent of the home [homeId] has a phone of their own in the group: after that, the
/// inviting family makes no more keys or people for it.
bool firstParentIn(RecordStore store, String homeId) {
  for (final d in devicesOfHome(store, homeId)) {
    if (d.mode != DeviceMode.personal || d.member == null) continue;
    final owner = store.liveAt(Space.family, RecordType.member, d.member!);
    if (owner != null && Member(owner.rec).isParent) return true;
  }
  return false;
}

/// Whether the invite key [key] is a window key: one the home that invited its home made, for
/// that home's first parent or its hub ([inviteWindowOpen]).
bool isWindowKey(RecordStore store, InviteKeyRecord key) {
  final home = key.rec.strOrNull('home');
  final maker = homeOfMember(store, key.by);
  return home != null && maker != null && maker != home;
}

/// An invited home's window closed by its own parent saying it is in: the change setting its
/// `status` from `invited` to `active`, which names in `closed` the last change it held from each
/// device of the inviting home and in `kept` the devices let in through the window it keeps (its
/// own, and its family's hub). Like a revocation's cutoff, it is settled from the log alone, so a
/// device's own clock can't get around it:
///
/// - a window power of the inviting home over this one (a person or key made for it, a key taken
///   back, a device removed, recovery words turned off, the invitation taken back) dated before
///   it counts for nothing unless it is one the closing device held: its device is in `closed`
///   and it is numbered no later;
/// - a device let in through the window (an invite key the inviting home made) dated before it
///   counts for nothing unless it is in `kept`.
///
/// After it, the window is shut: none of those count, whatever they claim.
class WindowClosure {
  const WindowClosure(this.home, this.at, this.closed, this.kept);

  /// The home whose window it closes.
  final String home;

  /// The clock of the change that closed it.
  final Hlc at;

  /// Device of the inviting home -> the last of its changes the closing device held.
  final Map<String, int> closed;

  /// Devices let in through the window that count.
  final Set<String> kept;

  /// As a snapshot keeps it, beside the replaced keys (recovery.dart).
  List<Object?> toJson() => [
        'window',
        home,
        at.toString(),
        kept.toList()..sort(),
        {for (final k in closed.keys.toList()..sort()) k: closed[k]},
      ];

  /// Reads [toJson]'s output.
  static WindowClosure fromJson(List<Object?> row) => WindowClosure(
        row[1]! as String,
        Hlc.parse(row[2]! as String),
        {for (final e in (row[4]! as Map).entries) e.key as String: e.value as int},
        (row[3]! as List).cast<String>().toSet(),
      );
}

/// Whether [c] closes a home's window (a change to a `home` naming `closed`, which validity takes
/// only from that home's own parent saying it is in). The materializer settles these with the
/// revocation cutoffs and replaced keys.
bool closesWindow(Change c) => c.type == RecordType.home && c.fields.containsKey('closed');

/// The closure [c] makes, when it makes one.
WindowClosure? windowClosureOf(Change c) {
  if (!closesWindow(c)) return null;
  final closed = c.fields['closed'], kept = c.fields['kept'];
  return WindowClosure(
    c.rid,
    c.hlc,
    {if (closed is Map) for (final e in closed.entries) if (e.value is int) '${e.key}': e.value as int},
    {if (kept is List) ...kept.whereType<String>()},
  );
}

/// The home whose window [c] is a window power over (see [WindowClosure]), or null: a change to
/// one of that home's people, devices, keys or its record, by a person of the home that invited
/// it. Read from what never changes once written (a person's, device's and key's family, a home's
/// inviter), so it reads the same at any point after those records exist.
String? _windowPowerOver(Change c, RecordStore store) {
  final actorHome = c.actor == null ? null : homeOfMember(store, c.actor);
  if (actorHome == null) return null;
  Object? target;
  switch (c.type) {
    case RecordType.home:
      target = c.rid;
    case RecordType.member:
      target = c.fields['home'] ?? store.at(Space.family, RecordType.member, c.rid)?.fields['home'];
    case RecordType.device:
      if (c.rid == c.device) return null;
      final d = store.at(Space.family, RecordType.device, c.rid);
      target = d == null ? null : d.fields['home'] ?? homeOfMember(store, d.fields['member']);
    case RecordType.inviteKey:
      target = c.fields['home'] ?? store.at(Space.family, RecordType.inviteKey, c.rid)?.fields['home'];
    default:
      return null;
  }
  if (target is! String || target == actorHome) return null;
  return homeAt(store, target)?.invitedBy == actorHome ? target : null;
}

/// The home [c] lets a device into through its window (with a key the inviting home made), or
/// null.
String? _windowAdmissionInto(Change c, RecordStore store) {
  if (c.type != RecordType.device || c.rid != c.device) return null;
  final proof = InviteProof.parse(c.fields['invite']);
  final key = proof == null ? null : store.at(Space.family, RecordType.inviteKey, proof.invite);
  if (key == null) return null;
  final home = key.fields['home'];
  final maker = homeOfMember(store, key.fields['by']);
  return home is String && maker != null && maker != home ? home : null;
}

/// Whether one of [closures] makes [c] count for nothing ([WindowClosure]).
bool windowClosedOut(Change c, RecordStore store, Iterable<WindowClosure> closures) {
  if (closures.isEmpty) return false;
  final admitted = _windowAdmissionInto(c, store);
  final power = admitted == null ? _windowPowerOver(c, store) : null;
  if (admitted == null && power == null) return false;
  for (final w in closures) {
    if (!(c.hlc < w.at)) continue;
    if (admitted == w.home && !w.kept.contains(c.rid)) return true;
    if (power == w.home) {
      final held = w.closed[c.device];
      if (held == null || c.counter > held) return true;
    }
  }
  return false;
}

/// Validity's one hook for groups (G1-G8), called for every change after its schema checks.
/// A rejection stands; null lets the family's rules decide, which still apply in a group, so
/// the rules here only ever narrow them, except where validity.dart asks [isGroupLog] (a group's
/// genesis writes its founder's home; a device joining a group writes its home).
///
/// In a family's log it refuses what only a group holds, so a family behaves as it did.
/// [closures] are the windows closed so far ([WindowClosure]), settled by the materializer.
Rejection? checkGroupRules(Change c, Entry? existing, RecordStore store, TrustRoot trust,
    {required bool group, Iterable<WindowClosure> closures = const []}) {
  if (!group) return _familyRefusesGroupThings(c);
  if (windowClosedOut(c, store, closures)) {
    return _trust('That family said it was in before this, without having heard of it');
  }
  return _GroupCheck(c, existing, store, trust).check();
}

Rejection? _familyRefusesGroupThings(Change c) {
  switch (c.type) {
    case RecordType.family:
      // A group's very first record: what a group never carries, from the start too.
      if (c.fields['kind'] == LogKind.group) return _groupRecordFields(c.fields);
    case RecordType.home:
      return _schema('Only a group of families has families in it');
    case RecordType.member:
      if (c.fields.containsKey('home') || c.fields.containsKey('link')) {
        return _schema('Only a person in a group of families has a family named on them');
      }
    case RecordType.device:
      if (c.fields.containsKey('home')) return _schema('Only a device in a group of families has a family named on it');
  }
  return null;
}

/// What a group's own record never carries (G7), at genesis too: each family decides these for
/// itself.
Rejection? _groupRecordFields(Map<String, Object?> f) {
  for (final k in f.keys) {
    if (k == 'oversight' || k.startsWith('oversight.')) {
      return _schema('Each family keeps its own privacy settings: a group has none');
    }
    if (k == 'assistant') return _schema('Each family decides about the assistant: a group doesn\'t');
    if (k == 'recovery') return _schema('A group has no server help: a parent gets back in with their recovery words');
  }
  if (f['pointsEnabled'] == true) return _schema('Stars stay in each family\'s own Den');
  return null;
}

class _GroupCheck {
  _GroupCheck(this.c, this.existing, this.store, this.trust);

  final Change c;
  final Entry? existing;
  final RecordStore store;
  final TrustRoot trust;

  late Device author;
  String? authorHome;
  Member? actor;
  String? actorHome;

  bool get creating => existing == null;

  bool only(Set<String> names) => c.fields.keys.every((k) => k == '_via' || k == '_from' || names.contains(k));

  /// As validity's: a personal device, or a parent's own device running as a hub with its owner
  /// using it; never a shared screen, a hub nobody owns, or anything acting through a hub.
  bool get ownDevice {
    if (c.fields.containsKey('_via')) return false;
    if (author.mode == DeviceMode.personal) return true;
    return author.mode == DeviceMode.hub && actor != null && actor!.id == author.member;
  }

  bool get parentHere => (actor?.isParent ?? false) && ownDevice;

  String homeName(Object? id) {
    final h = homeAt(store, id);
    return h == null || h.name.isEmpty ? 'That family' : h.name;
  }

  Member? liveMember(Object? id) {
    if (id is! String) return null;
    final e = store.liveAt(Space.family, RecordType.member, id);
    return e == null ? null : Member(e.rec);
  }

  Rejection? check() {
    // G7: what stays in each family's own log.
    if (groupRefusedTypes.contains(c.type)) return _schema('A group of families doesn\'t hold ${_typeName(c.type)}');
    // G5: a group has no one's own space. Every member family's hub holds the whole group, so
    // "Just me" things go in the person's own family's Den.
    if (Space.isMember(c.space)) {
      return _schema('A group has no one\'s own space: "Just me" things go in your family\'s own Den');
    }
    final fieldError = _refusedFields();
    if (fieldError != null) return fieldError;

    final authorEntry = store.at(Space.family, RecordType.device, c.device);
    if (c.device == trust.founderDevice && authorEntry == null) return _genesis();
    // G6: a device letting itself in, with a parent's recovery words or an invite key.
    if (c.type == RecordType.device && c.fields.containsKey('recovery')) return _recovery();
    if (c.type == RecordType.device && c.fields.containsKey('invite')) return _inviteJoin();
    if (c.type == RecordType.device && c.rid == c.device) {
      final pending = authorEntry == null ||
          (!authorEntry.deleted && authorEntry.fields['approved'] != true && authorEntry.fields['revoked'] != true);
      if (pending) return _joinRequest();
    }
    // Everything else needs an approved device: the family's rules say so when it isn't one.
    if (authorEntry == null || authorEntry.deleted) return null;
    author = Device(authorEntry.rec);
    if (author.revoked || !author.approved) return null;
    authorHome = homeOfDevice(store, author);
    // A device may always remove itself, even once its family left: that is how a family that
    // leaves names the last of its own changes (`revokedAfter`), so nothing it signs after counts.
    final selfRemoval = c.type == RecordType.device &&
        c.rid == c.device &&
        !c.isDelete &&
        c.fields['revoked'] == true &&
        only({'revoked', 'revokedAfter'});
    if (!selfRemoval) {
      if (authorHome == null) return _trust('This device belongs to no family in the group');
      // G8: nothing of a family that left counts.
      if (homeLeft(store, authorHome)) return _trust('${homeName(authorHome)} left the group');
    }
    if (c.actor != null) {
      actor = liveMember(c.actor);
      // The family's rules refuse an actor who isn't in the group.
      if (actor == null) return null;
      actorHome = actor!.home;
      if (!selfRemoval && homeLeft(store, actorHome)) return _trust('${homeName(actorHome)} left the group');
    }
    // G4: shared screens only show a group; hubs act only for their own family's people.
    if (author.mode == DeviceMode.shared && !(c.type == RecordType.device && c.rid == c.device)) {
      return _deny('A shared screen only shows a group: people change it on their own devices');
    }
    if (author.mode == DeviceMode.hub) {
      if (actor == null) {
        if (!(c.type == RecordType.device && c.rid == c.device)) {
          return _deny('In a group a hub acts only for its own family\'s people, never for nobody');
        }
      } else if (actorHome != authorHome) {
        return _deny('A hub acts only for its own family\'s people');
      }
    }
    if (actor != null && author.mode == DeviceMode.personal && actorHome != authorHome) {
      return _trust('This device belongs to another family');
    }
    switch (c.type) {
      case RecordType.home:
        return _home();
      case RecordType.member:
        return _member();
      case RecordType.device:
        return _device();
      case RecordType.inviteKey:
        return _inviteKey();
      case RecordType.photo:
        return _photo();
      case RecordType.event:
      case RecordType.eventException:
        return _drivers();
    }
    return null;
  }

  /// Fields a group's records never carry: what each family decides for itself.
  Rejection? _refusedFields() {
    final f = c.fields;
    switch (c.type) {
      case RecordType.family:
        if (f.containsKey('_deleted')) return _deny('A group stays until its last family leaves');
        return _groupRecordFields(f);
      case RecordType.member:
        final signIn = f['signIn'];
        if (signIn is Map && signIn['kind'] != 'none') {
          return _schema('PINs and picture patterns stay in each family\'s own Den');
        }
    }
    return null;
  }

  /// The founder's first changes, before its device's record exists: the group, the founder's
  /// family (in from the start), its first parent and the founder's device, all of that family.
  Rejection? _genesis() {
    switch (c.type) {
      case RecordType.home:
        if (existing != null || store.ofType(RecordType.home).isNotEmpty) {
          return _trust('The founder starts a group with their own family only');
        }
        if (c.fields['status'] != HomeStatus.active.name) return _trust('The founder\'s family is in from the start');
        if (c.fields['invitedBy'] != null) return _trust('Nobody invited the founder\'s family');
        return null;
      case RecordType.member:
        final home = homeAt(store, c.fields['home']);
        if (home == null || home.status != HomeStatus.active) {
          return _trust('The founder\'s first person belongs to the founder\'s family');
        }
        return null;
      case RecordType.device:
        final owner = liveMember(c.fields['member']);
        if (owner != null && c.fields['home'] != owner.home) {
          return _trust('The founder\'s device belongs to the founder\'s family');
        }
        return null;
    }
    return null;
  }

  /// G6, recovery: the words a parent copied into their group person (`member.recovery`) let a
  /// new phone in as theirs, a phone of their family. Never the hub's help: that is each family's
  /// own, and in a group it would let one family's server in as another family's parent.
  Rejection? _recovery() {
    final proof = RecoveryProof.parse(c.fields['recovery']);
    if (proof == null) return null;
    if (proof.kind == RecoveryKind.hub) {
      return _deny('A group has no server help: a parent gets back in with their recovery words');
    }
    final m = liveMember(proof.member);
    if (m == null) return null;
    if (c.fields['home'] != m.home) return _trust('A phone let in by recovery belongs to its person\'s family');
    if (homeLeft(store, m.home)) return _trust('${homeName(m.home)} left the group');
    return null;
  }

  /// G6, invite keys: a key of the device's own home lets it in as that home's (and, for a
  /// personal device, as someone of that home). A window key ([isWindowKey]) lets in the invited
  /// home's first parent or its hub while its window is open, and never once it is shut. Within
  /// the window one such key isn't used up by another device: a join dated earlier with the
  /// inviting family's copy of the key can't push out the real one, and the invited family's
  /// own parent keeps the devices it knows when it closes the window ([WindowClosure]).
  Rejection? _inviteJoin() {
    final proof = InviteProof.parse(c.fields['invite']);
    if (proof == null) return null;
    final entry = store.at(Space.family, RecordType.inviteKey, proof.invite);
    if (entry == null || entry.deleted) return null;
    final key = InviteKeyRecord(entry.rec);
    final keyHome = key.rec.strOrNull('home');
    if (keyHome == null) return _trust('That invite isn\'t for a family in this group');
    if (c.fields['home'] != keyHome) return _trust('That invite is for another family');
    final home = homeAt(store, keyHome);
    if (home == null || home.left) return _trust('${homeName(keyHome)} left the group');
    if (proof.member != null && homeOfMember(store, proof.member) != keyHome) {
      return _trust('That invite is for someone in another family');
    }
    final makerHome = homeOfMember(store, key.by);
    if (makerHome == null || homeLeft(store, makerHome)) return _trust('The family that made that invite left the group');
    if (makerHome == keyHome) return null;
    if (home.invitedBy != makerHome) return _trust('Only a family\'s own parents, or the family that invited it, let it in');
    if (proof.mode == DeviceMode.shared) return _trust('An invitation lets in a family\'s first parent and its hub only');
    if (!inviteWindowOpen(store, keyHome)) {
      return _trust('${home.name} is in the group already: their own parents let their people in now');
    }
    return null;
  }

  /// A device asking to join, waiting for a parent of its family (G2) to approve it.
  Rejection? _joinRequest() {
    if (!c.fields.containsKey('home')) return null;
    final home = homeAt(store, c.fields['home']);
    if (home == null || home.left) return _schema('That family isn\'t in the group');
    final member = c.fields['member'];
    if (member is String && homeOfMember(store, member) != home.id) return _schema('That person is in another family');
    return null;
  }

  /// G3: a family in the group.
  Rejection? _home() {
    if (c.fields.containsKey('_deleted')) return _deny('A family leaves a group: its record stays');
    final a = actor;
    if (creating) {
      // Any parent of a family in the group invites another, on their own device.
      if (c.fields['status'] != HomeStatus.invited.name) return _deny('A family joins a group when it\'s invited');
      if (a == null || !parentHere) return _deny('Only a parent on their own device invites another family');
      if (c.fields['invitedBy'] != actorHome) return _schema('An invitation names the family that sent it');
      // Its own log's id (fixed once said) and where its hub syncs are the invited family's to say.
      if (c.fields['family'] != null || c.fields['hubs'] != null) {
        return _schema('A family says where its Den is itself, once it\'s in');
      }
      return null;
    }
    final h = Home(existing!.rec);
    if (h.left) return _deny('${h.name} left the group, and that\'s final');
    if (existing!.fields['family'] != null && c.fields.containsKey('family') && c.fields['family'] != existing!.fields['family']) {
      return _schema('A family\'s id can\'t change');
    }
    final status = c.fields['status'];
    if (status == HomeStatus.invited.name && h.status != HomeStatus.invited) {
      return _schema('A family that is in can\'t go back to invited');
    }
    if (actorHome != c.rid) {
      // The family that sent an invitation takes it back, while the other hasn't said it's in.
      final takeBack = h.status == HomeStatus.invited &&
          h.invitedBy == actorHome &&
          status == HomeStatus.left.name &&
          only({'status'});
      if (takeBack && parentHere) return null;
      return _deny('Only ${h.name}\'s own parents can change their family in the group');
    }
    if (a == null || !a.isParent) return _deny('Only parents can change their family in the group');
    if (!ownDevice) return _deny(_ownDeviceOnly);
    // Saying an invited family is in closes its window ([WindowClosure]): it names the last
    // change it held from each device of the inviting family, and the devices let in through the
    // window it keeps, itself among them. Nothing else ever names them.
    final activates = h.status == HomeStatus.invited && status == HomeStatus.active.name;
    final closed = c.fields['closed'], kept = c.fields['kept'];
    if (activates) {
      if (h.invitedBy == null) return _schema('Only an invited family closes its invitation');
      if (closed is! Map || kept is! List) {
        return _schema('Saying the family is in names what it heard from the family that invited it');
      }
      if (!kept.contains(c.device)) return _schema('Saying the family is in keeps the device that says it');
    } else if (c.fields.containsKey('closed') || c.fields.containsKey('kept')) {
      return _schema('Only saying an invited family is in closes its invitation');
    }
    return null;
  }

  /// G1, G2 and G8 for a person.
  Rejection? _member() {
    final homeId = creating ? c.fields['home'] : existing!.fields['home'];
    if (creating && c.isDelete) return null;
    if (homeId is! String) return _schema('A person in a group belongs to one of its families');
    if (!creating && c.fields.containsKey('home') && c.fields['home'] != homeId) {
      return _schema('A person\'s family can\'t change');
    }
    final h = homeAt(store, homeId);
    if (h == null) return _schema('That family isn\'t in the group');
    if (h.left) return _deny('${h.name} left the group');
    final a = actor;
    if (a == null) return null;
    // Someone's own picture, sign-in (none, in a group) and recovery words: the family's rules.
    if (!creating && c.actor == c.rid && (only({'picture'}) || only({'signIn'}) || only({'recovery'}))) return null;
    if (actorHome != homeId) {
      // The window: the family that invited this one adds its first parent.
      if (creating) {
        if (!inviteWindowOpen(store, homeId) || h.invitedBy != actorHome || firstParentIn(store, homeId)) {
          return _deny('Only ${h.name}\'s own parents add their people');
        }
        if (c.fields['role'] != Role.parent.name) return _deny('The first person of an invited family is a parent');
        if (membersOfHome(store, homeId).any((m) => m.isParent)) {
          return _deny('${h.name}\'s parents add the rest of their family themselves');
        }
        if (!parentHere) return _deny(_ownDeviceOnly);
        return null;
      }
      // "That wasn't them": the inviting family takes away the recovery words of the parent its
      // invitation let in, so whoever used the invitation can't come back with words of theirs;
      // only until that family says it is in.
      final recovery = c.fields['recovery'];
      final made = homeOfMember(store, existing!.createdBy);
      if (only({'recovery'}) &&
          recovery is Map &&
          recovery['key'] == null &&
          made == actorHome &&
          h.invitedBy == actorHome &&
          inviteWindowOpen(store, homeId)) {
        return parentHere ? null : _deny(_ownDeviceOnly);
      }
      return _deny('Only ${h.name}\'s own parents can change their people');
    }
    // Adding someone to a group is a trust decision: they are let in with their own devices.
    if (creating && !ownDevice) return _deny(_ownDeviceOnly);
    // G8: every family keeps a parent until it leaves.
    if (!creating && _leavesHomeWithoutParent(homeId)) return _deny('Every family in the group keeps at least one parent');
    return null;
  }

  bool _leavesHomeWithoutParent(String homeId) {
    if (!c.fields.containsKey('role') && !c.isDelete) return false;
    final e = existing!;
    final wasParent = !e.deleted && e.fields['role'] == Role.parent.name;
    final isParent = !c.isDelete && (c.fields.containsKey('role') ? c.fields['role'] : e.fields['role']) == Role.parent.name;
    if (!wasParent || isParent) return false;
    return !membersOfHome(store, homeId).any((m) => m.id != c.rid && m.isParent);
  }

  /// G1 and G2 for a device that is in, changed by one that is in.
  Rejection? _device() {
    final e = existing;
    if (e == null) return null;
    final target = Device(e.rec);
    final before = e.fields['home'];
    if (c.fields.containsKey('home')) {
      final now = c.fields['home'];
      if (before != null && now != before) return _schema('A device\'s family can\'t change');
      if (c.rid == c.device && now != before) return _trust('A device can never change who owns it');
      final h = homeAt(store, now);
      if (h == null || h.left) return _schema('That family isn\'t in the group');
    }
    final owner = c.fields.containsKey('member') ? c.fields['member'] : target.member;
    final after = c.fields['home'] ?? before ?? homeOfMember(store, owner);
    if (owner != null && after != null && homeOfMember(store, owner) != after) {
      return _schema('A device belongs to its owner\'s family');
    }
    if (c.rid == c.device) return null;
    // "That wasn't them": the family that invited this one removes the device its invitation
    // let in, and nothing more; only until that family says it is in. How far back it reaches:
    // the device's own changes, all made before that ([WindowClosure] voids one dated earlier
    // without the invited family having heard of it).
    final proof = inviteOf(target);
    final keyEntry = proof == null ? null : store.at(Space.family, RecordType.inviteKey, proof.invite);
    if (keyEntry != null && actorHome != after && after is String && inviteWindowOpen(store, after)) {
      final key = InviteKeyRecord(keyEntry.rec);
      final removal = c.fields['revoked'] == true && only({'revoked', 'revokedAfter'});
      if (removal && isWindowKey(store, key) && homeOfMember(store, key.by) == actorHome) {
        return parentHere ? null : _deny(_ownDeviceOnly);
      }
    }
    if (actorHome != after) return _deny('Only ${homeName(after)}\'s own parents can let its devices in or change them');
    if (c.fields['approved'] == true && after == null) return _schema('Choose which family in the group this device belongs to');
    return null;
  }

  /// G2 and G6 for an invite key in a group: it names its home, and only that home's parents
  /// make one, except the window keys the inviting family makes.
  Rejection? _inviteKey() {
    final e = existing;
    if (e != null) {
      // Taking it away: that family's parents, or the family that made it (its invitation) until
      // that family says it is in.
      final keyHome = e.fields['home'];
      final makerHome = homeOfMember(store, e.fields['by']);
      if (actorHome == keyHome) return null;
      if (actorHome != makerHome || keyHome is! String || !inviteWindowOpen(store, keyHome)) {
        return _deny('Only ${homeName(keyHome)}\'s own parents, or the family that invited it, can take that invite back');
      }
      return null;
    }
    final homeId = c.fields['home'];
    if (homeId is! String) return _schema('An invite in a group names the family it lets people into');
    final h = homeAt(store, homeId);
    if (h == null) return _schema('That family isn\'t in the group');
    if (h.left) return _deny('${h.name} left the group');
    final member = c.fields['member'];
    if (actorHome == homeId) {
      if (member is String && homeOfMember(store, member) != homeId) return _schema('That person is in another family');
      return null;
    }
    // The window: one-use keys for the invited family's first parent and its hub, until that
    // parent's phone is in.
    if (!inviteWindowOpen(store, homeId) || h.invitedBy != actorHome || firstParentIn(store, homeId)) {
      return _deny('Only ${h.name}\'s own parents can invite their people');
    }
    if ((c.fields['uses'] ?? 1) != 1) return _deny('An invitation to another family lets in one device per key');
    if (member != null) {
      final m = liveMember(member);
      if (m == null || m.home != homeId || !m.isParent) {
        return _deny('An invitation lets in the invited family\'s first parent and its hub only');
      }
      return null;
    }
    final modes = c.fields['modes'];
    if (modes is! List || modes.length != 1 || modes.single != DeviceMode.hub.name) {
      return _deny('An invitation lets in the invited family\'s first parent and its hub only');
    }
    return null;
  }

  /// Someone's photo: themselves, or a parent of their own family (G2).
  Rejection? _photo() {
    final member = c.fields['member'] ?? existing?.fields['member'];
    if (member is! String || c.actor == member) return null;
    if (actorHome != homeOfMember(store, member)) {
      return _deny('Only ${liveMember(member)?.name ?? 'their'}\'s own family can change their picture');
    }
    return null;
  }

  /// Who drives: in a group, validity holds what the engine holds in a family (`canDrive`):
  /// every driver a change names is someone of the group who drives, a parent or a grown-up of a
  /// family still in it, unless that same leg of that same occurrence already has that same
  /// driver (a whole `rides` list, written for older versions, says every leg again). A group's
  /// log is new, so nothing older replays otherwise.
  Rejection? _drivers() {
    final named = _legDrivers(c.fields);
    if (named.isEmpty) return null;
    final List<Ride> now;
    if (c.type == RecordType.event) {
      now = existing == null ? const [] : Event(existing!.rec).rides;
    } else {
      final eventId = c.fields['event'] ?? existing?.fields['event'];
      final series = eventId is String ? store.at(c.space, RecordType.event, eventId) : null;
      final seriesRides = series == null ? const <Ride>[] : Event(series.rec).rides;
      now = existing == null ? seriesRides : EventException(existing!.rec).rides(seriesRides);
    }
    final held = {for (final r in now) r.leg: r.driver};
    for (final (leg, id) in named) {
      if (held[leg] == id) continue;
      final m = liveMember(id);
      if (m == null) return _schema('That driver isn\'t in the group');
      if (homeLeft(store, m.home)) return _deny('${homeName(m.home)} left the group');
      if (!canDrive(m)) return _deny('${m.name} can\'t drive: only parents and grown-ups drive');
    }
    return null;
  }

  /// Each (leg, driver) [fields] names, nobody left out.
  static List<(String, String)> _legDrivers(Map<String, Object?> fields) {
    final out = <(String, String)>[];
    void one(Object? leg, Object? v) {
      if (leg is String && v is String && v.isNotEmpty) out.add((leg, v));
    }

    void list(Object? v) {
      if (v is! List) return;
      for (final r in v) {
        if (r is Map) one(r['leg'], r['driver']);
      }
    }

    for (final e in fields.entries) {
      final k = e.key, v = e.value;
      if (k == 'drivers' && v is Map) {
        for (final d in v.entries) {
          one('${d.key}', d.value);
        }
      }
      if (k.startsWith('drivers.')) one(k.substring(8), v);
      if (k.startsWith('patch.drivers.')) one(k.substring(14), v);
      if (k == 'rides' || k == 'patch.rides') list(v);
      if (k == 'patch' && v is Map) {
        for (final p in v.entries) {
          final key = '${p.key}';
          if (key.startsWith('drivers.')) one(key.substring(8), p.value);
          if (key == 'rides') list(p.value);
        }
      }
    }
    return out;
  }

  static String _typeName(String type) => switch (type) {
        RecordType.chore || RecordType.completion => 'chores: they stay in each family\'s own Den',
        RecordType.adjustment || RecordType.goal || RecordType.reward || RecordType.redemption =>
          'stars, goals or rewards: they stay in each family\'s own Den',
        RecordType.subscription => 'calendar feeds: a family shares its calendar instead',
        RecordType.connection => 'AI or automation access: each family keeps its own',
        RecordType.signInTries => 'sign-in tries: PINs stay in each family\'s own Den',
        _ => 'that: it stays in each family\'s own Den',
      };
}

/// Validity for a change to a `groupLink` in a family's log: which groups the family is in, and
/// who of it is in each, is a parent's decision on their own device.
Rejection? checkGroupLinkWrite(Change c, Entry? existing, {required bool ownDevice, required Member? actor}) {
  if (!ownDevice || !(actor?.isParent ?? false)) return _deny(_ownDeviceOnly);
  if (c.fields.containsKey('_deleted')) return _schema('A group\'s link stays: it says when the family left');
  final group = c.fields['group'] ?? existing?.fields['group'];
  if (group != c.rid) return _schema('A group\'s link is named for the group');
  return null;
}

/// Validity for a change to a `groupInvite` in a family's log: a parent's own device seals one
/// device's admission into a group to that device, which must be in the family.
Rejection? checkGroupInviteWrite(Change c, Entry? existing, RecordStore store,
    {required bool ownDevice, required Member? actor}) {
  if (!ownDevice || !(actor?.isParent ?? false)) return _deny(_ownDeviceOnly);
  if (c.isDelete) return null;
  final group = c.fields['group'] ?? existing?.fields['group'];
  final device = c.fields['device'] ?? existing?.fields['device'];
  if (c.rid != '$group@$device') return _schema('A group invite is named "<group>@<device>"');
  final d = device is String ? store.liveAt(Space.family, RecordType.device, device) : null;
  if (d == null || d.fields['approved'] != true || d.fields['revoked'] == true) {
    return _schema('That device isn\'t in the family');
  }
  final sealed = c.fields['sealed'];
  if (sealed is Map) {
    if (sealed['to'] != device) return _schema('A group invite is sealed to its own device');
    if (sealed['from'] != c.device) return _schema('A group invite is sealed by the device that writes it');
  }
  return null;
}

/// One device's way into a group: the invite key that lets it in, and what as. What a
/// `groupInvite` seals to a device of a family ([toPayload]), and what an invitation to another
/// family carries for its first parent and its hub ([GroupInvitation]).
class GroupAdmission {
  const GroupAdmission({
    required this.group,
    required this.founder,
    required this.name,
    required this.home,
    required this.member,
    required this.mode,
    required this.invite,
    required this.seed,
    required this.expires,
    this.device,
  });

  /// The group's log id.
  final String group;

  /// The group's founder key (base64url Ed25519), which roots its trust.
  final String founder;

  /// The group's name, to show before its log arrives.
  final String name;

  /// The family in the group the device joins as one of.
  final String home;

  /// Whose own device it is, in the group (a member id there); null for a shared screen or a hub.
  final String? member;

  /// What the device will be.
  final DeviceMode mode;

  /// The `inviteKey` record's id ([inviteKeyIdOf] the key's public half).
  final String invite;

  /// The key's 32-byte private seed.
  final List<int> seed;

  /// When the key stops working (UTC ms).
  final int expires;

  /// The family's device it is sealed to, when it travels through a family's log.
  final String? device;

  /// The key itself.
  Future<InviteKey> key() => InviteKey.fromSeed(seed);

  /// What a `groupInvite` seals, naming the family's log it is written in ([family]), so it
  /// can't be passed off in another.
  Map<String, Object?> toPayload({required String family}) => {
        't': groupInviteKind,
        'family': family,
        'group': group,
        'founder': founder,
        'name': name,
        'home': home,
        'member': member,
        'mode': mode.name,
        'invite': invite,
        'seed': b64e(seed),
        'expires': expires,
        'device': device,
      };

  /// Reads [toPayload]'s output, or null when it isn't one.
  static GroupAdmission? fromPayload(Map<String, Object?> p) {
    final group = p['group'], founder = p['founder'], name = p['name'], home = p['home'], member = p['member'];
    final invite = p['invite'], seed = p['seed'], expires = p['expires'], device = p['device'];
    final mode = DeviceMode.values.asNameMap()[p['mode']];
    if (p['t'] != groupInviteKind || group is! String || founder is! String || name is! String || home is! String) return null;
    if ((member != null && member is! String) || mode == null || invite is! String || seed is! String || expires is! int) {
      return null;
    }
    if (device != null && device is! String) return null;
    final List<int> bytes;
    try {
      bytes = b64d(seed);
    } on FormatException {
      return null;
    }
    if (bytes.length != 32) return null;
    return GroupAdmission(
      group: group,
      founder: founder,
      name: name,
      home: home,
      member: member as String?,
      mode: mode,
      invite: invite,
      seed: bytes,
      expires: expires,
      device: device as String?,
    );
  }
}

/// An invitation for another family to join a group ([Den.inviteFamily]): its [Home], its first
/// parent, and the one-use keys that let that parent's phone and the family's hub in, which the
/// invitation sent to that parent carries.
class GroupInvitation {
  const GroupInvitation({
    required this.parent,
    required this.hub,
    required this.homeName,
    required this.parentName,
    required this.hubs,
  });

  /// For the invited family's first parent's own phone.
  final GroupAdmission parent;

  /// For the invited family's hub.
  final GroupAdmission hub;

  /// The invited family, as the group names it.
  final String homeName;

  /// Its first parent.
  final String parentName;

  /// Where the inviting family's hub syncs the group: the invited family's hub dials it first.
  final List<String> hubs;

  String get group => parent.group;
  String get home => parent.home;
  String get member => parent.member!;
  int get expires => parent.expires;
}
