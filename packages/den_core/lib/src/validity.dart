import 'package:collection/collection.dart';

import 'change.dart';
import 'chores.dart';
import 'model.dart';
import 'permissions.dart';
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

  Rejection? check(Change c) {
    final colon = c.id.lastIndexOf(':');
    final counter = colon > 0 ? int.tryParse(c.id.substring(colon + 1)) : null;
    if (counter == null || counter < 1 || c.id.substring(0, colon) != c.device) {
      return _trust('The change id doesn\'t name its device');
    }
    if (c.hlc.device != c.device) return _trust('The change\'s clock belongs to another device');
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

    final authorEntry = store.at(Space.family, RecordType.device, c.device);
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
    );

    if (c.space == Space.parents && !(hub || (actor?.isParent ?? false))) {
      return _deny('Only parents can add or change parents-only things');
    }
    final privateOwner = Space.memberOf(c.space);
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
        f.keys.any((k) => !const {'name', 'kind', 'xpub', 'revoked', 'approved'}.contains(k))) {
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
    }
    return null;
  }

  static const Map<String, Set<String>> _immutable = {
    RecordType.family: {'founderDevice'},
    RecordType.device: {'pubkey'},
    RecordType.eventException: {'event', 'occurrence'},
    RecordType.completion: {'chore', 'date'},
    RecordType.item: {'list'},
    RecordType.redemption: {'reward', 'member', 'cost'},
    RecordType.connection: {'kind'},
  };

  Rejection? _permit(_Ctx x, TrustRoot trust) {
    final c = x.c;
    switch (c.type) {
      case RecordType.family:
        if (x.creating || c.rid != trust.familyId) return _trust('The family already exists');
        return x.has(DenAction.manageFamily) ? null : _deny('Only parents can change family settings');
      case RecordType.member:
        if (!x.creating && x.only({'signIn'}) && c.actor == c.rid) return null;
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
        return x.has(DenAction.editChores) ? null : _deny('${x.who} can\'t add or change chores');
      case RecordType.completion:
        return _completion(x);
      case RecordType.adjustment:
        final member = c.fields['member'];
        if (member is! String || store.liveAt(Space.family, RecordType.member, member) == null) {
          return _schema('That person isn\'t in the family');
        }
        if (c.fields['by'] != c.actor) return _schema('An adjustment must name who made it');
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
    }
    return _schema('Den doesn\'t know records of type "${c.type}"');
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
    final target = Device(x.existing!.rec);
    final mode = c.fields.containsKey('mode') ? c.fields['mode'] : target.mode.name;
    final owner = c.fields.containsKey('member') ? c.fields['member'] : target.member;
    if (c.fields.containsKey('mode') && mode == DeviceMode.personal.name && owner == null) {
      return _schema('A personal device needs an owner');
    }
    if (c.rid == c.device) {
      final f = c.fields;
      if (f.containsKey('approved') ||
          f.containsKey('approvedBy') ||
          f.containsKey('member') ||
          (f.containsKey('revoked') && f['revoked'] != true)) {
        return _trust('A device can never approve itself or change who owns it');
      }
      if (x.only({'revoked'}) || c.isDelete) return null;
      final parent = x.actor?.isParent ?? false;
      if (f.containsKey('mode') && !parent) return _deny('Only a parent can change what this device is for');
      if (parent && x.only({'mode', 'name', 'display', 'kind', 'xpub', 'revoked'})) return null;
    }
    if (!x.has(DenAction.manageFamily)) return _deny('Only parents can approve or change devices');
    if (c.fields['approved'] == true && !(x.actor?.isParent ?? false)) {
      return _deny('Only a parent can approve a device');
    }
    return null;
  }

  Rejection? _completion(_Ctx x) {
    final c = x.c;
    final choreId = (c.fields['chore'] ?? x.existing?.fields['chore']) as String?;
    final date = (c.fields['date'] ?? x.existing?.fields['date']) as String?;
    final choreEntry = choreId == null ? null : store.at(c.space, RecordType.chore, choreId);
    if (choreEntry == null || date == null) return _schema('That chore doesn\'t exist');
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
      if (status == RedemptionStatus.declined.name && !manager) {
        return _deny('${x.who} can\'t decline rewards');
      }
      if (status == RedemptionStatus.approved.name && reward.needsApproval && !manager) {
        return _deny('A parent needs to approve that reward');
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
    if (c.fields['decidedBy'] != null && c.fields['decidedBy'] != c.actor) {
      return _schema('A decision must name who made it');
    }
    return null;
  }

  Rejection? _connection(_Ctx x) {
    final c = x.c;
    final parent = x.actor?.isParent ?? false;
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
  });

  final Change c;
  final Device device;
  final Member? actor;
  final bool hub;
  final bool openCheckoff;
  final Family? family;
  final Entry? existing;

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

  bool only(Set<String> names) => c.fields.keys.every((k) => k == '_via' || k == '_from' || names.contains(k));
}
