import 'package:collection/collection.dart';

import 'change.dart';
import 'chores.dart';
import 'groups.dart';
import 'hlc.dart';
import 'invite_keys.dart';
import 'model.dart';
import 'permissions.dart';
import 'recovery.dart';
import 'schema.dart';
import 'store.dart';
import 'views.dart';

enum RejectionKind {
  /// The author device or the acting member isn't trusted to make the change.
  trust,

  /// The acting member may not do this.
  permission,

  /// The fields don't fit the record type.
  schema,
}

/// Why a change doesn't count. [message] is written for people.
class Rejection {
  const Rejection(this.kind, this.message);
  final RejectionKind kind;
  final String message;

  Exception toException() =>
      kind == RejectionKind.schema ? InvalidInput(message) : PermissionDenied(message);

  @override
  String toString() => '${kind.name}: $message';
}

/// A revocation that names the last change the revoking device held from the revoked one: a
/// change from that device numbered past [after] and clocked before [at] was signed after the
/// revocation, whatever clock it claims.
class Cutoff {
  const Cutoff(this.after, this.at);

  /// The `revokedAfter` counter.
  final int after;

  /// The revocation's clock.
  final Hlc at;

  bool excludes(int counter, Hlc hlc) => counter > after && hlc < at;

  /// The cutoff a valid change sets, or null when it isn't a revocation naming one.
  static Cutoff? of(Change c) {
    if (c.type != RecordType.device || c.fields['revoked'] != true) return null;
    final after = c.fields['revokedAfter'];
    return after is int ? Cutoff(after, c.hlc) : null;
  }
}

/// What every replica of a family learned out of band: the family id and the founder's key.
class TrustRoot {
  TrustRoot({this.familyId, this.founderPubkey})
      : founderDevice = founderPubkey == null ? null : deviceIdOf(founderPubkey);
  final String? familyId;
  final String? founderPubkey;
  final String? founderDevice;
}

Rejection _trust(String m) => Rejection(RejectionKind.trust, m);
Rejection _deny(String m) => Rejection(RejectionKind.permission, m);
Rejection _schema(String m) => Rejection(RejectionKind.schema, m);

const String _ownDeviceOnly =
    'Only a parent on their own device can do that, not a shared screen or an app acting through the hub';

final RegExp _ridRe = RegExp(r'^[A-Za-z0-9_\-:@.]{1,120}$');

bool _validSpace(String s) =>
    s == Space.family || s == Space.parents || (Space.isMember(s) && s.length > 2 && s.length <= 82);

/// Decides whether a change counts, given the state built from every valid change before it in
/// HLC order. It reads only the change's own space and the family space, so every replica that
/// holds the change reaches the same answer.
class Validator {
  Validator(this.store, this.root);
  final RecordStore store;
  TrustRoot Function() root;

  /// Device id -> the revocations of it that name the last change the revoking device held
  /// (`revokedAfter`), with the revocation's clock. The materializer fills this from the whole
  /// log, so a change the revoked device signed later counts for nothing even when it claims an
  /// earlier clock.
  final Map<String, List<Cutoff>> cutoffs = {};

  /// Recovery keys replaced later in the log, and groups' closed windows; the materializer fills
  /// this like [cutoffs].
  final RetiredRecoveryKeys retiredRecoveryKeys = RetiredRecoveryKeys();

  /// Whether a group's closed window ([WindowClosure]) makes [c] count for nothing.
  bool closedOut(Change c) => windowClosedOut(c, store, retiredRecoveryKeys.closures);

  /// The counter of the change by [device] that made its record (its join request, its
  /// recovery change, or the founder's genesis), whose clock is [created]; null when unknown.
  /// The materializer, which holds the log, answers.
  int? Function(String device, Hlc created)? createdCounter;

  /// While an engine checks its own change before signing it ([Materializer.check]): a group's
  /// "we're in" is then judged as if it were the closure in force, which the materializer
  /// settles once the change is added.
  bool prechecking = false;

  Rejection? check(Change c) {
    // A group's home that ended later reads as it was when [c] was made (groups.dart, homeAt).
    store.judging = c.hlc;
    try {
      return _check(c);
    } finally {
      store.judging = null;
    }
  }

  Rejection? _check(Change c) {
    final colon = c.id.lastIndexOf(':');
    final counter = colon > 0 ? int.tryParse(c.id.substring(colon + 1)) : null;
    if (counter == null || counter < 1 || c.id.substring(0, colon) != c.device) {
      return _trust('The change id doesn\'t name its device');
    }
    if (c.hlc.device != c.device) return _trust('The change\'s clock belongs to another device');
    for (final cut in cutoffs[c.device] ?? const <Cutoff>[]) {
      if (cut.excludes(counter, c.hlc)) return _trust('This device was removed from the family');
    }
    final spec = typeSpecs[c.type];
    if (spec == null) return _schema('Den doesn\'t know records of type "${c.type}"');
    if (!_validSpace(c.space)) return _schema('Unknown space "${c.space}"');
    if (spec.space != null && c.space != spec.space) {
      return _schema('${c.type} records belong in space "${spec.space}"');
    }
    if (!_ridRe.hasMatch(c.rid)) return _schema('The record id isn\'t valid');
    final trust = root();
    if (trust.familyId == null || trust.founderDevice == null) {
      return _trust('This device hasn\'t joined a family');
    }
    final existing = store.at(c.space, c.type, c.rid);
    final creating = existing == null;
    if (creating && c.isDelete) return _schema('There\'s nothing to remove');
    final fieldError = checkFields(c.type, c.fields, creating: creating);
    if (fieldError != null) return _schema(fieldError);
    final crossError = _crossFields(c, existing);
    if (crossError != null) return _schema(crossError);
    // A cutoff never reaches the change that made the device's record: that would erase the
    // device itself, everything it wrote and every device it let in, whoever removed it.
    final after = c.fields['revokedAfter'];
    if (c.type == RecordType.device && after is int && existing != null) {
      final made = createdCounter?.call(c.rid, existing.created);
      if (made != null && after < made) {
        return _trust('A removal can\'t reach back past the device\'s own request to join');
      }
    }

    // A group of families (groups.dart): its rules G1-G8 narrow the family's below. A family's
    // log refuses what only a group holds.
    final group = isGroupLog(store, trust);
    final groupRejection =
        checkGroupRules(c, existing, store, trust, group: group, closures: retiredRecoveryKeys.closures, precheck: prechecking);
    if (groupRejection != null) return groupRejection;

    final authorEntry = store.at(Space.family, RecordType.device, c.device);
    // The one way a device approves itself: as an existing parent's, with a recovery proof.
    if (c.type == RecordType.device && c.fields.containsKey('recovery')) {
      return checkRecovery(c, store, trust, retiredRecoveryKeys, group: group);
    }
    // Or as someone's own, with a proof from an invite key a parent made (invite_keys.dart).
    if (c.type == RecordType.device && c.fields.containsKey('invite')) {
      final key = InviteProof.parse(c.fields['invite']);
      final record = key == null ? null : store.at(Space.family, RecordType.inviteKey, key.invite);
      final window = group && record != null && isWindowKey(store, InviteKeyRecord(record.rec));
      return checkInviteJoin(c, store, trust, excluded: retiredRecoveryKeys.excludes(c), group: group, window: window);
    }
    if (c.device == trust.founderDevice && authorEntry == null) {
      return _genesis(c, existing, trust);
    }
    if (c.type == RecordType.device && c.rid == c.device) {
      final pending = authorEntry == null ||
          (!authorEntry.deleted &&
              !Device(authorEntry.rec).approved &&
              !Device(authorEntry.rec).revoked);
      if (pending) return _join(c, existing);
    }
    if (authorEntry == null) return _trust('This device isn\'t part of the family');
    final author = Device(authorEntry.rec);
    if (authorEntry.deleted || author.revoked) {
      return _trust('This device was removed from the family');
    }
    if (!author.approved) return _trust('This device is waiting for a parent\'s approval');

    Member? actor;
    if (c.actor != null) {
      final m = store.liveAt(Space.family, RecordType.member, c.actor!);
      if (m == null) return _trust('That person isn\'t in the family');
      actor = Member(m.rec);
    }
    final hub = author.mode == DeviceMode.hub;
    if (author.mode == DeviceMode.personal && (author.member == null || c.actor != author.member)) {
      return _trust('This device acts only for its owner');
    }
    if (c.fields.containsKey('_via') && !hub) {
      return _schema('Only the hub records which connection made a change');
    }
    // In a group a hub acting for anyone but its owner says which connection it acts for (G4).
    if (group && hub && actor != null && actor.id != author.member && !c.fields.containsKey('_via')) {
      return _deny('A hub records which connection it acts for');
    }
    final familyEntry = store.liveAt(Space.family, RecordType.family, trust.familyId!);
    final family = familyEntry == null ? null : Family(familyEntry.rec);
    final x = _Ctx(
      c: c,
      device: author,
      actor: actor,
      hub: hub,
      openCheckoff: author.mode == DeviceMode.shared && actor == null && author.openCheckoff,
      family: family,
      existing: existing,
      group: group,
    );

    if (c.space == Space.parents && !(hub || (actor?.isParent ?? false))) {
      return _deny('Only parents can add or change parents-only things');
    }
    final privateOwner = Space.memberOf(c.space);
    // Acting for a connection, the hub writes only where the person it acts for could read
    // (or, for a connection with no person, where a parent could): what den_actions checks.
    if (hub && c.fields.containsKey('_via')) {
      final readable = actor != null
          ? canRead(actor, c.space, family)
          : privateOwner == null || (family?.parentsSeePrivate(privateOwner) ?? true);
      if (!readable) return _deny('This connection can\'t see that, so it can\'t put things there');
    }
    if (privateOwner != null) {
      final owner = store.liveAt(Space.family, RecordType.member, privateOwner);
      if (owner == null) return _schema('That person isn\'t in the family');
      final allowed = hub ||
          c.actor == privateOwner ||
          ((actor?.isParent ?? false) && (family?.parentsSeePrivate(privateOwner) ?? true));
      if (!allowed) return _deny('That belongs to ${Member(owner.rec).name} alone');
    }
    return _permit(x, trust);
  }

  Rejection? _genesis(Change c, Entry? existing, TrustRoot trust) {
    final familyExists = store.liveAt(Space.family, RecordType.family, trust.familyId!) != null;
    switch (c.type) {
      case RecordType.family:
        if (c.rid != trust.familyId) return _trust('That isn\'t this family');
        if (existing != null) return _trust('The family already exists');
        if (familyIdFor(trust.founderPubkey!, c.hlc.millis) != trust.familyId) {
          return _trust('The family id doesn\'t match its founder');
        }
        if (c.fields['founderDevice'] != c.device) {
          return _trust('The family must name the device that founded it');
        }
        return null;
      case RecordType.member:
        if (!familyExists) return _trust('The family isn\'t set up yet');
        if (existing != null) return _trust('The founder can only add people once the family is set up');
        if (c.fields['role'] != Role.parent.name) return _trust('The founder must be a parent');
        return null;
      case RecordType.device:
        if (!familyExists) return _trust('The family isn\'t set up yet');
        if (c.rid != c.device) return _trust('The founder must approve its own device first');
        if (c.fields['approved'] != true || c.fields['revoked'] == true) {
          return _trust('The founder\'s device must be approved');
        }
        if (c.fields['pubkey'] != trust.founderPubkey) {
          return _trust('The founder\'s device key doesn\'t match the family');
        }
        final ownerId = c.fields['member'];
        final owner = ownerId is String ? store.liveAt(Space.family, RecordType.member, ownerId) : null;
        if (owner == null || !Member(owner.rec).isParent) {
          return _trust('The founder\'s device must belong to a parent');
        }
        return null;
      case RecordType.home:
        // A group's founder's own family (groups.dart decides the rest).
        if (!familyExists) return _trust('The family isn\'t set up yet');
        return null;
      default:
        return _trust('The family isn\'t set up yet');
    }
  }

  Rejection? _join(Change c, Entry? existing) {
    if (existing != null) {
      final d = Device(existing.rec);
      if (existing.deleted || d.approved || d.revoked) return _trust('This device can\'t ask to join again');
    }
    if (c.actor != null) return _trust('A device asking to join can\'t act for anyone');
    final f = c.fields;
    if (f['approved'] == true || f.containsKey('approvedBy') || f['revoked'] == false) {
      return _trust('A device can never approve itself');
    }
    if (existing == null && f['approved'] != false) {
      return _trust('A join request must wait for approval');
    }
    if (existing != null &&
        !c.isDelete &&
        f.keys.any((k) => !const {'name', 'kind', 'xpub', 'revoked', 'revokedAfter', 'approved'}.contains(k))) {
      return _trust('A device can\'t change what it asked for while it waits for approval');
    }
    final pubkey = f['pubkey'];
    if (pubkey != null) {
      if (existing != null && pubkey != Device(existing.rec).pubkey) {
        return _trust('A device\'s key can\'t change');
      }
      if (deviceIdOf(pubkey as String) != c.rid) return _trust('The device key doesn\'t match its id');
    }
    return null;
  }

  String? _crossFields(Change c, Entry? existing) {
    Object? merged(String name) => c.fields.containsKey(name) ? c.fields[name] : existing?.fields[name];
    if (existing != null && !c.isDelete) {
      final fixed = _immutable[c.type] ?? const <String>{};
      for (final name in fixed) {
        if (c.fields.containsKey(name) && c.fields[name] != existing.fields[name]) {
          return 'This can\'t be changed after it\'s made';
        }
      }
      if (c.type == RecordType.adjustment) return 'Points adjustments can\'t be changed';
    }
    switch (c.type) {
      case RecordType.device:
        if (c.fields.containsKey('revokedAfter') && c.fields['revoked'] != true) {
          return 'Only a removal says which of a device\'s changes came before it';
        }
      case RecordType.event:
        final start = merged('start'), end = merged('end');
        if (start is int && end is int && end < start) return 'The end is before the start';
      case RecordType.eventException:
        if (!c.isDelete && c.rid != '${merged('event')}@${merged('occurrence')}') {
          return 'An occurrence\'s id must be "<event>@<start>"';
        }
      case RecordType.completion:
        if (!c.isDelete && c.rid != '${merged('chore')}@${merged('date')}') {
          return 'A completion\'s id must be "<chore>@<date>"';
        }
      case RecordType.goal:
        final start = merged('start'), end = merged('end');
        if (start is String && end is String && end.compareTo(start) < 0) {
          return 'The goal ends before it starts';
        }
      case RecordType.photo:
        final bytes = photoBytes(merged('data'));
        if (!c.isDelete && bytes != null && photoFormat(bytes)?.mime != merged('mime')) {
          return 'The photo isn\'t the kind it says it is';
        }
    }
    return null;
  }

  static const Map<String, Set<String>> _immutable = {
    RecordType.family: {'founderDevice', 'kind'},
    RecordType.device: {'pubkey'},
    RecordType.eventException: {'event', 'occurrence'},
    RecordType.completion: {'chore', 'date'},
    RecordType.item: {'list'},
    RecordType.redemption: {'reward', 'member', 'cost'},
    RecordType.connection: {'kind'},
    RecordType.photo: {'member', 'mime', 'data'},
    RecordType.member: {'home'},
    RecordType.inviteKey: {'member', 'home', 'modes', 'uses', 'by', 'device', 'expires'},
    RecordType.home: {'invitedBy', 'key'},
    RecordType.groupLink: {'group', 'founder'},
    RecordType.groupInvite: {'group', 'device'},
  };

  Rejection? _permit(_Ctx x, TrustRoot trust) {
    final c = x.c;
    switch (c.type) {
      case RecordType.family:
        if (x.creating || c.rid != trust.familyId) return _trust('The family already exists');
        if (!x.has(DenAction.manageFamily)) return _deny('Only parents can change family settings');
        // Privacy, and which AI may read the family's day and spend its money, are a parent's
        // decisions on their own device: never a shared screen or an app acting through the hub.
        if (c.fields.keys.any((k) => k == 'oversight' || k.startsWith('oversight.') || k == 'assistant') && !x.ownDevice) {
          return _deny(_ownDeviceOnly);
        }
        // So is whether the hub may let a parent's new phone in (recovery.dart).
        if (c.fields.containsKey('recovery') && !x.ownDevice) return _deny(_ownDeviceOnly);
        return null;
      case RecordType.member:
        // A person's role, permissions and sign-in, and whether they are in the family at all,
        // are trust decisions: never made by the hub (whoever it acts for) or on a shared screen.
        // Adding someone isn't: nothing can act for them until a parent approves a device or an
        // assistant for them, on their own device.
        // A sitter's last day decides when their devices are removed, so it is one too.
        final trusted = c.fields.containsKey('_deleted') ||
            (!x.creating && c.fields.keys.any(const {'role', 'grants', 'signIn', 'until'}.contains));
        if (trusted && !x.ownDevice) return _deny(_ownDeviceOnly);
        if (c.fields.containsKey('recovery')) {
          final r = checkRecoveryKey(c, ownDevice: x.ownDevice, actor: x.actor, creating: x.creating);
          if (r != null) return r;
        }
        final photo = c.fields['picture'] is String ? Picture.photoIdOf(c.fields['picture']! as String) : null;
        if (photo != null && store.liveAt(Space.family, RecordType.photo, photo)?.fields['member'] != c.rid) {
          return _schema('That photo isn\'t of this person');
        }
        if (!x.creating && x.only({'signIn'}) && c.actor == c.rid) return null;
        // People choose their own picture, a kid when a parent allows it.
        if (!x.creating && x.only({'picture'}) && c.actor == c.rid && !x.has(DenAction.manageFamily)) {
          return x.mayChangePicture(c.rid) ? null : _deny('${x.who} can\'t change their own picture');
        }
        if (!x.has(DenAction.manageFamily)) return _deny('Only parents can add or change people');
        if (_leavesNoParent(c, x.existing)) return _deny('The family needs at least one parent');
        return null;
      case RecordType.device:
        return _device(x);
      case RecordType.category:
        return x.has(DenAction.editEvents) ? null : _deny('${x.who} can\'t change categories');
      case RecordType.event:
        return x.has(DenAction.editEvents) ? null : _deny('${x.who} can\'t add or change events');
      case RecordType.eventException:
        final eventId = c.fields['event'] ?? x.existing?.fields['event'];
        if (eventId is! String || store.at(c.space, RecordType.event, eventId) == null) {
          return _schema('That event doesn\'t exist');
        }
        return x.has(DenAction.editEvents) ? null : _deny('${x.who} can\'t add or change events');
      case RecordType.chore:
        if (!x.has(DenAction.editChores)) return _deny('${x.who} can\'t add or change chores');
        // Moving a chore to another space writes a copy: one of a chore in everyone's space
        // (which every replica holding the copy holds too) at the same price sets none.
        final original = x.existing ?? (c.space == Space.family ? null : store.at(Space.family, RecordType.chore, c.rid));
        if (_setsPoints(c, original) && !x.has(DenAction.managePoints)) {
          return _deny('${x.who} can\'t set how many stars a chore is worth');
        }
        return null;
      case RecordType.completion:
        return _completion(x);
      case RecordType.adjustment:
        final member = c.fields['member'];
        if (member is! String || store.liveAt(Space.family, RecordType.member, member) == null) {
          return _schema('That person isn\'t in the family');
        }
        if (c.fields['by'] != c.actor) return _schema('An adjustment must name who made it');
        if (member == c.actor) return _deny('${x.who} can\'t give or take their own points');
        return x.has(DenAction.managePoints) ? null : _deny('${x.who} can\'t give or take points');
      case RecordType.goal:
      case RecordType.reward:
        return x.has(DenAction.managePoints) ? null : _deny('${x.who} can\'t change goals or rewards');
      case RecordType.redemption:
        return _redemption(x);
      case RecordType.list:
        return x.has(DenAction.editLists) ? null : _deny('${x.who} can\'t add or change lists');
      case RecordType.item:
        if (x.creating) {
          final list = c.fields['list'];
          if (list is! String || store.liveAt(c.space, RecordType.list, list) == null) {
            return _schema('That list doesn\'t exist');
          }
        }
        if (!x.creating && !c.isDelete && x.only({'checked', 'checkedBy'})) {
          return x.has(DenAction.checkItems) ? null : _deny('${x.who} can\'t check items');
        }
        return x.has(DenAction.editLists) ? null : _deny('${x.who} can\'t change lists');
      case RecordType.subscription:
        if (x.hub && !x.creating && !c.isDelete && x.only({'status'})) return null;
        return x.has(DenAction.manageFamily) ? null : _deny('Only parents can manage calendar feeds');
      case RecordType.connection:
        return _connection(x);
      case RecordType.signInTries:
        // A shared screen tells the parents that someone kept getting a person's PIN or pattern
        // wrong there: a new record each time, about itself, for nobody.
        if (!x.creating) return _schema('That can\'t be changed after it\'s made');
        if (x.device.mode != DeviceMode.shared || c.actor != null) {
          return _deny('Only a shared screen says that, for nobody');
        }
        if (c.fields['device'] != c.device) return _schema('A shared screen says that only about itself');
        final member = c.fields['member'];
        if (member is! String || store.liveAt(Space.family, RecordType.member, member) == null) {
          return _schema('That person isn\'t in the family');
        }
        return null;
      case RecordType.inviteKey:
        return checkInviteKeyWrite(c, x.existing, store, ownDevice: x.ownDevice, actor: x.actor, group: x.group);
      case RecordType.home:
        // Only a group holds these, and groups.dart decided.
        return null;
      case RecordType.groupLink:
        return checkGroupLinkWrite(c, x.existing, ownDevice: x.ownDevice, actor: x.actor);
      case RecordType.groupInvite:
        return checkGroupInviteWrite(c, x.existing, store, ownDevice: x.ownDevice, actor: x.actor);
      case RecordType.photo:
        final member = c.fields['member'] ?? x.existing?.fields['member'];
        if (member is! String || store.liveAt(Space.family, RecordType.member, member) == null) {
          return _schema('That person isn\'t in the family');
        }
        return x.mayChangePicture(member) ? null : _deny('${x.who} can\'t change that picture');
    }
    return _schema('Den doesn\'t know records of type "${c.type}"');
  }

  /// Whether a chore change sets what the chore or one of its steps is worth to anything but
  /// what it was: a new chore or step worth stars, or a new price for one.
  static bool _setsPoints(Change c, Entry? existing) {
    if (c.isDelete) return false;
    int worth(Object? v) => v is num ? v.toInt() : 0;
    final f = c.fields;
    if (f.containsKey('points') && worth(f['points']) != worth(existing?.fields['points'])) return true;
    final steps = f['steps'];
    if (steps is! List) return false;
    final before = {
      for (final s in (existing?.fields['steps'] as List?) ?? const <Object?>[])
        if (s is Map) s['id']: worth(s['points']),
    };
    return steps.any((s) => s is Map && worth(s['points']) != (before[s['id']] ?? 0));
  }

  bool _leavesNoParent(Change c, Entry? existing) {
    if (!c.fields.containsKey('role') && !c.isDelete) return false;
    final wasParent = existing != null && !existing.deleted && existing.fields['role'] == Role.parent.name;
    final isParent = !c.isDelete &&
        (c.fields.containsKey('role') ? c.fields['role'] : existing?.fields['role']) == Role.parent.name;
    if (!wasParent || isParent) return false;
    final others = store
        .liveOfType(RecordType.member)
        .where((e) => e.space == Space.family && e.id != c.rid && e.fields['role'] == Role.parent.name);
    return others.isEmpty;
  }

  Rejection? _device(_Ctx x) {
    final c = x.c;
    if (x.creating) return _trust('A device joins by sending its own request');
    // A hub acting for an API or MCP connection never touches device records, its own included:
    // a connection could otherwise turn the hub into a personal device and act as its owner.
    if (c.fields.containsKey('_via')) return _deny(_ownDeviceOnly);
    final target = Device(x.existing!.rec);
    final mode = c.fields.containsKey('mode') ? c.fields['mode'] : target.mode.name;
    final owner = c.fields.containsKey('member') ? c.fields['member'] : target.member;
    if (c.fields.containsKey('mode') && mode == DeviceMode.personal.name && owner == null) {
      return _schema('A personal device needs an owner');
    }
    // What a device holds follows its owner, and changing the owner would leave the old owner's
    // records on it: to give a device to someone else, remove it and add it again.
    if (c.fields.containsKey('member') && target.approved && !target.revoked && owner != target.member) {
      return _deny('A device stays with the person it was approved for. Remove it and add it again instead');
    }
    if (c.rid == c.device) {
      final f = c.fields;
      if (f.containsKey('approved') ||
          f.containsKey('approvedBy') ||
          f.containsKey('member') ||
          (f.containsKey('revoked') && f['revoked'] != true)) {
        return _trust('A device can never approve itself or change who owns it');
      }
      if (x.only({'revoked', 'revokedAfter'}) || c.isDelete) return null;
      final parent = x.actor?.isParent ?? false;
      if (f.containsKey('mode') && !parent) return _deny('Only a parent can change what this device is for');
      if (parent && x.only({'mode', 'name', 'display', 'kind', 'xpub', 'revoked', 'revokedAfter'})) return null;
    }
    if (!x.has(DenAction.manageFamily)) return _deny('Only parents can approve or change devices');
    if (c.fields['approved'] == true && !(x.actor?.isParent ?? false)) {
      return _deny('Only a parent can approve a device');
    }
    if (!x.ownDevice) return _deny(_ownDeviceOnly);
    return null;
  }

  Rejection? _completion(_Ctx x) {
    final c = x.c;
    final choreId = (c.fields['chore'] ?? x.existing?.fields['chore']) as String?;
    final date = (c.fields['date'] ?? x.existing?.fields['date']) as String?;
    final choreEntry = choreId == null ? null : store.at(c.space, RecordType.chore, choreId);
    if (choreEntry == null || date == null) return _schema('That chore doesn\'t exist');
    // A removed chore takes no more check-offs: one moved to another space lives on there, and
    // a device that hadn't heard of the move would otherwise be paid twice.
    if (choreEntry.deleted && !c.isDelete) return _schema('That chore was removed');
    final chore = Chore(choreEntry.rec);
    final completion = x.existing == null ? null : Completion(x.existing!.rec);
    final ownerBefore = dayOwner(chore, date, completion, x.family?.weekStart ?? 0);
    final me = c.actor;
    final kid = x.actor?.role == Role.kid;
    bool owns(String? owner) => owner == null || owner == me;
    Rejection? mayComplete(bool own) =>
        (own ? x.has(DenAction.completeOwnChore) : x.has(DenAction.completeAnyChore))
            ? null
            : _deny('${x.who} can\'t complete someone else\'s chore');

    if (c.isDelete) return mayComplete(false);
    if (c.fields.containsKey('owner')) {
      if (!x.has(DenAction.swapChore)) return _deny('${x.who} can\'t swap chores');
      if (kid && ownerBefore != me) return _deny('Kids can swap only their own chores');
    }
    final stepWrites = <String, Object?>{};
    if (c.fields.containsKey('steps')) {
      final whole = (c.fields['steps'] as Map?) ?? const {};
      for (final s in chore.steps) {
        stepWrites[s.id] = whole[s.id];
      }
      for (final k in whole.keys) {
        stepWrites.putIfAbsent(k as String, () => whole[k]);
      }
    }
    for (final e in c.fields.entries) {
      if (e.key.startsWith('steps.')) stepWrites[e.key.substring(6)] = e.value;
    }
    // What the chore and its steps were worth when done is kept with the completion, so a new
    // price later doesn't change what was earned. Only someone who sets prices may record more
    // than the price at the time.
    final pricer = x.has(DenAction.managePoints);
    final worth = c.fields['points'];
    if (worth is int && worth > chore.points && !pricer) {
      return _deny('${x.who} can\'t set how many stars a chore is worth');
    }
    final stepWorth = <String, Object?>{
      ...?(c.fields['stepPoints'] as Map?)?.cast<String, Object?>(),
      for (final e in c.fields.entries)
        if (e.key.startsWith('stepPoints.')) e.key.substring(11): e.value,
    };
    for (final e in stepWorth.entries) {
      final step = chore.steps.firstWhereOrNull((s) => s.id == e.key);
      if (step == null) return _schema('That chore has no such step');
      final v = e.value;
      if (v is int && v > step.points && !pricer) return _deny('${x.who} can\'t set how many stars a chore is worth');
    }
    for (final e in stepWrites.entries) {
      final step = chore.steps.firstWhereOrNull((s) => s.id == e.key);
      if (step == null) return _schema('That chore has no such step');
      final own = step.owner != null ? step.owner == me : owns(ownerBefore);
      final denied = mayComplete(own);
      if (denied != null) return denied;
      if (kid && e.value != null && e.value != me) return _deny('Kids check steps only for themselves');
    }
    if (c.fields.containsKey('done') || c.fields.containsKey('doneBy')) {
      if (kid && c.fields['doneBy'] != null && c.fields['doneBy'] != me) {
        return _deny('Kids complete chores only for themselves');
      }
      if (mayComplete(owns(ownerBefore)) != null) {
        final after = {...?completion?.steps, ...stepWrites};
        final allChecked = chore.steps.isNotEmpty && chore.steps.every((s) => after[s.id] != null);
        final follows = stepWrites.isNotEmpty &&
            (!c.fields.containsKey('done') || c.fields['done'] == allChecked) &&
            (c.fields['doneBy'] == null || c.fields['doneBy'] == me);
        if (!follows) return _deny('${x.who} can\'t complete someone else\'s chore');
      }
    }
    return null;
  }

  Rejection? _redemption(_Ctx x) {
    final c = x.c;
    if (x.creating) {
      final rewardId = c.fields['reward'] as String;
      final rewardEntry = store.liveAt(Space.family, RecordType.reward, rewardId);
      if (rewardEntry == null) return _schema('That reward doesn\'t exist');
      final reward = Reward(rewardEntry.rec);
      if (!reward.active) return _deny('That reward isn\'t available right now');
      if (store.liveAt(Space.family, RecordType.member, c.fields['member'] as String) == null) {
        return _schema('That person isn\'t in the family');
      }
      if (c.fields['cost'] != reward.cost) return _schema('The cost doesn\'t match the reward');
      final forSelf = c.fields['member'] == c.actor && c.actor != null;
      final manager = x.has(DenAction.managePoints);
      if (!(forSelf && x.has(DenAction.requestReward)) && !manager) {
        return _deny('${x.who} can ask for rewards only for themselves');
      }
      final status = c.fields['status'];
      // A request waits for a parent unless the reward says no asking or a parent let this
      // person trade their stars without asking: either one is enough.
      final needsOk = reward.needsApproval && (x.family?.rewardsNeedOk(c.fields['member']! as String) ?? true);
      if (status == RedemptionStatus.declined.name && !manager) {
        return _deny('${x.who} can\'t decline rewards');
      }
      if (status == RedemptionStatus.approved.name && needsOk && !manager) {
        return _deny('A parent needs to approve that reward');
      }
      // Someone who may change rewards could make one need no asking and take it: asking for
      // themselves, a points manager always waits for someone else.
      if (forSelf && (needsOk || manager) && status != RedemptionStatus.requested.name) {
        return _deny('Someone else needs to approve ${x.who}\'s reward');
      }
      if (c.fields['decidedBy'] != null && c.fields['decidedBy'] != c.actor) {
        return _schema('A decision must name who made it');
      }
      return null;
    }
    if (c.isDelete || !x.only({'status', 'decidedBy'})) {
      return _schema('A reward request can only be approved or declined');
    }
    if (!x.has(DenAction.managePoints)) return _deny('${x.who} can\'t approve rewards');
    if (c.actor != null && x.existing!.fields['member'] == c.actor) {
      return _deny('Someone else needs to approve ${x.who}\'s reward');
    }
    if (c.fields['decidedBy'] != null && c.fields['decidedBy'] != c.actor) {
      return _schema('A decision must name who made it');
    }
    return null;
  }

  Rejection? _connection(_Ctx x) {
    final c = x.c;
    // Only a parent on their own device grants access; the hub keeps its own narrow part (asking
    // for OAuth access, issuing tokens for granted access, revoking).
    final parent = (x.actor?.isParent ?? false) && x.ownDevice;
    const denied = 'Only a parent can create or approve AI and automation access';
    if (x.creating) {
      final status = c.fields['status'];
      if (status == ConnectionStatus.pending.name && c.fields['kind'] == ConnectionKind.oauth.name) {
        return x.hub || parent ? null : _deny(denied);
      }
      return parent ? null : _deny(denied);
    }
    if (c.isDelete) return parent ? null : _deny(denied);
    final current = Connection(x.existing!.rec);
    for (final e in c.fields.entries) {
      switch (e.key) {
        case '_via':
          break;
        case 'status':
          if (e.value == ConnectionStatus.revoked.name) {
            if (!(parent || x.hub)) return _deny(denied);
          } else if (!parent) {
            return _deny(denied);
          }
        case 'tokenHash':
        case 'expires':
          if (!(parent || (x.hub && current.status == ConnectionStatus.active))) return _deny(denied);
        default:
          if (!parent) return _deny(denied);
      }
    }
    return null;
  }
}

class _Ctx {
  _Ctx({
    required this.c,
    required this.device,
    required this.actor,
    required this.hub,
    required this.openCheckoff,
    required this.family,
    required this.existing,
    required this.group,
  });

  final Change c;
  final Device device;
  final Member? actor;
  final bool hub;
  final bool openCheckoff;
  final Family? family;
  final Entry? existing;

  /// Whether the log is a group of families (groups.dart).
  final bool group;

  bool get creating => existing == null;

  /// A hub writing for a connection with no member acts at parent level, except for family
  /// administration.
  bool get hubAutomation => hub && actor == null;

  /// Shared displays never administer the family, whoever verified on them.
  bool has(DenAction action) {
    if (action == DenAction.manageFamily && (hubAutomation || device.mode == DeviceMode.shared)) return false;
    return hubAutomation || can(actor, action, openCheckoff: openCheckoff);
  }

  String get who => actor?.name ?? device.name;

  /// Whether the change comes from someone's own device: trust decisions (approving and removing
  /// devices, people's roles, permissions and sign-in, privacy, AI access) are made only there.
  /// That is a personal device, or a parent's own device running as the family's hub with its
  /// owner using it; never a shared screen, a hub nobody owns, or an app or assistant acting
  /// through the hub (whose changes carry `_via`), whoever it acts for.
  bool get ownDevice {
    if (c.fields.containsKey('_via')) return false;
    if (device.mode == DeviceMode.personal) return true;
    return device.mode == DeviceMode.hub && actor != null && actor!.id == device.member;
  }

  /// Whether the actor may change [memberId]'s picture ([canChangePicture]).
  bool mayChangePicture(String memberId) {
    if (has(DenAction.manageFamily)) return true;
    final a = actor;
    return a != null && a.id == memberId && (family?.ownsPicture(a) ?? !a.isKid);
  }

  bool only(Set<String> names) => c.fields.keys.every((k) => k == '_via' || k == '_from' || names.contains(k));
}
