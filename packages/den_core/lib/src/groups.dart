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
///   The one exception is an invited home's window, until its first parent's phone says it is
///   in: the home that invited it adds that parent and the one key its id is bound to
///   ([homeIdFor]), or takes the invitation back; nothing else ([WindowClosure]).
/// - **G3** a `home` record changes only by that home's parents (or, while it is invited, is
///   taken back by the home that invited it), and leaving is final. A home two phones of its
///   window each said "we're in" for, or that the inviting phone disowned within a day, ends
///   for everyone ([GroupStarts]).
/// - **G4** a hub acts only for people of its own home, never for nobody; shared screens only
///   show a group.
/// - **G5** a group has no one's own space (`m:X`); `p` is every parent's and every hub's.
/// - **G6** a device lets itself in with an invite key of its own home (or, its first parent's
///   phone, the invitation's key while the window is open), or a parent's recovery words
///   copied into the group, and joins as a device of that home.
/// - **G7** chores, stars, feeds, connections and sign-in records stay in each family's own log.
/// - **G8** every home keeps a parent until it leaves; leaving is one commit by its own parent,
///   after which nothing of that home counts.
///
/// A family's log refuses everything here that only a group holds, so a family behaves exactly
/// as it did; and a group refuses `groupLink` and `groupInvite`, which only a family holds.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:cryptography/dart.dart';

import 'change.dart';
import 'hlc.dart';
import 'ids.dart';
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

/// The home [id], removed or not; null when the group has none. A home whose place ended
/// ([HomeEnd]) reads as left from its end on: while validity judges a change clocked before
/// that, as it was ([RecordStore.judging]).
Home? homeAt(RecordStore store, Object? id) {
  if (id is! String) return null;
  final e = store.at(Space.family, RecordType.home, id);
  if (e == null) return null;
  final end = store.endedHomes[id];
  final judging = store.judging;
  if (end == null || (judging != null && judging < end.at)) return Home(e.rec);
  final r = e.rec;
  return Home(Rec(
    type: r.type,
    id: r.id,
    space: r.space,
    fields: {...r.fields, 'status': HomeStatus.left.name, 'ended': end.why},
    created: r.created,
    updated: r.updated,
    createdBy: r.createdBy,
    updatedBy: r.updatedBy,
    fieldTimes: r.fieldTimes,
  ));
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

/// Whether the invited home [homeId] is in its window: it is still `invited`, so its first
/// parent hasn't said it is in. While it is, the home that invited it may add that parent, the
/// one key that lets that parent's phone in, and take the invitation back (G2).
bool inviteWindowOpen(RecordStore store, String homeId) => homeAt(store, homeId)?.status == HomeStatus.invited;

/// Whether a parent of the home [homeId] has a phone of their own in the group.
bool firstParentIn(RecordStore store, String homeId) {
  for (final d in devicesOfHome(store, homeId)) {
    if (d.mode != DeviceMode.personal || d.member == null) continue;
    final owner = store.liveAt(Space.family, RecordType.member, d.member!);
    if (owner != null && Member(owner.rec).isParent) return true;
  }
  return false;
}

/// Whether the invite key [key] is a window key: the one key of an invited home, made by the
/// home that invited it, for its first parent ([homeIdFor]).
bool isWindowKey(RecordStore store, InviteKeyRecord key) {
  final home = key.rec.strOrNull('home');
  final maker = homeOfMember(store, key.by);
  return home != null && maker != null && maker != home;
}

/// The id of an invited family's home: bound to the invitation's one key ([windowKey], the
/// base64url public half) and to the device that made the invitation. Nobody else makes a home
/// by that id (another device or another key gives another id), and a device that lets itself
/// in with that key is, from the log alone, one let in through that home's window.
String homeIdFor(String windowKey, String device) {
  final List<int> key;
  try {
    key = b64d(windowKey);
  } on FormatException {
    return '';
  }
  return base32(const DartSha256().hashSync([...utf8.encode('den/home/v1'), 0, ...key, 0, ...utf8.encode(device)]).bytes.sublist(0, 10));
}

/// How long after an invited family said it is in the family that invited it may still say
/// "That wasn't them" ([GroupStarts]).
const Duration disownWindow = Duration(hours: 24);

/// Why an invited family's place in a group ended before it began for good ([GroupStarts]):
/// two devices let in with its invitation's key each said it was in (contested), or the family
/// that invited it said "That wasn't them" within a day. Either way the home counts as left for
/// everyone from its first "we're in" on, and nothing brings it back.
class HomeEnd {
  const HomeEnd({required this.home, required this.at, required this.contested, this.disowned, this.closings = const []});

  final String home;

  /// The clock of the first "we're in": from it on, nothing of the home counts.
  final Hlc at;

  /// Whether two or more devices let in with the invitation's key each said the family is in.
  final bool contested;

  /// The inviting family's "That wasn't them" that ended it, when one did.
  final String? disowned;

  /// The "we're in" changes the log holds for the home, from devices let in with its key.
  final List<String> closings;

  /// What [RecordStore.endedHomes] keeps of it.
  ({Hlc at, String why, String? by}) get mark => (at: at, why: contested ? 'contested' : 'disowned', by: disowned);
}

/// What the log alone says about how each invited family began, without any verdict, so every
/// replica holding the same changes reads the same:
///
/// - an invitation: a `home` change naming its one key (`key`), whose id is [homeIdFor] that
///   key and the device that wrote it (the inviting device);
/// - the devices let in through its window: those whose own first change carries a proof by
///   that key for that home;
/// - "we're in": a change setting that home `active`, by one of those devices;
/// - "That wasn't them": a change saying `disowned`, by the inviting device.
///
/// A home two of those devices each said "we're in" for is contested: no beginning wins, and the
/// home ends ([HomeEnd]). So does one the inviting device disowned within [disownWindow] of its
/// first "we're in". Changes from a window device, or of these shapes, decide verdicts: the
/// materializer replays when one arrives late.
class GroupStarts {
  /// Home -> its invitation: its key, the device that made it, and the change.
  final Map<String, ({String key, String inviter, String change})> invitations = {};

  /// Home -> the devices let in with its key, each with its first change, in log order.
  final Map<String, Map<String, Change>> windowJoins = {};

  /// Home -> its "we're in"s by those devices, in log order.
  final Map<String, List<Change>> closings = {};

  /// Home -> "That wasn't them" by its inviting device, in log order.
  final Map<String, List<Change>> disowns = {};

  /// Homes whose place ended.
  final Map<String, HomeEnd> ended = {};

  /// Reads [log], in log order.
  static GroupStarts of(Iterable<Change> log) {
    final s = GroupStarts();
    for (final c in log) {
      if (isInvitation(c)) s.invitations.putIfAbsent(c.rid, () => (key: c.fields['key']! as String, inviter: c.device, change: c.id));
    }
    if (s.invitations.isEmpty) return s;
    for (final c in log) {
      final home = s.windowJoinInto(c);
      if (home != null) (s.windowJoins[home] ??= {}).putIfAbsent(c.device, () => c);
    }
    for (final c in log) {
      if (c.type != RecordType.home) continue;
      if (s.saysIn(c)) (s.closings[c.rid] ??= []).add(c);
      if (s.isDisown(c)) (s.disowns[c.rid] ??= []).add(c);
    }
    for (final e in s.closings.entries) {
      final first = e.value.first;
      final authors = {for (final c in e.value) c.device};
      final disown = s.disowns[e.key]?.firstWhereOrNull((d) => d.hlc.millis < first.hlc.millis + disownWindow.inMilliseconds);
      if (authors.length < 2 && disown == null) continue;
      s.ended[e.key] = HomeEnd(
        home: e.key,
        at: first.hlc,
        contested: authors.length >= 2,
        disowned: disown?.id,
        closings: [for (final c in e.value) c.id],
      );
    }
    return s;
  }

  /// Whether [c] makes an invited family's home with its one key ([homeIdFor]).
  static bool isInvitation(Change c) {
    if (c.type != RecordType.home) return false;
    final key = c.fields['key'];
    return key is String && c.fields['status'] == HomeStatus.invited.name && c.rid == homeIdFor(key, c.device);
  }

  /// The home whose window [c] lets its device in through (its first change, with a proof by
  /// that home's key), or null.
  String? windowJoinInto(Change c) {
    if (c.type != RecordType.device || c.rid != c.device) return null;
    final home = c.fields['home'];
    if (home is! String) return null;
    final key = invitations[home]?.key;
    if (key == null) return null;
    final proof = InviteProof.parse(c.fields['invite']);
    return proof != null && proof.key == key ? home : null;
  }

  /// Whether [c] says its home is in, from a device let in through that home's window.
  bool saysIn(Change c) =>
      c.type == RecordType.home && c.fields['status'] == HomeStatus.active.name && (windowJoins[c.rid]?.containsKey(c.device) ?? false);

  /// Whether [c] is "That wasn't them" by the device that made the home's invitation.
  bool isDisown(Change c) => c.type == RecordType.home && c.fields['disowned'] == true && invitations[c.rid]?.inviter == c.device;

  /// Whether [c] is one of the changes these facts read: the materializer replays when one
  /// arrives late.
  bool decides(Change c) => isInvitation(c) || windowJoinInto(c) != null || saysIn(c) || isDisown(c);
}

/// An invited home's window closed by its first parent's phone saying it is in: the change
/// setting the home from `invited` to `active`, which names in `heard` the window powers over the
/// home (changes the inviting family made to it) that the phone held and counted. Settled from
/// the log alone, like a revocation's cutoff, so no device's clock gets around it:
///
/// - a window power over the home dated before it counts only if it is one of those;
/// - a device let in through the window dated before it counts only if it is the phone itself.
///
/// After it the window is shut: none of those count, whatever they claim. A "we're in" counts
/// only as the closure in force (the materializer tries each, in log order, with itself in
/// force), so one that would void what let its own phone in is refused as a whole and the home
/// stays invited.
class WindowClosure {
  const WindowClosure(this.id, this.home, this.at, this.author, this.heard);

  /// The "we're in" change.
  final String id;

  /// The home whose window it closes.
  final String home;

  /// The clock of the change that closed it.
  final Hlc at;

  /// The device that said it: the one device the window let in that stays.
  final String author;

  /// The window powers over the home it held.
  final Set<String> heard;

  /// As a snapshot keeps it, beside the replaced keys (recovery.dart).
  List<Object?> toJson() => ['window', id, home, at.toString(), author, heard.toList()..sort()];

  /// Reads [toJson]'s output.
  static WindowClosure fromJson(List<Object?> row) => WindowClosure(
        row[1]! as String,
        row[2]! as String,
        Hlc.parse(row[3]! as String),
        row[4]! as String,
        (row[5]! as List).cast<String>().toSet(),
      );
}

/// A device that let itself in with an invited family's invitation ([Den.windowAdmissions]).
class WindowAdmission {
  const WindowAdmission({required this.device, required this.name, required this.joined, required this.counts, required this.saidIn});

  final String device;

  /// The name it gave itself.
  final String name;

  /// When it says it joined.
  final Hlc joined;

  /// Whether it counts in the group now.
  final bool counts;

  /// Whether it said the family was in.
  final bool saidIn;
}

/// What [GroupAlarm] is about.
enum GroupAlarmKind {
  /// Two phones each said they were the family: its place ended.
  contested,

  /// The family that invited it said "That wasn't them": its place ended.
  disowned,

  /// The group says the family left, and it didn't.
  removed,

  /// The group's "we're in" for the family isn't the one its phone made.
  notOurs,

  /// The phone that brought the family in no longer counts in the group.
  deviceGone,

  /// Another phone used the family's invitation.
  stranger,

  /// The inviting family dated changes to the family before it said it was in, which that phone
  /// hadn't heard of (all voided).
  backdated,
}

/// Something wrong with how a family began in a group, as its own log recorded it
/// ([Den.groupAlarm]), for its devices to show.
class GroupAlarm {
  const GroupAlarm(this.kind, this.message);
  final GroupAlarmKind kind;
  final String message;

  @override
  String toString() => '${kind.name}: $message';
}

/// Whether [c] is shaped like a "we're in": a change setting a home `active` and naming what it
/// heard. In a group, the materializer tries the ones by devices let in through that home's
/// window ([GroupStarts.saysIn]).
bool closesWindow(Change c) => c.type == RecordType.home && c.fields['status'] == HomeStatus.active.name && c.fields.containsKey('heard');

/// The closure [c] makes, when it makes one.
WindowClosure? windowClosureOf(Change c) {
  if (!closesWindow(c)) return null;
  final heard = c.fields['heard'];
  return WindowClosure(c.id, c.rid, c.hlc, c.device, {if (heard is List) ...heard.whereType<String>()});
}

/// The home whose window [c] is a window power over (see [WindowClosure]), or null: a change to
/// one of that home's people, devices, keys or its record, by a person of the home that invited
/// it. Read from what never changes once written (a person's, device's and key's family, a home's
/// inviter), so it reads the same at any point after those records exist.
String? windowPowerOver(Change c, RecordStore store) {
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
  final e = store.at(Space.family, RecordType.home, target);
  return e?.fields['invitedBy'] == actorHome ? target : null;
}

/// The home [c] lets its device into through its window (a proof by that home's one key), or
/// null.
String? windowAdmissionInto(Change c, RecordStore store) {
  if (c.type != RecordType.device || c.rid != c.device) return null;
  final home = c.fields['home'];
  if (home is! String) return null;
  final key = store.at(Space.family, RecordType.home, home)?.fields['key'];
  final proof = InviteProof.parse(c.fields['invite']);
  return key is String && proof != null && proof.key == key ? home : null;
}

/// Whether one of [closures] makes [c] count for nothing ([WindowClosure]).
bool windowClosedOut(Change c, RecordStore store, Iterable<WindowClosure> closures) {
  if (closures.isEmpty) return false;
  final admitted = windowAdmissionInto(c, store);
  final power = admitted == null ? windowPowerOver(c, store) : null;
  if (admitted == null && power == null) return false;
  for (final w in closures) {
    if (!(c.hlc < w.at)) continue;
    if (admitted == w.home && c.device != w.author) return true;
    if (power == w.home && !w.heard.contains(c.id)) return true;
  }
  return false;
}

/// Validity's one hook for groups (G1-G8), called for every change after its schema checks.
/// A rejection stands; null lets the family's rules decide, which still apply in a group, so
/// the rules here only ever narrow them, except where validity.dart asks [isGroupLog] (a group's
/// genesis writes its founder's home; a device joining a group writes its home).
///
/// In a family's log it refuses what only a group holds, so a family behaves as it did.
/// [closures] are the windows closed so far ([WindowClosure]), settled by the materializer; a
/// "we're in" counts only as one of them, unless [precheck] (an engine checking its own change
/// before it signs it, which the materializer then settles).
Rejection? checkGroupRules(Change c, Entry? existing, RecordStore store, TrustRoot trust,
    {required bool group, Iterable<WindowClosure> closures = const [], bool precheck = false}) {
  if (!group) return _familyRefusesGroupThings(c);
  if (windowClosedOut(c, store, closures)) {
    return _trust('That family said it was in before this, without having heard of it');
  }
  return _GroupCheck(c, existing, store, trust, closures, precheck).check();
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
  _GroupCheck(this.c, this.existing, this.store, this.trust, this.closures, this.precheck);

  final Change c;
  final Entry? existing;
  final RecordStore store;
  final TrustRoot trust;
  final Iterable<WindowClosure> closures;
  final bool precheck;

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
  /// personal device, as someone of that home). An invited home's one key ([homeIdFor]) lets in
  /// its first parent's phone while its window is open, and never once it is shut. Within the
  /// window it isn't used up: a join dated earlier with the inviting family's copy of the key
  /// can't push out the real one, and the phone that says the family is in is the one device the
  /// window let in that stays ([WindowClosure]).
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
    if (home.invitedBy != makerHome || proof.key != home.rec.strOrNull('key')) {
      return _trust('Only a family\'s own parents, or the family that invited it, let it in');
    }
    if (proof.mode != DeviceMode.personal || proof.member == null) {
      return _trust('An invitation lets in its family\'s first parent\'s phone only');
    }
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
      // Any parent of a family in the group invites another, on their own device, with the one
      // key its id is bound to.
      if (c.fields['status'] != HomeStatus.invited.name) return _deny('A family joins a group when it\'s invited');
      if (a == null || !parentHere) return _deny('Only a parent on their own device invites another family');
      if (c.fields['invitedBy'] != actorHome) return _schema('An invitation names the family that sent it');
      final key = c.fields['key'];
      if (key is! String || c.rid != homeIdFor(key, c.device)) {
        return _schema('An invited family\'s id is its invitation\'s, made on the device that sends it');
      }
      // Its own log's id (fixed once said) and where its hub syncs are the invited family's to say.
      if (c.fields['family'] != null || c.fields['hubs'] != null) {
        return _schema('A family says where its Den is itself, once it\'s in');
      }
      if (c.fields.containsKey('heard') || c.fields.containsKey('disowned')) return _schema('A family is invited first');
      return null;
    }
    // "That wasn't them" after the invited family said it was in: it counts as the change that
    // ended that family's place (GroupStarts), and nothing else.
    if (c.fields.containsKey('disowned')) {
      if (store.endedHomes[c.rid]?.by == c.id) return null;
      // Its own engine, before it signs it: the materializer then settles whether it ended it.
      if (precheck && only({'disowned'}) && c.fields['disowned'] == true && c.device == existing!.createdDevice) return null;
      return _deny('Only the phone that sent an invitation says "That wasn\'t them", within a day of that family saying it was in');
    }
    final h = homeAt(store, c.rid)!;
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
    // Saying an invited family is in closes its window ([WindowClosure]): only the phone its
    // invitation let in says it, as that first parent, naming the window powers it heard of; it
    // counts only as the closure in force, which the materializer settles.
    final activates = h.status == HomeStatus.invited && status == HomeStatus.active.name;
    if (activates) {
      if (h.invitedBy == null) return _schema('Only an invited family closes its invitation');
      final proof = inviteOf(author);
      if (proof == null || proof.key != h.rec.strOrNull('key') || author.member != proof.member || a.id != author.member) {
        return _deny('Only the phone ${h.name}\'s invitation let in says they\'re in');
      }
      if (c.fields['heard'] is! List) return _schema('Saying the family is in names what it heard from the family that invited it');
      if (!precheck && !closures.any((w) => w.id == c.id)) {
        return _trust('That "we\'re in" doesn\'t hold: it would void what let its own phone in');
      }
    } else if (c.fields.containsKey('heard')) {
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
      // The window: the family that invited this one adds its first parent, and nothing else.
      if (creating) {
        if (!inviteWindowOpen(store, homeId) || h.invitedBy != actorHome) {
          return _deny('Only ${h.name}\'s own parents add their people');
        }
        if (c.fields['role'] != Role.parent.name) return _deny('The first person of an invited family is a parent');
        if (membersOfHome(store, homeId).any((m) => m.isParent)) {
          return _deny('${h.name}\'s parents add the rest of their family themselves');
        }
        if (!parentHere) return _deny(_ownDeviceOnly);
        return null;
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
    // No other family touches a device, the one an invitation let in included: "That wasn't
    // them" takes the invitation back, or ends that family's place (GroupStarts).
    if (actorHome != after) return _deny('Only ${homeName(after)}\'s own parents can let its devices in or change them');
    if (c.fields['approved'] == true && after == null) return _schema('Choose which family in the group this device belongs to');
    return null;
  }

  /// G2 and G6 for an invite key in a group: it names its home, and only that home's parents
  /// make or withdraw one, except an invited home's one key, which the family that invited it
  /// makes with the invitation.
  Rejection? _inviteKey() {
    final e = existing;
    if (e != null) {
      if (actorHome == e.fields['home']) return null;
      return _deny('Only ${homeName(e.fields['home'])}\'s own parents can take that invite back');
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
    // The window: the invitation's one key, for the invited family's first parent's phone.
    if (!inviteWindowOpen(store, homeId) || h.invitedBy != actorHome) {
      return _deny('Only ${h.name}\'s own parents can invite their people');
    }
    final m = liveMember(member);
    final modes = c.fields['modes'];
    if (c.fields['key'] != h.rec.strOrNull('key') ||
        m == null ||
        m.home != homeId ||
        !m.isParent ||
        (modes != null && (modes is! List || modes.length != 1 || modes.single != DeviceMode.personal.name))) {
      return _deny('An invitation lets in its family\'s first parent\'s phone only, with its own key');
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
/// parent, and the one key that lets that parent's phone in (the home's id is bound to it,
/// [homeIdFor]), which the invitation sent to that parent carries. The family's hub joins later,
/// with a key of the family's own, once its parent's phone says the family is in.
class GroupInvitation {
  const GroupInvitation({
    required this.parent,
    required this.homeName,
    required this.parentName,
    required this.hubs,
  });

  /// For the invited family's first parent's own phone.
  final GroupAdmission parent;

  /// The invited family, as the group names it.
  final String homeName;

  /// Its first parent.
  final String parentName;

  /// Where the inviting family's hub syncs the group: the invited phone dials it first.
  final List<String> hubs;

  String get group => parent.group;
  String get home => parent.home;
  String get member => parent.member!;
  int get expires => parent.expires;
}
